<p align="center">
  <img src="docs/logo.png" alt="Zouch" width="180">
</p>

# Zouch

**A single-binary, CouchDB-compatible document database written in Zig.**

Zouch pairs Apache CouchDB's HTTP API and bidirectional replication protocol with an embedded,
crash-safe storage engine — no Erlang VM, no cluster configuration, and no runtime dependencies.
Drop one binary on a host or container, point it at a data directory, and serve documents,
attachments, views, Mango queries, and vector search over HTTP.

## Why Zouch

- **CouchDB Tier-1 replication:** Bidirectional `pull` and `push` with Apache CouchDB 3.x
  (conflicts, tombstones, attachments, `_local` checkpoints, filters, and continuous `_replicator`
  jobs).
- **Rich querying out of the box:** QuickJS MapReduce views (with optional `libicui18n` root
  collation), Mango `_find` / `_index` (including `$text` full-text search and `$regex`), and
  built-in vector search (persisted int8 flat index and incremental HNSW graph).
- **Single-binary deployment:** Vendored dependencies (`httpz`, `quickjs`), bundled CouchDB Fauxton
  web UI at `/_utils/`, and a small memory footprint (~19 MB idle RSS, 8 worker-pool threads).
- **Crash-safe local storage:** Append-only WAL with CRC-32C checksums, immutable segments,
  double-buffered A/B manifests, and content-addressed attachment blobs.

Licence: Apache-2.0.

## Quick start

```bash
# 1. Zig 0.17.x (pinned)
curl -LO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
tar -xf zig-x86_64-linux-0.17.0.tar.xz
export PATH="$PWD/zig-x86_64-linux-0.17.0:$PATH"

# 2. Build (dependencies are vendored; no network, no submodules)
zig build -Doptimize=ReleaseSafe

# 3. Run (loopback only by default)
./zig-out/bin/zouch serve ./data 5985

# 4. Open http://127.0.0.1:5985/_utils/ for Fauxton, or use the HTTP API:
curl -X PUT http://127.0.0.1:5985/notes
curl -X PUT http://127.0.0.1:5985/notes/a \
     -H 'content-type: application/json' \
     -d '{"text":"hello","tags":["demo"]}'
curl 'http://127.0.0.1:5985/notes/a?revs=true'
```

## CLI & Configuration

```bash
./zig-out/bin/zouch serve [data-dir] [port] [bind-address]   # defaults: data 5985 127.0.0.1
./zig-out/bin/zouch pull <source-url> <database> [data-dir]  # one-shot pull from CouchDB/Zouch
./zig-out/bin/zouch push <target-url> <database> [data-dir]  # one-shot push to CouchDB/Zouch
./zig-out/bin/zouch check [data-dir]                         # verify manifests, segments, and WAL
./zig-out/bin/zouch --version
./zig-out/bin/zouch --help
```

> **Note:** A data directory allows one writer at a time (enforced via `.zouch.lock`). Stop the
> server before running CLI `pull` or `push`.

Zouch is configured solely through environment variables (no config file):

- `ZOUCH_AUTH=user:password` — Global Basic auth for every request. Without it, Zouch runs in
  CouchDB's *admin party* mode on loopback (`127.0.0.1`); always set credentials before binding
  `0.0.0.0`.
- `ZOUCH_AUTH_FILE=/path` — Per-database credentials (`db:user:password` lines).
- `ZOUCH_ROLES="alice:dev,ops;bob:ops"` — Static role mapping for `_security` enforcement.
- `ZOUCH_MAX_FEEDS=256` — Concurrent longpoll/continuous `_changes` feeds (max `4096`).
- `ZOUCH_AUTO_COMPACT_SECS=3600` — Background compaction interval in seconds (`0` disables).
- `ZOUCH_MAX_BODY_MB=64` — Maximum HTTP request body size in MiB (`413` when exceeded).
- `ZOUCH_MAX_DB_MB=0` — Per-database live memory budget in MiB (`0` = unlimited; `507` when exceeded).
- `ZOUCH_VECTOR_INDEX_MB=0` — Vector index memory budget in MiB (`0` = unlimited; `507` when exceeded).
- `ZOUCH_WWW=/path/to/fauxton` — Serve an external Fauxton build at `/_utils/` instead of the
  embedded CouchDB 3.5.3 build.

## Prerequisites

- **Zig 0.17.x** (pinned in `build.zig.zon`; CI uses `0.17.0`).
- **`libicui18n`** (`libicu-dev` / `libicu72` on Debian/Ubuntu) loaded at runtime for CouchDB-compatible
  ICU view string collation. Without it, Zouch falls back to byte-order collation and logs a
  startup warning.
