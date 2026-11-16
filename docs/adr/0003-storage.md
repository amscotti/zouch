# ADR 0003 — WAL + snapshot + double-buffered manifest

**Status:** accepted · 2026-10-31 (simplified implementation)

## Context

The plan calls for WAL + immutable sorted segments + compaction. A correct durability substrate is
needed before segmentation is worth building.

## Decision

Implement the durability layer first: an append-only WAL with CRC-32C per record, a full-database
snapshot, and two manifests (`MANIFEST_A`, `MANIFEST_B`) with generation numbers. Recovery picks the
highest valid generation whose snapshot exists, then replays WAL records after `last_seq`. The WAL
is truncated only after the snapshot and manifest are fsynced.

Segments and compaction replace the whole-database snapshot. The WAL record format and
manifest generation scheme stay.

## Consequences

The current store rewrites the whole database on snapshot; it is correct but not yet scalable. The
crash ordering is: snapshot temp → fsync → rename → manifest temp → fsync → rename → truncate WAL.

> Update 2026-11-05: atomic renames in `writeAtomic` and streamed blob uploads now fsync the
> containing directory after the rename. `test/compat/dirsync.sh` checks the syscall sequence with
> `strace`.

> Update 2026-11-08: Segment flushing landed. The store now flushes the WAL into immutable
> `segment-NNNNNN.bin` files, merges them after eight, and `_compact` rewrites every current
> document into one segment, removes both snapshot candidates and truncates the WAL. Normal
> shutdown still writes a full snapshot, so the "whole database rewrite on snapshot" consequence
> above now applies only to shutdown and `_compact` remains the recovery path for a compacted
> database. See `docs/storage-format.md`.
