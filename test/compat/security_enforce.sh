#!/usr/bin/env bash
# Name-based _security members/admins enforcement under Basic auth.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6001}
DATA="$TMP/data"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start_server() {
  local auth=$1
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  if [ -n "$auth" ]; then
    ZOUCH_AUTH="$auth" "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  else
    "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  fi
  SPID=$!
  for _ in $(seq 1 100); do
    if [ -n "$auth" ]; then
      if curl -fsS -u "$auth" "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    else
      if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start_server ""
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/sec" >/dev/null
curl -fsS -X PUT "$Z/open" >/dev/null
curl -fsS -X PUT "$Z/sec/_security" -H 'content-type: application/json' \
  -d '{"admins":{"names":["root"],"roles":[]},"members":{"names":["alice"],"roles":[]}}' >/dev/null

start_server "zouch:pass"
[ "$(curl -sS -u zouch:pass -o /dev/null -w '%{http_code}' "$Z/sec")" = "403" ]
[ "$(curl -sS -u zouch:pass -o /dev/null -w '%{http_code}' "$Z/sec/doc")" = "403" ]
[ "$(curl -sS -u zouch:pass -o /dev/null -w '%{http_code}' "$Z/open")" = "200" ]

start_server "alice:pass"
[ "$(curl -sS -u alice:pass -o /dev/null -w '%{http_code}' "$Z/sec")" = "200" ]
[ "$(curl -sS -u alice:pass -o /dev/null -w '%{http_code}' -X PUT "$Z/sec/doc" -H 'content-type: application/json' -d '{"v":1}')" = "201" ]

start_server "root:pass"
[ "$(curl -sS -u root:pass -o /dev/null -w '%{http_code}' "$Z/sec")" = "200" ]

echo "PASS: _security members are enforced; admins and unrestricted databases remain accessible"
