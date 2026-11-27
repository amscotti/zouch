#!/usr/bin/env bash
# Regression tests for Phase 4 fixes (M1-M12): purge ancestor/views, _replicator lifecycle,
# authorization boundaries, delete during requests, bulk per-doc errors, clean JS docs & filter req,
# validate_doc_update secObj/unauthorized/DELETE, Mango binary search & explain, incremental counts, digest stubs.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
SPID=""
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
DATA2="$TMP/data2"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start_srv() {
  local d=$1 p=$2
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  wait "$SPID" 2>/dev/null || true
  SPID=""
  "$BIN" serve "$d" "$p" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$p/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start_srv "$DATA" "$PORT"
Z="http://127.0.0.1:$PORT"

# --- M1: _purge ancestor drops descendants, retained body, view rows, and updates stats ---
curl -fsS -X PUT "$Z/m1db" >/dev/null
R1=$(curl -fsS -X PUT "$Z/m1db/doc1" -H 'content-type: application/json' -d '{"v":1}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
R2=$(curl -fsS -X PUT "$Z/m1db/doc1" -H 'content-type: application/json' -d "{\"_rev\":\"$R1\",\"v\":2}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
curl -fsS -X PUT "$Z/m1db/_design/v" -H 'content-type: application/json' -d '{"views":{"by_v":{"map":"function(doc){emit(doc.v,doc._id);}"}}}' >/dev/null
# Also keep a retained body on doc2 and purge doc1 by ancestor R1
V_BEFORE=$(curl -fsS "$Z/m1db/_design/v/_view/by_v" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["rows"]))')
[ "$V_BEFORE" = "1" ]
P_RES=$(curl -fsS -X POST "$Z/m1db/_purge" -H 'content-type: application/json' -d "{\"doc1\":[\"$R1\"]}")
python3 - "$P_RES" "$R1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert sys.argv[2] in d["purged"]["doc1"], d
assert d["purge_seq"] >= 1, d
PY
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/m1db/doc1")" = "404" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/m1db/doc1?rev=$R1")" = "404" ]
V_AFTER=$(curl -fsS "$Z/m1db/_design/v/_view/by_v" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["rows"]))')
[ "$V_AFTER" = "0" ]
INFO=$(curl -fsS "$Z/m1db")
python3 - "$INFO" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["doc_count"] == 1, d  # only _design/v remains
assert d["doc_del_count"] == 0, d
PY

# --- M6: _bulk_docs per-doc error instead of aborting sibling docs ---
curl -fsS -X PUT "$Z/m6db" >/dev/null
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/m6db/_bulk_docs" -H 'content-type: text/plain' -d '{"docs":[]}')" = "415" ]
B_RES=$(curl -fsS -X POST "$Z/m6db/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"first","v":1},{"_id":"second","_attachments":{"nope":{"stub":true}}},{"_id":"third","v":3}]}')
python3 - "$B_RES" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert len(rows) == 3, rows
assert rows[0].get("ok") is True, rows[0]
assert rows[1].get("error") == "missing_stub", rows[1]
assert rows[2].get("ok") is True, rows[2]
PY
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/m6db/third")" = "200" ]

