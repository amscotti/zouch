#!/usr/bin/env bash
# Regression & compatibility tests for Phase 5 (§6 compat fixes) and Phase 7 (P2, P13).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
SPID=""
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start_srv() {
  local d=$1 p=$2
  shift 2
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  wait "$SPID" 2>/dev/null || true
  SPID=""
  env "$@" "$BIN" serve "$d" "$p" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$p/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start_srv "$DATA" "$PORT" ZOUCH_VECTOR_INDEX_MB=0
Z="http://127.0.0.1:$PORT"

# --- S6-1: PUT /{db} twice returns 412 file_exists ---
st1=$(curl -sS -o "$TMP/r1" -w '%{http_code}' -X PUT "$Z/s6db")
st2=$(curl -sS -o "$TMP/r2" -w '%{http_code}' -X PUT "$Z/s6db")
[ "$st1" = "201" ] && [ "$st2" = "412" ]
grep -q '"file_exists"' "$TMP/r2"

# --- S6-2: DB name & doc id validation ---
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/Bad_Name")" = "400" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/s6db/_private" -H 'content-type: application/json' -d '{"v":1}')" = "400" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/s6db/_local%2Fabc" -H 'content-type: application/json' -d '{"v":1}')" = "400" ]
bulk_bad=$(curl -sS -X POST "$Z/s6db/_bulk_docs" -H 'content-type: application/json' -d '{"docs":[{"_id":"_local/x","v":1}]}')
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d[0]["error"]=="bad_request"' "$bulk_bad"

# --- S6-4, S6-6, S6-7, S6-8: ETag/304, open_revs latest=true, _missing_revs ancestor, clean retained body ---
att_b64=$(python3 -c 'import base64;print(base64.b64encode(b"hello-att").decode())')
r1=$(curl -fsS -X PUT "$Z/s6db/d1" -H 'content-type: application/json' -d "{\"k\":1,\"_attachments\":{\"a.txt\":{\"content_type\":\"text/plain\",\"data\":\"$att_b64\"}}}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rev"])')
r2=$(curl -fsS -X PUT "$Z/s6db/d1" -H 'content-type: application/json' -d "{\"_rev\":\"$r1\",\"k\":2}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rev"])')

hdrs=$(curl -sS -D - -o "$TMP/doc.json" "$Z/s6db/d1")
echo "$hdrs" | grep -iq "^etag: \"$r2\""
echo "$hdrs" | grep -iq "^cache-control: must-revalidate"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "If-None-Match: \"$r2\"" "$Z/s6db/d1")" = "304" ]

or_res=$(curl -fsS "$Z/s6db/d1?open_revs=%5B%221-00000000000000000000000000000000%22%5D&latest=true")
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert len(d)==1 and "missing" in d[0]' "$or_res"

mr_res=$(curl -fsS -X POST "$Z/s6db/_missing_revs" -H 'content-type: application/json' -d "{\"d1\":[\"$r1\"]}")
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["missing_revs"]=={}' "$mr_res"

ret_get=$(curl -fsS "$Z/s6db/d1?rev=$r1&revs=true")
ret_bg=$(curl -fsS -X POST "$Z/s6db/_bulk_get?revs=true" -H 'content-type: application/json' -d "{\"docs\":[{\"id\":\"d1\",\"rev\":\"$r1\"}]}")
python3 -c '
import json,sys
d1=json.loads(sys.argv[1])
assert d1["_rev"]==sys.argv[3] and "_revisions" in d1
att=d1["_attachments"]["a.txt"]
assert att.get("stub") is True and "blob" not in att and "data" not in att
bg=json.loads(sys.argv[2])["results"][0]["docs"][0]["ok"]
assert bg["_rev"]==sys.argv[3] and "_revisions" in bg
att2=bg["_attachments"]["a.txt"]
assert att2.get("stub") is True and "blob" not in att2 and "data" not in att2
' "$ret_get" "$ret_bg" "$r1"

# --- S6-9: _revs_limit enforced ---
curl -fsS -X PUT "$Z/s6db/_revs_limit" -H 'content-type: application/json' -d '2' >/dev/null
rr=$r2
for n in 3 4 5; do
  rr=$(curl -fsS -X PUT "$Z/s6db/d1" -H 'content-type: application/json' -d "{\"_rev\":\"$rr\",\"k\":$n}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rev"])')
done
revs_len=$(curl -fsS "$Z/s6db/d1?revs=true" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["_revisions"]["ids"]))')
[ "$revs_len" = "2" ]
curl -fsS -X PUT "$Z/s6db/_revs_limit" -H 'content-type: application/json' -d '1005' >/dev/null
[ "$(curl -fsS "$Z/s6db/_revs_limit")" = "1005" ]

# --- S6-10, S6-11, S6-12, S6-20: _all_docs keys/POST opts, non-string key error, view POST opts & total_rows ---
curl -fsS -X PUT "$Z/s6db/a" -H 'content-type: application/json' -d '{"grp":"x"}' >/dev/null
curl -fsS -X PUT "$Z/s6db/b" -H 'content-type: application/json' -d '{"grp":"x"}' >/dev/null
curl -fsS -X PUT "$Z/s6db/c" -H 'content-type: application/json' -d '{"grp":"y"}' >/dev/null

ad_get_keys=$(curl -fsS "$Z/s6db/_all_docs?keys=%5B%22a%22,%22c%22%5D")
ad_post_opts=$(curl -fsS -X POST "$Z/s6db/_all_docs" -H 'content-type: application/json' -d '{"limit":1,"skip":1}')
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/s6db/_all_docs" -H 'content-type: application/json' -d '{"keys":[123]}')" = "400" ]
python3 -c '
import json,sys
g=json.loads(sys.argv[1])
assert [r["id"] for r in g["rows"]]==["a","c"]
p=json.loads(sys.argv[2])
assert len(p["rows"])==1 and p["offset"]==1
' "$ad_get_keys" "$ad_post_opts"

