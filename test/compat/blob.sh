#!/usr/bin/env bash
# Attachment blob-store checks. Uses ZOUCH (default http://127.0.0.1:5985).
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "blob.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "blob.sh: no Zouch answering at $Z" >&2
  echo "blob.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "blob.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi
DB="$Z/blob_test"

curl -fsS -X DELETE "$DB" >/dev/null 2>&1 || true
curl -fsS -X PUT "$DB" >/dev/null

# Inline attachment on a normal document write.
curl -fsS -X PUT "$DB/doc" -H 'content-type: application/json' -d '{
  "kind": "blob",
  "_attachments": {"hello.txt": {"content_type": "text/plain", "data": "YXR0YWNobWVudCBwYXlsb2Fk"}}
}' >/dev/null

doc=$(curl -fsS "$DB/doc")
python3 - "$doc" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
a = d["_attachments"]["hello.txt"]
assert a["stub"] is True, a
assert "data" not in a, a
assert a["length"] == 18, a
assert a["digest"] == "md5-vvPgt6kVohmiNxyJvEdg8w==", a
PY
[ "$(curl -fsS "$DB/doc/hello.txt")" = "attachment payload" ]

# A stub update must reuse the external blob.
rev=$(curl -fsS "$DB/doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X PUT "$DB/doc" -H 'content-type: application/json' \
  -d "{\"_rev\":\"$rev\",\"x\":2,\"_attachments\":{\"hello.txt\":{\"stub\":true}}}" >/dev/null
[ "$(curl -fsS "$DB/doc/hello.txt")" = "attachment payload" ]

# Bulk writes with attachment data are externalized too.
curl -fsS -X POST "$DB/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"bulk","_attachments":{"b.bin":{"content_type":"application/octet-stream","data":"AAECAwQ="}}}]}' >/dev/null
[ "$(curl -fsS "$DB/bulk/b.bin" | od -An -tx1 | tr -d ' \n')" = "0001020304" ]

# Inline expansion still works for replication clients.
curl -fsS "$DB/doc?attachments=true" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["_attachments"]["hello.txt"]["data"] == "YXR0YWNobWVudCBwYXlsb2Fk"
'

# _bulk_get honors attachments=true for replication clients.
brev=$(curl -fsS "$DB/bulk" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X POST "$DB/_bulk_get?revs=true&attachments=true" -H 'content-type: application/json' \
  -d "{\"docs\":[{\"id\":\"bulk\",\"rev\":\"$brev\"}]}" | python3 -c '
import json,sys
r=json.load(sys.stdin)["results"][0]["docs"][0]["ok"]
assert r["_attachments"]["b.bin"]["data"] == "AAECAwQ=", r
'

# Deleting the attachment must not leave a readable stub.
rev=$(curl -fsS "$DB/doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X DELETE "$DB/doc/hello.txt?rev=$rev" >/dev/null
code=$(curl -sS -o /dev/null -w '%{http_code}' "$DB/doc/hello.txt")
[ "$code" = "404" ]

# Raw streaming upload: larger than the 1 MiB lazy-read window and chunked transfer.
python3 - <<'PY'
with open("/tmp/zouch-stream.bin", "wb") as f:
    f.write((b"streaming-attachment-0123456789" * 80000)[:2_100_017])
PY
rev=$(curl -fsS "$DB/doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X PUT "$DB/doc/stream.bin?rev=$rev" -H 'content-type: application/octet-stream' \
  --data-binary @/tmp/zouch-stream.bin >/dev/null
curl -fsS "$DB/doc/stream.bin" -o /tmp/zouch-stream.out
cmp /tmp/zouch-stream.bin /tmp/zouch-stream.out
rev=$(curl -fsS "$DB/doc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X PUT "$DB/doc/chunk.txt?rev=$rev" -H 'content-type: text/plain' \
  -H 'Transfer-Encoding: chunked' --data-binary 'chunked attachment' >/dev/null
[ "$(curl -fsS "$DB/doc/chunk.txt")" = "chunked attachment" ]
rm -f /tmp/zouch-stream.bin /tmp/zouch-stream.out

echo "PASS: attachment blobs are externalized, reused, expanded and deleted"
