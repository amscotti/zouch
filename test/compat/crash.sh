#!/usr/bin/env bash
# Kill -9 recovery and torn-WAL-tail check. Uses an isolated port and directory.
set -euo pipefail
BIN="${BIN:-./zig-out/bin/zouch}"
PORT="${PORT:-5987}"
DIR="$(mktemp -d)"
BASE="http://127.0.0.1:$PORT"
PID=""

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$DIR"
}
trap cleanup EXIT

start() {
  "$BIN" serve "$DIR" "$PORT" >"$DIR/server.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 50); do
    curl -fsS -m 1 "$BASE/" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "zouch did not start"; cat "$DIR/server.log"; exit 1
}

echo "== write and kill -9 =="
start
curl -fsS -X PUT "$BASE/crash" >/dev/null
curl -fsS -X PUT "$BASE/crash/a" -H 'content-type: application/json' -d '{"v":1}' >/dev/null
curl -fsS -X PUT "$BASE/crash/b" -H 'content-type: application/json' -d '{"v":2}' >/dev/null
curl -fsS -X PUT "$BASE/crash/_local/ck" -H 'content-type: application/json' -d '{"since":42}' >/dev/null
kill -9 "$PID"
wait "$PID" 2>/dev/null || true
PID=""

echo "== restart =="
start
[ "$(curl -fsS "$BASE/crash/a" | python3 -c 'import sys,json;print(json.load(sys.stdin)["v"])')" = "1" ]
[ "$(curl -fsS "$BASE/crash/_all_docs" | python3 -c 'import sys,json;print(json.load(sys.stdin)["total_rows"])')" = "2" ]
[ "$(curl -fsS "$BASE/crash/_local/ck" | python3 -c 'import sys,json;print(json.load(sys.stdin)["since"])')" = "42" ]

echo "== torn WAL tail =="
kill -9 "$PID"
wait "$PID" 2>/dev/null || true
PID=""
printf 'torn-tail' >> "$DIR/crash/wal.log"
start
[ "$(curl -fsS "$BASE/crash/b" | python3 -c 'import sys,json;print(json.load(sys.stdin)["v"])')" = "2" ]
[ "$(curl -fsS "$BASE/crash/_local/ck" | python3 -c 'import sys,json;print(json.load(sys.stdin)["since"])')" = "42" ]

echo "PASS: kill -9 and torn WAL tail"
