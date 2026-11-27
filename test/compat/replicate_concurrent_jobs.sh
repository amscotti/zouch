#!/usr/bin/env bash
# A hung _replicator job must not starve other _replicator jobs, and GET /_scheduler/jobs must answer while a job is running (H6).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6075}
HOLE_PORT=${HOLE_PORT:-6076}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""
HPID=""

cleanup() {
  [ -n "$HPID" ] && kill -9 "$HPID" 2>/dev/null || true
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# TCP blackhole that accepts connections and never sends any bytes.
python3 - "$HOLE_PORT" "$TMP/hole.ready" <<'PY' &
import socket, sys, threading, time
port, ready = int(sys.argv[1]), sys.argv[2]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(16)
conns = []
open(ready, "w").write("ok")
while True:
    c, _ = srv.accept()
    conns.append(c)
PY
HPID=$!
for _ in $(seq 1 50); do [ -e "$TMP/hole.ready" ] && break; sleep 0.05; done

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
Z="http://127.0.0.1:$PORT"
J='content-type: application/json'
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "$Z/_up" >/dev/null

curl -fsS -X PUT "$Z/src_ok" >/dev/null
curl -fsS -X PUT "$Z/dst_ok" >/dev/null
curl -fsS -X PUT "$Z/dst_hung" >/dev/null
curl -fsS -X PUT "$Z/src_ok/d1" -H "$J" -d '{"v":1}' >/dev/null
curl -fsS -X PUT "$Z/src_ok/d2" -H "$J" -d '{"v":2}' >/dev/null

# 1. Start the job pointed at the blackhole source.
curl -fsS -X PUT "$Z/_replicator/hung_job" -H "$J" \
  -d "{\"source\":\"http://127.0.0.1:$HOLE_PORT/db\",\"target\":\"$Z/dst_hung\"}" >/dev/null

# Wait until _scheduler/jobs reports hung_job as running (also verifies no SIGSYS on macOS!).
seen=0
for _ in $(seq 1 40); do
  curl -fsS -m 2 "$Z/_scheduler/jobs" >"$TMP/jobs.json"
  if jq -e '.jobs[] | select(.doc_id == "hung_job")' <"$TMP/jobs.json" >/dev/null 2>&1; then
    seen=1
    break
  fi
  sleep 0.25
done
[ "$seen" = "1" ] || { echo "FAIL: hung_job never appeared in _scheduler/jobs: $(cat "$TMP/jobs.json")" >&2; exit 1; }

# 2. Start a healthy job while hung_job is stuck on its socket; it must complete within 10s.
curl -fsS -X PUT "$Z/_replicator/fast_job" -H "$J" \
  -d "{\"source\":\"$Z/src_ok\",\"target\":\"$Z/dst_ok\"}" >/dev/null

state=""
for _ in $(seq 1 40); do
  state=$(curl -fsS -m 2 "$Z/_replicator/fast_job" | jq -r '._replication_state // empty')
  [ "$state" = "completed" ] && break
  sleep 0.25
done
[ "$state" = "completed" ] || { echo "FAIL: fast_job state '$state', expected completed" >&2; exit 1; }
[ "$(curl -fsS "$Z/dst_ok" | jq -r .doc_count)" = "2" ]

echo "PASS: healthy _replicator job completed while hung job ran and _scheduler/jobs answered"
