# ADR 0004 — Revision trees and the CouchDB winner rule

**Status:** accepted · 2026-10-31

## Context

Replication correctness depends on preserving every leaf revision and its ancestry, not just the
current body.

## Decision

Each document keeps its leaf revisions. A leaf stores `{rev, deleted, body, ancestry}`; the
ancestry is the `_revisions` chain as received. A local edit removes the parent leaf and appends a
child; an imported revision (`new_edits=false`) inserts the supplied leaf verbatim, including
ancestors Zouch has never seen. The winner is the highest generation, then the lexicographically
highest hash. Leaves and tombstones are never pruned except through `_revs_limit`, which prunes only
ancestor chains.

## Consequences

`_revisions`, `open_revs=all`, `_revs_diff` and conflict replication work. The revision hash for
local edits is MD5 of the body plus the parent revision; it is unique and stable, but not guaranteed
byte-identical to CouchDB's canonical hash.
