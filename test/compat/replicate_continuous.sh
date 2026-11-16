#!/usr/bin/env bash
# continuous:true keeps polling the source and pulling new changes. A
# _replicator document may not name a local endpoint (CouchDB refuses that, and
# so do we), so the job is started through the transient /_replicate API, which
# both implementations allow to target a local database.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6034}
DATA="$TMP/data"
SPID=""
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_repl_cont" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_repl_cont" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_repl_cont" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_repl_cont/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"c1","v":1},{"_id":"c2","v":2}]}' >/dev/null

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
B="http://127.0.0.1:$PORT"
for _ in $(seq 1 100); do
  curl -fsS "$B/_up" >/dev/null 2>&1 && break
  sleep 0.05
done

curl -fsS -X PUT "$B/cont_target" >/dev/null
curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/zouch_repl_cont\",\"target\":\"cont_target\",\"continuous\":true}" >/dev/null

for _ in $(seq 1 40); do
  n=$(curl -sS "$B/cont_target/_all_docs" | jq -r .total_rows)
  [ "$n" = "2" ] && break
  sleep 0.25
done
[ "$n" = "2" ]

curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_repl_cont" -H 'content-type: application/json' \
  -d '{"_id":"c3","v":3}' >/dev/null
for _ in $(seq 1 60); do
  n=$(curl -sS "$B/cont_target/_all_docs" | jq -r .total_rows)
  [ "$n" = "3" ] && break
  sleep 0.25
done
[ "$n" = "3" ]

echo "PASS: continuous replication polling"
