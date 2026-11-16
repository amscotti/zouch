#!/usr/bin/env bash
# Mango operators added for app parity: $regex, $allMatch and $keyMapMatch.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6009}
DATA="$TMP/data"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  pkill -f "zouch serve $DATA" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
Z="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$Z/mango" >/dev/null
curl -fsS -X PUT "$Z/mango/alpha" -H 'content-type: application/json' \
  -d '{"name":"Alpha-42","tags":["a","b"],"nested":{"x":1,"y":"z"}}' >/dev/null
curl -fsS -X PUT "$Z/mango/beta" -H 'content-type: application/json' \
  -d '{"name":"beta","tags":["a","x"],"nested":{"x":2}}' >/dev/null
curl -fsS -X PUT "$Z/mango/odd" -H 'content-type: application/json' \
  -d '{"name":"other","tags":["a","BB"],"nested":{"x":"nope","z":3}}' >/dev/null

find() { curl -fsS -X POST "$Z/mango/_find" -H 'content-type: application/json' -d "$1"; }
ids() { jq -c '[.docs[]._id] | sort'; }

[ "$(find '{"selector":{"name":{"$regex":"^Alpha-[0-9]+$"}}}' | ids)" = '["alpha"]' ]
[ "$(find '{"selector":{"tags":{"$allMatch":{"$regex":"^[a-z]$"}}}}' | ids)" = '["alpha","beta"]' ]
[ "$(find '{"selector":{"nested":{"$keyMapMatch":{"$gte":2}}}}' | ids)" = '["beta","odd"]' ]
[ "$(find '{"selector":{"name":{"$regex":"["}}}' | ids)" = '[]' ]

curl -fsS -X POST "$Z/mango/_index" -H 'content-type: application/json' \
  -d '{"index":{"fields":["name"]},"ddoc":"mango_idx","name":"name_idx"}' >/dev/null
[ "$(find '{"selector":{"name":"beta"},"use_index":["mango_idx","name_idx"]}' | ids)" = '["beta"]' ]
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/mango/_find" \
  -H 'content-type: application/json' -d '{"selector":{"name":"beta"},"use_index":["mango_idx","missing"]}')
[ "$code" = "400" ]

curl -fsS -X POST "$Z/mango/_index" -H 'content-type: application/json' \
  -d '{"index":{"fields":["name","nested.x"]},"ddoc":"mango_idx2","name":"composite"}' >/dev/null
[ "$(find '{"selector":{"name":"beta","nested.x":2},"use_index":["mango_idx2","composite"]}' | ids)" = '["beta"]' ]
[ "$(find '{"selector":{"name":"beta","nested.x":1},"use_index":["mango_idx2","composite"]}' | ids)" = '[]' ]
curl -fsS -X PUT "$Z/mango/r1" -H 'content-type: application/json' -d '{"name":"range","nested":{"x":3}}' >/dev/null
curl -fsS -X PUT "$Z/mango/r2" -H 'content-type: application/json' -d '{"name":"range","nested":{"x":5}}' >/dev/null
[ "$(find '{"selector":{"name":"range","nested.x":{"$gte":3,"$lt":6}},"use_index":["mango_idx2","composite"]}' | ids)" = '["r1","r2"]' ]
[ "$(find '{"selector":{"name":"range","nested.x":{"$gt":3,"$lte":5}},"use_index":["mango_idx2","composite"]}' | ids)" = '["r2"]' ]
[ "$(curl -fsS -X POST "$Z/mango/_explain" -H 'content-type: application/json' \
  -d '{"selector":{"name":"range","nested.x":{"$gte":3}},"use_index":["mango_idx2","composite"]}' | jq -r .index.name)" = "composite" ]
[ "$(find '{"selector":{"$text":"alpha"}}' | ids)" = '["alpha"]' ]
[ "$(find '{"selector":{"$text":"name:beta"}}' | ids)" = '["beta"]' ]
[ "$(find '{"selector":{"$text":"BB"}}' | ids)" = '["odd"]' ]
[ "$(find '{"selector":{"name":"beta"},"execution_stats":true}' | jq -r '.execution_stats.total_docs_examined >= 1 and .execution_stats.results_returned == 1')" = "true" ]

# The text index must follow updates rather than serving stale tokens.
REV=$(curl -fsS "$Z/mango/alpha" | jq -r ._rev)
curl -fsS -X PUT "$Z/mango/alpha" -H 'content-type: application/json' \
  -d "{\"_rev\":\"$REV\",\"name\":\"Gamma-42\",\"tags\":[\"a\",\"b\"],\"nested\":{\"x\":1,\"y\":\"z\"}}" >/dev/null
[ "$(find '{"selector":{"$text":"gamma"}}' | ids)" = '["alpha"]' ]
[ "$(find '{"selector":{"$text":"alpha"}}' | ids)" = '[]' ]

[ -s "$DATA/mango/text.idx" ]
kill -9 "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
"$BIN" serve "$DATA" "$PORT" >"$TMP/server2.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
[ "$(curl -fsS -X POST "$Z/mango/_find" -H 'content-type: application/json' \
  -d '{"selector":{"$text":"gamma"}}' | ids)" = '["alpha"]' ]
[ "$(curl -fsS -X POST "$Z/mango/_find" -H 'content-type: application/json' \
  -d '{"selector":{"name":"beta","nested.x":2},"use_index":["mango_idx2","composite"]}' | ids)" = '["beta"]' ]

echo "PASS: Mango \$regex, \$allMatch and \$keyMapMatch match CouchDB shapes"
