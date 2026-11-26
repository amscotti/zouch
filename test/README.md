# Tests

Generated from the scripts by `scripts/test_index.py` — run it after adding, renaming
or removing one. `scripts/ci.sh` fails when this file is out of date.

The two gates are the ones to run before trusting a change:

```bash
./scripts/ci.sh            # formatting, ReleaseSafe build, unit tests, HTTP smoke (~9 min)
./scripts/integration.sh   # CouchDB-backed replication and parity suites (~12 min)
```

Everything below is a single script you can run on its own.

## Self-contained

Each starts its own server on a private port and needs nothing running.

| Script | What it proves |
| --- | --- |
| `test/compat/attachment_memory.sh` | A replication that carries a large attachment must not hold it in memory: the response is streamed into the blob, so peak RSS grows by buffers, not by the file size. |
| `test/compat/auth.sh` | Per-database Basic auth from ZOUCH_AUTH_FILE. |
| `test/compat/auto_compact.sh` | Opt-in background compaction and blob GC. |
| `test/compat/bulk_fsync.sh` | Calibration for the batched _bulk_docs path: the single fsync at the end of the request must fail closed, and no document from the batch may survive a restart. |
| `test/compat/bulk_multipart.sh` | Multipart Couchbase-family _bulk_docs and _bulk_get compatibility. |
| `test/compat/combined_soak.sh` | Combined power-cut + soak campaign.  Writes a stream of documents through Zouch on a FUSE disk that commits only on fsync, cuts power at a fixed interval, restarts against the backing directory, and verifies every acknowledged document after each cut. Defaults to 24 hours; set COMBINED_SECONDS and CUT_EVERY for a shorter campaign. |
| `test/compat/conflict_app.sh` | Conflicts are application-level: a losing leaf stays visible until the application explicitly deletes it. |
| `test/compat/crash.sh` | Kill -9 recovery and torn-WAL-tail check. |
| `test/compat/crash_requests.sh` | Requests that used to abort the whole process (float formatting, throwing map functions, big integers in _find, limit/skip overflow, _local rev overflow, _scheduler/jobs) must answer and leave the server alive. |
| `test/compat/dirsync.sh` | Verify that atomic storage writes fsync the containing directory after rename. |
| `test/compat/diskfull.sh` | Disk-full and read-only data directories must fail requests cleanly and leave the database recoverable, rather than panicking or silently acking the write. |
| `test/compat/fauxton_support.sh` | What Fauxton needs beyond the document API: the build itself at /_utils, the setup probe it calls on load, the config page, and a session that works when no credential is configured - CouchDB's admin party. |
| `test/compat/feeds.sh` | Two blocked longpoll feeds must not starve ordinary CRUD. |
| `test/compat/feeds_continuous.sh` | Continuous feeds through the shared scheduler must emit new changes, heartbeat, and close. |
| `test/compat/feeds_many.sh` | More than 64 concurrent longpoll feeds must be accepted and must wake correctly. |
| `test/compat/fsync.sh` | Calibration: an fsync failure must not be acknowledged as a successful write. |
| `test/compat/mango.sh` | Mango operators added for app parity: $regex, $allMatch and $keyMapMatch. |
| `test/compat/powerloss.sh` | Power-loss test through a FUSE disk that only persists bytes on fsync. |
| `test/compat/pull_concurrency.sh` | A pull must not freeze the server, and its target must not be deletable while it runs. |
| `test/compat/replicate_local.sh` | Replicating one database of this server into another, which CouchDB does with two plain database names and no network hop. |
| `test/compat/replicate_resilience.sh` | An interrupted replication must resume where it stopped, never lose documents and never leave a checkpoint ahead of the data. |
| `test/compat/replicate_retry.sh` | A failed one-shot _replicator job must stay retryable, not be marked completed. |
| `test/compat/revs_info.sh` | A revision that stops being a leaf keeps its body until compaction, exactly as CouchDB does: `?rev=` still serves it and `_revs_info` says `available`. |
| `test/compat/security_enforce.sh` | Name-based _security members/admins enforcement under Basic auth. |
| `test/compat/security_roles.sh` | Role-based _security enforcement with the local ZOUCH_ROLES map. |
| `test/compat/session_persistence.sh` | A session must outlive the process that issued it: CouchDB signs its cookie with a persisted secret, so a restart does not log clients out. |
| `test/compat/users.sh` | _users-backed Basic auth and role enforcement. |
| `test/compat/vector_hnsw.sh` | HNSW engine builds a graph, persists it, and reuses it after restart. |

