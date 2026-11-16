# Changelog

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
