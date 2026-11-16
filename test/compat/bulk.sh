#!/usr/bin/env bash
# Bulk-load 10,000 documents through _bulk_docs.
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "bulk.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "bulk.sh: no Zouch answering at $Z" >&2
  echo "bulk.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "bulk.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi
COUNT="${BULK_COUNT:-10000}"

curl -sS -X DELETE "$Z/bulk_test" >/dev/null 2>&1 || true
curl -fsS -X PUT "$Z/bulk_test" >/dev/null

python3 - "$COUNT" >/tmp/zouch-bulk.json <<'PY'
import json, sys
n = int(sys.argv[1])
docs = [{"_id": f"d{i:06d}", "n": i, "pad": "x" * 32} for i in range(n)]
sys.stdout.write(json.dumps({"docs": docs, "new_edits": True}))
PY

start=$(date +%s%N)
result=$(curl -fsS -X POST "$Z/bulk_test/_bulk_docs" -H 'content-type: application/json' --data-binary @/tmp/zouch-bulk.json)
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))

errors=$(printf '%s' "$result" | jq '[.[] | select(.error != null)] | length')
[ "$errors" = "0" ]
count=$(curl -fsS "$Z/bulk_test" | jq -r .doc_count)
[ "$count" = "$COUNT" ]
[ "$(curl -fsS "$Z/bulk_test/d000000" | jq -r .n)" = "0" ]
[ "$(curl -fsS "$Z/bulk_test/d$(printf '%06d' $((COUNT - 1)))" | jq -r .n)" = "$((COUNT - 1))" ]

echo "PASS: bulk loaded $COUNT documents in ${elapsed_ms} ms"
