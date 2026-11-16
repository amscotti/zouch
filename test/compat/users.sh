#!/usr/bin/env bash
# _users-backed Basic auth and role enforcement.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6019}
DATA="$TMP/data"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    if curl -fsS -u alice:secret "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start
B="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$B/_users" >/dev/null
curl -fsS -X PUT "$B/_users/org.couchdb.user:alice" -H 'content-type: application/json' \
  -d '{"name":"alice","type":"user","roles":["dev","_admin"],"password":"secret"}' >/dev/null

[ "$(curl -sS -o /dev/null -w '%{http_code}' "$B/_users/org.couchdb.user:alice")" = "401" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$B/_up")" = "200" ]
[ "$(curl -sS -u alice:wrong -o /dev/null -w '%{http_code}' "$B/_users/org.couchdb.user:alice")" = "401" ]
[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' "$B/_users/org.couchdb.user:alice")" = "200" ]
[ "$(curl -sS -u alice:secret "$B/_users/org.couchdb.user:alice" | jq -r 'has("password")')" = "false" ]
[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' -X PUT "$B/_users/org.couchdb.user:alice" -H 'content-type: application/json' -d '{"name":"wrong","type":"user","roles":[]}')" = "400" ]

for user in bob:ops:bobpass carol:other:carolpass; do
  name=${user%%:*}; rest=${user#*:}; role=${rest%%:*}; pass=${rest#*:}
  curl -fsS -u alice:secret -X PUT "$B/_users/org.couchdb.user:$name" -H 'content-type: application/json' \
    -d "{\"name\":\"$name\",\"type\":\"user\",\"roles\":[\"$role\"],\"password\":\"$pass\"}" >/dev/null
done

[ "$(curl -sS -u bob:bobpass -o /dev/null -w '%{http_code}' "$B/_users/org.couchdb.user:alice")" = "403" ]


curl -fsS -u alice:secret -X PUT "$B/protected" >/dev/null
curl -fsS -u alice:secret -X PUT "$B/protected/_security" -H 'content-type: application/json' \
  -d '{"admins":{"names":[],"roles":["ops"]},"members":{"names":[],"roles":["dev"]}}' >/dev/null

[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]
[ "$(curl -sS -u bob:bobpass -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]
[ "$(curl -sS -u carol:carolpass -o /dev/null -w '%{http_code}' "$B/protected")" = "403" ]
[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' -X POST "$B/_create_user" -H 'content-type: application/json' -d '{"name":"dave","password":"davepass","roles":["dev"]}')" = "201" ]
[ "$(curl -sS -u dave:davepass -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]
[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' -X POST "$B/_create_user" -H 'content-type: application/json' -d '{"name":"dave","password":"again"}')" = "409" ]

BULK=$(curl -sS -u alice:secret -X POST "$B/_users/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"org.couchdb.user:bulk","name":"bulk","type":"user","roles":["dev"],"password":"bulkpass"}]}')
[ "$(echo "$BULK" | jq -r '.[0].ok')" = "true" ]
[ "$(curl -sS -u bulk:bulkpass -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]
[ "$(curl -sS -u alice:secret "$B/_users/org.couchdb.user:bulk" | jq -r 'has("password")')" = "false" ]
[ "$(curl -sS -u alice:secret -X POST "$B/_users/_bulk_docs" -H 'content-type: application/json' -d '{"docs":[{"_id":"org.couchdb.user:bad","name":"wrong","type":"user"}]}' | jq -r '.[0].error')" = "bad_request" ]

curl -fsS -u alice:secret -c "$TMP/cookies" -X POST "$B/_session" -H 'content-type: application/json' \
  -d '{"name":"alice","password":"secret"}' >/dev/null
[ "$(curl -sS -b "$TMP/cookies" -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]
[ "$(curl -sS -b "$TMP/cookies" "$B/_session" | jq -r '.userCtx.name')" = "alice" ]
[ "$(curl -sS -b "$TMP/cookies" "$B/_session" | jq -r '.userCtx.roles | index("_admin") != null')" = "true" ]
[ "$(curl -sS -X POST "$B/_session" -H 'content-type: application/json' -d '{"name":"alice","password":"wrong"}' -o /dev/null -w '%{http_code}')" = "401" ]

start
[ "$(curl -sS -u alice:secret -o /dev/null -w '%{http_code}' "$B/protected")" = "200" ]

echo "PASS: _users Basic auth, password hashing, roles and cookie sessions"
