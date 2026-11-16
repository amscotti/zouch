#!/usr/bin/env bash
# Segment-only compaction checks. Uses ZOUCH (default http://127.0.0.1:5985).
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "compact.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "compact.sh: no Zouch answering at $Z" >&2
  echo "compact.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "compact.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi
DB="$Z/compact_test"

curl -fsS -X DELETE "$DB" >/dev/null 2>&1 || true
curl -fsS -X PUT "$DB" >/dev/null

python3 - "$DB" <<'PY'
import json, sys, urllib.request
base = sys.argv[1]
def req(method, path, body=None, headers=None):
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(r) as resp:
        return resp.status, resp.read()
docs = [{"_id": f"d{i}", "n": i, "v": "old"} for i in range(100)]
docs.append({"_id": "att", "_attachments": {"f.txt": {"content_type": "text/plain", "data": "aGVsbG8="}}})
st, _ = req("POST", "/_bulk_docs", json.dumps({"docs": docs}).encode(), {"content-type": "application/json"})
assert st == 201, st
for i in range(30):
    _, b = req("GET", f"/d{i}")
    rev = json.loads(b)["_rev"]
    st, _ = req("PUT", f"/d{i}", json.dumps({"_rev": rev, "n": i, "v": "new"}).encode(), {"content-type": "application/json"})
    assert st == 201, (i, st)
st, _ = req("PUT", "/_design/v", json.dumps({"views": {"by_n": {"map": "function(doc){emit(doc.n,doc.v)}"}}}).encode(), {"content-type": "application/json"})
assert st == 201, st
st, _ = req("POST", "/_compact")
assert st == 202, st
_, b = req("GET", "/d0")
assert json.loads(b)["v"] == "new", b
st, b = req("GET", "/att/f.txt")
assert st == 200 and b == b"hello", (st, b)
st, b = req("GET", "/_design/v/_view/by_n?limit=1")
assert st == 200 and json.loads(b)["rows"], b
print("PASS: segment-only compaction preserved documents, attachments and views")
PY