# --- M7 & M8: Clean JS docs (_id/_rev/clean _attachments), filter req.query, VDU secObj & unauthorized ---
curl -fsS -X PUT "$Z/m7db" >/dev/null
curl -fsS -X PUT "$Z/m7db/_security" -H 'content-type: application/json' -d '{"admins":{"names":["boss"],"roles":[]},"members":{"names":["alice"],"roles":[]}}' >/dev/null
curl -fsS -X PUT "$Z/m7db/_design/app" -H 'content-type: application/json' -d '{
  "views": {
    "meta": {"map": "function(doc){ var a=doc._attachments&&doc._attachments[\"a.txt\"]; emit(doc._id, {id:doc._id, has_rev:!!doc._rev, has_blob:!!(a&&\"blob\" in a), stub:!!(a&&a.stub), len:a?a.length:0}); }"}
  },
  "filters": {
    "by_kind": "function(doc, req){ return req && req.query && doc.kind === req.query.kind; }"
  },
  "validate_doc_update": "function(newDoc, oldDoc, userCtx, secObj){ if(!newDoc._id || (oldDoc && !newDoc._rev)) throw({forbidden:\"missing id/rev\"}); if(newDoc.need_auth) throw({unauthorized:\"login needed\"}); if(newDoc.check_sec && (!secObj || !secObj.admins || secObj.admins.names[0]!==\"boss\")) throw({forbidden:\"bad secObj\"}); }"
}' >/dev/null
D1=$(curl -fsS -X PUT "$Z/m7db/d1" -H 'content-type: application/json' -d '{"kind":"alpha","check_sec":true,"_attachments":{"a.txt":{"content_type":"text/plain","data":"aGVsbG8="}}}')
D1_REV=$(echo "$D1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
# M11 digest/length stub present
curl -fsS "$Z/m7db/d1" | python3 -c 'import sys,json;a=json.load(sys.stdin)["_attachments"]["a.txt"];assert a["length"]==5 and a["digest"].startswith("md5-")'
# View sees clean stub (no blob field) + _id + _rev
VIEW_ROW=$(curl -fsS "$Z/m7db/_design/app/_view/meta")
python3 - "$VIEW_ROW" <<'PY'
import json, sys
v = json.loads(sys.argv[1])["rows"][0]["value"]
assert v["id"] == "d1" and v["has_rev"] and not v["has_blob"] and v["stub"] and v["len"] == 5, v
PY
# VDU unauthorized returns 401
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/m7db/u1" -H 'content-type: application/json' -d '{"need_auth":true}')" = "401" ]
# DELETE passes _id and _rev to VDU
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$Z/m7db/d1?rev=$D1_REV")" = "200" ]
# Filter sees req.query
curl -fsS -X PUT "$Z/m7db/fa" -H 'content-type: application/json' -d '{"kind":"pick"}' >/dev/null
curl -fsS -X PUT "$Z/m7db/fb" -H 'content-type: application/json' -d '{"kind":"skip"}' >/dev/null
CH=$(curl -fsS "$Z/m7db/_changes?filter=app/by_kind&kind=pick")
python3 - "$CH" <<'PY'
import json, sys
ids = [r["id"] for r in json.loads(sys.argv[1])["results"]]
assert ids == ["fa"], ids
PY

# --- M9: Mango binary search range + _explain does not rewrite index ---
curl -fsS -X PUT "$Z/m9db" >/dev/null
curl -fsS -X POST "$Z/m9db/_index" -H 'content-type: application/json' -d '{"index":{"fields":["score"]},"name":"by_score"}' >/dev/null
for n in 10 20 30 40 50; do
  curl -fsS -X PUT "$Z/m9db/k$n" -H 'content-type: application/json' -d "{\"score\":$n}" >/dev/null
done
FIND_RES=$(curl -fsS -X POST "$Z/m9db/_find" -H 'content-type: application/json' -d '{"selector":{"score":{"$gte":20,"$lt":45}},"fields":["score"]}')
python3 - "$FIND_RES" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
scores = sorted(doc["score"] for doc in d["docs"])
assert scores == [20, 30, 40], (scores, d)
PY
IDX_FILE=$(ls "$DATA/m9db/indexes/"*.idx | head -n 1)
MTIME_BEFORE=$(stat -f '%m' "$IDX_FILE" 2>/dev/null || stat -c '%Y' "$IDX_FILE")
# Write one more doc then call _explain; explain must not rewrite index file
curl -fsS -X PUT "$Z/m9db/k60" -H 'content-type: application/json' -d '{"score":60}' >/dev/null
sleep 1.1
EXP=$(curl -fsS -X POST "$Z/m9db/_explain" -H 'content-type: application/json' -d '{"selector":{"score":{"$eq":30}}}')
python3 - "$EXP" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["index"]["type"] == "json" and d["index"]["name"] == "by_score", d
PY
MTIME_AFTER=$(stat -f '%m' "$IDX_FILE" 2>/dev/null || stat -c '%Y' "$IDX_FILE")
[ "$MTIME_BEFORE" = "$MTIME_AFTER" ]

