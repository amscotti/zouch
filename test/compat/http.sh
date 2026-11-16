#!/usr/bin/env bash
# Local HTTP conformance checks. Requires Zouch on :5985.
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
# Prerequisites, checked up front: this file needs a Zouch already listening
# at $ZOUCH (it does not start one) plus curl, python3 and jq.
for tool in curl python3 jq; do
  command -v "$tool" >/dev/null || { echo "http.sh: missing $tool" >&2; exit 1; }
done
if ! curl -fsS -m 2 "$Z/" >/dev/null 2>&1; then
  echo "http.sh: no Zouch answering at $Z" >&2
  echo "http.sh: start one with ./zig-out/bin/zouch serve ./data 5985," >&2
  echo "http.sh: or run ./scripts/ci.sh, which starts a server, runs http.sh and stops it." >&2
  exit 1
fi

jqget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

curl -fsS "$Z/" | jqget 'd["couchdb"]' | grep -qx Welcome
[ "$(curl -fsS "$Z/" | jq -r 'has("features")')" = "true" ]
curl -fsS -X DELETE "$Z/http_test" >/dev/null 2>&1 || true
curl -fsS -X DELETE "$Z/http_extra" >/dev/null 2>&1 || true
curl -fsS -X PUT "$Z/http_test" >/dev/null
curl -fsS -X PUT "$Z/http_extra" >/dev/null
[ "$(curl -fsS "$Z/_all_dbs" | jq -r 'index("http_extra") != null')" = "true" ]

echo "== malformed bulk requests =="
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/http_test/_all_docs" -H 'content-type: application/json' -d '{"keys":null}')" = "400" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/http_test/_all_docs" -H 'content-type: application/json' -d '{"keys":true}')" = "400" ]
BID=$(curl -fsS -X POST "$Z/http_test/_bulk_docs" -H 'content-type: application/json' -d '{"docs":[{"v":42}]}' | jqget 'd[0]["id"]')
[ -n "$BID" ]
[ "$(curl -fsS "$Z/http_test/$BID" | jqget 'd["v"]')" = "42" ]
[ "$(curl -fsS -X POST "$Z/http_test/_bulk_get" -H 'content-type: application/json' -d '{"docs":[null]}')" = '{"results":[]}' ]

echo "== JSON not found =="
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/no/such/route/here")" = "404" ]
[ "$(curl -sS "$Z/no/such/route/here" | jq -r .error)" = "not_found" ]