- **`curl`, `python3`, and `jq`** for the compatibility test scripts.
- **Docker** (or an existing CouchDB instance) only for CouchDB-backed integration tests and
  side-by-side benchmarks.

## Core Capabilities

- **Documents & Revisions:** `GET`/`PUT`/`DELETE`, `_rev`, `?rev=`, `?revs=true`, `?conflicts=true`,
  `?open_revs=all`, `_revs_info`, `_purge`, `_bulk_docs`, `_bulk_get`, `_revs_diff`, `_missing_revs`,
  and durable `_local` checkpoints. Conflicts are preserved application-level using CouchDB's winner
  rule.
- **Attachments:** Inline base64, raw `GET`/`PUT`/`DELETE`, stubs, `?attachments=true`, and
  `multipart/related`, stored in content-addressed `blobs/<md5-hex>.bin`.
- **Replication & Feeds:** `POST /_replicate`, `_replicator` (one-shot and continuous polling with
  exponential backoff retry, filters, `doc_ids`, `selector`), and `_changes` (`normal`, `longpoll`,
  `continuous`, `eventsource` sharing a single scheduler thread).
- **Views & Mango:** QuickJS `map`/`reduce` (`_count`, `_sum`, `_stats`, custom JS), `validate_doc_update`,
  `_view_cleanup`, and Mango `_find`/`_index`/`_explain` (`$regex`, `$text`, composite `use_index`,
  bookmarks, `execution_stats`).
- **Vector Search:** `POST /{db}/_vector_search` with int8 flat scan + float32 rescoring or
  persisted incremental HNSW graph (`engine: "hnsw"`).
- **Auth & UI:** `_users` PBKDF2 password hashing and roles, `_security` admins/members enforcement,
  `POST /_session` cookie auth, `GET /_active_tasks`, `GET /_up`, and bundled Fauxton at `/_utils/`.

See [`docs/compatibility.md`](docs/compatibility.md) for the full endpoint matrix and known
differences from CouchDB.

## Benchmarking

Zouch includes a zero-dependency Python 3 benchmark suite in [`bench/README.md`](bench/README.md):

```bash
python3 bench/bench.py                                   # ephemeral Zouch (small scale)
python3 bench/bench.py --docker-couch                    # side-by-side vs CouchDB 3.5.3
python3 bench/bench.py --save bench/baseline.json        # save baseline
python3 bench/bench.py --baseline bench/baseline.json    # compare against baseline
```

## Testing

```bash
./scripts/ci.sh                # formatting, ReleaseSafe build, unit tests, shell syntax, compat suite
./scripts/integration.sh       # CouchDB-backed replication & Python interop suites (needs CouchDB/Docker)

zig build test                 # unit tests only
zig build test -Dtest-filter=rev
```

Individual compatibility scripts under `test/compat/` are cataloged in
[`test/README.md`](test/README.md). Optional PouchDB client verification:

```bash
(cd test/compat/pouchdb && npm install --silent && node test.js)
```

## Deployment & Operations

```bash
# Docker: non-root, read-only rootfs, data volume
ZOUCH_AUTH="user:password" docker compose up --build -d
curl http://127.0.0.1:5985/_up
```

- [`docs/deployment.md`](docs/deployment.md) — systemd (`packaging/zouch.service`), Caddy TLS
  termination (`packaging/Caddyfile`), and security limits.
- [`docs/operations.md`](docs/operations.md) — backups, recovery, and handling `zouch check` failures.
- [`docs/migration.md`](docs/migration.md) — migrating data from CouchDB.

## Architecture

```
src/
├── main.zig              CLI: serve, pull, push, check
├── replicator.zig        one-shot pull/push primitives shared by CLI and HTTP
├── doc/                  revisions, ancestry, winner rule
├── store/                WAL, segments, manifests, recovery, blob store
├── http/                 httpz adapter, JSON writer, handlers, scheduler
├── views/                QuickJS binding, Mango, HNSW graph, ICU collation
└── util/                 CRC-32C
```

- **I/O & Concurrency:** Platform I/O goes through Zig's `std.Io` interface. The HTTP layer uses
  an 8 × 1 MiB buffer pool and 8 worker-pool threads; database mutations serialize per database while
  reads see immutable snapshots.
- **Storage Engine:** Append-only WAL records with CRC-32C and fsync-before-ack; WAL overflow
  flushes changed documents to immutable segments, eight segments merge automatically, and `_compact`
  rewrites a single segment.

Further design docs: [`docs/storage-format.md`](docs/storage-format.md),
[`docs/memory-design.md`](docs/memory-design.md), and [`docs/adr/`](docs/adr/).

## Scope & Limits

- Single-node by design (no clustering).
- Native TLS and HTTP/2/HTTP/3 are not built in — terminate TLS with a reverse proxy such as Caddy.
