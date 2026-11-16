#!/usr/bin/env bash
# A pull fetches the revisions it lacks through `_bulk_get`, a page at a time,
# rather than one GET per document - and reports the two counters CouchDB
# publishes in `_scheduler/docs`: bulk_get_attempts and bulk_get_docs.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
TMP=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
SPID=""
COUCH=${COUCH:-http://127.0.0.1:5984}
AUTH=${AUTH:-admin:zouchtestpw}
SRC=zouch_bulk_src
TGT=zouch_bulk_tgt
DOCS=600

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  pkill -f "zouch serve $DATA" 2>/dev/null
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$SRC" >/dev/null 2>&1
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$TGT" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

for db in "$SRC" "$TGT"; do
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$db" >/dev/null 2>&1
done
curl -fsS -u "$AUTH" -X PUT "$COUCH/$SRC" >/dev/null || { echo "FAIL: no CouchDB at $COUCH"; exit 1; }
curl -fsS -u "$AUTH" -X PUT "$COUCH/$TGT" >/dev/null

# More documents than one page, so the pull must batch at least twice.
python3 - "$COUCH" "$AUTH" "$SRC" "$DOCS" <<'PY'
import base64, json, sys, urllib.request
couch, auth, db, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
h = {"authorization": "Basic " + base64.b64encode(auth.encode()).decode(), "content-type": "application/json"}
for start in range(0, n, 200):
    body = json.dumps({"docs": [{"_id": "d%d" % i, "v": i} for i in range(start, min(start + 200, n))]}).encode()
    req = urllib.request.Request("%s/%s/_bulk_docs" % (couch, db), data=body, method="POST")
    for k, v in h.items():
        req.add_header(k, v)
    urllib.request.urlopen(req).read()
PY

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1 && break
  sleep 0.1
done

curl -fsS -X PUT "http://127.0.0.1:$PORT/_replicator/bulkjob" \
  -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/$SRC\",\"target\":\"http://$AUTH@127.0.0.1:5984/$TGT\"}" >/dev/null

STATE=""
for _ in $(seq 1 160); do
  STATE=$(curl -fsS "http://127.0.0.1:$PORT/_replicator/bulkjob" 2>/dev/null |
    python3 -c 'import json,sys;print(json.load(sys.stdin).get("_replication_state",""))' 2>/dev/null)
  [ "$STATE" = "completed" ] && break
  [ "$STATE" = "error" ] && break
  sleep 0.5
done
[ "$STATE" = "completed" ] || { echo "FAIL: job ended '$STATE'"; tail -5 "$TMP/server.log"; exit 1; }

INFO=$(curl -fsS "http://127.0.0.1:$PORT/_scheduler/docs" |
  python3 -c 'import json,sys
docs=[d for d in json.load(sys.stdin)["docs"] if d["doc_id"]=="bulkjob"]
print(json.dumps(docs[0]["info"]) if docs else "{}")')

echo "info: $INFO"
python3 - "$INFO" "$DOCS" <<'PY'
import json, sys
info, n = json.loads(sys.argv[1]), int(sys.argv[2])
attempts, docs = info.get("bulk_get_attempts", 0), info.get("bulk_get_docs", 0)
if attempts < 2:
    print("FAIL: %d bulk_get attempt(s) for %d documents" % (attempts, n))
    raise SystemExit(1)
if docs != n:
    print("FAIL: bulk_get_docs %d, expected %d" % (docs, n))
    raise SystemExit(1)
if info.get("docs_written") != n:
    print("FAIL: docs_written %s, expected %d" % (info.get("docs_written"), n))
    raise SystemExit(1)
PY
[ $? -eq 0 ] || exit 1

GOT=$(curl -fsS -u "$AUTH" "$COUCH/$TGT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["doc_count"])')
[ "$GOT" = "$DOCS" ] || { echo "FAIL: target has $GOT documents, expected $DOCS"; exit 1; }
echo "PASS: pulled $DOCS documents through _bulk_get"