echo "== documents and revisions =="
R1=$(curl -fsS -X PUT "$Z/http_test/a" -H 'content-type: application/json' -d '{"v":1,"kind":"x"}' | jqget 'd["rev"]')
R2=$(curl -fsS -X PUT "$Z/http_test/a" -H 'content-type: application/json' -d "{\"_rev\":\"$R1\",\"v\":2,\"kind\":\"x\"}" | jqget 'd["rev"]')
[ "$(curl -fsS "$Z/http_test/a" | jqget 'd["v"]')" = "2" ]
[ "$(curl -fsS "$Z/http_test/a?revs=true" | jqget 'len(d["_revisions"]["ids"])')" = "2" ]
[ "$(curl -fsS -X POST "$Z/http_test/_bulk_get" -H 'content-type: application/json' -d '{"docs":[{"id":"a","rev":"9-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' | jq -r '.results[0].docs[0].error.error')" = "not_found" ]
# latest=true answers a *known ancestor* with the leaf below it, and an unknown
# revision is still not_found (both measured against CouchDB):
[ "$(curl -fsS -X POST "$Z/http_test/_bulk_get?latest=true" -H 'content-type: application/json' -d '{"docs":[{"id":"a","rev":"9-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' | jq -r '.results[0].docs[0].error.error')" = "not_found" ]
[ "$(curl -fsS -X POST "$Z/http_test/_bulk_get?latest=true" -H 'content-type: application/json' -d "{\"docs\":[{\"id\":\"a\",\"rev\":\"$R1\"}]}" | jq -r '.results[0].docs[0].ok._rev')" = "$R2" ]
# CouchDB reads revs from the query string, not the body:
[ "$(curl -fsS -X POST "$Z/http_test/_bulk_get?revs=true" -H 'content-type: application/json' -d "{\"docs\":[{\"id\":\"a\",\"rev\":\"$R2\"}]}" | jq -r '.results[0].docs[0].ok._revisions.ids | length')" = "2" ]
# ?rev= and If-Match name the revision being updated, as _rev does:
R3=$(curl -fsS -X PUT "$Z/http_test/a?rev=$R2" -H 'content-type: application/json' -d '{"v":3,"kind":"x"}' | jqget 'd["rev"]')
[ -n "$R3" ]
[ "$(curl -fsS -X PUT "$Z/http_test/a" -H 'content-type: application/json' -H "if-match: $R3" -d '{"v":4,"kind":"x"}' | jqget 'd["rev"]')" != "" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/http_test/a?rev=$R2" -H 'content-type: application/json' -d '{"v":5,"kind":"x"}')" = "409" ]

echo "== deleted documents can be recreated =="
D1=$(curl -fsS -X PUT "$Z/http_test/tomb" -H 'content-type: application/json' -d '{"v":1}' | jqget 'd["rev"]')
D2=$(curl -fsS -X DELETE "$Z/http_test/tomb?rev=$D1" | jqget 'd["rev"]')
D3=$(curl -fsS -X PUT "$Z/http_test/tomb" -H 'content-type: application/json' -d '{"v":2}' | jqget 'd["rev"]')
[ -n "$D3" ]
[ "$(curl -fsS "$Z/http_test/tomb" | jqget 'd["v"]')" = "2" ]

echo "== illegal path-like database names =="
[ "$(curl --path-as-is -sS -o /dev/null -w '%{http_code}' -X PUT "$Z/.")" = "400" ]
[ "$(curl --path-as-is -sS -o /dev/null -w '%{http_code}' -X DELETE "$Z/.")" = "404" ]
curl -fsS "$Z/http_test" >/dev/null

echo "== percent-encoded document ids =="
SR=$(curl -fsS -X PUT "$Z/http_test/a%2Fb" -H 'content-type: application/json' -d '{"v":9}' | jqget 'd["rev"]')
[ -n "$SR" ]
[ "$(curl -fsS "$Z/http_test/a%2Fb" | jqget 'd["_id"]')" = "a/b" ]

echo "== attachments =="
curl -fsS -X PUT "$Z/http_test/att" -H 'content-type: application/json' \
  -d '{"_attachments":{"n.txt":{"content_type":"text/plain","data":"aGVsbG8="}}}' >/dev/null
[ "$(curl -fsS "$Z/http_test/att/n.txt")" = "hello" ]
[ "$(curl -fsS "$Z/http_test/att" | jqget 'd["_attachments"]["n.txt"]["length"]')" = "5" ]
curl -fsS -X PUT "$Z/http_test/att-zero" -H 'content-type: application/json' \
  -d '{"_attachments":{"empty.txt":{"content_type":"text/plain","data":""}}}' >/dev/null
[ "$(curl -fsS "$Z/http_test/att-zero/empty.txt" | wc -c)" = "0" ]
# CouchDB ignores Range on an attachment (serves the whole body) but refuses a
# range that starts past the end, so we do exactly the same:
[ "$(curl -fsS -H 'range: bytes=0-2' "$Z/http_test/att/n.txt")" = "hello" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'range: bytes=9-' "$Z/http_test/att/n.txt")" = "416" ]
[ "$(curl -sS -H 'range: bytes=9-' "$Z/http_test/att/n.txt" | jq -r .error)" = "requested_range_not_satisfiable" ]
curl -fsS -X PUT "$Z/http_test/att-header" -H 'content-type: application/json' \
  -d '{"_attachments":{"h.txt":{"content_type":"text/plain\r\nX-Injected: yes","data":"aGk="}}}' >/dev/null
curl -sS -D /tmp/zouch-att-header -o /dev/null "$Z/http_test/att-header/h.txt"
! grep -qi '^X-Injected:' /tmp/zouch-att-header

echo "== gzip attachment limit =="
python3 - "$Z" <<'PY'
import base64, gzip, json, sys, urllib.error, urllib.request
z = sys.argv[1]
payload = gzip.compress(b"\0" * (65 * 1024 * 1024))
body = json.dumps({
    "new_edits": False,
    "docs": [{
        "_id": "bomb",
        "_rev": "1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "_attachments": {"bomb.gz": {
            "content_type": "application/gzip",
            "encoding": "gzip",
            "data": base64.b64encode(payload).decode(),
        }},
    }],
}).encode()
req = urllib.request.Request(z + "/http_test/_bulk_docs", data=body, method="POST",
                             headers={"Content-Type": "application/json"})
assert urllib.request.urlopen(req).status == 201
try:
    urllib.request.urlopen(z + "/http_test/bomb/bomb.gz")
    raise SystemExit("gzip bomb was not rejected")
except urllib.error.HTTPError as e:
    assert e.code == 413, e.code
PY

echo "== client-supplied blob path is rejected =="
curl -fsS -X POST "$Z/http_test/_bulk_docs" -H 'content-type: application/json' \
  -d '{"new_edits":false,"docs":[{"_id":"evil","_rev":"1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","_attachments":{"x":{"blob":"../../../../etc/passwd","stub":true}}}]}' >/dev/null
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/http_test/evil/x")" = "404" ]

echo "== all_docs ranges =="
curl -fsS -X PUT "$Z/http_test/b" -H 'content-type: application/json' -d '{"kind":"y"}' >/dev/null
[ "$(curl -fsS --get "$Z/http_test/_all_docs" --data-urlencode 'startkey="a"' --data-urlencode 'endkey="b"' | jqget 'len(d["rows"])')" -ge 2 ]

echo "== changes =="
[ "$(curl -fsS "$Z/http_test/_changes?since=0" | jqget 'len(d["results"])')" -ge 2 ]

echo "== ensure_full_commit =="
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/http_test/_ensure_full_commit")" = "415" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$Z/http_test/_ensure_full_commit" -H 'content-type: application/json')" = "201" ]

