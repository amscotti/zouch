#!/usr/bin/env bash
# Combined power-cut + soak campaign.
#
# Writes a stream of documents through Zouch on a FUSE disk that commits only on fsync,
# cuts power at a fixed interval, restarts against the backing directory, and verifies
# every acknowledged document after each cut. Defaults to 24 hours; set
# COMBINED_SECONDS and CUT_EVERY for a shorter campaign.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
FS="$PWD/scripts/powerloss_fs.py"
TMP=$(mktemp -d)
BACK="$TMP/back"
MNT="$TMP/mnt"
ACK="$TMP/acked"
PORT=${PORT:-5974}
SECONDS_TO_RUN=${COMBINED_SECONDS:-86400}
CUT_EVERY=${CUT_EVERY:-600}
VERIFY_EACH_CUT=${VERIFY_EACH_CUT:-1}
FUSE_PID=""
SPID=""
WRITER_PID=""

cleanup() {
  touch "$TMP/stop" 2>/dev/null || true
  for pid in "$WRITER_PID" "$SPID" "$FUSE_PID"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  [ -n "$SPID" ] && wait "$SPID" 2>/dev/null || true
  [ -n "$FUSE_PID" ] && wait "$FUSE_PID" 2>/dev/null || true
  fusermount3 -u -z "$MNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  for _ in $(seq 1 200); do
    if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

start_fuse() {
  mkdir -p "$MNT"
  python3 "$FS" "$BACK" "$MNT" >"$TMP/fuse.log" 2>&1 &
  FUSE_PID=$!
  for _ in $(seq 1 100); do
    mountpoint -q "$MNT" && return 0
    sleep 0.05
  done
  cat "$TMP/fuse.log" >&2
  return 1
}

start_server() {
  "$BIN" serve "$MNT/data" "$PORT" >>"$TMP/server.log" 2>&1 &
  SPID=$!
  wait_ready || { cat "$TMP/server.log" >&2; return 1; }
}

verify_acked() {
  [ -s "$ACK" ] || return 0
  python3 - "http://127.0.0.1:$PORT/soak" "$ACK" <<'PY'
import json, sys, urllib.request
base, ack_path = sys.argv[1], sys.argv[2]
missing = []
with open(ack_path) as ack:
    while True:
        ids = [line.strip() for line in [next(ack, "") for _ in range(500)] if line.strip()]
        if not ids:
            break
        body = json.dumps({"keys": ids}).encode()
        req = urllib.request.Request(base + "/_all_docs", data=body, method="POST",
                                     headers={"content-type": "application/json"})
        with urllib.request.urlopen(req) as resp:
            rows = json.loads(resp.read())["rows"]
        missing.extend(row["key"] for row in rows if row.get("error"))
if missing:
    print(f"FAIL: {len(missing)} acknowledged documents missing after power cut: {missing[:5]}", file=sys.stderr)
    sys.exit(1)
PY
}

check_acked_count() {
  [ -s "$ACK" ] || return 0
  local acked count
  acked=$(wc -l <"$ACK")
  count=$(curl -fsS "http://127.0.0.1:$PORT/soak" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doc_count"])')
  if [ "$count" -lt "$acked" ]; then
    echo "FAIL: doc_count $count is below $acked acknowledged writes after power cut" >&2
    exit 1
  fi
}

cut_power() {
  touch "$TMP/pause"
  sleep 0.4
  kill -9 "$SPID" 2>/dev/null || true
  wait "$SPID" 2>/dev/null || true
  SPID=""
  kill -9 "$FUSE_PID" 2>/dev/null || true
  wait "$FUSE_PID" 2>/dev/null || true
  FUSE_PID=""
  fusermount3 -u -z "$MNT" 2>/dev/null || true
  start_fuse
  start_server
  if [ "$VERIFY_EACH_CUT" = "1" ]; then
    verify_acked
  else
    check_acked_count
  fi
  rm -f "$TMP/pause"
}

start_fuse
start_server
curl -fsS -X PUT "http://127.0.0.1:$PORT/soak" >/dev/null

writer() {
  while [ ! -f "$TMP/stop" ]; do
    if [ -f "$TMP/pause" ]; then sleep 0.05; continue; fi
    id="doc-$(date +%s%N)-$RANDOM"
    code=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
      -X PUT "http://127.0.0.1:$PORT/soak/$id" -H 'content-type: application/json' \
      -d "{\"n\":$RANDOM,\"pad\":\"11111111111111111111111111111111\"}" 2>/dev/null || true)
    if [ "$code" = "201" ]; then echo "$id" >>"$ACK"; fi
  done
}
writer &
WRITER_PID=$!

start=$(date +%s)
deadline=$((start + SECONDS_TO_RUN))
cuts=0
peak=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  now=$(date +%s)
  left=$((deadline - now))
  nap=$((CUT_EVERY < left ? CUT_EVERY : left))
  sleep "$nap"
  if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
  if [ -n "$SPID" ] && kill -0 "$SPID" 2>/dev/null; then
    rss=$(awk '/VmRSS/ {print $2}' "/proc/$SPID/status" 2>/dev/null || echo 0)
    [ "$rss" -gt "$peak" ] && peak=$rss
  fi
  cut_power
  cuts=$((cuts + 1))
done

touch "$TMP/stop"
wait "$WRITER_PID" 2>/dev/null || true
WRITER_PID=""

# Final cut with the writer stopped, then verify and check recovery.
cut_power
cuts=$((cuts + 1))
verify_acked
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""
kill -9 "$FUSE_PID" 2>/dev/null || true
wait "$FUSE_PID" 2>/dev/null || true
FUSE_PID=""
fusermount3 -u -z "$MNT" 2>/dev/null || true
"$BIN" check "$BACK/data" >/dev/null

count=$(wc -l <"$ACK")
echo "PASS: combined soak wrote $count acknowledged documents through $cuts power cuts; zouch check clean (peak RSS ${peak} kB)"