# --- M2: _replicator rerun on update + continuous _replicate preserves opts ---
curl -fsS -X PUT "$Z/rep_src" >/dev/null
curl -fsS -X PUT "$Z/rep_dst" >/dev/null
curl -fsS -X PUT "$Z/rep_src/d1" -H 'content-type: application/json' -d '{"v":1}' >/dev/null
REP_R1=$(curl -fsS -X PUT "$Z/_replicator/job1" -H 'content-type: application/json' -d "{\"source\":\"$Z/rep_src\",\"target\":\"$Z/rep_dst\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
for _ in $(seq 1 40); do
  ST=$(curl -fsS "$Z/_replicator/job1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("_replication_state",""))')
  [ "$ST" = "completed" ] && break
  sleep 0.2
done
[ "$ST" = "completed" ]
[ "$(curl -fsS "$Z/rep_dst/d1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["v"])')" = "1" ]
curl -fsS -X PUT "$Z/rep_src/d2" -H 'content-type: application/json' -d '{"v":2}' >/dev/null
JDOC=$(curl -fsS "$Z/_replicator/job1")
JREV=$(echo "$JDOC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X PUT "$Z/_replicator/job1" -H 'content-type: application/json' -d "{\"_rev\":\"$JREV\",\"source\":\"$Z/rep_src\",\"target\":\"$Z/rep_dst\",\"note\":\"rerun\"}" >/dev/null
for _ in $(seq 1 40); do
  [ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/rep_dst/d2")" = "200" ] && break
  sleep 0.2
done
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/rep_dst/d2")" = "200" ]
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$Z/rep_src\",\"target\":\"$Z/rep_dst\",\"continuous\":true,\"worker_batch_size\":42,\"use_checkpoints\":false}" >/dev/null
curl -fsS "$Z/_replicator" >/dev/null
# Check preserved options in continuous doc
CONT_ID=$(curl -fsS "$Z/_replicator/_all_docs?include_docs=true" | python3 -c 'import sys,json;docs=[r["doc"] for r in json.load(sys.stdin)["rows"] if r["doc"].get("worker_batch_size")==42];assert len(docs)==1 and docs[0].get("use_checkpoints") is False;print(docs[0]["_id"])')
[ -n "$CONT_ID" ]

# --- M4/M5: DELETE /{db} succeeds while concurrent GETs hit db ---
curl -fsS -X PUT "$Z/delme" >/dev/null
for i in $(seq 1 50); do curl -fsS -X PUT "$Z/delme/d$i" -H 'content-type: application/json' -d "{\"i\":$i}" >/dev/null; done
( for _ in $(seq 1 30); do curl -sS "$Z/delme/_all_docs" >/dev/null || true; done ) &
READ_PID=$!
sleep 0.02
DCODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$Z/delme")
wait "$READ_PID" || true
[ "$DCODE" = "200" ]

# --- M3: Auth boundaries (_utils unauth, _design/compact/_replicator forbidden for member, comma role rejected, cluster_setup persists across restart) ---
start_srv "$DATA2" "$PORT2"
Z2="http://127.0.0.1:$PORT2"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z2/_cluster_setup" -H 'content-type: application/json' -d '{"action":"enable_single_node","username":"admin1","password":"pw1"}')" = "200" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z2/_all_dbs")" = "401" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z2/_utils/")" = "200" ]
# Bad role containing comma rejected
[ "$(curl -sS -u admin1:pw1 -o /dev/null -w '%{http_code}' -X PUT "$Z2/_users/org.couchdb.user:badrole" -H 'content-type: application/json' -d '{"name":"badrole","type":"user","roles":["x,_admin"],"password":"pw"}')" = "400" ]
curl -fsS -u admin1:pw1 -X PUT "$Z2/_users/org.couchdb.user:alice" -H 'content-type: application/json' -d '{"name":"alice","type":"user","roles":[],"password":"pw"}' >/dev/null
curl -fsS -u admin1:pw1 -X PUT "$Z2/priv" >/dev/null
curl -fsS -u admin1:pw1 -X PUT "$Z2/priv/_security" -H 'content-type: application/json' -d '{"admins":{"names":["admin1"],"roles":[]},"members":{"names":["alice"],"roles":[]}}' >/dev/null
[ "$(curl -sS -u alice:pw -o /dev/null -w '%{http_code}' -X PUT "$Z2/priv/_design/evil" -H 'content-type: application/json' -d '{"validate_doc_update":"function(){}" }')" = "403" ]
[ "$(curl -sS -u alice:pw -o /dev/null -w '%{http_code}' -X POST "$Z2/priv/_compact")" = "403" ]
[ "$(curl -sS -u alice:pw -o /dev/null -w '%{http_code}' "$Z2/_replicator/_all_docs")" = "403" ]
[ "$(curl -sS -u alice:pw -o /dev/null -w '%{http_code}' "$Z2/priv")" = "200" ]
# Restart server on DATA2: cluster_setup admin1 must still be required!
start_srv "$DATA2" "$PORT2"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z2/_all_dbs")" = "401" ]
[ "$(curl -sS -u admin1:pw1 -o /dev/null -w '%{http_code}' "$Z2/_all_dbs")" = "200" ]

echo "PASS: Phase 4 regressions (M1-M11)"
