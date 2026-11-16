# ADR 0007 — Conflicts stay application-level

**Status:** accepted · 2026-11-05

## Context

CouchDB does not silently merge concurrent edits. It stores every leaf revision, picks a
deterministic winner for normal reads, and exposes the losing leaves through `_conflicts` and
`open_revs`. Applications decide whether to merge, keep both, or delete a losing revision.

A storage engine can make conflict handling look simpler by automatically picking a value or
deleting losing leaves. That changes the data model, loses information, and makes Zouch behave
differently from the database it is meant to replace.

## Decision

Zouch follows CouchDB: conflicts belong to the application.

- Store every replicated and local leaf revision, including tombstones and their ancestry.
- Pick the CouchDB winner (highest generation, then lexicographically higher hash) for ordinary
  reads, but never delete or rewrite the losing leaves.
- Expose conflicts with `GET /{db}/{doc}?conflicts=true` and expose every leaf with
  `GET /{db}/{doc}?open_revs=all&revs=true`.
- Replication carries every leaf in both directions; a push is not complete if a conflict branch
  cannot be sent.
- Do not add an automatic conflict resolver, a conflict-resolution configuration, or a background
  job that removes losing revisions.
- Applications resolve conflicts by reading the conflict set and writing a new revision. `_purge`
  can remove a specific losing revision when the application has recorded that decision, but purge
  history is local to the node.

## Consequences

- Zouch preserves the same conflict semantics as CouchDB, including the information needed by
  PouchDB and application-level merge code.
- Conflict monitoring and resolution remain the application's responsibility. A migration or
  replication run can leave conflicts visible; that is expected, not data loss.
- There is no hidden merge policy to reason about, and no automatic deletion of a revision that a
  client may still depend on.
- The `_conflicts` field is part of the compatibility surface and must remain correct when
  replication imports leaves, when a local edit creates a branch, and after restart.