echo "== mango selector operators =="
curl -sS -X PUT "$Z/http_test/op1" -H 'content-type: application/json' -d '{"n":1,"tags":["a","b"]}' >/dev/null || true
curl -sS -X PUT "$Z/http_test/op2" -H 'content-type: application/json' -d '{"n":3,"tags":["c"]}' >/dev/null || true
[ "$(curl -fsS -X POST "$Z/http_test/_find" -H 'content-type: application/json' -d '{"selector":{"tags":{"$all":["a","b"]}}}' | jq -c '[.docs[]._id]')" = '["op1"]' ]
[ "$(curl -fsS -X POST "$Z/http_test/_find" -H 'content-type: application/json' -d '{"selector":{"n":{"$not":{"$gt":2}}},"limit":20}' | jq -c '[.docs[]._id] | index("op1") != null')" = "true" ]
curl -sS -X PUT "$Z/http_test/op3" -H 'content-type: application/json' -d '{"tags":[{"n":4}]}' >/dev/null || true
[ "$(curl -fsS -X POST "$Z/http_test/_find" -H 'content-type: application/json' -d '{"selector":{"tags":{"$elemMatch":{"n":{"$gte":3}}}}}' | jq -c '[.docs[]._id]')" = '["op3"]' ]

echo "== mango bookmark =="
curl -sS -X DELETE "$Z/page_test" >/dev/null 2>&1 || true
curl -fsS -X PUT "$Z/page_test" >/dev/null
for i in 1 2 3; do curl -fsS -X PUT "$Z/page_test/p$i" -H 'content-type: application/json' -d "{\"n\":$i}" >/dev/null; done
curl -fsS -X POST "$Z/page_test/_index" -H 'content-type: application/json' -d '{"index":{"fields":["n"]},"name":"by_n","ddoc":"page"}' >/dev/null
PAGE1=$(curl -fsS -X POST "$Z/page_test/_find" -H 'content-type: application/json' -d '{"selector":{"n":{"$gte":1}},"sort":["n"],"limit":1}')
[ "$(echo "$PAGE1" | jqget 'd["docs"][0]["n"]')" = "1" ]
BM=$(echo "$PAGE1" | jq -r .bookmark)
PAGE2=$(curl -fsS -X POST "$Z/page_test/_find" -H 'content-type: application/json' -d "{\"selector\":{\"n\":{\"\$gte\":1}},\"sort\":[\"n\"],\"limit\":1,\"bookmark\":\"$BM\"}")
[ "$(echo "$PAGE2" | jqget 'd["docs"][0]["n"]')" = "2" ]

