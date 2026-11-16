#!/usr/bin/env bash
# Verify that atomic storage writes fsync the containing directory after rename.
# This is a syscall-level test: SIGKILL does not drop the page cache, so it cannot
# prove directory durability. strace is optional; skip when unavailable.
set -euo pipefail

cd "$(dirname "$0")/../.."
BIN="${ZOUCH_BIN:-./zig-out/bin/zouch}"
PORT="${ZOUCH_TEST_PORT:-5996}"

if ! command -v strace >/dev/null 2>&1; then
  echo "SKIP: strace is not installed"
  exit 0
fi
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: missing $BIN; run 'zig build' first" >&2
  exit 1
fi

DATA="$(mktemp -d /tmp/zouch-dirsync.XXXXXX)"
TRACE="${DATA}.trace"
LOG="${DATA}.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    child="$(pgrep -P "$PID" -x zouch 2>/dev/null || true)"
    [[ -n "$child" ]] && kill -9 $child 2>/dev/null || true
    kill -9 "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$DATA" "$TRACE" "$LOG"
}
trap cleanup EXIT

strace -f -yy -e trace=fsync -o "$TRACE" "$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if ! curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null; then
  echo "FAIL: server did not start" >&2
  tail -20 "$LOG" >&2 || true
  exit 1
fi

curl -fsS -X PUT "http://127.0.0.1:$PORT/probe" >/dev/null
curl -fsS -X PUT "http://127.0.0.1:$PORT/probe/doc" \
  -H 'content-type: application/json' \
  -d '{"_attachments":{"hello.txt":{"content_type":"text/plain","data":"YXR0YWNobWVudCBwYXlsb2Fk"}}}' >/dev/null
curl -fsS -X POST "http://127.0.0.1:$PORT/probe/_compact" >/dev/null

# strace writes the trace asynchronously; poll briefly before judging.
for _ in $(seq 1 50); do
  if grep -q "fsync(.*${DATA}/probe>)" "$TRACE" 2>/dev/null; then break; fi
  sleep 0.1
done

if ! grep -q "fsync(.*${DATA}/probe>)" "$TRACE"; then
  echo "FAIL: no directory fsync for the database directory" >&2
  tail -20 "$TRACE" >&2 || true
  exit 1
fi
for _ in $(seq 1 50); do
  if grep -q "fsync(.*${DATA}/probe/blobs>)" "$TRACE" 2>/dev/null; then break; fi
  sleep 0.1
done

if ! grep -q "fsync(.*${DATA}/probe/blobs>)" "$TRACE"; then
  echo "FAIL: no directory fsync for blobs/" >&2
  tail -20 "$TRACE" >&2 || true
  exit 1
fi
echo "PASS: database and blob directories are fsynced after rename"
