# Zouch — Memory & Ownership Design

**Status:** v0.1.0 — companion to `docs/storage-format.md`.
**In-repo home:** `docs/memory-design.md`.
**Purpose:** prevent, by construction, the failure class that hurt Bun — in a Zig storage engine
that also embeds a garbage-collected JavaScript engine for views.

**How to use:** read §1–3 before writing code that owns memory; use §7's checklist in review; add
every new mechanism to §8.

---

## 0. Implementation status (v0.1.0)

This document describes the memory and ownership design for the engine. The
current code implements a smaller subset; the rules below that are still aspirational are marked
**planned** so a reader does not mistake them for invariants the code enforces.

**What the code does today**

- **Per-database locking and HTTP worker pool.** `httpz` runs eight worker threads and each
  handler takes the database lock only for the snapshot/commit it performs.
  There is no per-database writer thread and no snapshot registry (Law 2 is **planned**).
- **Request memory is an arena.** httpz hands each response a `res.arena`; handlers build JSON,
  parse request bodies and hold query scratch there. It is released with the response, but it is
  not a capped `FixedBufferAllocator`, and a 64 MiB request body can be materialised in it
  (Law 6 is partially implemented: every allocation is explicit, but budgets are not enforced).
- **Documents are owned by `Db.docs`.** `Doc` and `Leaf` own their `id`, body and ancestry bytes;
  the map is the single owner until `_purge` or close. Caches that outlive a document keep copies
  (ADR 0008), not borrowed slices.
- **Storage is WAL + segments + snapshot + A/B manifest** with a single writer, one `.zouch.lock`
  per database. Recovery fails closed on a read error; only `FileNotFound` means "absent".
- **Views run one QuickJS runtime per query call**, with a 64 MiB memory limit and no interrupt
  handler. A per-database runtime and time budget are **planned** (Law 3/§5 "QuickJS views").
- **Feeds are one scheduler thread** that sweeps every registered feed every 50 ms, not a thread
  and ring buffer per feed. Contexts carry their allocator, and deletion is serialized against
  registration (§5 "Feeds" is the target; admission control via `ZOUCH_MAX_FEEDS` is implemented,
  the fixed ring buffer is not).
- **Caches** (`vector_cache`, `text_cache`) are keyed by database name, owned by `App`, and dropped
  with the database or when their `seq` is stale.
- **Not implemented:** block cache, segment refcounts, snapshot handles with generation checks,
  memtable budgets and admission control, C-side counter assertions, RSS gates, and a Valgrind/ASan
  job for QuickJS. Treat those sections as design intent, not as a description of the build.

**What is enforced now:** `std.testing.checkAllAllocationFailures` over the storage open/write/
recovery paths, targeted regression tests for each ownership rule in ADR 0008, a leak-checking test
allocator for every Zig allocation, and the compatibility suites under `test/compat/`.

---

## 1. Why this document exists

Bun embedded JavaScriptCore — a generational, non-moving mark-sweep GC — inside a Zig codebase with
manual memory management. It worked at scale and still produced a steady stream of the same bugs:
use-after-free, double-free, leaks on error paths, and GC roots that never died. Jarred Sumner's
postmortem names the reason plainly: *"mixing GC with manually-managed memory is an uncommon enough
thing for software to need that no language really designs for it."* The eventual response was a
Rust port so the compiler could enforce what review had not.

The lesson is not "Zig is bad". The lesson is that **the boundary between a GC and manual memory is
where no language's defaults protect you**, and that warnings, style guides and a late test suite do
not fix it. Structure does: a small boundary, simple laws, and gates that make the unsafe thing
impossible to merge.

Zouch has the same shape, plus more:

- Zig owns document bytes, WAL records, segment blocks, attachment buffers and the memtable.
- QuickJS owns JS values, objects and its own heap when views run.
- Four asynchronous lifetimes overlap: HTTP requests, `_changes` feeds, snapshot readers, and
  compaction/GC jobs.
- Two threads touch memory: the per-database writer and httpz's request pool; readers hold
  snapshots the writer must not invalidate.

That is enough shared surface to reproduce every Bun bug class if we let it. This document is the
guard.

## 2. Bun's failure classes, mapped to Zouch

