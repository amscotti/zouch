#!/usr/bin/env bash
# _security object storage checks. Uses ZOUCH (default http://127.0.0.1:5985).
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "security.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "security.sh: no Zouch answering at $Z" >&2
  echo "security.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "security.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi
DB="$Z/security_test"
SEC='{"admins":{"names":["alice"],"roles":["admin"]},"members":{"names":["bob"],"roles":[]}}'

EMPTY_SEC='{"admins":{"names":[],"roles":[]},"members":{"names":[],"roles":[]}}'

curl -fsS -X DELETE "$DB" >/dev/null 2>&1 || true
curl -fsS -X PUT "$DB" >/dev/null
[ "$(curl -fsS "$DB/_security")" = "$EMPTY_SEC" ]
[ "$(curl -fsS -X PUT "$DB/_security" -H 'content-type: application/json' -d "$SEC")" = '{"ok":true}' ]
[ "$(curl -fsS "$DB/_security")" = "$SEC" ]

code=$(curl -sS -o /tmp/zouch-security-bad -w '%{http_code}' -X PUT "$DB/_security" \
  -H 'content-type: application/json' -d '[]')
[ "$code" = "400" ]
grep -q '"error":"bad_request"' /tmp/zouch-security-bad

# A security object does not become a normal document.
code=$(curl -sS -o /dev/null -w '%{http_code}' "$DB/_security")
[ "$code" = "200" ]

# It survives a normal restart and database recreation.
curl -fsS -X DELETE "$DB" >/dev/null
curl -fsS -X PUT "$DB" >/dev/null
[ "$(curl -fsS "$DB/_security")" = "$EMPTY_SEC" ]

echo "PASS: _security objects are stored, validated and recreated empty"
