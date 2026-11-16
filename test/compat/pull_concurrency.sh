#!/usr/bin/env bash
# A pull must not freeze the server, and its target must not be deletable while
# it runs. Self-contained: starts its own Zouch and a deliberately slow
# CouchDB-shaped source (test/compat/slow_source.py), so it needs no CouchDB.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-5996}
DATA="$TMP/data"
Z="http://127.0.0.1:$PORT"

cleanup() {
  kill -9 "${SPID:-0}" "${SRC:-0}" "${SRC2:-0}" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# 300 documents at 20ms each: a pull that lasts several seconds.
SRC_PORT=${SRC_PORT:-5995}
python3 test/compat/slow_source.py 300 0.02 "$SRC_PORT" >"$TMP/source.port" 2>"$TMP/source.log" &
SRC=$!
"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "$Z/_up" >/dev/null
# The source is a Python process; wait for it to bind before replicating from
# it, or the pull fails with a connection error instead of testing the lock.
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$SRC_PORT/src/_changes?since=0" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$SRC_PORT/src/_changes?since=0" >/dev/null
curl -fsS -X PUT "$Z/small" >/dev/null
curl -fsS -X PUT "$Z/target" >/dev/null

echo "== a pull does not freeze other requests =="
# Four readers sample a different database while the pull runs. With the mutex
# held for the whole copy every read waits until the copy ends; with the lock
# released between network waits, most come back at once. Parallel lanes keep
# one unlucky request from stopping the measurement.
curl -sS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://127.0.0.1:$SRC_PORT/src\",\"target\":\"target\"}" >"$TMP/pull.json" &
PULL=$!
sleep 0.3
seq 1 4 | xargs -P4 -n1 sh -c '
  Z=$1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    t0=$(date +%s%N)
    curl -fsS "$Z/small" >/dev/null || true
    echo $(( ($(date +%s%N) - t0) / 1000000 ))
    sleep 0.1
  done' _ "$Z" >"$TMP/reads"
wait "$PULL"
docs=$(jq -r .documents "$TMP/pull.json")
if [ "$docs" != "300" ]; then
  echo "pull did not replicate: $(cat "$TMP/pull.json")" >&2
  tail -5 "$TMP/server.log" >&2
  exit 1
fi
reads=$(wc -l <"$TMP/reads")
fast=$(awk '$1 < 200' "$TMP/reads" | wc -l)
slowest=$(sort -n "$TMP/reads" | tail -1)
echo "reads during pull: $reads, under 200ms: $fast, slowest: ${slowest}ms"
# The old behaviour was zero of N: every read waited for the whole copy.
[ "$reads" -ge 20 ]
[ "$fast" -ge $(( reads / 2 )) ]

echo "== the target cannot be deleted mid-pull =="
curl -fsS -X PUT "$Z/target2" >/dev/null
curl -sS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"http://127.0.0.1:$SRC_PORT/src\",\"target\":\"target2\"}" >"$TMP/pull2.json" &
PULL=$!
sleep 0.4
code=$(curl -sS -o "$TMP/del.json" -w '%{http_code}' -X DELETE "$Z/target2")
[ "$code" = "409" ]
jq -e '.error == "conflict"' <"$TMP/del.json" >/dev/null
wait "$PULL"
# Once the pull is done the same delete succeeds.
curl -fsS -X DELETE "$Z/target2" >/dev/null
echo "delete during pull -> 409, after -> ok"

echo "== an attachment whose digest does not match is refused =="
# A source that lies about its attachment digest must not be stored: the
# imported bytes would look valid and every later hop would inherit them.
SRC2_PORT=${SRC2_PORT:-5994}
python3 test/compat/slow_source.py 3 0 "$SRC2_PORT" bad-digest >/dev/null 2>"$TMP/source2.log" &
SRC2=$!
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$SRC2_PORT/src/_changes?since=0" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS -X PUT "$Z/baddigest" >/dev/null
code=$(curl -sS -o "$TMP/bad.json" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' \
  -d "{\"source\":\"http://127.0.0.1:$SRC2_PORT/src\",\"target\":\"baddigest\"}")
[ "$code" = "502" ]
jq -e '.error == "replication_failed"' <"$TMP/bad.json" >/dev/null
jq -r .reason <"$TMP/bad.json" | grep -q AttachmentDigestMismatch
[ "$(curl -fsS "$Z/baddigest" | jq -r .doc_count)" = "0" ]
echo "bad digest -> 502, nothing imported"

echo "== a pull from this server into itself does not deadlock =="
# The pull fetches attachments over HTTP while it holds the database lock only
# for the write. Fetching them under the lock deadlocked the server when the
# source was the same process: the request it waited on needed that lock.
curl -fsS -X PUT "$Z/selfsrc" >/dev/null
curl -fsS -X PUT "$Z/selfsrc/d" -H 'content-type: application/json' -d '{"v":1}' >/dev/null
REV=$(curl -fsS "$Z/selfsrc/d" | jq -r ._rev)
curl -fsS -X PUT "$Z/selfsrc/d/a.txt?rev=$REV" -H 'content-type: text/plain' --data-binary 'self payload' >/dev/null
curl -fsS -X PUT "$Z/selfcopy" >/dev/null
code=$(curl -sS -m 20 -o "$TMP/self.json" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' -d "{\"source\":\"$Z/selfsrc\",\"target\":\"selfcopy\"}")
[ "$code" = "200" ]
[ "$(jq -r .documents "$TMP/self.json")" = "1" ]
[ "$(curl -fsS "$Z/selfcopy/d/a.txt")" = "self payload" ]
echo "same-server pull -> ok"

echo "PASS: pull releases the lock and pins its target"
