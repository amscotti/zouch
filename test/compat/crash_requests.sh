#!/usr/bin/env bash
# Requests that used to abort the whole process (float formatting, throwing map functions, big integers in _find, limit/skip overflow, _local rev overflow, _scheduler/jobs) must answer and leave the server alive.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5997}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
wait_ready || { cat "$LOG" >&2; exit 1; }
Z="http://127.0.0.1:$PORT"
J='content-type: application/json'
fail=0

# expect <label> <want-status> <curl args...>
expect() {
  local label=$1 want=$2
  shift 2
  local got
  got=$(curl -sS -m 10 -o "$TMP/body" -w '%{http_code}' "$@" || echo "000")
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: want $want got $got: $(head -c 200 "$TMP/body" 2>/dev/null)" >&2
    fail=1
  else
    echo "ok   $label ($got)"
  fi
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "FAIL $label: server died" >&2
    tail -5 "$LOG" >&2
    exit 1
  fi
}

curl -fsS -X PUT "$Z/c" >/dev/null

# C2: floats whose plain-decimal form does not fit a small buffer.
for n in 1e64 1e100 1.5e300 1.7976931348623157e308 1e-63 5e-324; do
  curl -fsS -X PUT "$Z/c/f$n" -H "$J" -d "{\"n\":$n}" >/dev/null
  expect "float $n GET" 200 "$Z/c/f$n"
  python3 -c "import json,sys; json.load(open('$TMP/body'))" || { echo "FAIL float $n: body is not JSON" >&2; fail=1; }
done
expect "all_docs include_docs with huge floats" 200 "$Z/c/_all_docs?include_docs=true"
expect "changes include_docs with huge floats" 200 "$Z/c/_changes?include_docs=true"

# C3: a map function that throws, and one that does not parse.
curl -fsS -X PUT "$Z/c/plain" -H "$J" -d '{"x":1}' >/dev/null
curl -fsS -X PUT "$Z/c/_design/throws" -H "$J" \
  -d '{"views":{"v":{"map":"function(doc){ emit(doc.type.toUpperCase(), null); }"}}}' >/dev/null
curl -fsS -X PUT "$Z/c/_design/syntax" -H "$J" \
  -d '{"views":{"v":{"map":"function(doc){ emit(doc._id; }"}}}' >/dev/null
curl -fsS -X PUT "$Z/c/_design/fine" -H "$J" \
  -d '{"views":{"v":{"map":"function(doc){ emit(doc._id, null); }"}}}' >/dev/null
expect "view with throwing map" 500 "$Z/c/_design/throws/_view/v"
expect "view with syntax error" 500 "$Z/c/_design/syntax/_view/v"
expect "view that works afterwards" 200 "$Z/c/_design/fine/_view/v"
expect "throwing view again (lock state intact)" 500 "$Z/c/_design/throws/_view/v"
curl -fsS -X PUT "$Z/c/after" -H "$J" -d '{"ok":true}' >/dev/null

# C4: integers outside i64 and literals that parse to infinity.
curl -fsS -X PUT "$Z/c/big" -H "$J" -d '{"n":99999999999999999999}' >/dev/null
curl -fsS -X PUT "$Z/c/inf" -H "$J" -d '{"n":1e999}' >/dev/null
for op in '$gt' '$gte' '$lt' '$lte' '$eq' '$ne'; do
  expect "find n $op 0" 200 -X POST "$Z/c/_find" -H "$J" -d "{\"selector\":{\"n\":{\"$op\":0}}}"
  expect "find n $op bigint" 200 -X POST "$Z/c/_find" -H "$J" -d "{\"selector\":{\"n\":{\"$op\":99999999999999999999}}}"
done
curl -fsS -X POST "$Z/c/_index" -H "$J" -d '{"index":{"fields":["n"]},"name":"by-n","type":"json"}' >/dev/null
expect "find sort by bigint field" 200 -X POST "$Z/c/_find" -H "$J" \
  -d '{"selector":{"n":{"$gt":-1}},"sort":[{"n":"asc"}]}'
curl -fsS -X POST "$Z/c/_find" -H "$J" -d '{"selector":{"n":{"$gt":0}}}' |
  python3 -c "
import json,sys
ids=[d['_id'] for d in json.load(sys.stdin)['docs']]
assert 'big' in ids, ids
" || { echo "FAIL: bigint document missing from \$gt:0" >&2; fail=1; }

# C5: limit + skip overflow.
expect "_all_docs limit=2^64-1 skip=1" 200 "$Z/c/_all_docs?limit=18446744073709551615&skip=1"
expect "view limit=2^64-1 skip=1" 200 "$Z/c/_design/fine/_view/v?limit=18446744073709551615&skip=1"
expect "view reduce=false limit=2^64-1 skip=1" 200 "$Z/c/_design/fine/_view/v?reduce=false&limit=18446744073709551615&skip=1"
expect "_find skip=2^64-1" 200 -X POST "$Z/c/_find" -H "$J" -d '{"selector":{},"skip":9223372036854775807,"limit":10}'

# C6: _local revision arithmetic.
expect "_local _rev 0-4294967295" 400 -X PUT "$Z/c/_local/x" -H "$J" -d '{"_rev":"0-4294967295"}'

# H6: _scheduler/jobs must work on every platform.
expect "_scheduler/jobs" 200 "$Z/_scheduler/jobs"
expect "_scheduler/docs" 200 "$Z/_scheduler/docs"
expect "_active_tasks" 200 "$Z/_active_tasks"

[ "$fail" = 0 ] || exit 1
echo "crash_requests: ok"
