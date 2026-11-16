#!/usr/bin/env bash
# A replication that carries a large attachment must not hold it in memory: the
# response is streamed into the blob, so peak RSS grows by buffers, not by the
# file size. Self-contained: Zouch copying one local database into another.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6212}
Z="http://127.0.0.1:$PORT"
SIZE=$((12 * 1024 * 1024))
# Bounded by the copy buffers; a buffered implementation adds the whole file.
ALLOW_KB=$((6 * 1024))

cleanup() {
  [ -n "${SPID:-}" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

"$BIN" serve "$TMP/data" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 150); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "$Z/_up" >/dev/null || fail "the server never came up"
kill -0 "$SPID" 2>/dev/null || fail "the server exited: $(cat "$TMP/server.log")"

head -c "$SIZE" /dev/urandom >"$TMP/att.bin"

curl -fsS -X PUT "$Z/src" >/dev/null
REV=$(curl -fsS -X PUT "$Z/src/doc" -H 'content-type: application/json' -d '{"k":1}' |
  python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
code=$(curl -sS -o "$TMP/put.json" -w '%{http_code}' -X PUT "$Z/src/doc/big.bin?rev=$REV" \
  -H 'content-type: application/octet-stream' --data-binary "@$TMP/att.bin")
[ "$code" = "201" ] || fail "uploading the attachment returned $code"
REV=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["rev"])' "$TMP/put.json")

curl -fsS -X PUT "$Z/dst" >/dev/null
before=$(awk '/VmHWM/{print $2}' "/proc/$SPID/status")
code=$(curl -sS -o "$TMP/rep.json" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' -d '{"source":"src","target":"dst"}')
[ "$code" = "200" ] || fail "the copy returned $code: $(cat "$TMP/rep.json")"
after=$(awk '/VmHWM/{print $2}' "/proc/$SPID/status")

blob=$(ls "$TMP/data/dst/blobs"/*.bin 2>/dev/null | head -1)
[ -n "$blob" ] || fail "the copy wrote no blob"
cmp -s "$TMP/att.bin" "$blob" || fail "the copied attachment differs from the source"

grew=$((after - before))
if [ "$grew" -gt "$ALLOW_KB" ]; then
  fail "peak RSS grew by ${grew}kB for a $((SIZE / 1024 / 1024))MB attachment (limit ${ALLOW_KB}kB)"
fi
echo "PASS: $((SIZE / 1024 / 1024))MB attachment copied, peak RSS +${grew}kB"

# Serving it back must not read the blob into memory either, and must still say
# how long the body is (the streaming path writes its own content-length).
before=$(awk '/VmHWM/{print $2}' "/proc/$SPID/status")
code=$(curl -sS -D "$TMP/served.hdr" -o "$TMP/served.bin" -w '%{http_code}' "$Z/src/doc/big.bin?rev=$REV")
after=$(awk '/VmHWM/{print $2}' "/proc/$SPID/status")
[ "$code" = "200" ] || fail "serving the attachment returned $code"
cmp -s "$TMP/att.bin" "$TMP/served.bin" || fail "the served attachment differs from the source"
grep -qi "^content-length: $SIZE" "$TMP/served.hdr" ||
  fail "no content-length for the served attachment: $(tr -d '\r' <"$TMP/served.hdr" | tr '\n' ' ')"
grew=$((after - before))
if [ "$grew" -gt "$ALLOW_KB" ]; then
  fail "peak RSS grew by ${grew}kB while serving a $((SIZE / 1024 / 1024))MB attachment (limit ${ALLOW_KB}kB)"
fi
echo "PASS: $((SIZE / 1024 / 1024))MB attachment served, peak RSS +${grew}kB"