| Class | Bun example | Zouch manifestation | Guard |
|---|---|---|---|
| **A. Async close vs free** | zlib stream reset while an async write was in flight; `uv_close` handed a box that dropped before the callback | A feed subscription, snapshot handle or compaction job freed while a reader or compaction is still using it | Generation-checked handles; release only in the completion path; never `defer`-release a handle next to its acquire |
| **B. Re-entrancy invalidation** | JS callback during `node:http2` request rehashed a map and invalidated stream pointers; `valueOf()` detached a buffer during `Buffer#copy` | `emit()` appends to the view index while the map function still holds a pointer into that buffer; a JS getter mutates state between conversion and use | Copy inputs before the callout; re-lookup after it; index-based cursor, never a raw pointer into a growable array |
| **C. Leak on error path** | `crypto.scrypt` leaked callback and buffers when output allocation failed; TLS leaked `strdup`ed passphrase on error | JSON parse allocates a doc body then rejects the document; attachment temp file written then doc commit fails; QuickJS exception after allocating a result | `errdefer` adjacency; allocation-failure injection; no `catch {}` on fallible paths |
| **D. GC-root leaks** | `fs.watch()` watchers pinned forever after `.close()` via a refcount underflow | `JS_DupValue` for a map function never freed; a `JSValue` cached in a Zig struct; a finalizer holding a Zig pointer | Dup/free pairs adjacent; no `JSValue` in long-lived structs; teardown asserts handle count zero |
| **E. Double free** | CSS parser double-free; ported `uv_close` path freed twice | Doc body owned by both the request arena and the memtable; snapshot and compaction both free a segment; blob freed by GC and refcount | One owner per allocation; move semantics at boundaries; refcounts only for immutable segments; pending-blob set |
| **F. Torn reads / threading** | GC marker thread saw a torn variant during concurrent worker access | Writer mutates a document while a reader scans it; compaction unlinks a segment a reader holds; non-atomic refcount | Immutable snapshots only; no mutable sharing across threads; atomic refcounts; one writer per database |

Bun had ASan, fuzzing and leak tests. They were late and partial. The difference here is that the
gates below run from Phase 0, and every guard has a mutation check: delete the guard, the owning
test must fail.

## 3. The nine laws

Review of anything touching `store/`, `doc/`, `chttp/`, `views/` or a lifetime is against this list.

**Law 1 — One boundary, one owner.** `io` owns OS calls; `store` owns bytes on disk and in the
memtable; `doc` owns revision semantics and the document bytes it hands to `store`; `chttp` owns
request/response buffers; `views` owns the QuickJS runtime. No raw pointer to another layer's
allocation crosses a boundary. *Because* the boundary is where bugs concentrate; a boundary you
cannot isolate is one you cannot test. *Prevents* A and E.

**Law 2 — Lifetimes that outlive a call are handles, not pointers.** Snapshots, feed subscriptions,
in-flight attachment writes and compaction jobs are generation-checked slots in a registry. Release
is explicit and lands in the completion path. A stale handle validates as dead and is dropped, never
dereferenced. *Because* an async completion can arrive after the owner is gone. *Prevents* A.

**Law 3 — JS values are refcounted and confined.** A `JSValue` may live on the stack for the
duration of a call. Anything stored longer is duplicated with `JS_DupValue` and freed with
`JS_FreeValue` on every path; the two are adjacent in the diff. No `JSValue` is stored in a Zig
struct that outlives the call, and no Zig pointer is stored in a JS object without an owner.
*Because* an unrooted value dies at the next collection, and a forgotten free pins memory forever.
*Prevents* D.

**Law 4 — Exceptions convert immediately.** Every QuickJS call is followed by `JS_IsException`;
the exception is converted to a Zig error and cleared before any other work. No code path continues
with a pending exception. *Because* a pending exception detonates later, in unrelated code.
*Prevents* C and confusing secondary failures.

**Law 5 — Nothing survives a callout.** Before calling into JS, copy every input the operation
needs into owned storage. After the call returns, re-fetch every pointer, index and state field;
treat everything cached across the call as invalid. `emit()` is a callout into Zig: it may grow the
index buffer, fail, or re-enter. *Because* user JS runs in the middle of native operations and can
mutate everything the operation was holding. *Prevents* B.

**Law 6 — Explicit allocators, capped arenas.** Every allocation receives its allocator. Request
work uses a `FixedBufferAllocator` with a hard cap, not an unbounded `ArenaAllocator`. Long-lived
structures use the database allocator with a documented owner and release path. No hidden
allocation, no global allocator except the entry point, no arena shared across threads. *Because*
"where do these bytes get freed?" must be answerable from the code, not discovered by the OOM
killer. *Prevents* C and unbounded growth.

**Law 7 — Every acquire has a cleanup on every path.** `defer` for the success path, `errdefer` for
every failure path, adjacent to the acquire. No `catch unreachable`, no `catch {}` on allocation or
I/O. The review question is: *can this function return between acquire and cleanup?* *Because* Zig
has no destructors. *Prevents* C.

