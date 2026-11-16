#!/usr/bin/env bash
# Calibration for the batched _bulk_docs path: the single fsync at the end of the
# request must fail closed, and no document from the batch may survive a restart.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5974}
PORT2=$((PORT + 1))
PORT3=$((PORT + 2))
DATA="$TMP/data"
LOG="$TMP/server.log"
TRACE="$TMP/trace"

cleanup() {
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  local port=$1
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  echo "server did not become ready" >&2
  return 1
}

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
if ! wait_ready "$PORT"; then cat "$LOG" >&2; exit 1; fi
curl -fsS -X PUT "http://127.0.0.1:$PORT/bulk_fsync" >/dev/null
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true

strace -f -e trace=fsync -e inject=fsync:error=EIO:when=1 -o "$TRACE" \
  "$BIN" serve "$DATA" "$PORT2" >"$LOG" 2>&1 &
SPID=$!
if ! wait_ready "$PORT2"; then cat "$LOG" >&2; exit 1; fi

STATUS=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X POST \
  "http://127.0.0.1:$PORT2/bulk_fsync/_bulk_docs" \
  -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"b1","v":1},{"_id":"b2","v":2},{"_id":"b3","v":3}]}')
if [ "$STATUS" -lt 500 ]; then
  echo "FAIL: bulk fsync failure was acknowledged with HTTP $STATUS" >&2
  cat "$TMP/body" >&2
  exit 1
fi
if ! grep -q "internal_server_error" "$TMP/body"; then
  echo "FAIL: bulk error response was not JSON" >&2
  cat "$TMP/body" >&2
  exit 1
fi
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
pkill -f "zouch serve $DATA" 2>/dev/null || true

# The WAL records were written before the failed sync; a power cut discards them.
: >"$DATA/bulk_fsync/wal.log"
"$BIN" serve "$DATA" "$PORT3" >"$LOG" 2>&1 &
SPID=$!
if ! wait_ready "$PORT3"; then cat "$LOG" >&2; exit 1; fi
for id in b1 b2 b3; do
  GOT=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/bulk_fsync/$id")
  if [ "$GOT" != "404" ]; then
    echo "FAIL: $id survived a discarded bulk write (HTTP $GOT)" >&2
    exit 1
  fi
done

echo "PASS: a failed bulk fsync was not acknowledged and no batch document survived"
