#!/usr/bin/env bash
# One-shot CouchDB -> Zouch migration with count and body verification.
# Requires an admin-capable COUCH_URL, e.g. export COUCH_URL=http://admin:pass@127.0.0.1:5984
# and a running Zouch. This script never prints COUCH_URL.
set -euo pipefail
: "${COUCH_URL:?set COUCH_URL to an admin-capable CouchDB URL}"
ZOUCH_URL="${ZOUCH_URL:-http://127.0.0.1:5985}"
DOCS="${MIGRATION_DOCS:-100000}"
SOURCE_DB="${MIGRATION_SOURCE_DB:-zouch_migration}"
TARGET_DB="${MIGRATION_TARGET_DB:-migration}"

python3 - "$COUCH_URL" "$SOURCE_DB" "$DOCS" <<'PY'
import base64, json, sys, urllib.request, urllib.error
from urllib.parse import urlparse, urlunparse
raw = sys.argv[1].rstrip('/')
parsed = urlparse(raw)
auth = None
if parsed.username is not None:
    pair = f'{parsed.username}:{parsed.password or ""}'.encode()
    auth = 'Basic ' + base64.b64encode(pair).decode()
base = urlunparse(parsed._replace(netloc=parsed.hostname + (f':{parsed.port}' if parsed.port else '')))
db, total = sys.argv[2], int(sys.argv[3])
def req(method, path, obj=None):
    data = None if obj is None else json.dumps(obj).encode()
    headers = {'content-type': 'application/json'}
    if auth: headers['authorization'] = auth
    r = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
status, body = req('PUT', '/' + db)
if status not in (201, 412):
    raise SystemExit(f'cannot create source database: HTTP {status}')
made = 0
while made < total:
    n = min(5000, total - made)
    docs = [{'_id': f'doc-{made+i:08d}', 'n': made+i,
             'text': 'migration fixture', 'tags': ['a', 'b']} for i in range(n)]
    status, body = req('POST', f'/{db}/_bulk_docs', {'docs': docs})
    if status != 201:
        raise SystemExit(f'bulk load failed: HTTP {status}: {body[:200]!r}')
    result = json.loads(body)
    if any('error' in d for d in result):
        raise SystemExit('bulk load returned per-document errors')
    made += n
# Fixtures the plain bulk path does not cover: an inline attachment, a conflict pair, and a
# design document with a MapReduce view.
attachment = base64.b64encode(b'attachment payload').decode()
status, body = req('PUT', f'/{db}/attachment-doc', {
    'kind': 'attachment',
    '_attachments': {'hello.txt': {'content_type': 'text/plain', 'data': attachment}},
})
if status not in (201, 202):
    raise SystemExit(f'attachment fixture failed: HTTP {status}: {body[:200]!r}')
conflict_docs = [
    {'_id': 'conflict-doc', '_rev': '1-' + 'a' * 32, 'side': 'left'},
    {'_id': 'conflict-doc', '_rev': '1-' + 'b' * 32, 'side': 'right'},
]
status, body = req('POST', f'/{db}/_bulk_docs', {'new_edits': False, 'docs': conflict_docs})
if status != 201:
    raise SystemExit(f'conflict fixture failed: HTTP {status}: {body[:200]!r}')
status, body = req('PUT', f'/{db}/_design/migrate', {
    'views': {'by_n': {'map': 'function(doc){ if (doc.n !== undefined) emit(doc.n, 1); }'}},
})
if status not in (201, 202):
    raise SystemExit(f'design fixture failed: HTTP {status}: {body[:200]!r}')
print(f'loaded {made} source documents plus attachment, conflict and design fixtures')
PY

curl -fsS -X PUT "$ZOUCH_URL/$TARGET_DB" >/dev/null 2>&1 || true
start=$(date +%s)
curl -fsS -X POST "$COUCH_URL/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$SOURCE_DB\",\"target\":\"$ZOUCH_URL/$TARGET_DB\",\"create_target\":false}" \
  >/tmp/zouch-migration-replicate.json
elapsed=$(( $(date +%s) - start ))
python3 - "$COUCH_URL" "$ZOUCH_URL" "$SOURCE_DB" "$TARGET_DB" "$DOCS" "$elapsed" <<'PY'
import base64, json, sys, urllib.request
from urllib.parse import urlparse, urlunparse
raw = sys.argv[1].rstrip('/')
parsed = urlparse(raw)
auth = None
if parsed.username is not None:
    pair = f'{parsed.username}:{parsed.password or ""}'.encode()
    auth = 'Basic ' + base64.b64encode(pair).decode()
couch = urlunparse(parsed._replace(netloc=parsed.hostname + (f':{parsed.port}' if parsed.port else '')))
zouch, src, dst, total, elapsed = sys.argv[2].rstrip('/'), sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
def get(url):
    headers = {'authorization': auth} if auth and url.startswith(couch) else {}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)
s = get(f'{couch}/{src}')
z = get(f'{zouch}/{dst}')
if s['doc_count'] != z['doc_count'] or z['doc_count'] < total:
    raise SystemExit(f'count mismatch: source {s["doc_count"]}, target {z["doc_count"]}, expected at least {total}')
for i in (0, 1, total // 2, total - 1):
    doc = get(f'{zouch}/{dst}/doc-{i:08d}')
    if doc.get('n') != i:
        raise SystemExit(f'body mismatch for doc-{i:08d}')
# Attachment body and bytes.
att = get(f'{zouch}/{dst}/attachment-doc')
if '_attachments' not in att or 'hello.txt' not in att['_attachments']:
    raise SystemExit('attachment metadata missing from migrated document')
with urllib.request.urlopen(f'{zouch}/{dst}/attachment-doc/hello.txt', timeout=60) as r:
    if r.read() != b'attachment payload':
        raise SystemExit('attachment bytes differ after migration')
# Conflict leaves.
conflict = get(f'{zouch}/{dst}/conflict-doc?conflicts=true')
if not conflict.get('_conflicts'):
    raise SystemExit('conflict leaves were not preserved')
# Design document and its view.
view = get(f'{zouch}/{dst}/_design/migrate/_view/by_n?limit=1')
if not view.get('rows'):
    raise SystemExit('migrated design view returned no rows')
print(f'PASS: {total} documents plus attachment, conflict and design fixtures migrated in {elapsed}s; counts, bytes and view match')
PY