curl -fsS -X PUT "$Z/s6db/_design/dd" -H 'content-type: application/json' \
  -d '{"views":{"by_grp":{"map":"function(doc){if(doc.grp)emit(doc.grp,1);}","reduce":"_count"}}}' >/dev/null
vw_post=$(curl -fsS -X POST "$Z/s6db/_design/dd/_view/by_grp" -H 'content-type: application/json' \
  -d '{"reduce":false,"limit":1,"skip":1,"include_docs":true}')
vw_key=$(curl -fsS "$Z/s6db/_design/dd/_view/by_grp?reduce=false&key=%22y%22")
python3 -c '
import json,sys
vp=json.loads(sys.argv[1])
assert vp["total_rows"]==3 and vp["offset"]==1 and len(vp["rows"])==1
assert vp["rows"][0]["doc"]["_id"]=="b"
vk=json.loads(sys.argv[2])
assert vk["total_rows"]==3 and len(vk["rows"])==1 and vk["rows"][0]["id"]=="c"
' "$vw_post" "$vw_key"

# --- S6-19: _explain with quote in field name ---
curl -fsS -X POST "$Z/s6db/_index" -H 'content-type: application/json' -d '{"index":{"fields":["a\"b"]},"name":"q_idx"}' >/dev/null
exp_json=$(curl -fsS -X POST "$Z/s6db/_explain" -H 'content-type: application/json' -d '{"selector":{"a\"b":1}}')
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert list(d["index"]["def"]["fields"][0].keys())[0]=="a\"b"' "$exp_json"

# --- S6-21: _local id > 504 chars keeps _local/ prefix ---
long_id=$(python3 -c 'print("x"*520)')
lp_res=$(curl -fsS -X PUT "$Z/s6db/_local/$long_id" -H 'content-type: application/json' -d '{"ok":1}')
lg_res=$(curl -fsS "$Z/s6db/_local/$long_id")
lrev=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); g=json.loads(sys.argv[2]); assert d["id"]=="_local/"+sys.argv[3] and g["_id"]=="_local/"+sys.argv[3]; print(d["rev"])' "$lp_res" "$lg_res" "$long_id")
ld_res=$(curl -fsS -X DELETE "$Z/s6db/_local/$long_id?rev=$lrev")
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["id"]=="_local/"+sys.argv[2]' "$ld_res" "$long_id"

# --- S6-25: _index ddoc prefix & idempotency ---
idx1=$(curl -fsS -X POST "$Z/s6db/_index" -H 'content-type: application/json' -d '{"index":{"fields":["grp"]},"ddoc":"_design/myddoc","name":"grp_idx"}')
idx2=$(curl -fsS -X POST "$Z/s6db/_index" -H 'content-type: application/json' -d '{"index":{"fields":["grp"]},"ddoc":"_design/myddoc","name":"grp_idx"}')
st_diff=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/s6db/_index" -H 'content-type: application/json' -d '{"index":{"fields":["other"]},"ddoc":"_design/myddoc","name":"grp_idx"}')
python3 -c '
import json,sys
i1=json.loads(sys.argv[1]); i2=json.loads(sys.argv[2])
assert i1["id"]=="_design/myddoc" and i1["result"]=="created"
assert i2["id"]=="_design/myddoc" and i2["result"]=="exists"
' "$idx1" "$idx2"
[ "$st_diff" = "400" ]

# --- S6-31: _security invalid object -> 400 ---
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/s6db/_security" -H 'content-type: application/json' -d '{"members":"bad"}')" = "400" ]

# --- S6-15: ZOUCH_VECTOR_INDEX_MB=0 means unlimited ---
curl -fsS -X PUT "$Z/s6db/vdoc" -H 'content-type: application/json' -d '{"embedding_b64":"AACAPwAAAD8AAIA+AAAAPg=="}' >/dev/null
vec_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/s6db/_vector_search" -H 'content-type: application/json' -d '{"vector":[1.0,0.0,0.0,0.0],"k":1,"engine":"hnsw"}')
[ "$vec_code" = "200" ]

# --- P13: Mango $regex repeated matches (cached bytecode) ---
for _ in 1 2 3; do
  rx=$(curl -fsS -X POST "$Z/s6db/_find" -H 'content-type: application/json' -d '{"selector":{"grp":{"$regex":"^y$"}}}')
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert [x["_id"] for x in d["docs"]]==["c"]' "$rx"
done

# --- S6-35 & P2: long username (>239 chars) + _users cache invalidation ---
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/_all_dbs")" = "200" ]
curl -fsS -X PUT "$Z/_users" >/dev/null
long_user=$(python3 -c 'print("u"*245)')
u_put=$(curl -sS -o "$TMP/up.json" -w '%{http_code}' -X PUT "$Z/_users/org.couchdb.user:$long_user" -H 'content-type: application/json' \
  -d "{\"_id\":\"org.couchdb.user:$long_user\",\"name\":\"$long_user\",\"type\":\"user\",\"roles\":[\"_admin\"],\"password\":\"secret\"}")
[ "$u_put" = "201" ]
urev=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rev"])' "$TMP/up.json")
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/_all_dbs")" = "401" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -u "$long_user:secret" "$Z/_all_dbs")" = "200" ]
curl -fsS -u "$long_user:secret" -X POST "$Z/_users/_purge" -H 'content-type: application/json' \
  -d "{\"org.couchdb.user:$long_user\":[\"$urev\"]}" >/dev/null
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/_all_dbs")" = "200" ]

echo "phase5_compat: all checks passed"
