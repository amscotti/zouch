# Zouch Benchmark Suite

Reproducible HTTP/storage benchmark suite for Zouch (and optionally CouchDB 3.5.3) using Python 3 standard library only.

## Usage

Build `ReleaseSafe` first so numbers reflect production performance:

```bash
zig build -Doptimize=ReleaseSafe
```

Run against an auto-started ephemeral Zouch instance (`small` scale, ~15–30s):

```bash
python3 bench/bench.py
```

Save a baseline and compare later changes against it:

```bash
python3 bench/bench.py --save bench/baseline.json
python3 bench/bench.py --baseline bench/baseline.json
```

Compare Zouch side-by-side against an ephemeral Docker `couchdb:3.5.3` container:

```bash
python3 bench/bench.py --docker-couch
```

Or point at running servers and/or use the larger `medium` scale:

```bash
python3 bench/bench.py --scale medium --threads 8 \
  --zouch-url http://127.0.0.1:5985 \
  --couch-url http://admin:zouchtestpw@127.0.0.1:5984
```

## Workloads

- `put_seq` / `put_conc`: sequential and 8-thread concurrent single-document `PUT`
- `get_seq` / `get_conc`: sequential and 8-thread concurrent single-document `GET`
- `bulk_docs`: `_bulk_docs` batches of 100 documents
- `all_docs`: `_all_docs?include_docs=true` full scan
- `changes`: `_changes` full feed read
- `mango_scan`: `_find` selector scan without an index
- `mango_index`: `_index` creation + indexed `_find` queries
- `view_cold` / `view_warm`: MapReduce `_design/bench/_view/by_cat` cold build and warm queries
- `replicate_local`: same-server `POST /_replicate`
- `replicate_from_couch` / `replicate_to_couch`: cross-server replication (when CouchDB is enabled)

## Metrics

Each workload reports `ops`, `total_ms`, `ops_per_sec`, `docs_per_sec` (where applicable), `p50_ms`, `p95_ms`, and `p99_ms`.
