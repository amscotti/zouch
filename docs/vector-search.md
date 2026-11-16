# Zouch — Vector Search for RAG

**Status:** design note, 2026-10-31 · companion to `2026-10-31_182745-zouch.md`
**Implementation note (2026-11-06):** the repository contains the persisted int8 flat index with
float32 rescoring, plus an optional HNSW graph selected with `engine: "hnsw"` on
`POST /{db}/_vector_search`. The graph is persisted in `hnsw.idx`, reused across restarts, and
rebuilt when the database sequence changes; `ef` controls the search breadth; the incremental `_changes` indexer, memory admission
control and PQ/OPQ described below remain future work.
**Decision:** yes — as a Zouch **extension**, not a CouchDB-compatibility feature. Vectors travel as
ordinary document fields; the index and the query endpoint are local.

## 1. Why it fits Zouch

- Documents are JSON, so an embedding is just a field; CouchDB and PouchDB replicate it without
  knowing what it is.
- The change feed already gives an incremental, resumable source for index maintenance.
- The storage engine already owns immutable segments, manifests and snapshots; a vector index is
  another segment type with its own manifest entry.
- Zig makes a SIMD distance kernel straightforward, and the measured baseline below says the CPU is
  not the problem at personal-corpus scale.

The thing that has to be designed carefully is **memory**, not compute.

## 2. Measured baseline

Measured on the development host (AMD Ryzen 3 3200U, 2 cores/4 threads, 9 GB RAM), top-1 over
100,000 vectors of 1,536 dimensions:

| Encoding | Memory | Latency per query |
|---|---|---|
| float32 | 614 MB | 51.4 ms (6.0 GFLOP/s) |
| int8 scalar | 154 MB | 18.4 ms |

Extrapolated linearly (this scan is **memory-bandwidth-bound**, not ALU-bound): 1M vectors is
6.1 GB / 514 ms for float32, or 1.5 GB / 184 ms for int8. The float32 scan moves 614 MB per query
in 51 ms — about 12 GB/s, which is laptop DRAM bandwidth, not dot-product throughput. That is why
int8 is ~2.8× faster as well as 4× smaller, and why layout and quantisation matter more than the
kernel. It also sets the boundary: **flat search is the right first implementation up to roughly
100k–250k chunks; beyond that, or below a 10 ms p99, an approximate index is required.**

HNSW reduces the bytes touched per query, not the resident footprint: the vectors still have to be
in memory (or disk-backed). Memory reduction needs product quantization (PQ/OPQ), which trades
recall.

## 3. Storage format

Recommended document shape:

```json
{
  "_id": "note-123#chunk-4",
  "parent_id": "note-123",
  "chunk_index": 4,
  "text": "…",
  "embedding_b64": "…",          // float32 little-endian, base64
  "embedding_dim": 1536,
  "embedding_model": "text-embedding-3-small",
  "embedding_metric": "cosine"
}
```

- **base64 float32** rather than a JSON array: 1,536 floats as JSON numbers are roughly 12–20 KB
  and lose exactness through decimal formatting; base64 is 8,192 characters and exact. The indexer
  accepts a JSON array too, for small vectors and hand-written documents.
- Vectors are normalised at index time for cosine; the stored bytes stay as the producer wrote them.
- Chunking is an application concern. One vector per chunk document is simpler than multi-vector
  documents and matches how RAG pipelines already work; `parent_id` lets the caller regroup hits.
- The index configuration lives in `_design/vector` (a design doc, so it replicates):

```json
{"_id":"_design/vector",
 "vector_index":{"field":"embedding_b64","dim":1536,"metric":"cosine",
                 "encoding":"int8","rescore":true,"engine":"flat"}}
```

## 4. Index design

**Flat int8, rescored (default).**
- In-memory array of int8 vectors, one scale per vector (max-abs), plus a doc-id/rev table.
- Query: quantise the query to int8, SIMD dot product over all vectors, take the top `4×k`
  candidates, decode their float32 vectors from the document and rescore exactly, return top `k`.
- Memory: 1.5 KB/vector at 1,536 dims (154 MB per 100k), plus ~24 B/vector of metadata.
- Deletes: tombstone slot; compaction rebuilds the array without holes.
- Build: stream `_changes`, decode, quantise, append. Persist as an immutable index segment with
  `{indexed_seq, count, dim, metric, encoding, scales[], vectors[]}`; on crash, resume from
  `indexed_seq`.

**HNSW graph (`engine: "hnsw"`).** The graph engine, persistence, incremental append and recall gate are implemented; the incremental
`_changes` indexer and larger-collection tuning are not.
- Trigger: p99 above 25 ms, or more than ~250k vectors.
- Parameters: M=16, efConstruction=200, efSearch=64–128; deterministic seed and tie-breaking so the
  graph is reproducible in tests.
- Persist the graph alongside the vectors; rebuild on incompatible parameter changes.
- Expected: 1–5 ms at 100k–1M, at the cost of ~13 MB of graph per 100k vectors (~130 MB at 1M) and
  a multi-minute build.

**Memory reduction (future, if needed).**
- IVF-PQ or OPQ when the corpus exceeds the memory budget; recall is measured against exact search,
  never assumed.

## 5. Query API