echo "== local checkpoint =="
CK="ck-$(date +%s%N)"
[ "$(curl -fsS -o /tmp/zouch-local.json -w '%{http_code}' -X PUT "$Z/http_test/_local/$CK" -H 'content-type: application/json' -d '{"_rev":"0-1","last_seq":1}')" = "201" ]
[ "$(curl -fsS "$Z/http_test/_local/$CK" | jq -r ._rev)" = "0-2" ]

echo "== filtered changes =="
curl -sS -X PUT "$Z/http_test/f1" -H 'content-type: application/json' -d '{"n":1}' >/dev/null || true
curl -sS -X PUT "$Z/http_test/f2" -H 'content-type: application/json' -d '{"n":2}' >/dev/null || true
curl -fsS -X PUT "$Z/http_test/_design/flt" -H 'content-type: application/json' \
  -d '{"filters":{"even":"function(doc,req){ return doc.n % 2 === 0; }"}}' >/dev/null
[ "$(curl -fsS "$Z/http_test/_changes?filter=flt/even" | jq -c '[.results[].id]')" = '["f2"]' ]
[ "$(curl -fsS "$Z/http_test/_changes?filter=flt/even&feed=longpoll&timeout=100" | jq -c '[.results[].id]')" = '["f2"]' ]
FEED=$(curl -sS --max-time 1 "$Z/http_test/_changes?filter=flt/even&feed=continuous&timeout=100" || true)
echo "$FEED" | grep -q '"id":"f2"' 

echo "== views =="
curl -fsS -X PUT "$Z/http_test/_design/shop" -H 'content-type: application/json' \
  -d '{"views":{"kind":{"map":"function(doc){ if(doc.kind){ emit(doc.kind, 1); } }"}}}' >/dev/null
[ "$(curl -fsS "$Z/http_test/_design/shop/_view/kind" | jqget 'len(d["rows"])')" = "2" ]

echo "== mango index and find =="
[ "$(curl -fsS -X POST "$Z/http_test/_index" -H 'content-type: application/json' -d '{"index":{"fields":["kind"]},"name":"by_kind","ddoc":"shop"}' | jqget 'd["result"]')" = "created" ]
[ "$(curl -fsS -X POST "$Z/http_test/_find" -H 'content-type: application/json' -d '{"selector":{"kind":"x"}}' | jqget 'len(d["docs"])')" = "1" ]

echo "== mango index sort =="
curl -fsS -X PUT "$Z/http_test/n1" -H 'content-type: application/json' -d '{"n":2}' >/dev/null
curl -fsS -X PUT "$Z/http_test/n2" -H 'content-type: application/json' -d '{"n":1}' >/dev/null
curl -fsS -X POST "$Z/http_test/_index" -H 'content-type: application/json' -d '{"index":{"fields":["n"]},"name":"by_n","ddoc":"shop2"}' >/dev/null
[ "$(curl -fsS -X POST "$Z/http_test/_find" -H 'content-type: application/json' -d '{"selector":{"n":{"$gte":1}},"sort":["n"]}' | jqget 'd["docs"][0]["n"]')" = "1" ]

