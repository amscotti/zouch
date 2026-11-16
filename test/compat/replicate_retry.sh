#!/usr/bin/env bash
# A failed one-shot _replicator job must stay retryable, not be marked completed.
# The source is deliberately unavailable first, then started; backoff must retry it.
set -euo pipefail

cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP="$(mktemp -d /tmp/zouch-repl-retry.XXXXXX)"
PORT="${PORT:-6041}"
SRC_PORT=$((PORT + 1))
DATA="$TMP/target"
SRC_DATA="$TMP/source"
PID=""
SRC_PID=""

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- target log" >&2
    cat "$TMP/target.log" >&2 2>/dev/null || true
    echo "--- source log" >&2
    cat "$TMP/source.log" >&2 2>/dev/null || true
  fi
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
  [ -n "$SRC_PID" ] && kill -9 "$SRC_PID" 2>/dev/null || true
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT

start_target() {
  "$BIN" serve "$DATA" "$PORT" >"$TMP/target.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  cat "$TMP/target.log" >&2
  return 1
}

start_target
B="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$B/retry_target" >/dev/null
# A replication document may not name a local endpoint (CouchDB refuses that and
# so do we), so the job is started through the transient API, which stores the
# same scheduler job and returns its id.
job=$(curl -fsS -X POST "$B/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://127.0.0.1:$SRC_PORT/src\",\"target\":\"retry_target\",\"continuous\":true}" | jq -r ._local_id)
[ -n "$job" ] && [ "$job" != "null" ]

# The source is down: the first attempt must record an error, not completion.
state=""
for _ in $(seq 1 40); do
  state="$(curl -sS "$B/_replicator/$job" | jq -r '._replication_state // empty')"
  [ "$state" = "error" ] && break
  sleep 0.25
done
if [ "$state" != "error" ]; then
  echo "FAIL: failed replication state was '$state', expected 'error'" >&2
  curl -sS "$B/_replicator/$job" >&2 || true
  exit 1
fi

# Restart the target: the failure count is persisted, so backoff must survive
# the restart rather than resetting and immediately hammering the source.
kill -9 "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
start_target

# Now make the source available. The scheduler must retry after its backoff.
"$BIN" serve "$SRC_DATA" "$SRC_PORT" >"$TMP/source.log" 2>&1 &
SRC_PID=$!
S="http://127.0.0.1:$SRC_PORT"
for _ in $(seq 1 100); do
  curl -fsS "$S/_up" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS -X PUT "$S/src" >/dev/null
curl -fsS -X POST "$S/src/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"r1","v":1},{"_id":"r2","v":2}]}' >/dev/null

n=0
for _ in $(seq 1 60); do
  n="$(curl -sS "$B/retry_target/_all_docs" | jq -r .total_rows)"
  [ "$n" = "2" ] && break
  sleep 0.5
done
if [ "$n" != "2" ]; then
  echo "FAIL: target did not converge after retry (rows=$n)" >&2
  curl -sS "$B/_replicator/$job" >&2 || true
  exit 1
fi
# A continuous job keeps running once it recovers, so the check is the data it
# delivered, not a completion state a one-shot job would have recorded.
state="$(curl -sS "$B/_replicator/$job" | jq -r '._replication_state // empty')"
case "$state" in
  triggered|completed) ;;
  *) echo "FAIL: final state '$state', expected triggered or completed" >&2; exit 1 ;;
esac
echo "PASS: failed replication job retried with backoff and recovered"
