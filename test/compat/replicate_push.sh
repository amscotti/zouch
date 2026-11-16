#!/usr/bin/env bash
# One-shot push from a local Zouch database to CouchDB.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6036}
DATA="$TMP/data"
SPID=""
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_push_cli" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start
B="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$B/push_src" >/dev/null
curl -fsS -X POST "$B/push_src/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"p1","v":1},{"_id":"p2","v":2}]}' >/dev/null
REV=$(curl -sS "$B/push_src/p1" | jq -r ._rev)
curl -fsS -X PUT "$B/push_src/p1" -H 'content-type: application/json' \
  -d "{\"_rev\":\"$REV\",\"v\":11}" >/dev/null
kill -9 "$SPID" 2>/dev/null || true
SPID=""

curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_push_cli" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_push_cli" >/dev/null
"$BIN" push "http://$AUTH@127.0.0.1:5984/zouch_push_cli" push_src "$DATA" >/dev/null

[ "$(curl -sS -u "$AUTH" "$COUCH/zouch_push_cli/_all_docs" | jq -r .total_rows)" = "2" ]
[ "$(curl -sS -u "$AUTH" "$COUCH/zouch_push_cli/p1" | jq -r .v)" = "11" ]
[ "$(curl -sS -u "$AUTH" "$COUCH/zouch_push_cli/p2" | jq -r .v)" = "2" ]

# HTTP push through /_replicate.
start
B="http://127.0.0.1:$PORT"
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_push_http" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_push_http" >/dev/null
REP=$(curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"push_src\",\"target\":\"http://$AUTH@127.0.0.1:5984/zouch_push_http\"}")
[ "$(echo "$REP" | jq -r .documents)" = "2" ]
[ "$(curl -sS -u "$AUTH" "$COUCH/zouch_push_http/_all_docs" | jq -r .total_rows)" = "2" ]

# A conflicting local leaf must reach the target as a conflict, not disappear.
R=$(curl -sS "$B/push_src/p1" | jq -r ._rev)
R1=$(curl -sS "$B/push_src/p1?revs=true" | jq -r '._revisions.ids[-1]')
curl -fsS -X POST "$B/push_src/_bulk_docs" -H 'content-type: application/json' \
  -d "{\"new_edits\":false,\"docs\":[{\"_id\":\"p1\",\"_rev\":\"2-cccccccccccccccccccccccccccccccc\",\"v\":77,\"_revisions\":{\"start\":2,\"ids\":[\"cccccccccccccccccccccccccccccccc\",\"$R1\"]}}]}" >/dev/null
REP2=$(curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"push_src\",\"target\":\"http://$AUTH@127.0.0.1:5984/zouch_push_http\"}")
[ "$(echo "$REP2" | jq -r .documents)" = "1" ]
[ "$(curl -sS -u "$AUTH" "$COUCH/zouch_push_http/p1?conflicts=true" | jq -r '._conflicts | length')" = "1" ]

# _replicator-driven push to a remote target.
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_push_sched" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_push_sched" >/dev/null
curl -fsS -X PUT "$B/push_sched_src" >/dev/null
curl -fsS -X POST "$B/push_sched_src/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"q1","v":1}]}' >/dev/null
# A replication document may not name a local endpoint (CouchDB refuses it), so
# the push goes through the transient API, which accepts one.
curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"push_sched_src\",\"target\":\"http://$AUTH@127.0.0.1:5984/zouch_push_sched\"}" >/dev/null
for _ in $(seq 1 40); do
  n=$(curl -sS -u "$AUTH" "$COUCH/zouch_push_sched/_all_docs" | jq -r .total_rows)
  [ "$n" = "1" ] && break
  sleep 0.25
done
[ "$n" = "1" ]

echo "PASS: one-shot push replication to CouchDB"
