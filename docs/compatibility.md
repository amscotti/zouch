# Zouch compatibility matrix

Measured against **Apache CouchDB 3.5.3** on 2026-10-31/11-01, with CouchDB and PouchDB 9 as
replication peers.

## Implemented

| Endpoint | Status | Notes |
|---|---|---|
| `GET /` | yes | version/vendor and an explicit empty `features` list |
| `GET /_up` | yes | |
| `GET /_all_dbs` | yes | lists database directories on disk; requires an admin when users are configured |
| `PUT/GET/DELETE /{db}` | yes | info includes `doc_count`, `doc_del_count`, `update_seq`, `cluster` |
| `GET/PUT/DELETE /{db}/{doc}` | yes | `_rev`, `?rev=` and `If-Match` all name the revision being updated or deleted, as in CouchDB; `?revs=true`, `?conflicts=true`, `?open_revs=all`; design-doc `validate_doc_update` runs on writes |
| `POST /{db}/_bulk_docs` | yes | local edits and `new_edits=false` imports; `[]` on import |
| `POST /{db}/_bulk_get` | yes | `revs=true`, `attachments=true` (base64 `data`), the default and `attachments=false` (stubs), and `latest=true` swapping a *known ancestor* for the leaf that descends from it; an unknown revision is `not_found` with or without `latest` (measured). Every case is compared against CouchDB by `test/interop/bulk_get_parity.py`, 8/8 - including a bare request for an ancestor revision, which answers with the retained body exactly as CouchDB does until compaction drops it |
| `POST /{db}/_revs_diff` | yes | `missing`, `possible_ancestors` |
| `GET/POST /{db}/_changes` | yes | `normal`, `longpoll`, `continuous`; `since`, `limit`, `style=all_docs`, `include_docs`; longpoll and continuous feeds share one scheduler; active feeds are capped by `ZOUCH_MAX_FEEDS` (default 256) |
| `GET/POST /{db}/_all_docs` | yes | `keys`, `include_docs`, `limit`, `skip`, `startkey`/`endkey`, `descending`, `inclusive_end` |
| `GET/PUT/DELETE /{db}/_local/{id}` | yes | LWW, `0-N` revisions, durable in `locals.log` |
| `POST /{db}/_ensure_full_commit` | yes | requires `application/json`; 201 with `instance_start_time` |
| `POST /{db}/_vector_search` | yes | Zouch extension: persisted int8 flat index with float32 rescoring; rebuilds when the database changes |
| `GET/PUT /{db}/_design/{ddoc}` | yes | design documents are ordinary documents with `_design/` IDs |
| `POST /{db}/_view_cleanup` | yes | deletes persisted view index files; queries rebuild them |
| `POST /{db}/_purge` | yes | removes listed revisions, recomputes the winner, drops empty documents; durable `purge_seq`; purges are local to the node and intentionally not replicated |
| `GET/POST /{db}/_design/{ddoc}/_view/{view}` | yes | QuickJS map/custom reduce; `_count`/`_sum`; group, key/startkey/endkey, POST keys, include_docs, limit/skip; persisted per-document index; ICU string collation |
| `POST /{db}/_find` | yes | persisted indexes plus selector scan; `$eq/$ne/$gt/$gte/$lt/$lte/$in/$nin/$exists/$beginsWith/$regex/$size/$type/$mod/$all/$elemMatch/$allMatch/$keyMapMatch/$and/$or/$nor/$not`; projection, limit/skip, single-field sort, opaque bookmark; `$regex` uses POSIX ERE. Comparisons use CouchDB's type order (null < boolean < number < string < array < object), so `$gt: null` means "present and not null" and a missing field matches neither `$eq` nor `$ne`; an unknown operator is `400 invalid_operator` with CouchDB's wording. `test/interop/find_parity.py` compares all 13 queries against a real CouchDB, including the refusals: a `sort` no index can serve is `400 no_usable_index` with CouchDB's exact wording, and `sort:["_id"]` is refused too unless the selector ranges over `_id` (both measured) |
| `POST/GET /{db}/_index` | yes | persisted single-field indexes; `_find` intersects indexes for every indexed selector field and rechecks the full selector |
| `POST /{db}/_explain` | yes | reports the index it would use (`_all_docs`, or a created index with its own name, `_design/zouch` and `def.fields`) in CouchDB's document shape: `dbname`, `index{ddoc,name,type,partitioned,def.fields}`, `partitioned`, `selector`, the full `opts` block, `limit`, `skip`, `fields`, `index_candidates`, `selector_hints`, `covering` and `mrargs`; `limit` is echoed. `test/interop/explain_parity.py` compares the shape, the created index's name and its `def` with a real CouchDB, 3/3. Divergence: `index.ddoc` is `_design/zouch` rather than a hash-named design document |
| `GET/PUT/DELETE /{db}/{doc}/{att}` | yes | raw bytes; `Content-Type`, gzip `Content-Encoding` preserved |
| `?attachments=true` on doc GET | yes | inline base64; stub form otherwise |
| `open_revs` multipart | yes | `multipart/mixed` with JSON parts containing base64 attachments |
| Attachment bodies | streamed | a blob above 256kB goes to the socket straight from the file with its own `Content-Length`; smaller ones, and ones that must be gunzipped first, are finished in memory; `Range` is ignored and the whole body is served, which is what CouchDB does - a range that starts at or past the end is the one case it refuses, and so do we (`416 requested_range_not_satisfiable`) |
| Replication interop | verified | CouchDB 3.5.3 drives replication in both directions against this server, including attachments, deletions, conflicts, design documents, `doc_ids` and `selector` filtering and a continuous feed; `test/interop/replication_matrix.py` (28 scenarios) is the gate |
| Concurrency during a replication | yes | a replication no longer holds up other requests: they answer in milliseconds while it copies. This was a bug in the vendored httpz, which kept a queue per pool thread and dispatched round-robin, so a job handed to the thread running the replication waited there until it finished; idle threads only looked at a peer queue after something woke them. One queue shared by every thread fixes it (four concurrent four-second longpolls: 4.0s, was 12.6s). `test/compat/pull_concurrency.sh` measures it |
| `POST /_replicate` | verified | one-shot pull into a local target, push to a remote target, or a local-to-local copy, including attachments, deletions, conflicts and design documents; `doc_ids`, `selector`, `filter` and `since_seq` narrow what is copied, `create_target` creates a local target, `continuous: true` answers `202` with a `_local_id` job in `_replicator`, and the response carries CouchDB's `session_id`, `source_last_seq` and `history` counters |
| `_replicator` | yes | the database exists on a fresh data directory, as in CouchDB. A document naming a local database endpoint is refused exactly as CouchDB 3.5.3 refuses it (`403 forbidden` / `local_endpoints_not_supported`, or `endpoint has an invalid url` for an endpoint object); remote-to-remote - the only shape CouchDB accepts there - pulls the changes into a staging database (`repl_stage_<hash>`, dropped when the job finishes) and pushes them to the target, so a job completes and delivers documents as CouchDB's does. A local source with a URL target and a URL source with a local target also run, through `/_replicate` or a document. Filters, `doc_ids` and `selector` narrow what is copied; failed jobs retry with capped exponential backoff. `use_checkpoints` is honoured (false reads and writes no `_local` revision, so a repeat starts from the beginning) and `worker_batch_size` sets the page size. Not acted on: `checkpoint_interval`, `http_connections`, `connection_timeout`, `socket_options` (each needs a scheduler or client change, not a parse). A remote-to-remote job keeps its checkpoint on the target, as CouchDB does (`_local/<hash>`, read and rewritten by each run, so a restart resumes instead of re-reading the source) |
| `POST /_session`, `GET /_session`, `DELETE /_session` | yes | the cookie is `base64url(user:roles:expiry:HMAC-SHA256)`, signed with a key kept in the data directory (`.session-secret`), so a session survives a restart the way CouchDB's does with `couch_httpd_auth.secret`; `GET` reports `userCtx` and, when authenticated, `info.authenticated`; `DELETE` answers `{"ok":true}` and clears the cookie; a tampered or expired cookie is anonymous. Roles travel inside the signature, so they are fixed at login rather than re-read from `_users` on every request. `test/compat/session_persistence.sh` restarts a server and reuses the cookie |

