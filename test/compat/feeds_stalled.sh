#!/usr/bin/env bash
# A stalled continuous _changes feed consumer must not block new feed registrations or ordinary HTTP requests (H4).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6074}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""

cleanup() {
  [ -n "$STALL_PID" ] && kill -9 "$STALL_PID" 2>/dev/null || true
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
STALL_PID=""
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
Z="http://127.0.0.1:$PORT"
J='content-type: application/json'
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "$Z/_up" >/dev/null

curl -fsS -X PUT "$Z/f" >/dev/null

# Open a continuous feed and deliberately never read from the socket so the
# server's send buffer fills and blocks writes to this peer.
python3 - "$PORT" "$TMP/stalled.ready" <<'PY' &
import socket, sys, time
port, ready = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"GET /f/_changes?feed=continuous&since=0&timeout=30000 HTTP/1.1\r\nHost: localhost\r\n\r\n")
open(ready, "w").write("ok")
time.sleep(30)
PY
STALL_PID=$!
for _ in $(seq 1 50); do [ -e "$TMP/stalled.ready" ] && break; sleep 0.05; done

# Write 12,000 docs (~1.4 MB of changes) to saturate the stalled socket buffer.
python3 - >"$TMP/bulk.json" <<'PY'
import json
print(json.dumps({"docs": [{"_id": "d%05d" % i, "pad": "x" * 80} for i in range(12000)]}))
PY
curl -fsS -m 30 -X POST "$Z/f/_bulk_docs" -H "$J" --data-binary @"$TMP/bulk.json" >/dev/null
sleep 0.2

# Both /_up and a fresh longpoll feed must answer quickly despite the stalled consumer.
t0=$(python3 -c 'import time; print(time.monotonic())')
curl -fsS -m 2 "$Z/_up" >/dev/null
code=$(curl -sS -m 2 -o "$TMP/lp.json" -w '%{http_code}' "$Z/f/_changes?feed=longpoll&since=now&timeout=500")
[ "$code" = "200" ] || { echo "FAIL: second longpoll returned $code" >&2; exit 1; }
elapsed=$(python3 -c "import time; print(time.monotonic() - $t0)")
python3 -c "assert float('$elapsed') < 2.5, 'blocked for %.2fs' % float('$elapsed')"

echo "PASS: stalled feed did not block server (${elapsed}s)"
