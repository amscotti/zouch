#!/usr/bin/env bash
# Power-loss test through a FUSE disk that only persists bytes on fsync.
# Acknowledged writes must survive; an in-flight bulk write whose fsync never completed must not.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
FS="$PWD/scripts/powerloss_fs.py"
TMP=$(mktemp -d)
BACK="$TMP/back"
MNT="$TMP/mnt"
MNT2="$TMP/mnt2"
PORT=5971
FUSE_PID=""
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  [ -n "$FUSE_PID" ] && kill -9 "$FUSE_PID" 2>/dev/null || true
  fusermount3 -u -z "$MNT" 2>/dev/null || true
  fusermount3 -u -z "$MNT2" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  local port=$1
  for _ in $(seq 1 200); do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

start_fuse() {
  local mount=$1
  local env=$2
  mkdir -p "$mount"
  env $env python3 "$FS" "$BACK" "$mount" >"$TMP/fuse.log" 2>&1 &
  FUSE_PID=$!
  for _ in $(seq 1 100); do
    if mountpoint -q "$mount"; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/fuse.log" >&2
  return 1
}

# ---- acknowledged write survives a cut -------------------------------------
start_fuse "$MNT" ""
"$BIN" serve "$MNT/data" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
wait_ready "$PORT" || { cat "$TMP/server.log" >&2; exit 1; }
curl -fsS -X PUT "http://127.0.0.1:$PORT/pl" >/dev/null
curl -fsS -X PUT "http://127.0.0.1:$PORT/pl/a" -H 'content-type: application/json' -d '{"v":"a"}' >/dev/null
curl -fsS -X PUT "http://127.0.0.1:$PORT/pl/b" -H 'content-type: application/json' -d '{"v":"b"}' >/dev/null

kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""
kill -9 "$FUSE_PID" 2>/dev/null || true
wait "$FUSE_PID" 2>/dev/null || true
FUSE_PID=""
fusermount3 -u -z "$MNT" 2>/dev/null || true

"$BIN" serve "$BACK/data" "$((PORT + 1))" >"$TMP/restart.log" 2>&1 &
SPID=$!
wait_ready "$((PORT + 1))" || { cat "$TMP/restart.log" >&2; exit 1; }
[ "$(curl -sS "http://127.0.0.1:$((PORT + 1))/pl/a" | jq -r .v)" = "a" ]
[ "$(curl -sS "http://127.0.0.1:$((PORT + 1))/pl/b" | jq -r .v)" = "b" ]
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""

# ---- an in-flight bulk whose fsync never completes is not durable ----------
start_fuse "$MNT2" "PL_SLOW_FSYNC=2"
"$BIN" serve "$MNT2/data" "$((PORT + 2))" >"$TMP/server2.log" 2>&1 &
SPID=$!
wait_ready "$((PORT + 2))" || { cat "$TMP/server2.log" >&2; exit 1; }
curl -fsS -X PUT "http://127.0.0.1:$((PORT + 2))/inflight" >/dev/null

python3 - <<'PY' >"$TMP/bulk.json"
import json, sys
docs = [{"_id": f"i{i:05d}", "n": i} for i in range(20000)]
sys.stdout.write(json.dumps({"docs": docs}))
PY
curl -sS -o "$TMP/bulk.out" -w '%{http_code}' -X POST \
  "http://127.0.0.1:$((PORT + 2))/inflight/_bulk_docs" \
  -H 'content-type: application/json' --data-binary @"$TMP/bulk.json" >"$TMP/bulk.status" &
CURL_PID=$!
sleep 0.5
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""
kill -9 "$CURL_PID" 2>/dev/null || true
kill -9 "$FUSE_PID" 2>/dev/null || true
wait "$FUSE_PID" 2>/dev/null || true
FUSE_PID=""
fusermount3 -u -z "$MNT2" 2>/dev/null || true

"$BIN" serve "$BACK/data" "$((PORT + 3))" >"$TMP/restart2.log" 2>&1 &
SPID=$!
wait_ready "$((PORT + 3))" || { cat "$TMP/restart2.log" >&2; exit 1; }
COUNT=$(curl -fsS "http://127.0.0.1:$((PORT + 3))/inflight" | jq -r .doc_count)
if [ "$COUNT" != "0" ]; then
  echo "FAIL: $COUNT documents from an unfynced bulk became durable" >&2
  exit 1
fi
"$BIN" check "$BACK/data" >/dev/null

echo "PASS: acknowledged writes survived a power cut; an unfynced bulk did not"
