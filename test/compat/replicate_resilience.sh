#!/usr/bin/env bash
# An interrupted replication must resume where it stopped, never lose documents
# and never leave a checkpoint ahead of the data. Self-contained: it starts its
# own Zouch and a deliberately slow CouchDB-shaped source.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6112}
SRC_PORT=${SRC_PORT:-6111}
DATA="$TMP/data"
Z="http://127.0.0.1:$PORT"
SRC="http://127.0.0.1:$SRC_PORT"
SPID=0
S1=0

cleanup() {
  kill -9 "$SPID" "$S1" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

start_source() {
  # A source from the previous case is still running and holds the port; a new
  # one would fail to bind and the old one would answer instead.
  if [ "$S1" -gt 0 ]; then
    kill -9 "$S1" 2>/dev/null || true
    wait "$S1" 2>/dev/null || true
  fi
  python3 test/compat/slow_source.py "$1" "$2" "$SRC_PORT" >/dev/null 2>"$TMP/source.log" &
  S1=$!
  sleep 0.3
  kill -0 "$S1" 2>/dev/null || fail "the source exited: $(cat "$TMP/source.log")"
  # /_stats identifies the source this run started; a stale one from a killed
  # run answers /_changes but not /_stats, and would silently serve the wrong
  # number of documents.
  for _ in $(seq 1 100); do
    curl -fsS --max-time 2 "$SRC/_stats" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "the source on $SRC_PORT is not the one this run started"
}

start_server() {
  "$BIN" serve "$DATA" "$PORT" >>"$TMP/server.log" 2>&1 &
  SPID=$!
  for _ in $(seq 1 150); do
    curl -fsS "$Z/_up" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "the server never came up"
}

# repl SOURCE_DB TARGET [OUT] -> prints the HTTP status
repl() {
  local out="${3:-$TMP/rep.json}"
  curl -sS -o "$out" -w '%{http_code}' -X POST "$Z/_replicate" \
    -H 'content-type: application/json' \
    -d "{\"source\":\"$SRC/$1\",\"target\":\"$2\"}"
}

# A request that lands on the worker running the replication waits for it, so a
# plain read can hang for the whole copy: give up quickly and ask again, which
# lands on an idle worker.
count() {
  local tries=0 c=""
  while [ "$tries" -lt 5 ]; do
    c=$(curl -sS --max-time 3 -f "$Z/$1" 2>/dev/null |
      python3 -c 'import sys,json;print(json.load(sys.stdin)["doc_count"])' 2>/dev/null || true)
    if [ -n "$c" ]; then
      echo "$c"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  echo 0
}

# How many documents the source has handed out. Asking the source keeps the
# poll off the server that is busy with the replication.
served() {
  curl -sS --max-time 2 "$SRC/_stats" 2>/dev/null |
    python3 -c 'import sys,json;print(json.load(sys.stdin)["served"])' 2>/dev/null || echo 0
}

jget() {
  python3 -c "import json;print(json.load(open('$1')).get('$2'))"
}

echo "== an interrupted pull resumes without losing documents =="
start_source 1200 0.006
start_server
curl -fsS -X PUT "$Z/t1" >/dev/null
t0=$(date +%s)
(repl t1 t1 "$TMP/first.json" >"$TMP/first.code") &
PULL=$!
# Wait until the first page is committed and the next one is under way, so the
# checkpoint is somewhere in the middle rather than at zero.
for _ in $(seq 1 300); do
  [ "$(served)" -ge 600 ] && break
  sleep 0.2
done
kill -9 "$S1" 2>/dev/null || true
wait "$PULL" 2>/dev/null || true
code=$(cat "$TMP/first.code")
present=$(count t1)
[ "$code" != "200" ] || fail "the interrupted pull reported success after $(( $(date +%s) - t0 ))s: $(cat "$TMP/first.json")"
[ "$present" -gt 0 ] || fail "nothing was copied before the interruption"
[ "$present" -lt 1200 ] || fail "the whole database was copied before the interruption"
curl -fsS "$Z/t1/s050" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["n"]==50,d' \
  || fail "a document copied before the interruption is unreadable"

start_source 1200 0.006
code=$(repl t1 t1 "$TMP/resume.json")
[ "$code" = "200" ] || fail "the resumed pull returned $code: $(cat "$TMP/resume.json")"
copied=$(jget "$TMP/resume.json" documents)
expected=$((1200 - present))
[ "$copied" = "$expected" ] || fail "the resumed pull copied $copied documents, expected $expected"
total=$(count t1)
[ "$total" = "1200" ] || fail "the target holds $total documents after resuming, expected 1200"
code=$(repl t1 t1 "$TMP/third.json")
again=$(jget "$TMP/third.json" documents)
[ "$again" = "0" ] || fail "a third pull copied $again documents instead of none"
echo "PASS: stopped at $present, resumed with $copied, 1200 documents intact"

echo "== two identical pulls at once do not duplicate or corrupt =="
start_source 300 0.01
curl -fsS -X PUT "$Z/t2" >/dev/null
(repl t2 t2 "$TMP/c_a.json" >"$TMP/c_a.code") &
A=$!
(repl t2 t2 "$TMP/c_b.json" >"$TMP/c_b.code") &
B=$!
wait "$A" "$B" 2>/dev/null || true
a=$(cat "$TMP/c_a.code")
b=$(cat "$TMP/c_b.code")
case "$a/$b" in
  200/200 | 200/409 | 409/200) ;;
  *) fail "concurrent pulls answered $a and $b" ;;
esac
n=$(count t2)
[ "$n" = "300" ] || fail "the target holds $n documents, expected 300"
curl -fsS "$Z/t2/s150" | python3 -c 'import sys,json;d=json.load(sys.stdin);assert d["n"]==150,d'
echo "PASS: concurrent pulls answered $a and $b, 300 documents intact"

echo "== a restart mid-pull resumes from the checkpoint =="
start_source 800 0.006
curl -fsS -X PUT "$Z/t3" >/dev/null
(repl t3 t3 "$TMP/r3.json" >"$TMP/r3.code") &
PULL=$!
for _ in $(seq 1 300); do
  [ "$(served)" -ge 550 ] && break
  sleep 0.2
done
kill -9 "$SPID" 2>/dev/null || true
wait "$PULL" 2>/dev/null || true
start_server
present=$(count t3)
[ "$present" -gt 0 ] || fail "the restart lost every document copied before it"
code=$(repl t3 t3 "$TMP/r3b.json")
[ "$code" = "200" ] || fail "the pull after the restart returned $code: $(cat "$TMP/r3b.json")"
copied=$(jget "$TMP/r3b.json" documents)
expected=$((800 - present))
[ "$copied" = "$expected" ] || fail "after the restart the pull copied $copied documents, expected $expected"
total=$(count t3)
[ "$total" = "800" ] || fail "the target holds $total documents after the restart, expected 800"
echo "PASS: survived a restart with $present documents and resumed with $copied"

echo "PASS: replication resilience"
