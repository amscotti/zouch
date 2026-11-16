# Zouch storage format

Current implementation: **WAL + immutable segments + double-buffered manifest**, with an optional
snapshot for normal shutdown. `_compact` rewrites a single segment without writing a snapshot. This
document describes what the code does today.

## Directory layout

```
data/<db>/
├── .zouch.lock         # exclusive lock held by the open database
├── MANIFEST_A          # generation N
├── MANIFEST_B          # generation N-1
├── wal.log
├── locals.log          # _local checkpoints
├── segments            # ZSEGS001 manifest
├── segment-000001.bin
├── blobs/<md5-hex>.bin
├── views/<hash>.idx
├── indexes/<hash>.idx
├── vectors.idx         # flat int8 vector index
├── hnsw.idx            # optional HNSW graph
├── text.idx            # $text inverted index
├── revs_limit          # 4-byte little-endian integer
├── purge_seq           # 8-byte little-endian integer
├── security.json       # _security object
└── snapshot-000001.bin  # optional; present after a normal shutdown, absent after _compact
```

All integers are little-endian.

## WAL

```
header:  len:u32 | crc32c:u32 | seq:u64
payload: encoded document (see below)
```

- `len` is the payload length; `crc32c` covers the payload (CRC-32/ISCSI).
- Each append is one `writePositionalAll` at the current end, followed by `fsync`.
- A record is acknowledged only after the fsync returns.
- Replay stops at the first short, corrupted or CRC-mismatched record; the WAL is truncated to the
  last good offset. A trailing partial record is therefore safe.

## Document record

```
id_len:u32 | id | seq:u64 | leaf_count:u32
  per leaf:
    gen:u32 | hash[32] | deleted:u8 |
    body_len:u32 | body |
    ancestry_count:u32 | (gen:u32 | hash[32])*
```

The body is the JSON object as submitted, including any `_rev`/`_revisions` fields; the HTTP layer
overrides metadata on output. Ancestry is leaf-first.

## Snapshot

```
magic "ZSNP0001" | generation:u64 | last_seq:u64 | count:u32
per document:
  len:u32 | crc32c:u32 | payload
```

A snapshot is written to `snapshot-<gen>.tmp`, fsynced, renamed to `snapshot-<gen>.bin`, and only
then referenced by a manifest. Normal shutdowns write a snapshot and clear segments. `_compact`
does not write a snapshot; it writes one full segment and removes both snapshot candidates.

## Manifest

```
magic "ZMAN0001" | generation:u64 | last_seq:u64 | crc32c:u32
```

`MANIFEST_A` is written for odd generations, `MANIFEST_B` for even ones; the other file retains the
previous generation. Recovery reads both, validates magic and CRC, and chooses the highest
generation whose snapshot file exists. If neither candidate has a readable snapshot (the normal
state after `_compact`), it loads the segment manifest and replays the WAL.

## Recovery

1. Read both manifests; pick the highest valid generation. A read error other than `FileNotFound`
   aborts the open (it is not treated as "no manifest").
2. If that generation's snapshot exists, load it and set `seq = last_seq`. A missing snapshot may
   fall back to the other manifest's snapshot; a corrupt or unreadable one aborts the open.
3. Load every segment listed in the `segments` manifest, applying records newer than the current
   sequence. A missing segment file is skipped; any other read error aborts the open.
4. Replay WAL records newer than the current sequence; track the largest replayed sequence.
5. Truncate the WAL at the last good record boundary.
6. `seq` is the highest sequence applied from snapshot, segments or WAL.

A data directory with a manifest but neither a loadable snapshot nor any segment is reported as
corrupt rather than opened empty, so an interrupted delete or a bad backup cannot silently look
like an empty database.

## Local documents (checkpoints)

`_local` documents live in `locals.log`, separate from `wal.log`:

```
len:u32 | crc32c:u32 | payload
payload: id_len:u32 | rev:u32 | flags:u8 | body_len:u32 | id | body
```

`flags` bit 0 marks a delete tombstone. Each write is fsynced. Replay stops at the first short or
corrupt record, and the file is truncated to the last good record. `_local` documents are not
included in snapshots or `_changes`; they are replayed from this file on open.

## Revision limit

`revs_limit` is a 4-byte little-endian integer written atomically beside the manifests. It is read
on open; the default is 1000.

## Segments

When the WAL exceeds 64 MiB, Zouch flushes every document whose sequence is newer than the last
flushed sequence into a `segment-NNNNNN.bin` file:

```
magic "ZSEG0001" 8
count u32
records: len u32 | crc32c u32 | encoded document
```

The segment is written first, then the `segments` manifest is atomically replaced, and only then is
the WAL truncated. On open, Zouch loads the snapshot, then each segment in manifest order, then the
WAL. Documents are applied only if their sequence is newer than the currently loaded sequence.
After eight segments accumulate, Zouch merges them into one segment containing the current documents
at or below the segment sequence, then atomically rewrites the manifest and deletes the old files.
`_compact` writes one segment containing every current document, replaces the segment manifest,
deletes both snapshot candidates, writes a new manifest and truncates the WAL. A compacted database
therefore has a `segments` file and a segment but no snapshot; `zouch check` and a restart handle
that state. Compaction also removes attachment blobs not referenced by any leaf revision.

## View cache

Views are materialized into `views/<hash>.idx`:

```json
{"db_seq": 12, "ddoc_rev": "2-…", "rows": [{"id": "a", "key": "fruit", "value": 2}]}
```

The index is lazy: the first query runs the JS map over every document and writes the file. Later
queries reuse it when the design-document revision matches and `db_seq` is not ahead of the
database. Documents with a sequence greater than `db_seq` are re-mapped: rows for that document are
removed, then the current version is mapped again. Deletes remove their rows. A design-document
change rebuilds the whole index.

## Snapshot / checkpoint order

1. Encode every document into a new snapshot buffer.
2. Write the temp file, fsync it, rename to `snapshot-<gen>.bin`.
3. Write the inactive manifest, fsync it, rename.
4. Truncate `wal.log` to zero and fsync.
5. Delete the previous snapshot.

A crash before step 3 leaves the old manifest valid and the old snapshot present; the new snapshot
is orphaned. A crash after step 3 but before step 4 is harmless: replay skips records at or below
`last_seq`.

## Known gaps

- There is no format-version field and no migration tool: a newer binary must read the layout
  written by the old one. Check this document and the release notes before replacing a binary.
- Snapshots copy the whole database; `_compact` is the only way to rewrite segments, and it holds
  the database lock for the duration.
- `locals.log` is not compacted; it grows with checkpoint writes.
- `revs_limit` and `purge_seq` fall back to their defaults if the file cannot be read. They are
  metadata only; document, manifest and segment reads fail closed.
- No encryption at rest.