```
POST /{db}/_vector_search
{
  "vector": [0.013, -0.22, ...],       // or "vector_b64": "..."
  "k": 10,
  "filter": {"type": "note"},           // Mango selector, optional
  "include_docs": true,
  "metric": "cosine",                   // default from the index
  "stale": "ok"                         // or "update" (default)
}
```

Response:

```json
{"took_ms": 18.4, "indexed_seq": "…", "hits": [
  {"id": "note-123#chunk-4", "score": 0.873, "doc": {…}}
]}
```

- Errors are CouchDB-shaped: 400 for a dimension mismatch or unknown metric, 404 for a missing
  index, 413 for a vector over the cap, 503 when the index is rebuilding.
- `filter` is evaluated after the vector scan with over-fetch (`k×4`, capped at 1,000); this is
  correct but not selective-aware. Pre-filtering by doc IDs is a later optimisation.
- `stale=ok` returns the current index snapshot; the default waits for the index to reach the
  database's current sequence, bounded by a timeout, then returns stale results with a flag.

## 6. Consistency and failure behaviour

- The index is a derived structure: the source of truth is always the document.
- A background indexer consumes `_changes` from `indexed_seq`, applies puts and deletes in order,
  and persists the new `indexed_seq` with the index segment (fsync before publishing).
- Crash: reopen the last index segment, replay `_changes` after `indexed_seq`. A corrupt index
  segment is discarded and rebuilt; it never blocks database recovery.
- Compaction of the document store does not move sequences, so the index cursor stays valid.
- Replication: a replicated document with an embedding is indexed by the normal `_changes` path.
- Deleting a document removes it from the index; tombstoned slots are compacted away.
- An index build never blocks writes; a search during a rebuild sees the previous immutable segment.

## 7. Memory budget

The vector index is an **add-on budget**, not part of the core 512 MiB:

| Corpus | int8 vectors | Metadata | Default budget |
|---|---|---|---|
| 10k × 1536 | 15 MB | <1 MB | fits |
| 100k × 1536 | 154 MB | 3 MB | fits |
| 250k × 1536 | 384 MB | 6 MB | raise to 512 MB |
| 1M × 1536 | 1.5 GB | 24 MB | PQ or disk-backed |

`vector_index_mb` defaults to 256 and is admission-controlled: once the index would exceed it, new
vectors are rejected with a clear error rather than silently degrading the whole database. The
index is reloaded lazily on first search, and can be dropped with `DELETE /{db}/_design/vector`
without touching documents.

## 8. Phases and effort

| Phase | Scope | Effort (part-time) |
|---|---|---|
| 8A | storage format, flat int8 index, rescore, `_vector_search`, filters, persistence, tests | 3–5 weeks |
| 8B | HNSW, deterministic build, recall/latency gates | 4–8 weeks |
| 8C | PQ/OPQ or disk-backed index for >500k vectors | 3–6 weeks |

8A is enough for a personal RAG corpus. 8B is a performance project, not a correctness one; do not
start it before 8A's recall and memory numbers are real.

## 9. Gates

- Recall@10 ≥ 0.95 against exact float32 search on a fixed 10k-vector corpus (int8 + rescore should
  be ~0.99; measure, do not claim).
- p99 ≤ 25 ms at 100k × 1536 on the reference host (8A); ≤ 5 ms at 1M (8B).
- Index freshness ≤ 1 s after a committed write under steady load; `indexed_seq` never goes
  backwards.
- Memory ≤ `vector_index_mb`; RSS gate raised by the configured budget, not silently.
- Kill during index build or compaction: reopen, resume from `indexed_seq`, no duplicates, no
  missing live vectors.
- Dimension mismatch, NaN/Inf, zero vectors and oversized vectors return 400/413, never a panic.

## 10. Risks

- **Memory is the real constraint**, not CPU; a 1M-vector corpus does not fit the default budget.
- **Quantisation recall** can be worse than expected on anisotropic embeddings; rescoring and a
  measured recall gate are mandatory.
- **Index drift** if `_changes` is filtered or the cursor is persisted before the segment is
  fsynced; publish the segment first, then the cursor.
- **HNSW complexity**: persistence, deletes and deterministic builds are where the bugs live; it is
  a later phase for a reason.
- **Security**: embeddings can leak document content; there is no encryption at rest in v1, and the
  same admin-token model applies.

## 11. Open questions

1. Default metric: cosine (normalise at index time) or dot product?
2. Vector encoding: base64 float32 (recommended) or JSON arrays for readability?
3. Chunking: one chunk per document (recommended) or multiple vectors per document?
4. Filters: post-filter with over-fetch (v1) or index-aware pre-filtering later?
5. When does HNSW ship — only after 8A's p99 gate fails, or alongside 8A behind a flag?
6. Is hybrid search (vector + Mango/keyword) in scope for v1.1, or a separate phase?

## 12. References

- HNSW: Malkov & Yashunin, "Efficient and robust approximate nearest neighbor search using
  Hierarchical Navigable Small World graphs" (arXiv:1603.09320).
- FAISS index trade-offs (flat, IVF, PQ, HNSW): https://github.com/facebookresearch/faiss/wiki
- CouchDB has no native vector search; this is deliberately an extension, not a compatibility claim.