`test/interop/api_sweep.py` calls fifty endpoints against both servers and compares status, the top-level JSON keys
and the content type. It reports 50/50 agreeing with a real CouchDB 3.5.3, with no exceptions left:

- `GET /_scheduler/jobs` reports the replication the scheduler thread is running, and nothing when idle, in CouchDB's
  field set: `database`, `id` (a hash of the endpoints, `+continuous`), `pid`, `source` and `target` (no credentials),
  `user`, `doc_id`, `info`, `history` (ISO timestamps, `started`/`added`), `node` and `start_time`. `state` and
  `error_count` belong to `_scheduler/docs`, not here.
- `GET /_scheduler/docs` reports one entry per replication document with its `state` and `info` statistics. Endpoints are
  reported the way CouchDB reports them - without credentials, with a trailing slash - so the endpoint cannot leak a password.
  `info` carries the counters CouchDB publishes (`revisions_checked`, `missing_revisions_found`, `docs_read`,
  `docs_written`, `changes_pending`, `doc_write_failures`, `bulk_get_attempts`, `bulk_get_docs`,
  `checkpointed_source_seq`). A pull fetches the revisions it lacks through `POST /{db}/_bulk_get` a page at a time, so the
  `bulk_get_*` counters are real: 600 documents arrive in 2 requests at the default page size of 500. A source that
  does not implement `_bulk_get` - an old CouchDB, a proxy, a stub - is not an error: the pull falls back to one GET
  per revision and stays on that path, with the counters left at 0.