**Law 8 — No allocation after the commit point.** Once a write is committed (WAL fsynced, sequence
assigned), the acknowledgement path performs no fallible allocation. Response JSON, headers and
buffers are prepared before commit or drawn from a preallocated buffer. *Because* an allocation
failure after commit cannot un-commit the write; it can only produce a lost acknowledgement or a
retry that conflicts. *Prevents* a database-specific version of C.

**Law 9 — Teardown is ordered and tested.** Close feeds → stop accepting → drain requests → stop
writer → flush memtable → write manifest → fsync → release snapshots → close segments → free
QuickJS context → free runtime → assert every registry and handle count is zero. Leak tests force
collection before measuring and never infer liveness from untouched stack words. *Because* freeing a
runtime before its values is use-after-free, and a leak test that skips GC is fiction. *Prevents* D
and E.

## 4. Allocation map and budgets

| Owner | Allocator | Budget | Lifetime |
|---|---|---|---|
| Process | `std.heap.smp_allocator` (release), `DebugAllocator` (debug) | — | process |
| HTTP metadata | `FixedBufferAllocator` per request | 1 MiB | one request; reset at response end |
| Document buffer | fixed slot from a bounded pool | 16 MiB × 8 slots = 128 MiB | one document write |
| JSON/doc parse | within the document buffer + 1 MiB scratch | ≤16 MiB/document | converted to owned bytes, then freed |
| Memtable | database allocator | 64 MiB active + 64 MiB immutable | until flush |
| Block cache | fixed 4 KiB frames | 128 MiB | LRU, process |
| Snapshot | small struct + refcounted segment handles | O(1) per reader | until reader closes |
| Attachment streaming | fixed 64 KiB buffer + temp file | 64 MiB/attachment | one upload/download |
| Compaction | fixed read buffers + segment writer | 32 MiB scratch | one job |
| QuickJS runtime | its own allocator, `JS_SetMemoryLimit` | 64 MiB | database lifetime |
| View index build | external merge sort, capped runs | 32 MiB per run, spill | one index build |
| Feed buffer | fixed ring per feed | 256 KiB × 16 | feed lifetime |

Steady state is roughly 400 MiB without views and ~470 MiB with the QuickJS runtime and a full
document pool; the published gate is 512 MiB. Every budget is enforced **before** allocation, not
after: a request that would exceed its cap gets 413, a write that would exceed the memtable gets a
flush, a feed that cannot keep up is disconnected. Allocation failure is `503`, not a panic.

## 5. Boundary rules in practice

### HTTP requests
Each request gets a 1 MiB metadata arena. A document write takes one 16 MiB slot from a pool of
eight; a request that cannot get a slot waits briefly or gets 503. That pool is the admission control
that bounds worst-case memory. Bodies stream into fixed buffers; `_bulk_docs` and attachments never
materialise the whole body in memory. The response is serialised into a preallocated buffer up to a
cap, then streamed. The metadata arena is reset once, at the end, on every path — including errors
and disconnects.

### Store and snapshots
The memtable owns document bytes. When a batch commits, ownership moves into the memtable; the
request must not free it afterwards. A snapshot is `{generation, immutable memtable, pinned segment
handles}`; segment files are unlinked only when the refcount reaches zero. A reader never holds a
pointer into the active memtable across a call that can flush.

### Attachments
Blobs stream to a temp file while hashing; fsync, rename, then insert the blob record into the
pending set. GC only collects blobs that no live document and no pending write references. A failed
upload removes the temp file on the error path; a failed commit leaves the blob pending until the
next reconciliation.

### QuickJS views
One runtime per database, one context, `JS_SetMemoryLimit(rt, 64 MiB)`, and an interrupt handler
that aborts a map function after its time budget. Per document: copy the fields the map needs into
JS values, call the function, copy emitted keys/values into the index writer, free every value.
The map function itself is rooted once (dup) and freed at teardown. Finalizers may release plain
memory only — no allocation, no JS calls, no exceptions.

QuickJS allocations are invisible to Zig's leak-reporting test allocator. They get counters, the
runtime memory limit, RSS bounds and a Valgrind/ASan pass; the document never claims more than the
tooling can prove.

### Feeds
Each feed owns a fixed ring buffer and a dedicated thread (measured: two blocked handlers on the
request pool dropped throughput from 83k to 234 req/s). A slow consumer is disconnected rather than
allowed to grow an unbounded queue. `max_concurrent_feeds` is admission control, not a suggestion.

## 6. Zig-specific rules

- **No destructors.** `defer`/`errdefer` are the only cleanup. Recent Zig removed `errdefer`
  payload capture; split the function or use a small helper instead of fighting it.
- **Allocator thread safety is not implied.** `FixedBufferAllocator` and `ArenaAllocator` are
  thread-confined; `smp_allocator` and `c_allocator` are thread-safe. Nothing allocated in a request
  arena crosses into the writer thread; cross-thread work receives owned buffers from a thread-safe
  allocator and returns owned results.
