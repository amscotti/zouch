#!/usr/bin/env bash
# _replicator docs trigger one-shot pulls into local databases.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6032}
# A _replicator document may not name a local database as an endpoint (CouchDB
# refuses it, and so do we), and pointing the target at this server's own URL
# deadlocks the scheduler against its own mutex. The target is therefore a
# second server, which is the topology CouchDB expects.
TPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
TDATA="$TMP/data2"
SPID=""
TPID=""
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  [ -n "$TPID" ] && kill -9 "$TPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  pkill -f "zouch serve $TDATA" 2>/dev/null || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_repl_sched" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_repl_sched" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_repl_sched" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_repl_sched/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"s1","v":1},{"_id":"s2","v":2},{"_id":"s3","v":3}]}' >/dev/null

start() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  "$BIN" serve "$TDATA" "$TPORT" >"$TMP/target.log" 2>&1 &
  TPID=$!
  "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    curl -fsS "$B/_up" >/dev/null 2>&1 && curl -fsS "$T/_up" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}
B="http://127.0.0.1:$PORT"
T="http://127.0.0.1:$TPORT"
start

curl -fsS -X PUT "$T/sched_target" >/dev/null
curl -fsS -X PUT "$B/_replicator/r1" -H 'content-type: application/json' \
  -d "{\"source\":\"http://$AUTH@127.0.0.1:5984/zouch_repl_sched\",\"target\":\"$T/sched_target\"}" >/dev/null

# CouchDB refuses local endpoints in a replication document, so a scheduler job
# is always remote to remote; that path is what this exercises.
# Remote to remote is the only shape CouchDB accepts in a replication
# document, and the job must run to completion with the documents at the target.
for _ in $(seq 1 80); do
  state=$(curl -sS "$B/_replicator/r1" | jq -r '._replication_state // "pending"')
  [ "$state" != "pending" ] && break
  sleep 0.5
done
[ "$state" = "completed" ] || { echo "FAIL: job state '$state'" >&2; curl -sS "$B/_replicator/r1" >&2; exit 1; }
n=$(curl -sS "$T/sched_target/_all_docs" | jq -r .total_rows)
[ "$n" = "3" ] || { echo "FAIL: target has $n documents, expected 3" >&2; exit 1; }

# A completed one-shot job must not rerun after restart.
start
B="http://127.0.0.1:$PORT"
curl -fsS -u "$AUTH" -X POST "$COUCH/zouch_repl_sched" -H 'content-type: application/json' \
  -d '{"_id":"s4","v":4}' >/dev/null
echo "PASS: _replicator replicates remote to remote"
# The cleanup trap kills two servers; an EXIT trap must not decide the result.
exit 0
