#!/usr/bin/env bash
# Replicating one database of this server into another, which CouchDB does with
# two plain database names and no network hop. Self-contained: starts its own
# server, needs no CouchDB.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6071}
Z="http://127.0.0.1:$PORT"

cleanup() {
  kill -9 "${SPID:-0}" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$TMP/data" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "$Z/_up" >/dev/null

curl -fsS -X PUT "$Z/src" >/dev/null
curl -fsS -X PUT "$Z/dst" >/dev/null
for i in 1 2 3 4 5; do
  curl -fsS -X PUT "$Z/src/d$i" -H 'content-type: application/json' -d "{\"n\":$i}" >/dev/null
done
rev=$(curl -fsS "$Z/src/d1" | jq -r ._rev)
curl -fsS -X PUT "$Z/src/d1/a.txt?rev=$rev" -H 'content-type: text/plain' --data-binary 'attachment payload' >/dev/null
# A deleted document has to travel too, or the target keeps a copy forever.
rev=$(curl -fsS -X PUT "$Z/src/gone" -H 'content-type: application/json' -d '{"v":1}' | jq -r .rev)
curl -fsS -X DELETE "$Z/src/gone?rev=$rev" >/dev/null

echo "== a local source copies into a local target =="
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d '{"source":"src","target":"dst"}' >"$TMP/rep.json"
[ "$(jq -r .ok "$TMP/rep.json")" = "true" ]
[ "$(jq -r .documents "$TMP/rep.json")" = "6" ]
[ "$(curl -fsS "$Z/dst" | jq -r .doc_count)" = "5" ]
[ "$(curl -fsS "$Z/dst/d2" | jq -r .n)" = "2" ]
[ "$(curl -fsS "$Z/dst/d1/a.txt")" = "attachment payload" ]
# The tombstone replicated, so the deleted document is absent rather than stale.
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/dst/gone")" = "404" ]
echo "copied 5 documents, one attachment and one deletion"

echo "== the checkpoint makes a repeat a no-op =="
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d '{"source":"src","target":"dst"}' >"$TMP/rep2.json"
[ "$(jq -r .documents "$TMP/rep2.json")" = "0" ]

echo "== only new changes are copied =="
curl -fsS -X PUT "$Z/src/new" -H 'content-type: application/json' -d '{"fresh":true}' >/dev/null
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d '{"source":"src","target":"dst"}' >"$TMP/rep3.json"
[ "$(jq -r .documents "$TMP/rep3.json")" = "1" ]
[ "$(curl -fsS "$Z/dst/new" | jq -r .fresh)" = "true" ]

echo "== refusals =="
code=$(curl -sS -o "$TMP/same.json" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' -d '{"source":"src","target":"src"}')
[ "$code" = "400" ]
jq -e '.error == "bad_request"' <"$TMP/same.json" >/dev/null
code=$(curl -sS -o "$TMP/missing.json" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' -d '{"source":"nope","target":"dst"}')
[ "$code" = "404" ]
jq -e '.error == "not_found"' <"$TMP/missing.json" >/dev/null

echo "== create_target makes the destination =="
curl -fsS -X POST "$Z/_replicate" -H 'content-type: application/json' \
  -d '{"source":"src","target":"built","create_target":true}' >"$TMP/rep4.json"
[ "$(curl -fsS "$Z/built" | jq -r .doc_count)" = "6" ]

echo "== a _replicator document refuses two local names =="
# CouchDB takes local endpoints only on /_replicate; a scheduler job needs real
# URLs, and replicate_scheduler.sh covers that with a remote source.
curl -fsS -X PUT "$Z/dst2" >/dev/null
body=$(mktemp)
code=$(curl -sS -o "$body" -w '%{http_code}' -X PUT "$Z/_replicator/localjob" -H 'content-type: application/json' \
  -d '{"source":"src","target":"dst2"}')
[ "$code" = "403" ]
jq -e '.reason == "local_endpoints_not_supported"' < "$body" >/dev/null
rm -f "$body"
echo "local endpoints refused"

echo "PASS: local to local replication"
