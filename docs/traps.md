# Zouch traps ledger

Mechanism-indexed hazards from `docs/memory-design.md`. Add an entry for every new failure
mechanism; do not delete entries when a bug is fixed.

## 8. Traps ledger (seed for `docs/traps.md`)

1. **Symptom:** crash after a client disconnects mid-feed. **Mechanism:** the feed handle was freed
   while the writer still held a queued change. **Detection:** disconnect stress + generation
   mutation. **Countermeasure:** handle released only in the feed completion path.
2. **Symptom:** view rows duplicated or missing under load. **Mechanism:** a pointer into the index
   buffer was held across `emit()`, which grew and moved it. **Detection:** emit-during-map stress.
   **Countermeasure:** index-based cursor; re-fetch after every emit.
3. **Symptom:** memory grows only when documents are rejected. **Mechanism:** parse error after the
   body was allocated, before ownership moved. **Detection:** allocation-failure injection; fuzz
   with malformed docs. **Countermeasure:** `errdefer` adjacency.
4. **Symptom:** RSS climbs after every view rebuild. **Mechanism:** map function `JSValue` dup'd at
   compile time and never freed. **Detection:** runtime handle counter; teardown assertion.
   **Countermeasure:** one explicit root, freed in teardown.
5. **Symptom:** double free at database close. **Mechanism:** snapshot and compaction both release a
   segment. **Detection:** shutdown suite; refcount underflow assertion. **Countermeasure:** segment
   refcount owned solely by the snapshot registry.
6. **Symptom:** document bytes corrupted under concurrent read/write. **Mechanism:** reader held a
   pointer into the active memtable while the writer flushed it. **Detection:** snapshot stress with
   flushes. **Countermeasure:** immutable snapshots; no active-memtable pointers.
7. **Symptom:** attachment lost after a crash. **Mechanism:** blob was GC-eligible before the doc
   committed. **Detection:** kill-between-blob-and-commit test. **Countermeasure:** pending set.
8. **Symptom:** works in ReleaseSafe, fails in Debug (or the reverse). **Mechanism:** relying on
   checks present in only one mode. **Detection:** both modes in CI. **Countermeasure:** checked
   arithmetic for untrusted input; assertions only for internal invariants.
9. **Symptom:** a "fix" makes a crash disappear without fixing the lifetime. **Mechanism:** an error
   is swallowed or a pointer is nulled. **Detection:** forbidden-pattern review. **Countermeasure:**
   process fix plus a mutation test.
10. **Symptom:** OOM kills the process instead of returning 503. **Mechanism:** allocation after the
    commit point, or an unbounded queue. **Detection:** allocation-failure injection; cgroup memory
    limit run. **Countermeasure:** Law 8 + admission control.

11. **Symptom:** a database reopens with fewer documents (or none) after a transient allocation
    failure. **Mechanism:** recovery used `catch return`/`catch continue` for every read error, so
    `OutOfMemory` while reading the segment manifest, a segment, a manifest or `locals.log` was
    indistinguishable from "file absent"; `segment_seq` then advanced past records that were never
    loaded and the next snapshot persisted the hole. **Detection:** allocation-failure scan over
    `Db.open` on a segment-only database. **Countermeasure:** only `FileNotFound` is swallowed;
    every other error aborts the open (ADR 0008 §3).
12. **Symptom:** invalid-free panic when `DELETE /db` runs while a `_changes` feed is open.
    **Mechanism:** the feed context and its filter spec were allocated with `page_allocator` and
    released by `App.closeFeedsFor` with the App allocator. **Detection:** code review; a generic
    mismatched-free test panics in the same way. **Countermeasure:** the context carries its
    allocator (ADR 0008 §2).
13. **Symptom:** use-after-free read during `_vector_search` after `_purge`. **Mechanism:**
    `VectorCache.ids` borrowed `Doc.id`; purge frees the document, and the next cache refresh
    hashed and looked up the freed bytes. **Detection:** assert the cache id does not alias
    `Doc.id`; the freed block reads back as allocator poison. **Countermeasure:** owned id copies,
    caches dropped on database delete (ADR 0008 §1).
14. **Symptom:** RSS grows per request with no documents added. **Mechanism:** a buffer allocated
    on `Db.alloc` was returned to a request scope (`readSecurity`), a file buffer was kept alive by
    borrowed ids (`loadVectorIndex`), and per-tick scratch was never freed (`buildFilterIds`).
    **Detection:** leak-checking allocator with the caller's allocator in a unit test.
    **Countermeasure:** allocator parameter is authoritative; functions document what the caller
    owns.
15. **Symptom:** `validate_doc_update` sees the identity of an earlier request. **Mechanism:** the
    thread-local identity outlived the stack buffer and response arena that backed its slices.
    **Detection:** review; no test can observe a freed slice deterministically. **Countermeasure:**
    cleared in a `defer` in `dispatch` (ADR 0008 §5).
16. **Symptom:** the feed scheduler dereferences a freed `Db` after a delete. **Mechanism:** a feed
    request that had already captured the handle appended its context between `closeFeedsFor` and
    `deleteDb`. **Detection:** review; needs a live chunked connection to reproduce.
    **Countermeasure:** `feed_mutex` held across the teardown plus a liveness re-check before
    append (ADR 0008 §4).
17. **Symptom:** a database is permanently `DatabaseLocked` after an out-of-memory event.
    **Mechanism:** a failed `dbs` map insert dropped the open `*Db`, keeping its `.zouch.lock`
    descriptor and flock for the process lifetime. **Detection:** `FailingAllocator` scan asserting
    allocated bytes equal freed bytes. **Countermeasure:** publish last; `errdefer db.close()`
    (ADR 0008 §6).
