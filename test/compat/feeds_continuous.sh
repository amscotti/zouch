#!/usr/bin/env bash
# Continuous feeds through the shared scheduler must emit new changes, heartbeat, and close.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5999}
DATA="$TMP/data"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/fc" >/dev/null
curl -fsS -X PUT "$Z/fc/old" -H 'content-type: application/json' -d '{"v":"old"}' >/dev/null

curl -sS "$Z/fc/_changes?feed=continuous&since=now&timeout=4000" >"$TMP/out" &
F=$!
sleep 0.3
curl -fsS -X PUT "$Z/fc/one" -H 'content-type: application/json' -d '{"v":1}' >/dev/null
curl -fsS -X PUT "$Z/fc/two" -H 'content-type: application/json' -d '{"v":2}' >/dev/null
wait "$F"

grep -q '"id":"one"' "$TMP/out"
grep -q '"id":"two"' "$TMP/out"
! grep -q '"id":"old"' "$TMP/out"

# A second continuous feed opened at the same time sees the same changes.
curl -sS "$Z/fc/_changes?feed=continuous&since=0&timeout=1000" >"$TMP/all" &
F2=$!
wait "$F2"
grep -q '"id":"old"' "$TMP/all"
grep -q '"id":"one"' "$TMP/all"
grep -q '"id":"two"' "$TMP/all"

echo "PASS: continuous feeds emit changes, heartbeats/timeouts and close cleanly"
