#!/usr/bin/env bash
# Role-based _security enforcement with the local ZOUCH_ROLES map.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6012}
DATA="$TMP/data"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start_server() {
  local auth=$1 roles=$2
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  if [ -n "$roles" ]; then
    ZOUCH_AUTH="$auth" ZOUCH_ROLES="$roles" "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  else
    ZOUCH_AUTH="$auth" "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  fi
  SPID=$!
  for _ in $(seq 1 100); do
    if curl -fsS -u "$auth" "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

# Seed a database and a role-only security object without auth.
"$BIN" serve "$DATA" "$PORT" >"$TMP/seed.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/roles" >/dev/null
curl -fsS -X PUT "$Z/roles/_security" -H 'content-type: application/json' \
  -d '{"admins":{"names":[],"roles":["ops"]},"members":{"names":[],"roles":["dev"]}}' >/dev/null

start_server "alice:pass" "alice:dev"
[ "$(curl -sS -u alice:pass -o /dev/null -w '%{http_code}' "$Z/roles")" = "200" ]
[ "$(curl -sS -u alice:pass -o /dev/null -w '%{http_code}' -X PUT "$Z/roles/a" -H 'content-type: application/json' -d '{"v":1}')" = "201" ]

start_server "bob:pass" "bob:ops"
[ "$(curl -sS -u bob:pass -o /dev/null -w '%{http_code}' "$Z/roles")" = "200" ]

start_server "carol:pass" "carol:other"
[ "$(curl -sS -u carol:pass -o /dev/null -w '%{http_code}' "$Z/roles")" = "403" ]

echo "PASS: _security roles are enforced through ZOUCH_ROLES; admins bypass"
