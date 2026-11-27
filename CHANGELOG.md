# Changelog

## Unreleased

### Bug Fixes & Safety
- **Concurrency & Locking:** Reworked `ReplLock` to lock per-database `Db.mutex` instead of the global `App.mutex`, eliminated cross-lock-domain races (`hAttGet`, `_replicator`, feed registration/cleanup), made `DELETE /{db}` drain active pins and delete files outside `App.mutex`, and enforced lock assertions (`lock_checks`).
- **Crash & Overflow Fixes:** Removed float formatting stack panics (arbitrary float formatting + `.number_string` handling), caught throws in view map/reduce functions cleanly, handled arbitrary-size integers and non-finite literals in Mango comparisons, prevented `limit + skip` overflows in `_all_docs`/views, and handled `_local` revision overflow.
- **Storage & Memory Bounds:** Enforced 2 GiB segment/WAL file limits (`507 insufficient_storage`) with streaming `mergeSegments`, removed duplicate `Retained.ancestry` storage (bounding retained bodies), persisted `Db.uuid` for isolated replication checkpoints, bounded attachment/HTTP response caches and decompression (`ZOUCH_MAX_BODY_MB`), and wired `_revs_limit` directly into tree updates.
- **Replicator & Feeds:** Added 3-phase lock-free feed socket flushing (`SO_SNDTIMEO`), socket timeouts and concurrent worker pool for `_replicator`, per-document push/pull error isolation (`doc_write_failures`), full `gzip` `Content-Encoding` preservation across replication/attachments, MIME header escaping on multipart push, and cleaned up `_scheduler`/job completion tracking.
- **Auth & JavaScript:** Restricted unauthenticated `/_utils/` dashboard asset access only appropriately, gated `_replicator` and design docs/compaction properly, persisted `_cluster_setup` admin users into `_users`, rejected malformed `_security` payloads with `400`, passed clean documents (`_attachments` stubs without internal blob metadata, `req.query`, `secObj`) to `validate_doc_update` (including `DELETE`) and view mappers, and stopped using `page_allocator` in `Engine.eval`.

### Compatibility & Performance
- **HTTP & CouchDB Parity:** `PUT /{db}` returns `412 file_exists` when present; strict CouchDB DB and document ID validation (`_local%2F` rejected as regular docs); `ETag`/`Cache-Control`/`If-None-Match` (`304`) on doc GET; `open_revs` `latest=true` checks ancestry; `_missing_revs` checks ancestors/retained revisions; superseded `GET ?rev=` and `_bulk_get` return cleaned JSON; `_all_docs` and views honour `GET ?keys=`, full POST body options, and view `total_rows`; `_find` lifts the 10,000 `limit` cap; `ZOUCH_VECTOR_INDEX_MB=0` acts as unlimited; `_explain` escapes quoted field names; `_index` avoids `_design/_design/` double prefix and detects existing definitions; `_local` IDs > 504 bytes preserve `_local/`.
- **Performance:** Incremental `live_doc_count`/`deleted_doc_count`/`live_body_bytes` for O(1) `GET /{db}`, stored attachment `digest`/`length` to avoid reading blobs on stub generation, binary-search lookups + incremental Mango indexes, cached `_users` presence flag, and cached compiled QuickJS regex bytecodes.

## 0.1.0

Initial public release.

### Storage & Durability
- Append-only WAL with CRC-32C checksums, immutable segments, automatic segment merge, and double-buffered A/B manifests.
- Content-addressed attachment blob store (`blobs/<md5-hex>.bin`) and single-segment `_compact` with background compaction (`ZOUCH_AUTO_COMPACT_SECS`) and blob GC.
- Transient WAL/write error recovery, per-database live memory budget (`ZOUCH_MAX_DB_MB`), request body cap (`ZOUCH_MAX_BODY_MB`), and vector index memory budget (`ZOUCH_VECTOR_INDEX_MB`).

### CouchDB HTTP API & Replication
- Full document lifecycle (`GET`/`PUT`/`DELETE`, `_rev`, `?rev=`, `?revs=true`, `?conflicts=true`, `?open_revs=all`, `_revs_info`, `_purge`, `_bulk_docs`, `_bulk_get`, `_revs_diff`, `_missing_revs`, `_local` checkpoints).
- Bidirectional replication (`POST /_replicate`, `_replicator` one-shot and continuous jobs with exponential backoff, CLI `pull`/`push`, filters, `doc_ids`, `selector`, multipart attachments).
- `_changes` (`normal`, `longpoll`, `continuous`, `eventsource`) on a shared scheduler thread, plus live `/_active_tasks`.
- `_users` PBKDF2 authentication, `_security` admins/members/roles enforcement, `_session` cookie auth, `validate_doc_update`, and bundled Fauxton UI at `/_utils/`.

### Views, Mango & Vector Search
- QuickJS MapReduce views (`_count`, `_sum`, `_stats`, custom JS reduce), in-memory `ViewCache`, and optional `libicui18n` root collation.
- Mango `_find`, `_index`, and `_explain` with `$text` full-text search, `$regex`, composite indexes, and CouchDB-compatible error shapes.
- `POST /{db}/_vector_search` with persisted int8 flat index (float32 rescoring) and incremental HNSW graph (`engine: "hnsw"`).
