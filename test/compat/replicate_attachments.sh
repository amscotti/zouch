#!/usr/bin/env bash
# Attachments survive both pull and push replication.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6050}
DATA="$TMP/data"
SPID=""
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"
COUCH_CRED="${COUCH/:\/\//:\/\/$AUTH@}"
BIND_HOST="127.0.0.1"
ZOUCH_FOR_COUCH="http://127.0.0.1:$PORT"
if [ "$(uname -s)" = "Darwin" ] && [[ "$COUCH" == http://127.0.0.1:* || "$COUCH" == http://localhost:* ]]; then
  BIND_HOST="0.0.0.0"
  ZOUCH_FOR_COUCH="http://host.docker.internal:$PORT"
fi

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_src" >/dev/null 2>&1 || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_dest" >/dev/null 2>&1 || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_pushsrc" >/dev/null 2>&1 || true
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_round" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  sleep 0.2
  "$BIN" serve "$DATA" "$PORT" "$BIND_HOST" >"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

# Source attachment in CouchDB.
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_src" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_src" >/dev/null
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_src/a1" -H 'content-type: application/json' \
  -d '{"v":1}' >/dev/null
REV=$(curl -fsS -u "$AUTH" "$COUCH/zouch_att_src/a1" | jq -r ._rev)
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_src/a1/note.txt?rev=$REV" \
  -H 'content-type: text/plain' --data-binary 'hello attachment' >/dev/null

"$BIN" pull "http://$AUTH@127.0.0.1:5984/zouch_att_src" pull_att "$DATA"
start
B="http://127.0.0.1:$PORT"
[ "$(curl -fsS "$B/pull_att/a1/note.txt")" = "hello attachment" ]

# CouchDB-initiated replication exercises the multipart/related attachment write path.
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_pushsrc" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_pushsrc" >/dev/null
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_pushsrc/c1" -H 'content-type: application/json' -d '{"v":2}' >/dev/null
R=$(curl -fsS -u "$AUTH" "$COUCH/zouch_att_pushsrc/c1" | jq -r ._rev)
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_pushsrc/c1/in.txt?rev=$R" \
  -H 'content-type: text/plain' --data-binary 'incoming attachment' >/dev/null
curl -fsS -X PUT "$B/incoming_att" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$COUCH_CRED/zouch_att_pushsrc\",\"target\":\"$ZOUCH_FOR_COUCH/incoming_att\"}" >/dev/null
for _ in $(seq 1 40); do
  got=$(curl -sS "$B/incoming_att/c1/in.txt" 2>/dev/null || true)
  [ "$got" = "incoming attachment" ] && break
  sleep 0.25
done
[ "$got" = "incoming attachment" ]

# Local attachment pushed to CouchDB.
DATA_JSON=$(printf 'local attachment' | base64 -w0)
curl -fsS -X PUT "$B/local_source" >/dev/null
curl -fsS -X PUT "$B/local_source/l1" -H 'content-type: application/json' \
  -d "{\"v\":1,\"_attachments\":{\"note.txt\":{\"content_type\":\"text/plain\",\"data\":\"$DATA_JSON\"}}}" >/dev/null
kill -9 "$SPID" 2>/dev/null || true
SPID=""

curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_dest" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_dest" >/dev/null
"$BIN" push "http://$AUTH@127.0.0.1:5984/zouch_att_dest" local_source "$DATA"
[ "$(curl -fsS -u "$AUTH" "$COUCH/zouch_att_dest/l1/note.txt")" = "local attachment" ]

# The incoming copy stored CouchDB's gzip bytes; pushing it must decode them.
curl -fsS -u "$AUTH" -X DELETE "$COUCH/zouch_att_round" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/zouch_att_round" >/dev/null
"$BIN" push "http://$AUTH@127.0.0.1:5984/zouch_att_round" incoming_att "$DATA"
[ "$(curl -fsS -u "$AUTH" "$COUCH/zouch_att_round/c1/in.txt")" = "incoming attachment" ]

echo "PASS: attachments replicate in both directions"
