# ADR 0005 — No clustering

**Status:** accepted · 2026-10-31

## Context

CouchDB's cluster semantics (sharding, quorum, resharding, conflict resolution across nodes) are
the largest and least stable part of the system. The intended deployment is a personal single node.

## Decision

Zouch is single-node. `cluster` in database info is always `{q:1,n:1,w:1,r:1}`. There is no
membership, sharding, resharding or quorum code.

## Consequences

The storage engine can assume one writer and one copy of each database. Replication remains the
only way data moves between machines.