## Needs a running Zouch

Set `ZOUCH` (default `http://127.0.0.1:5985`); none of these start one.

| Script | What it proves |
| --- | --- |
| `test/compat/blob.sh` | Attachment blob-store checks. Uses ZOUCH (default http://127.0.0.1:5985). |
| `test/compat/bulk.sh` | Bulk-load 10,000 documents through _bulk_docs. |
| `test/compat/compact.sh` | Segment-only compaction checks. Uses ZOUCH (default http://127.0.0.1:5985). |
| `test/compat/fuzz_categories.sh` | Run each fuzz category separately; default duration matches the release gate. |
| `test/compat/http.sh` | Local HTTP conformance checks. Requires Zouch on :5985. |
| `test/compat/security.sh` | _security object storage checks. Uses ZOUCH (default http://127.0.0.1:5985). |
| `test/compat/soak.sh` | Short soak: writes, reads, views, Mango and optional CouchDB replication, sampling RSS for leaks. |
| `test/compat/validate.sh` | Server-side validate_doc_update checks against a local Zouch. |

## Needs CouchDB

A real CouchDB answers too; `COUCH`/`AUTH` or `COUCH_URL`, plus a Zouch.

| Script | What it proves |
| --- | --- |
| `test/compat/migration.sh` | One-shot CouchDB -> Zouch migration with count and body verification. |
| `test/compat/replicate.sh` | End-to-end replication checks against a real CouchDB. |
| `test/compat/replicate_attachments.sh` | Attachments survive both pull and push replication. |
| `test/compat/replicate_bulk_get.sh` | A pull fetches the revisions it lacks through `_bulk_get`, a page at a time, rather than one GET per document - and reports the two counters CouchDB publishes in `_scheduler/docs`: bulk_get_attempts and bulk_get_docs. |
| `test/compat/replicate_continuous.sh` | continuous:true keeps polling the source and pulling new changes. |
| `test/compat/replicate_knobs.sh` | `use_checkpoints: false` means no `_local` revision is read or written, so a repeat starts from the beginning - CouchDB leaves no `_local` document behind in that case, and neither should we. |
| `test/compat/replicate_pull.sh` | One-shot pull replication from CouchDB into a local Zouch database. |
| `test/compat/replicate_push.sh` | One-shot push from a local Zouch database to CouchDB. |
| `test/compat/replicate_remote_checkpoint.sh` | A remote-to-remote job drops its staging database, so the checkpoint has to live on the target - which is where CouchDB keeps it. |
| `test/compat/replicate_scheduler.sh` | _replicator docs trigger one-shot pulls into local databases. |

## Cross-implementation suites (`test/interop/`)

These drive both servers and compare answers; they need CouchDB, and most need a
Zouch on `:5985` as well (each prints its endpoint when it cannot reach one).

| Script | What it compares |
| --- | --- |
| `test/interop/api_sweep.py` | Compare a broad set of endpoints between CouchDB and zouch. |
| `test/interop/bulk_get_parity.py` | Compare _bulk_get between CouchDB and zouch on identical data. |
| `test/interop/explain_parity.py` | Compare the shape of _explain between CouchDB and zouch. |
| `test/interop/find_parity.py` | Diff _find and _explain between CouchDB and zouch on identical data. |
| `test/interop/replication_matrix.py` | Replication interop matrix: Zouch <-> CouchDB, both directions. |