echo "== purge =="
PR=$(curl -fsS -X PUT "$Z/http_test/purge" -H 'content-type: application/json' -d '{"v":1}' | jqget 'd["rev"]')
curl -fsS -X POST "$Z/http_test/_purge" -H 'content-type: application/json' -d "{\"purge\":[\"$PR\"]}" >/dev/null
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$Z/http_test/purge")" = "404" ]

echo "== vector search =="
python3 - "$Z" <<'EOF'
import base64, json, struct, sys, urllib.request
Z = sys.argv[1]
def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(Z + path, data=data, method=method)
    if data: req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as r: return json.loads(r.read() or b"null")
def b64(v): return base64.b64encode(struct.pack("<%df" % len(v), *v)).decode()
call("POST", "/http_test/_bulk_docs", {"docs": [
    {"_id": "v1", "embedding_b64": b64([1, 0, 0])},
    {"_id": "v2", "embedding_b64": b64([0, 1, 0])},
]})
hits = call("POST", "/http_test/_vector_search", {"vector": [1, 0, 0], "k": 1})["hits"]
assert hits[0]["id"] == "v1", hits
hits = call("POST", "/http_test/_vector_search", {"vector": [1, 0, 0], "k": 1, "engine": "hnsw", "ef": 128})["hits"]
assert hits[0]["id"] == "v1", hits
EOF

# Continuous replication is a background job: CouchDB answers 202 with a
# _local_id, and the job lives in _replicator where the scheduler runs it.
body=$(mktemp)
code=$(curl -sS -o "$body" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' \
  -d '{"source":"http://127.0.0.1:1/x","target":"http_test","continuous":true}')
[ "$code" = "202" ]
jq -e '.ok == true and (._local_id | type == "string")' < "$body" >/dev/null
job=$(jq -r ._local_id < "$body")
jrev=$(curl -fsS "$Z/_replicator/$job" | jq -r ._rev)
# The source is unreachable, so the job would keep retrying; remove it.
curl -sS -X DELETE "$Z/_replicator/$job?rev=$jrev" >/dev/null || true
# ... and a request with no URL on either side is a local-to-local copy, which
# needs a target that exists; replicate_local.sh covers the copy itself.
code=$(curl -sS -o "$body" -w '%{http_code}' -X POST "$Z/_replicate" \
  -H 'content-type: application/json' -d '{"source":"http_test","target":"http_test2"}')
[ "$code" = "404" ]
jq -e '.error == "not_found"' < "$body" >/dev/null
rm -f "$body"
# _replicator exists on a fresh server, as it does in CouchDB, so a job
# document can be written without creating the database first.
rev=$(curl -fsS -X PUT "$Z/_replicator/ci_probe" \
  -H 'content-type: application/json' \
  -d "{\"source\":\"http://127.0.0.1:1/x\",\"target\":\"$Z/http_test\"}" | jq -r .rev)
curl -sS -X DELETE "$Z/_replicator/ci_probe?rev=$rev" >/dev/null || true
# Local endpoints are only allowed on the transient API: CouchDB refuses a
# _replicator document that names a local database.
body=$(mktemp)
code=$(curl -sS -o "$body" -w '%{http_code}' -X PUT "$Z/_replicator/local_job" \
  -H 'content-type: application/json' -d '{"source":"http_test","target":"http_test2"}')
[ "$code" = "403" ]
jq -e '.error == "forbidden" and .reason == "local_endpoints_not_supported"' < "$body" >/dev/null
code=$(curl -sS -o "$body" -w '%{http_code}' -X PUT "$Z/_replicator/local_job" \
  -H 'content-type: application/json' -d '{"source":{"url":"http_test"},"target":"http://127.0.0.1:1/x"}')
[ "$code" = "403" ]
jq -e '.reason == "endpoint has an invalid url"' < "$body" >/dev/null
rm -f "$body"
echo "== replication option validation =="

echo "PASS: HTTP conformance"
