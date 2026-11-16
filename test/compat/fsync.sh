#!/usr/bin/env bash
# Calibration: an fsync failure must not be acknowledged as a successful write.
# strace injects EIO on the first fsync; the WAL is then truncated to model the
# lost unsynced record, and a restart must not expose the document.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5992}
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
curl -fsS -X PUT "http://127.0.0.1:$PORT/fs_test" >/dev/null
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true

strace -f -e trace=fsync -e inject=fsync:error=EIO:when=1 -o "$TRACE" \
  "$BIN" serve "$DATA" "$PORT2" >"$LOG" 2>&1 &
SPID=$!
if ! wait_ready "$PORT2"; then cat "$LOG" >&2; exit 1; fi

STATUS=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X PUT \
  "http://127.0.0.1:$PORT2/fs_test/a" \
  -H 'content-type: application/json' -d '{"v":1}')
if [ "$STATUS" -lt 500 ]; then
  echo "FAIL: fsync failure was acknowledged with HTTP $STATUS" >&2
  cat "$TMP/body" >&2
  exit 1
fi
if ! grep -q "internal_server_error" "$TMP/body"; then
  echo "FAIL: error response was not JSON" >&2
  cat "$TMP/body" >&2
  exit 1
fi
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
pkill -f "zouch serve $DATA" 2>/dev/null || true

# The record never reached stable storage; discard it.
: >"$DATA/fs_test/wal.log"
"$BIN" serve "$DATA" "$PORT3" >"$LOG" 2>&1 &
SPID=$!
if ! wait_ready "$PORT3"; then cat "$LOG" >&2; exit 1; fi
GOT=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT3/fs_test/a")
if [ "$GOT" != "404" ]; then
  echo "FAIL: document survived a discarded unsynced write (HTTP $GOT)" >&2
  exit 1
fi

echo "PASS: fsync failure was not acknowledged and the discarded write stayed absent"
