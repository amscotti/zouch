#!/usr/bin/env bash
# `use_checkpoints: false` means no `_local` revision is read or written, so a
# repeat starts from the beginning - CouchDB leaves no `_local` document behind
# in that case, and neither should we. `_local_docs` is how that is observed.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
TMP=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
SPID=""
COUCH=${COUCH:-http://127.0.0.1:5984}
AUTH=${AUTH:-admin:zouchtestpw}
SRC=zouch_knobs_src

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  pkill -f "zouch serve $DATA" 2>/dev/null
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$SRC" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

curl -fsS -u "$AUTH" -X DELETE "$COUCH/$SRC" >/dev/null 2>&1
curl -fsS -u "$AUTH" -X PUT "$COUCH/$SRC" >/dev/null || { echo "FAIL: no CouchDB at $COUCH"; exit 1; }
curl -fsS -u "$AUTH" -X POST "$COUCH/$SRC/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"k1"},{"_id":"k2"}]}' >/dev/null

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
Z="http://127.0.0.1:$PORT"
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.05
done

rows() { curl -sS "$Z/$1/_local_docs" | jq -r '.rows | length'; }

curl -fsS -X PUT "$Z/with_ck" >/dev/null
curl -fsS -X PUT "$Z/without_ck" >/dev/null
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/$SRC\",\"target\":\"with_ck\"}" >/dev/null
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/$SRC\",\"target\":\"without_ck\",\"use_checkpoints\":false}" >/dev/null

[ "$(rows with_ck)" = "1" ] || { echo "FAIL: default pull left $(rows with_ck) checkpoints, expected 1"; exit 1; }
[ "$(rows without_ck)" = "0" ] || { echo "FAIL: use_checkpoints:false left $(rows without_ck) checkpoints, expected 0"; exit 1; }
# CouchDB reports null for both, not a count.
curl -sS "$Z/with_ck/_local_docs" | jq -e '.total_rows == null and .offset == null' >/dev/null \
  || { echo "FAIL: _local_docs reported a total"; exit 1; }
[ "$(curl -sS "$Z/with_ck/_all_docs" | jq -r .total_rows)" = "2" ] || { echo "FAIL: documents did not arrive"; exit 1; }

# Both targets have the documents: the knob changes checkpointing, not copying.
[ "$(curl -sS "$Z/without_ck/_all_docs" | jq -r .total_rows)" = "2" ] || { echo "FAIL: documents missing without checkpoints"; exit 1; }

echo "PASS: use_checkpoints is honoured"
