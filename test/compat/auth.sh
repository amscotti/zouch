#!/usr/bin/env bash
# Per-database Basic auth from ZOUCH_AUTH_FILE.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5997}
DATA="$TMP/data"
AUTH="$TMP/auth"
USER="zouch"
PASS="test-$(date +%s)"

cleanup() {
  kill -9 "${SPID:-0}" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

printf 'secure:%s:%s\n' "$USER" "$PASS" >"$AUTH"
chmod 600 "$AUTH"

ZOUCH_AUTH_FILE="$AUTH" "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done

Z="http://127.0.0.1:$PORT"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/secure")" = "401" ]
[ "$(curl -sS -u "$USER:$PASS" -o /dev/null -w '%{http_code}' -X PUT "$Z/secure")" = "201" ]
[ "$(curl -sS -u "$USER:wrong" -o /dev/null -w '%{http_code}' -X PUT "$Z/secure")" = "401" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/open")" = "201" ]
[ "$(curl -sS -u "$USER:$PASS" -o /dev/null -w '%{http_code}' -X PUT "$Z/secure/a" -H 'content-type: application/json' -d '{"v":1}')" = "201" ]

COOKIE="$TMP/cookies"
[ "$(curl -sS -c "$COOKIE" -o /dev/null -w '%{http_code}' -X POST "$Z/_session" -H 'content-type: application/json' -d "{\"name\":\"$USER\",\"password\":\"$PASS\"}")" = "200" ]
[ "$(curl -sS -b "$COOKIE" -o /dev/null -w '%{http_code}' -X PUT "$Z/secure/session" -H 'content-type: application/json' -d '{"v":1}')" = "201" ]
[ "$(curl -sS -b "$COOKIE" -o /dev/null -w '%{http_code}' -X PUT "$Z/open/session" -H 'content-type: application/json' -d '{"v":1}')" = "201" ]

# A browser posts the login form; CouchDB accepts that encoding as well as JSON
# (right, it is what Fauxton sends).
FORM=$(curl -sS -c "$TMP/formcookie" -X POST "$Z/_session" \
  -H 'content-type: application/x-www-form-urlencoded' -d "name=$USER&password=$PASS")
printf '%s' "$FORM" | grep -q '"_admin"' || { echo "FAIL: form login did not report the admin role: $FORM"; exit 1; }
[ "$(curl -sS -b "$TMP/formcookie" -o /dev/null -w '%{http_code}' "$Z/secure")" = "200" ] ||
  { echo "FAIL: form login cookie does not authenticate"; exit 1; }
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/_session" \
  -H 'content-type: application/x-www-form-urlencoded' -d "name=$USER&password=wrong")" = "401" ] ||
  { echo "FAIL: form login accepted a wrong password"; exit 1; }

echo "PASS: per-database Basic auth and cookie sessions"