- Database info carries `sizes` (`file` measured from the write-ahead log, segments and local-document log;
  `external` and `active` are the stored leaf bodies, since one copy of each is kept).
- `GET /{db}/_changes?feed=eventsource` is a `text/event-stream` of `data:` frames, not a JSON body.
- `/{db}/_partition/...` answers `400 database is not partitioned`, as CouchDB does on a non-partitioned
  database, rather than 404.
- `?revs_info=true` adds `_revs_info`, and `?rev=` serves a revision that is no longer a leaf: a body is kept for every
  revision that stops being a leaf, so both say `available` - until compaction revises the document down to its leaves,
  after which the same revision is `missing` and `GET ?rev=` answers 404. `_bulk_get` and `open_revs` read the same
  retained bodies. Measured against CouchDB, which behaves identically before and after `_compact`.
- `_find` carries CouchDB's `warning` when the query had to scan.
- `/_utils` serves Fauxton: Apache CouchDB 3.5.3's own build, copied unmodified into `src/www/` (Apache-2.0, `LICENSE` beside
  it) and embedded in the binary by `src/www_assets.zig`, so a single binary carries its own UI. `$ZOUCH_WWW` or a `www`
  directory in the data directory overrides it, which is how a newer build can be tried without rebuilding; without any build
  the status page remains. Because it is CouchDB's UI, its pages behave exactly as they do against CouchDB - databases,
  documents, Mango, replication and the config page - which is verified by driving it in a browser.
- `/_cluster_setup` answers `{"state":"single_node_enabled"}`, so Fauxton never shows its cluster wizard; its one meaningful
  action, `enable_single_node`, sets the admin credential. `/_node/{node}/_config` lists the settings this server actually has
  and refuses writes: zouch is configured by its command line.
- A server with no credential configured is in admin party, as CouchDB is: `/_session` reports `roles:["_admin"]` for the
  anonymous caller, so Fauxton opens straight into the dashboard instead of asking for a login that cannot exist.

## Tested replication

| Scenario | Result |
|---|---|
| CouchDB pulls 100 documents from Zouch | 100 read, 100 written, 0 failures |
| CouchDB pushes 3 documents into Zouch | 3 read, 3 written, 0 failures |
| Conflict (two leaves at generation 2) | CouchDB stores both; winner is the higher hash; `_conflicts` lists the other; Zouch never auto-resolves or deletes the losing leaf |
| Replication checkpoints | `_local` written; a second run reads 0, writes 0; checkpoints survive restart |
| Attachment pull | CouchDB reads the exact bytes from Zouch |
| Attachment push | CouchDB sends `multipart/related` to Zouch; gzip metadata is preserved |
| Attachment stream upload | 2.1 MiB raw body and a chunked-transfer body read back byte-for-byte |
| `_bulk_get` attachments | `attachments=true` returns inline base64 data |
| Composite Mango ranges | trailing-field `$gt`/`$gte`/`$lt`/`$lte` through a composite index |
| Background compaction | hourly rewrite, superseded blob collected, document readable |

| PouchDB 9 | push 20, pull 20, update, checkpoint; `test/compat/pouchdb/` |
| Bulk load | 100,000 documents through `_bulk_docs`; 15.1 s debug, 0.83 s ReleaseSafe |
| CouchDB -> Zouch migration | 100,000 documents in 14 s; source/target counts and four spot bodies match |
| Migration fixtures | Attachment bytes, conflict leaves and a design-document view survive migration |
| Segment compaction | 100,000 migrated documents, an attachment and a view survive `_compact` and restart; no snapshot remains; unreferenced blobs are removed |
| Attachment blobs | Inline, stub, bulk, multipart and gzip payloads externalize to `blobs/` and rehydrate on read |
| Zero-length attachment | PASS; returns 200 with an empty body and does not crash the server |

## Hardening evidence