- **Safety-check panics are uncatchable.** They abort; they never become HTTP errors. Untrusted
  input never reaches `unreachable`, `@intCast`, or an assertion. Sizes are checked before arithmetic.
- **The leak-reporting test allocator sees only Zig-routed allocations.** QuickJS, ICU and any
  vendored C are counted separately.
- **Toolchain churn is real.** `@cImport` is gone in 0.17 (hand-written `extern` declarations);
  `std.time.Timer` is gone (time comes through `io`); `std.net`/`std.posix.socket` are gone. Pin the
  compiler and keep the C surface behind a small binding layer.
- **`std.testing.checkAllAllocationFailures` exists** and is the cheapest way to execute error paths
  that would otherwise only run under real OOM.

## 7. Enforcement machinery

**Gates**
- Leak gate: every unit and integration test runs with `std.testing.allocator`; a leak fails the
  build. C-side counters must return to zero at teardown.
- Allocation-failure injection: the simulator fails each allocation site once, at every ordinal,
  and asserts the operation returns `503`/`error.OutOfMemory`, leaves no partial state, and leaks
  nothing. `checkAllAllocationFailures` covers pure units; the crash harness covers the store.
- Budget gate: RSS after open ≤128 MiB, steady ≤512 MiB; per-request arena high-water ≤4 MiB;
  memtable never exceeds its budget; feed buffers never grow.
- Soak: 24 hours with replication, queries and random power cuts; RSS slope and allocator counters
  must plateau, not merely stay under a cap.
- C side: Valgrind or ASan for QuickJS/ICU, with versioned suppressions; the JIT is disabled for the
  leak run.
- Fuzz: rev parser, JSON, multipart; `zig build test --fuzz` from Phase 1.

**Mutation checks.** Every guard above gets one: delete the generation check, the `errdefer`, the
refcount or the post-callout re-lookup, and its owning test must fail. A guard without a mutation
check is a comment.

**Review checklist** (every PR touching a lifetime, a buffer, or the JS boundary):
1. Cleanup adjacency: every acquire has `defer`/`errdefer`; error paths exercised. Evidence: adjacent
   lines in the diff + an allocation-failure test.
2. No borrowed pointer crosses a boundary or an async wait. Evidence: grep for the type outside its
   owning package is empty.
3. Every callback validates its handle generation before use. Evidence: visible in each callback.
4. Every callout has a copy before and a re-lookup after. Evidence: both visible in the diff.
5. No `JSValue` in a struct that outlives the call; dup/free pairs adjacent. Evidence: grep + diff.
6. New resources have a counter and a stress test. Evidence: counter entry + test name.
7. Teardown updated if a lifecycle changed. Evidence: shutdown-suite delta or "no change needed".
8. Leak gate and the relevant budget gate ran. Evidence: CI links.
9. Traps ledger updated if a new mechanism appeared. Evidence: ledger diff.
10. An adversarial reviewer is named for anything touching `views/` or `store/`. Evidence: reviewer
    handle.

## 8. Traps ledger (seed for `docs/traps.md`)

`docs/traps.md` is the live ledger. It carries every entry below plus the mechanisms found by the
2026-11 ownership review (entries 11–17, see ADR 0008); the seed stays here unchanged for history.

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

## 9. Success metrics

- Leak gate green on every merge; zero unexplained counter drift in a 24-hour soak.
- Every Bun bug class has a corresponding test and a mutation check; recurrence triggers a process
  fix (gate or ledger), never a one-off patch.
- Allocation failure produces `503` with the database still openable — never a panic, never a lost
  acknowledged write.
- RSS plateaus under sustained replication and view builds; no queue grows without a bound.
- The boundary stays small enough to review: `views/` is the only package that touches `JSValue`,
  and `store/` is the only package that owns persistent bytes.

## 10. References

- Bun, "Rewriting Bun in Rust" (Jarred Sumner, July 2026) — the postmortem's bug classes.
- Zeste, `MEMORY-DESIGN.md` (the original anti-Bun playbook for a Zig JS runtime):
  `/mnt/nas/tony/from-hermes/zig-js-runtime/MEMORY-DESIGN.md`.
- TigerBeetle, `docs/TIGER_STYLE.md` — assertions, explicit bounds, "always say why".
- QuickJS API: `JS_DupValue`/`JS_FreeValue`, `JS_SetMemoryLimit`, `JS_SetInterruptHandler`,
  `JS_IsException`.
- Zig 0.17: `std.testing.checkAllAllocationFailures`, `std.heap.FixedBufferAllocator`,
  `std.heap.smp_allocator`, `std.heap.DebugAllocator`.
