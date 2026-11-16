#!/usr/bin/env bash
# Multipart Couchbase-family _bulk_docs and _bulk_get compatibility.
set -euo pipefail
BIN="${ZOUCH_BIN:-./zig-out/bin/zouch}"
PORT="${ZOUCH_BULK_MP_PORT:-6044}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zouch-bulk-mp.XXXXXX")
DATA="$TMP/data"
LOG="$TMP/server.log"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if ! curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then
  cat "$LOG" >&2 || true
  exit 1
fi

python3 - "$PORT" <<'PY'
import http.client
import json
import sys

port = int(sys.argv[1])

def request(method, path, body=None, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    hdrs = {k.lower(): v for k, v in r.getheaders()}
    c.close()
    return r.status, hdrs, data

status, _, _ = request("PUT", "/bulk_mp")
assert status == 201, status

payload = b"hello raw attachment"
status, _, _ = request("PUT", "/bulk_mp/mp", body=json.dumps({
    "_id": "mp",
    "v": 1,
    "_attachments": {"a.txt": {
        "content_type": "text/plain",
        "data": __import__("base64").b64encode(payload).decode(),
    }},
}).encode(), headers={"Content-Type": "application/json"})
assert status == 201, status

# _bulk_get returns nested multipart/related for attachment docs and plain
# application/json parts for attachment-free docs.
body = json.dumps({"docs": [{"id": "mp"}, {"id": "none"}]}).encode()
status, hdrs, resp = request(
    "POST", "/bulk_mp/_bulk_get?revs=true&attachments=true", body,
    {"Content-Type": "application/json", "Accept": "multipart/related, application/json"},
)
assert status == 200, (status, resp[:500])
assert hdrs.get("content-type", "").startswith("multipart/mixed"), hdrs
text = resp.decode("latin1")
assert "X-Doc-Id: mp" in text, text[:1000]
outer_boundary = hdrs["content-type"].split("boundary=")[1].split(";")[0]
assert f"--{outer_boundary}" in text
inner_match = __import__("re").search(r"multipart/related; boundary=([^\r\n]+)", text)
assert inner_match, text[:1000]
inner_boundary = inner_match.group(1)
assert f"--{inner_boundary}--" in text
assert '"follows":true' in text
assert payload.decode() in text
assert "X-Doc-Id: none" in text
assert '"error":"not_found"' in text

# _bulk_docs accepts a multipart/related body where each top-level part is a
# document and attachment documents nest another multipart/related body.
outer = "zouchouter"
inner = "zouchinner"
plain = json.dumps({"_id": "plain", "v": 2}).encode()
att = json.dumps({
    "_id": "nested",
    "_attachments": {"a.txt": {
        "content_type": "text/plain",
        "length": len(payload),
        "follows": True,
    }},
}).encode()
nested = (
    b"--" + inner.encode() + b"\r\nContent-Type: application/json\r\n\r\n" + att +
    b"\r\n--" + inner.encode() +
    b"\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=\"a.txt\"\r\n\r\n" +
    payload + b"\r\n--" + inner.encode() + b"--\r\n"
)
body = (
    b"--" + outer.encode() + b"\r\nContent-Type: application/json\r\n\r\n" + plain +
    b"\r\n--" + outer.encode() +
    b"\r\nContent-Type: multipart/related; boundary=" + inner.encode() + b"\r\n\r\n" + nested +
    b"\r\n--" + outer.encode() + b"--\r\n"
)
status, _, resp = request(
    "POST", "/bulk_mp/_bulk_docs?new_edits=true", body,
    {"Content-Type": "multipart/related; boundary=" + outer},
)
assert status == 201, (status, resp[:1000])
rows = json.loads(resp)
assert {row.get("id") for row in rows} == {"plain", "nested"}, rows
assert all(row.get("ok") is True for row in rows), rows

status, _, resp = request("GET", "/bulk_mp/nested/a.txt")
assert status == 200 and resp == payload, (status, resp)
status, _, resp = request("GET", "/bulk_mp/plain")
assert status == 200 and json.loads(resp)["v"] == 2

# A multipart update that retains an attachment stub must not drop the blob.
status, _, doc = request("GET", "/bulk_mp/nested")
doc = json.loads(doc)
update = json.dumps({
    "_id": "nested",
    "_rev": doc["_rev"],
    "_attachments": doc["_attachments"],
}).encode()
body = (
    b"--" + outer.encode() + b"\r\nContent-Type: application/json\r\n\r\n" + update +
    b"\r\n--" + outer.encode() + b"--\r\n"
)
upd_status, _, upd_resp = request(
    "POST", "/bulk_mp/_bulk_docs?new_edits=true", body,
    {"Content-Type": "multipart/related; boundary=" + outer},
)
assert upd_status == 201, (upd_status, upd_resp)
status, _, resp = request("GET", "/bulk_mp/nested/a.txt")
assert status == 200 and resp == payload, (status, resp)

# Invalid docs shape must be a JSON 400, not a worker panic.
status, _, resp = request("POST", "/bulk_mp/_bulk_get", b'{"docs":null}',
                          {"Content-Type": "application/json"})
assert status == 400 and json.loads(resp)["error"] == "bad_request", (status, resp)

print("PASS: multipart _bulk_docs and _bulk_get")
PY
