#!/usr/bin/env bash
# Every thread that touches a database takes that database's own lock: a pull replication racing ordinary writers, a longpoll feed with include_docs and an attachment download racing rewrites must lose no acknowledged write and must not crash the server.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5996}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""
DOCS=${DOCS:-60000}
WRITERS=4
Z="http://127.0.0.1:$PORT"
J='content-type: application/json'

cleanup() {
  jobs -p | xargs kill 2>/dev/null || true
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start() {
  "$BIN" serve "$DATA" "$PORT" >>"$LOG" 2>&1 &
  SPID=$!
  for _ in $(seq 1 200); do
    if curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  cat "$LOG" >&2
  return 1
}

alive() {
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "FAIL: server died during $1" >&2
    tail -8 "$LOG" >&2
    exit 1
  fi
}

start
curl -fsS -m 10 -X PUT "$Z/src" >/dev/null
curl -fsS -m 10 -X PUT "$Z/dst" >/dev/null

# 20,000 source documents through _bulk_docs.
python3 - "$DOCS" >"$TMP/bulk.json" <<'EOF'
import json, sys
n = int(sys.argv[1])
print(json.dumps({"docs": [{"_id": "s%06d" % i, "n": i, "pad": "x" * 40} for i in range(n)]}))
EOF
curl -fsS -m 120 -X POST "$Z/src/_bulk_docs" -H "$J" --data-binary @"$TMP/bulk.json" >/dev/null

# --- 1. pull replication against concurrent writers on the target ---------
curl -sS -m 120 -X POST "$Z/_replicate" -H "$J" \
  -d "{\"source\":\"$Z/src\",\"target\":\"dst\",\"worker_batch_size\":100}" >"$TMP/repl.out" 2>"$TMP/repl.err" &
REPL=$!
sleep 0.3

cat >"$TMP/writers.py" <<'PY'
import http.client, sys, threading, os
port, stop, out, n = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
lock = threading.Lock()
def run(w):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    i = 0
    mine = []
    while not os.path.exists(stop):
        i += 1
        doc = "race-%d-%d" % (w, i)
        try:
            c.request("PUT", "/dst/" + doc, body='{"w":%d,"i":%d}' % (w, i), headers={"content-type": "application/json"})
            r = c.getresponse()
            r.read()
            if r.status == 201:
                mine.append(doc)
        except Exception:
            c.close()
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    with lock, open(out, "a") as f:
        f.write("\n".join(mine) + ("\n" if mine else ""))
ts = [threading.Thread(target=run, args=(w,)) for w in range(1, n + 1)]
[t.start() for t in ts]
[t.join() for t in ts]
PY
python3 "$TMP/writers.py" "$PORT" "$TMP/repl.done" "$TMP/acked.all" "$WRITERS" &
WPID=$!
wait "$REPL" || true
touch "$TMP/repl.done"
wait "$WPID" 2>/dev/null || true
alive "replication with writers"

grep -q '"ok":true' "$TMP/repl.out" || { echo "FAIL: replication answered: $(head -c 300 "$TMP/repl.out")" >&2; exit 1; }
[ -e "$TMP/acked.all" ] || : >"$TMP/acked.all"
ACKED=$(wc -l <"$TMP/acked.all" | tr -d ' ')
echo "replicated with $ACKED concurrent writes acknowledged"
if [ "$ACKED" -lt 200 ]; then
  echo "FAIL: only $ACKED writes overlapped the replication; the test proves nothing" >&2
  exit 1
fi

# Crash the process the hard way and check what a restart finds.
kill -9 "$SPID"
wait "$SPID" 2>/dev/null || true
start
python3 - "$Z" "$TMP/acked.all" "$DOCS" <<'EOF'
import json, sys, urllib.request
z, acked_path, docs = sys.argv[1], sys.argv[2], int(sys.argv[3])
def get(path):
    with urllib.request.urlopen(z + path, timeout=60) as r:
        return json.load(r)
ids = set()
start = None
while True:
    q = "/dst/_all_docs?limit=5000" + (("&startkey=" + json.dumps(start) + "&skip=1") if start else "")
    rows = get(q)["rows"]
    if not rows:
        break
    ids.update(r["id"] for r in rows)
    start = rows[-1]["id"]
acked = [l.strip() for l in open(acked_path) if l.strip()]
lost = [a for a in acked if a not in ids]
repl = sum(1 for i in ids if i.startswith("s"))
print("after restart: %d acknowledged writes, %d lost; %d/%d replicated documents" % (len(acked), len(lost), repl, docs))
if lost:
    sys.exit("FAIL: acknowledged writes lost: %s" % lost[:5])
if repl != docs:
    sys.exit("FAIL: only %d of %d replicated documents survived" % (repl, docs))
EOF

# --- 2. feeds and attachment downloads racing rewrites of one document ------
curl -fsS -m 10 -X PUT "$Z/hot" >/dev/null
REV=$(curl -fsS -m 10 -X PUT "$Z/hot/doc" -H "$J" -d '{"v":0}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')
head -c 400000 /dev/zero | tr '\0' 'a' > "$TMP/att.bin"
REV=$(curl -fsS -m 10 -X PUT "$Z/hot/doc/att?rev=$REV" -H 'content-type: text/plain' --data-binary "@$TMP/att.bin" | python3 -c 'import sys,json;print(json.load(sys.stdin)["rev"])')

STOP="$TMP/stop"
rewriter() {
  local rev=$1 i=0
  while [ ! -e "$STOP" ]; do
    i=$((i + 1))
    rev=$(curl -sS -m 10 -X PUT "$Z/hot/doc" -H "$J" -d "{\"_rev\":\"$rev\",\"v\":$i,\"_attachments\":{\"att\":{\"stub\":true}}}" 2>/dev/null |
      python3 -c 'import sys,json;print(json.load(sys.stdin).get("rev",""))' 2>/dev/null || true)
    [ -n "$rev" ] || rev=$(curl -sS -m 10 "$Z/hot/doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
  done
}
feeder() {
  while [ ! -e "$STOP" ]; do
    curl -sS -m 3 "$Z/hot/_changes?feed=longpoll&include_docs=true&since=now&timeout=300" >/dev/null 2>&1 || true
  done
}
downloader() {
  while [ ! -e "$STOP" ]; do
    curl -sS -m 5 -o /dev/null "$Z/hot/doc/att" 2>/dev/null || true
    curl -sS -m 5 -o /dev/null "$Z/hot/doc?attachments=true" 2>/dev/null || true
  done
}
rewriter "$REV" &
LOADPIDS="$!"
feeder &
LOADPIDS="$LOADPIDS $!"
feeder &
LOADPIDS="$LOADPIDS $!"
downloader &
LOADPIDS="$LOADPIDS $!"
downloader &
LOADPIDS="$LOADPIDS $!"
for _ in $(seq 1 15); do
  sleep 1
  alive "feed/attachment race"
done
touch "$STOP"
# shellcheck disable=SC2086
wait $LOADPIDS 2>/dev/null || true
alive "feed/attachment race"
curl -fsS -m 10 "$Z/_up" >/dev/null

echo "lock_domains: ok"