| Test | Result |
|---|---|
| Kill -9 and torn WAL tail | PASS; committed docs survive, torn tail ignored |
| FUSE power-loss disk | PASS; acknowledged writes survive, unfynced in-flight bulk does not |
| Failed single/bulk fsync | PASS; error is JSON and the write is not acknowledged |
| ENOSPC / read-only filesystem | PASS; returns HTTP 507 `insufficient_storage`, process alive, `zouch check` clean |
| Directory fsync after rename | PASS; `test/compat/dirsync.sh` observes `fsync` on the database and `blobs/` directories after atomic writes |
| `_replicator` failure handling | PASS; failed one-shot jobs record `error`, retry with backoff (including after a target restart), then complete after the source returns |
| Push response handling | PASS; successful `new_edits:false` empty responses and error objects are distinguished; `replicate_push.sh` covers ordinary and conflict pushes |
| Multipart bulk | PASS; `bulk_multipart.sh` covers multipart `_bulk_docs` with nested attachments and multipart `_bulk_get` response parts |
| Percent-encoded ID | PASS; `http.sh` writes and reads a document whose ID contains `%2F` |
| HNSW recall gate | PASS; 1,024 vectors, recall@10 at `ef=64` exceeds the 80% gate |
| HNSW allocation failure | PASS; all HNSW insertion/search allocation points are exercised; fixed a double free found by the gate |
| Pull failure handling | One-shot and scheduled pulls propagate document, parse, import and checkpoint failures; they no longer skip a document and advance past it |
| Feed starvation | PASS; two longpoll+continuous feeds leave CRUD around 15-20k req/s |
| 100 concurrent feeds | PASS; all 100 longpoll feeds woke through the shared scheduler, CRUD responsive |
| Continuous feed | PASS; changes stream, heartbeat/timeout close cleanly, `since=now` excludes old documents |
| Combined power-cut soak | PASS on the full 24-hour gate: 799,226 acknowledged documents through 143 power cuts; every restart verified and `check` was clean; peak RSS 337,456 kB |
| `_security` storage | PASS; object round-trips, invalid roots return 400, database recreation starts empty |
| `_security` names | PASS; members are allowed, other authenticated users get 403, admins bypass |
| `_security` roles | PASS via `_users` user documents or the local `ZOUCH_ROLES` map |
| `_users` auth | PASS; PBKDF2 password hashing, Basic/cookie auth, roles, `_admin` bypass and `_users` protection |
| Mango operators | `$regex` (POSIX ERE), `$allMatch`, `$keyMapMatch` and `$text` over a persisted inverted index and `execution_stats` covered by `mango.sh` |
| Fuzz | PASS on the full 600-second-per-category campaign: HTTP 673,932, JSON 835,946, multipart 915,330, revisions 654,873 cases (3,079,081 total) |
| 24-hour soak | PASS; 404,900 writes plus 100 replicated docs, 405,002 total, `zouch check` clean, peak RSS 1.46 GiB |
| Backup/restore | `scripts/backup.sh` verifies, archives, checks tar and SHA-256; restore checked |
| systemd | Transient unit with `ProtectSystem=strict` served `_up` and was stopped cleanly |
| Docker | Non-root, read-only rootfs, healthcheck healthy, data survives restart |

## Not implemented

- `_replicator` stores the failure count and state; after a restart it recomputes the next retry
  from that count rather than storing a wall-clock deadline. This is intentional and avoids a
  dependency on clock adjustment.
- Native TLS, HTTP/2 or HTTP/3. Terminate TLS at Caddy; the bundled Fauxton is served plain over loopback.
- A cap on the bodies kept for superseded revisions: they accumulate until compaction, as CouchDB's do, but there is no
  `revs_limit`-style bound on how many are held between compactions.
- Clustering, sharding, quorum and resharding.
- Allocation-failure injection covers JSON serialization, HNSW and database open/local writes; HTTP handler and Mango/query allocation paths still need dedicated failure tests.

## Error responses

Bodies are CouchDB-shaped `{"error":...,"reason":...}`. These codes cover the states that are easy
to confuse with a server bug:

| Status | `error` | Meaning |
|---|---|---|
| 400 | `illegal_database_name` | name is empty, starts with `_` (except `_users`/`_replicator`), or contains `/`, `\\` or NUL |
| 400 | `invalid_operator` | `_find` selector uses a `$operator` Zouch does not implement |
| 409 | `database_locked` | another process holds this database's `.zouch.lock` |
| 409 | `conflict` | a delete or a second replication request against a database a replication is using |
| 500 | `corrupt_database` | recovery failed; run `zouch check` on a copy and restore the last backup |
| 502 | `replication_failed` | a pull or push did not complete; `reason` carries the remote status and body |
| 507 | `insufficient_storage` | ENOSPC, read-only filesystem, or an oversized body |

`GET /_up` returns `{"status":"ok","seeds":{}}`. It is a liveness probe and does not open
databases: a damaged database still answers `_up` with 200 and reports `corrupt_database` when it is
read.

## Known incompatibilities

- `update_seq` is an integer, not CouchDB 3.x's opaque string. CouchDB's replicator accepts it; a
  client that compares sequence strings literally would not.
- Percent-encoded document IDs, including `%2F`, are decoded and routed; an unencoded slash remains the document/attachment path separator.
- View string keys use ICU root collation when `libicui18n` is available; array keys compare
  lexicographically and object keys by sorted key name then value, not full ICU deep collation.
- A missing filter returns 404 rather than silently returning unfiltered changes.
- `_find` bookmark pagination is stable only while the result order is stable.
