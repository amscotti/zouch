# Migrating from CouchDB

Zouch implements `POST /_replicate` and the `zouch pull` / `zouch push` CLI for Zouch-initiated
copies, and it can act as either end of a CouchDB replication. The runbook below drives the copy
from CouchDB because that reads from the source the operator already trusts; use `zouch pull` or
`POST /_replicate` instead when the Zouch side should drive (for example a source reachable only
from the Zouch host).

## Before starting

- Zouch is running and `GET /_up` returns 200.
- The target database exists and its per-database credential (if any) is known.
- The source CouchDB database is reachable from the CouchDB node, and `_all_docs` and `_changes`
  are not blocked by a proxy.
- Enough space exists for a full copy plus compaction headroom.
- You have a rollback target: the CouchDB database stays authoritative until the final switch.

## One-shot pull

Create the target, then ask CouchDB to replicate into it. Run this on the CouchDB node (or against
its `_replicate` endpoint):

```bash
curl -X PUT http://127.0.0.1:5985/notes
curl -X POST "$COUCH/_replicate" \
  -H 'content-type: application/json' \
  -d '{
    "source": "http://couch.example:5984/notes",
    "target": "http://zouch.example:5985/notes",
    "create_target": false
  }'
```

For a filtered migration, add CouchDB's `filter` field exactly as for any CouchDB replication. Zouch
evaluates the design-document filter on normal, longpoll and continuous `_changes` feeds. For a
credentialed target use `http://user:password@zouch.example:5985/notes` or an `Authorization` header
supported by your replicator.

The first request copies documents and attachments and writes `_local` checkpoints into Zouch. A
second run resumes from the durable checkpoint; it must not resend the whole database.

## Verify before cutover

```bash
# Row counts, including design documents
curl -sS 'http://zouch.example:5985/notes/_all_docs?include_docs=false' | jq '.total_rows'

# Compare IDs and revisions with the source, not update_seq
curl -sS 'http://couch.example:5984/notes/_all_docs' > /tmp/couch.json
curl -sS 'http://zouch.example:5985/notes/_all_docs' > /tmp/zouch.json
jq -S '[.rows[] | {id, rev: .value.rev}] | sort_by(.id)' /tmp/couch.json > /tmp/couch.norm
jq -S '[.rows[] | {id, rev: .value.rev}] | sort_by(.id)' /tmp/zouch.json > /tmp/zouch.norm
diff -u /tmp/couch.norm /tmp/zouch.norm

# A deleted revision must stay deleted, a conflict set must expose every leaf
curl -sS 'http://zouch.example:5985/notes/doc?open_revs=all' -H 'accept: application/json'
curl -sS 'http://zouch.example:5985/notes/doc?conflicts=true'
```

Also verify one attachment round-trip and one design-document view result against CouchDB. Do not
compare `update_seq` values: sequences are per-node and opaque.

## Cutover

1. Put clients into read-only mode or stop writes.
2. Run the replication once more.
3. Re-run the `_all_docs` diff until it is empty.
4. Change the application's CouchDB URL to Zouch, keeping the database name.
5. Keep the old CouchDB database intact for rollback.

For a large database, run the bulk load before cutover and measure it:

```bash
BULK_COUNT=100000 ./test/compat/bulk.sh
```

On the reference 4-vCPU host, 100,000 small documents load through `_bulk_docs` in about 15 seconds
with roughly 210 MB RSS in the debug build.

## Rollback

Reverse the replication while CouchDB is still authoritative or immediately after cutover:

```bash
curl -X POST "$COUCH/_replicate" \
  -H 'content-type: application/json' \
  -d '{
    "source": "http://zouch.example:5985/notes",
    "target": "http://couch.example:5984/notes"
  }'
```

CouchDB pulls Zouch's revision trees and leaves, so conflicts created on either side survive as
conflict leaves. Resolve them in the application after the reverse pass; do not delete the losing
leaf without recording the decision. This is intentional CouchDB behavior; see
`docs/adr/0007-conflicts-application-level.md`.

## Limits

- `validate_doc_update` and `_security` objects are implemented. Test the application's validators
  and member/admin rules against the migrated database before cutover; a failed validator rejects
  writes during the reverse sync.
- Purges are local to a node; do not expect `_purge` history to replicate.
- There is no clustering, shard placement or quorum. A single Zouch node is the availability domain.
- The runbook above has not been replayed against a production CouchDB in this repository's test
  environment; validate the diff steps against your CouchDB version before cutover.

## Automated 100,000-document check

`test/compat/migration.sh` creates a CouchDB source database, bulk-loads 100,000 documents, runs
CouchDB's `_replicate` into Zouch, and verifies both counts and four spot-checked bodies. It requires
an admin-capable `COUCH_URL`; the URL is never printed. `scripts/integration.sh` accepts either the
same `COUCH_URL` or the `COUCH` + `AUTH` pair used by the individual scripts.

```bash
export COUCH_URL='http://admin:password@127.0.0.1:5984'
./test/compat/migration.sh
```
