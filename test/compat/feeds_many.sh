#!/usr/bin/env bash
# More than 64 concurrent longpoll feeds must be accepted and must wake correctly.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5997}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""

cleanup() {
  if [ -n "$SPID" ]; then
    kill -9 "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
  fi
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

ZOUCH_MAX_FEEDS=128 "$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/feeds_many" >/dev/null
curl -fsS -X PUT "$Z/feeds_many/a" -H 'content-type: application/json' -d '{"v":1}' >/dev/null

pids=()
for i in $(seq 1 100); do
  curl -sS "$Z/feeds_many/_changes?feed=longpoll&since=now&timeout=15000" >"$TMP/feed-$i" &
  pids+=("$!")
done
sleep 0.5
curl -fsS -X PUT "$Z/feeds_many/b" -H 'content-type: application/json' -d '{"v":2}' >/dev/null

# Ordinary requests must still work while 100 feeds are open.
start=$(date +%s%N)
for _ in $(seq 1 100); do curl -fsS "$Z/feeds_many/a" >/dev/null; done
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$elapsed_ms" -le 5000 ]

for pid in "${pids[@]}"; do wait "$pid"; done
ok=0
for f in "$TMP"/feed-*; do
  grep -q '"id":"b"' "$f" && ok=$((ok + 1))
done
[ "$ok" -eq 100 ] || { echo "only $ok/100 feeds woke"; exit 1; }

echo "PASS: 100 concurrent longpoll feeds accepted and woke; 100 CRUD reads in ${elapsed_ms} ms"
