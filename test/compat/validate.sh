#!/usr/bin/env bash
# Server-side validate_doc_update checks against a local Zouch.
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "validate.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "validate.sh: no Zouch answering at $Z" >&2
  echo "validate.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "validate.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi
DB="$Z/validate_test"

curl -fsS -X DELETE "$DB" >/dev/null 2>&1 || true
curl -fsS -X PUT "$DB" >/dev/null

# A second design document proves every validator is evaluated, not just the first.
curl -fsS -X PUT "$DB/_design/guard" -H 'content-type: application/json' -d '{
  "validate_doc_update": "function(newDoc, oldDoc, userCtx, secObj) { if (newDoc._deleted) return; if (!newDoc.kind) throw({forbidden: \"kind required\"}); if (oldDoc && newDoc.kind === \"locked\" && oldDoc.kind === \"locked\") throw({forbidden: \"locked document\"}); }"
}' >/dev/null
curl -fsS -X PUT "$DB/_design/guard2" -H 'content-type: application/json' -d '{
  "validate_doc_update": "function(newDoc, oldDoc, userCtx, secObj) { if (newDoc.kind === \"blocked\") throw({forbidden: \"blocked by guard2\"}); }"
}' >/dev/null

code=$(curl -sS -o /tmp/zouch-validate-valid.json -w '%{http_code}' -X PUT "$DB/good" -H 'content-type: application/json' -d '{"kind":"ok","v":1}')
[ "$code" = "201" ] || { echo "valid write got HTTP $code"; exit 1; }

code=$(curl -sS -o /tmp/zouch-validate-invalid.json -w '%{http_code}' -X PUT "$DB/bad" -H 'content-type: application/json' -d '{"v":1}')
[ "$code" = "403" ] || { echo "missing kind got HTTP $code"; exit 1; }
grep -q 'kind required' /tmp/zouch-validate-invalid.json

code=$(curl -sS -o /tmp/zouch-validate-blocked.json -w '%{http_code}' -X PUT "$DB/blocked" -H 'content-type: application/json' -d '{"kind":"blocked"}')
[ "$code" = "403" ] || { echo "second validator got HTTP $code"; exit 1; }
grep -q 'blocked by guard2' /tmp/zouch-validate-blocked.json

# A delete is allowed by this validator even though the new document has no kind.
rev=$(python3 -c 'import json;print(json.load(open("/tmp/zouch-validate-valid.json"))["rev"])')
code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$DB/good?rev=$rev")
[ "$code" = "200" ] || { echo "validated delete got HTTP $code"; exit 1; }

# Bulk errors are per-document, not a failed batch.
bulk=$(curl -sS -X POST "$DB/_bulk_docs" -H 'content-type: application/json' -d '{"docs":[{"_id":"bulk-ok","kind":"ok"},{"_id":"bulk-bad"}]}')
python3 - "$bulk" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
by_id = {r.get('id'): r for r in rows}
assert by_id['bulk-ok'].get('ok') is True, rows
assert by_id['bulk-bad'].get('error') == 'forbidden', rows
assert by_id['bulk-bad'].get('reason') == 'kind required', rows
PY

echo "PASS: validate_doc_update accepts, rejects and reports per-document bulk errors"
