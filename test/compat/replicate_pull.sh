#!/usr/bin/env bash
# One-shot pull replication from CouchDB into a local Zouch database.
# Requires CouchDB on :5984 (admin:zouchtestpw by default).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6029}
DATA="$TMP/data"
SPID=""
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_pull_cli" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_pull_cli" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_pull_cli" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_pull_cli/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"p1","v":1},{"_id":"p2","v":2}]}' >/dev/null

"$BIN" pull "http://$AUTH@127.0.0.1:5984/zouch_pull_cli" pull_test "$DATA" >/dev/null

start() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}
start
B="http://127.0.0.1:$PORT"
[ "$(curl -sS "$B/pull_test/_all_docs" | jq -r .total_rows)" = "2" ]
[ "$(curl -sS "$B/pull_test/p1" | jq -r .v)" = "1" ]
curl -fsS -X PUT "$B/pull_http" >/dev/null
REP=$(curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/zouch_pull_cli\",\"target\":\"pull_http\"}")
[ "$(echo "$REP" | jq -r .documents)" = "2" ]
[ "$(curl -sS "$B/pull_http/_all_docs" | jq -r .total_rows)" = "2" ]

curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_pull_cli/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"f1","keep":true},{"_id":"f2","keep":false}]}' >/dev/null
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_pull_cli/_design/f" -H 'content-type: application/json' \
  -d '{"filters":{"only_keep":"function(doc, req) { return doc.keep === true; }"}}' >/dev/null
curl -fsS -X PUT "$B/filter_target" >/dev/null
REPF=$(curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/zouch_pull_cli\",\"target\":\"filter_target\",\"filter\":\"f/only_keep\"}")
[ "$(echo "$REPF" | jq -r .documents)" = "1" ]
[ "$(curl -sS "$B/filter_target/_all_docs" | jq -r '[.rows[].id] | join(",")')" = "f1" ]

REV=$(curl -sS -u "$AUTH" "$COUCH/zouch_pull_cli/p1" | jq -r ._rev)
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_pull_cli/p1" -H 'content-type: application/json' \
  -d "{\"_rev\":\"$REV\",\"v\":99}" >/dev/null
REV2=$(curl -sS -u "$AUTH" "$COUCH/zouch_pull_cli/p2" | jq -r ._rev)
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_pull_cli/p2?rev=$REV2" >/dev/null

# The CLI owns the database while it runs; restart the server afterwards.
kill -9 "$SPID" 2>/dev/null || true
for _ in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.02; done
SPID=""
"$BIN" pull "http://$AUTH@127.0.0.1:5984/zouch_pull_cli" pull_test "$DATA" >/dev/null
start
[ "$(curl -sS "$B/pull_test/p1" | jq -r .v)" = "99" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$B/pull_test/p2")" = "404" ]
[ "$(curl -sS "$B/pull_test/_all_docs" | jq -r .total_rows)" = "4" ]

echo "PASS: one-shot pull replication from CouchDB"
