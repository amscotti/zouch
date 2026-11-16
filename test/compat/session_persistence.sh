#!/usr/bin/env bash
# A session must outlive the process that issued it: CouchDB signs its cookie
# with a persisted secret, so a restart does not log clients out. This starts a
# server, logs in, restarts the server on the same data directory, and checks
# the same cookie still authenticates.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
DIR=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
Z="http://127.0.0.1:$PORT"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "$DIR"
}
trap cleanup EXIT

start() {
  ZOUCH_AUTH=admin:testpw "$BIN" serve "$DIR/data" "$PORT" >"$DIR/log" 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do
    if curl -sS -o /dev/null "$Z/_session" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "FAIL: server did not start on $PORT"; cat "$DIR/log"; exit 1
}

start
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/")" = "401" ] || { echo "FAIL: no auth required"; exit 1; }

COOKIE=$(curl -sS -i -X POST "$Z/_session" -H 'content-type: application/json' \
  -d '{"name":"admin","password":"testpw"}' | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: //p' | cut -d';' -f1)
[ -n "$COOKIE" ] || { echo "FAIL: no cookie from POST /_session"; exit 1; }
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "cookie: $COOKIE" "$Z/")" = "200" ] \
  || { echo "FAIL: cookie did not authenticate"; exit 1; }
[ "$(curl -sS -H "cookie: $COOKIE" "$Z/_session" | python3 -c 'import sys,json;print(json.load(sys.stdin)["userCtx"]["name"])')" = "admin" ] \
  || { echo "FAIL: userCtx did not name the user"; exit 1; }
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/_session" -H 'content-type: application/json' \
  -d '{"name":"admin","password":"wrong"}')" = "401" ] || { echo "FAIL: wrong password accepted"; exit 1; }

# The point of the test: same cookie, new process.
kill "$PID"; wait "$PID" 2>/dev/null; PID=""
start
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "cookie: $COOKIE" "$Z/")" = "200" ] \
  || { echo "FAIL: cookie stopped working after a restart"; exit 1; }
[ "$(curl -sS -H "cookie: $COOKIE" "$Z/_session" | python3 -c 'import sys,json;print(json.load(sys.stdin)["userCtx"]["name"])')" = "admin" ] \
  || { echo "FAIL: userCtx lost after a restart"; exit 1; }

# A cookie whose signature does not check out is not a session.
TAMPERED="${COOKIE%?}X"
[ "$(curl -sS -H "cookie: $TAMPERED" "$Z/_session" | python3 -c 'import sys,json;print(json.load(sys.stdin)["userCtx"]["name"])')" = "None" ] \
  || { echo "FAIL: tampered cookie accepted"; exit 1; }
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "cookie: $TAMPERED" "$Z/")" = "401" ] \
  || { echo "FAIL: tampered cookie authenticated"; exit 1; }

# Logging out clears the cookie server-side, as CouchDB does.
DEL=$(curl -sS -i -X DELETE "$Z/_session" -H "cookie: $COOKIE" | tr -d '\r')
echo "$DEL" | grep -q '"ok":true' || { echo "FAIL: DELETE /_session did not answer ok"; exit 1; }
echo "$DEL" | grep -qi 'set-cookie: AuthSession=;' || { echo "FAIL: DELETE did not clear the cookie"; exit 1; }

echo "PASS: sessions survive a restart"
