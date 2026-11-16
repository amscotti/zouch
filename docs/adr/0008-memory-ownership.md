# ADR 0008 — Ownership rules for caches, feeds and open state

**Status:** accepted · 2026-11-08

## Context

A memory-ownership review of `store/`, `http/` and the caches found a set of defects with one
common shape: a pointer outlived the thing that owned it, or an allocation was released by an
allocator that did not make it. The individual fixes are small, but without a written rule the
next feature reintroduces them. The affected areas are the ones with more than one lifetime in
play:

- the vector and text caches, which outlive a request and a document revision;
- `_changes` feed contexts, which outlive the request that created them and are torn down from a
  different thread;
- the open-database map, whose entries hold an exclusive file lock;
- `validate_doc_update`, which needs the request identity from inside a storage-level call;
- recovery, which decides whether a failure is "the file is not there" or "we cannot read it".

## Decision

1. **A cache owns what it keeps.** `VectorCache.ids` stores copies, not `Doc.id` slices, and
   `TextCache` owns its keys. Anything that survives the document it names must be copied. Caches
   keyed by database name are dropped by `App.deleteDb`; a same-named database starts empty.
2. **The allocator travels with the object.** A `LongpollCtx`/`ContinuousCtx` carries its
   allocator, because `closeFeedsFor` runs on a request thread and the scheduler runs on another.
   A function that takes an allocator uses it for everything it returns (`readFileAlloc`,
   `loadVectorIndex`), so the caller can release what it received.
3. **Recovery fails closed.** Only `FileNotFound` may be treated as "absent". `OutOfMemory` or an
   I/O error while reading a manifest, the segment manifest, a segment, `locals.log` or
   `security.json` aborts the open. Serving a subset of acknowledged documents — or an
   unrestricted security object — is worse than refusing to start.
4. **Teardown is serialized with registration.** `hDbDelete` holds `feed_mutex` across
   `closeFeedsFor` and `deleteDb`, and feed handlers re-check that the `*Db` they captured is still
   the live one before appending. Lock order is always `feed_mutex` then `app.mutex`.
5. **Request identity is per request.** `validate_user`/`validate_roles`/`validate_admin` are
   thread-local only for the duration of `dispatch`, and are cleared in a `defer` so a later
   request cannot observe a slice into a dead arena or stack frame.
6. **Publish last.** A container (`App`, `*Db`, `Local`) is inserted into its map only after every
   allocation it needs exists; a failed insert releases the container. A half-built object is never
   published.
7. **OOM is an error, not a state.** Paths that swallow `OutOfMemory` are bugs even when they look
   harmless (defaults, best-effort cleanup), because they turn a transient failure into a silent
   behaviour change.

## Consequences

- Every rule above has a test that fails without it: segment recovery under injected allocation
  failures, local checkpoint creation, `App.init`/`createDb` handle accounting, vector-cache
  ownership across a purge, vector-index loading, filter scans, security reads, and settings
  replacement.
- `std.testing.checkAllAllocationFailures` is the default tool for new storage paths; the manual
  `FailingAllocator` scan is used where the workload closes a database (the closing snapshot is
  best-effort by design and would otherwise mask a swallowed OOM).
- The caches cost one extra copy of each document id. That is bounded by the number of indexed
  documents and is cheaper than a dangling slice.
- Deleting a database blocks feed registration for the duration of the teardown. Deletes are rare
  and already take the database lock, so this is not a throughput concern.
- The thread-local identity is still a thread-local. A future handler that runs work on a pool
  thread must pass the identity explicitly rather than reading the thread-local.
