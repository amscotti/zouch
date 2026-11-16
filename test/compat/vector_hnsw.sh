#!/usr/bin/env bash
# HNSW engine builds a graph, persists it, and reuses it after restart.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6023}
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
    if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$TMP/server.log" >&2
  return 1
}

start
B="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$B/vec" >/dev/null

python3 - "$B" <<'PY'
import base64, json, math, struct, sys, urllib.request
B = sys.argv[1]
def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(B + path, data=data, method=method)
    if data: req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as r: return json.loads(r.read() or b"null")
def b64(v): return base64.b64encode(struct.pack("<%df" % len(v), *v)).decode()
docs = []
for i in range(24):
    v = [math.sin(i * 0.7 + j) for j in range(6)]
    docs.append({"_id": "v%02d" % i, "embedding_b64": b64(v)})
call("POST", "/vec/_bulk_docs", {"docs": docs})
hits = call("POST", "/vec/_vector_search", {"vector": [math.sin(0.0), math.sin(1.0), math.sin(2.0), math.sin(3.0), math.sin(4.0), math.sin(5.0)], "k": 1, "engine": "hnsw"})["hits"]
assert hits[0]["id"] == "v00", hits
print("hnsw query ok")

# A new document should be appended without rebuilding the graph.
qnew = [0, 0, 0, 0, 0, 1]
call("PUT", "/vec/vnew", {"embedding_b64": b64(qnew)})
hits = call("POST", "/vec/_vector_search", {"vector": qnew, "k": 1, "engine": "hnsw"})["hits"]
assert hits[0]["id"] == "vnew", hits
print("hnsw incremental append ok")

# Updating an existing vector must invalidate and rebuild instead of appending.
cur = call("GET", "/vec/v00")
cur["embedding_b64"] = b64([1, 0, 0, 0, 0, 0])
call("PUT", "/vec/v00", cur)
hits = call("POST", "/vec/_vector_search", {"vector": qnew, "k": 1, "engine": "hnsw"})["hits"]
assert hits[0]["id"] == "vnew", hits
print("hnsw update rebuild ok")
PY

[ -s "$DATA/vec/hnsw.idx" ]
start
python3 - "$B" <<'PY'
import json, math, sys, urllib.request
B = sys.argv[1]
req = urllib.request.Request(B + "/vec/_vector_search", data=json.dumps({"vector": [0, 0, 0, 0, 0, 1], "k": 1, "engine": "hnsw"}).encode(), method="POST")
req.add_header("Content-Type", "application/json")
with urllib.request.urlopen(req) as r: hits = json.loads(r.read())["hits"]
assert hits[0]["id"] == "vnew", hits
print("hnsw restart query ok")
PY

echo "PASS: HNSW graph persistence and restart reuse"
