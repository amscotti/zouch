#!/usr/bin/env bash
# Opt-in background compaction and blob GC.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6059}
DATA="$TMP/data"
SPID=""
cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

ZOUCH_AUTO_COMPACT_SECS=1 "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/db" >/dev/null
curl -fsS -X PUT "$Z/db/d" -H 'content-type: application/json' \
  -d '{"v":1,"_attachments":{"a.txt":{"content_type":"text/plain","data":"b2xk"}}}' >/dev/null
REV=$(curl -fsS "$Z/db/d" | jq -r ._rev)
curl -fsS -X PUT "$Z/db/d" -H 'content-type: application/json' \
  -d "{\"_rev\":\"$REV\",\"v\":2,\"_attachments\":{\"a.txt\":{\"content_type\":\"text/plain\",\"data\":\"bmV3\"}}}" >/dev/null

for _ in $(seq 1 20); do
  [ "$(wc -c <"$DATA/db/wal.log" | tr -d '[:space:]')" = "0" ] && break
  sleep 0.5
done
[ "$(wc -c <"$DATA/db/wal.log" | tr -d '[:space:]')" = "0" ]
[ "$(find "$DATA/db" -maxdepth 1 -name 'segment-*.bin' | wc -l | tr -d '[:space:]')" -ge 1 ]
[ "$(find "$DATA/db/blobs" -name '*.bin' | wc -l | tr -d '[:space:]')" = "1" ]
[ "$(curl -fsS "$Z/db/d/a.txt")" = "new" ]

echo "PASS: background compaction rewrites the segment and collects the superseded blob"
