#!/usr/bin/env bash
# Per-database checkpoint isolation (H3), per-document push rejections continuing (H8), and gzip attachment encoding preservation across PUT, inline JSON, GET, and multipart _bulk_get (H7).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$PWD/zig-out/bin/zouch"
TMP=$(mktemp -d)
PORT=${PORT:-6073}
DATA="$TMP/data"
LOG="$TMP/server.log"
SPID=""

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
SPID=$!
Z="http://127.0.0.1:$PORT"
J='content-type: application/json'
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "$Z/_up" >/dev/null

# --- H3: separate or recreated targets do not inherit another target's checkpoint ---
curl -fsS -X PUT "$Z/s5" >/dev/null
for i in 1 2 3; do
  curl -fsS -X PUT "$Z/s5/d$i" -H "$J" -d "{\"n\":$i}" >/dev/null
done
curl -fsS -X PUT "$Z/a5" >/dev/null
curl -fsS -X PUT "$Z/b5" >/dev/null

curl -fsS -X POST "$Z/_replicate" -H "$J" -d "{\"source\":\"$Z/s5\",\"target\":\"a5\"}" >"$TMP/h3_a.json"
[ "$(jq -r .documents "$TMP/h3_a.json")" = "3" ]
[ "$(curl -fsS "$Z/a5" | jq -r .doc_count)" = "3" ]

curl -fsS -X POST "$Z/_replicate" -H "$J" -d "{\"source\":\"$Z/s5\",\"target\":\"b5\"}" >"$TMP/h3_b.json"
[ "$(jq -r .documents "$TMP/h3_b.json")" = "3" ]
[ "$(curl -fsS "$Z/b5" | jq -r .doc_count)" = "3" ]

curl -fsS -X DELETE "$Z/a5" >/dev/null
curl -fsS -X PUT "$Z/a5" >/dev/null
curl -fsS -X POST "$Z/_replicate" -H "$J" -d "{\"source\":\"$Z/s5\",\"target\":\"a5\"}" >"$TMP/h3_a2.json"
[ "$(jq -r .documents "$TMP/h3_a2.json")" = "3" ]
[ "$(curl -fsS "$Z/a5" | jq -r .doc_count)" = "3" ]
echo "ok   H3 checkpoint isolation"

# --- H8: push continues past per-document VDU rejections and advances checkpoint ---
curl -fsS -X PUT "$Z/p_src" >/dev/null
curl -fsS -X PUT "$Z/p_dst" >/dev/null
curl -fsS -X PUT "$Z/p_dst/_design/vdu" -H "$J" \
  -d '{"validate_doc_update":"function(newDoc){ if(newDoc.reject) throw({forbidden:\"nope\"}); }"}' >/dev/null
curl -fsS -X PUT "$Z/p_src/ok1" -H "$J" -d '{"n":1}' >/dev/null
curl -fsS -X PUT "$Z/p_src/bad2" -H "$J" -d '{"n":2,"reject":true}' >/dev/null
curl -fsS -X PUT "$Z/p_src/ok3" -H "$J" -d '{"n":3}' >/dev/null
curl -fsS -X PUT "$Z/p_src/ok4" -H "$J" -d '{"n":4}' >/dev/null

curl -fsS -X POST "$Z/_replicate" -H "$J" -d "{\"source\":\"p_src\",\"target\":\"$Z/p_dst\"}" >"$TMP/h8_1.json"
[ "$(jq -r .ok "$TMP/h8_1.json")" = "true" ]
[ "$(jq -r .documents "$TMP/h8_1.json")" = "3" ]
[ "$(jq -r .history[0].doc_write_failures "$TMP/h8_1.json")" = "1" ]
[ "$(curl -fsS "$Z/p_dst" | jq -r .doc_count)" = "4" ] # 3 docs + _design/vdu

curl -fsS -X PUT "$Z/p_src/ok5" -H "$J" -d '{"n":5}' >/dev/null
curl -fsS -X POST "$Z/_replicate" -H "$J" -d "{\"source\":\"p_src\",\"target\":\"$Z/p_dst\"}" >"$TMP/h8_2.json"
[ "$(jq -r .documents "$TMP/h8_2.json")" = "1" ]
[ "$(jq -r .history[0].doc_write_failures "$TMP/h8_2.json")" = "0" ]
echo "ok   H8 per-doc push failures"

# --- H7: attachment gzip encoding preserved across PUT, inline JSON, GET, _bulk_get ---
curl -fsS -X PUT "$Z/att" >/dev/null
python3 - "$Z" "$TMP" <<'PY'
import base64, gzip, json, sys, urllib.request
z, tmp = sys.argv[1], sys.argv[2]
raw = b"hello gzip attachment " * 200
gz = gzip.compress(raw)

# 1. PUT attachment with Content-Encoding: gzip
r = urllib.request.Request(z + "/att/d1", data=b"{}", method="PUT", headers={"Content-Type": "application/json"})
rev = json.load(urllib.request.urlopen(r))["rev"]
r2 = urllib.request.Request(
    z + "/att/d1/note.txt?rev=" + rev,
    data=gz,
    method="PUT",
    headers={"Content-Type": "text/plain", "Content-Encoding": "gzip"},
)
rev2 = json.load(urllib.request.urlopen(r2))["rev"]
doc = json.load(urllib.request.urlopen(z + "/att/d1"))
stub = doc["_attachments"]["note.txt"]
assert stub["encoding"] == "gzip", stub
assert stub["length"] == len(raw), (stub["length"], len(raw))
assert stub["encoded_length"] == len(gz), (stub["encoded_length"], len(gz))

# GET without Accept-Encoding: gzip decodes; with Accept-Encoding: gzip preserves gzip
assert urllib.request.urlopen(z + "/att/d1/note.txt").read() == raw
req_gz = urllib.request.Request(z + "/att/d1/note.txt", headers={"Accept-Encoding": "gzip"})
resp_gz = urllib.request.urlopen(req_gz)
assert resp_gz.headers.get("Content-Encoding") == "gzip", dict(resp_gz.headers)
assert resp_gz.read() == gz

# 2. Inline JSON document with data + encoding: gzip
doc2_body = json.dumps({
    "_attachments": {
        "inline.txt": {
            "content_type": "text/plain",
            "encoding": "gzip",
            "data": base64.b64encode(gz).decode(),
        }
    }
}).encode()
r3 = urllib.request.Request(z + "/att/d2", data=doc2_body, method="PUT", headers={"Content-Type": "application/json"})
rev3 = json.load(urllib.request.urlopen(r3))["rev"]
doc2 = json.load(urllib.request.urlopen(z + "/att/d2"))
stub2 = doc2["_attachments"]["inline.txt"]
assert stub2["encoding"] == "gzip", stub2
assert stub2["length"] == len(raw), stub2
assert urllib.request.urlopen(z + "/att/d2/inline.txt").read() == raw

# 3. _bulk_get with Accept: multipart/mixed emits Content-Encoding: gzip on part
bg_req = urllib.request.Request(
    z + "/att/_bulk_get?attachments=true",
    data=json.dumps({"docs": [{"id": "d1", "rev": rev2}]}).encode(),
    method="POST",
    headers={"Content-Type": "application/json", "Accept": "multipart/mixed"},
)
mp_bytes = urllib.request.urlopen(bg_req).read()
assert b"Content-Encoding: gzip" in mp_bytes, mp_bytes[:500]
PY
echo "ok   H7 gzip attachment encoding"
echo "PASS: replicate_h3_h8_h7"
