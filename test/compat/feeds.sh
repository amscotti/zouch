#!/usr/bin/env bash
# Two blocked longpoll feeds must not starve ordinary CRUD.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5998}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
wait_ready || { cat "$LOG" >&2; exit 1; }
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/feeds" >/dev/null
curl -fsS -X PUT "$Z/feeds/a" -H 'content-type: application/json' -d '{"v":1}' >/dev/null

base=""
if command -v wrk >/dev/null 2>&1; then
  base=$(wrk -t1 -c4 -d1s "$Z/feeds/a" 2>/dev/null | awk '/Requests\/sec:/ {print $2}')
fi

curl -sS "$Z/feeds/_changes?feed=longpoll&since=now&timeout=5000" >"$TMP/feed1" &
F1=$!
curl -sS "$Z/feeds/_changes?feed=longpoll&since=now&timeout=5000" >"$TMP/feed2" &
F2=$!
sleep 0.3

if command -v wrk >/dev/null 2>&1; then
  with_feeds=$(wrk -t1 -c4 -d1s "$Z/feeds/a" 2>/dev/null | awk '/Requests\/sec:/ {print $2}')
  [ -n "$base" ] && [ -n "$with_feeds" ]
  awk -v b="$base" -v f="$with_feeds" 'BEGIN { exit !(f > b / 4) }'
else
  start=$(date +%s%N)
  for _ in $(seq 1 100); do curl -fsS "$Z/feeds/a" >/dev/null; done
  elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
  [ "$elapsed_ms" -le 5000 ]
  base="n/a"; with_feeds="${elapsed_ms} ms/100"
fi

curl -fsS -X PUT "$Z/feeds/b" -H 'content-type: application/json' -d '{"v":2}' >/dev/null
wait "$F1"
wait "$F2"
grep -q '"id":"b"' "$TMP/feed1"
grep -q '"id":"b"' "$TMP/feed2"

if command -v wrk >/dev/null 2>&1; then
  curl -sS --max-time 10 "$Z/feeds/_changes?feed=continuous&since=now&timeout=10000" >"$TMP/cont1" &
  C1=$!
  curl -sS --max-time 10 "$Z/feeds/_changes?feed=continuous&since=now&timeout=10000" >"$TMP/cont2" &
  C2=$!
  sleep 0.3
  with_cont=$(wrk -t1 -c4 -d1s "$Z/feeds/a" 2>/dev/null | awk '/Requests\/sec:/ {print $2}')
  awk -v b="$base" -v f="$with_cont" 'BEGIN { exit !(f > b / 4) }'
  kill "$C1" "$C2" 2>/dev/null || true
  wait "$C1" "$C2" 2>/dev/null || true
fi

echo "PASS: two blocked longpoll and continuous feeds left CRUD responsive (${base} -> ${with_feeds} req/s)"
