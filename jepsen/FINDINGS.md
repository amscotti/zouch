# Jepsen findings — 2026-11-05

These are the first multi-scenario results against Zouch v0.4.0 on a local
single-node test host (Zig `ReleaseSafe`, `localhost`, port 5985). The workload
is Jepsen's linearizable CAS register over independent documents; the checker
is Knossos. All runs ended with `Jepsen valid? true` and `:failures []`.

## Scenarios

| Suite | Faults applied | Completed ops | Indeterminate results | Notable observations |
|---|---|---:|---:|---|
| smoke | none | 4,000 | 0 | baseline |
| kill | 4 SIGKILL events, 3 complete restarts | 12,000 | 7,225 connection-refused plus 6 timeouts | recovery passed |
| pause | 4 SIGSTOP/SIGCONT cycles | 7,498 | 24 read timeouts | recovery passed |
| partition | 4 iptables drop/heal cycles | 5,784 | 71 connect timeouts | client isolation only |
| disk | 2 ENOSPC fills, frees and a kill/restart | ~9,500 | 1,527 refused, 724 write-507, 26 CAS-507 | storage errors now return 507 |
| replication | target kill/restart, target partition/heal, source kill/restart | 11,052 | 1,254 refused, 12 timeouts | all observed keys converged |

The `:info` results above are indeterminate, not model failures. They occur
because a request was in flight when the server was killed, paused, isolated or
out of space. The checker still found no linearizability violation.

## Fixed: ENOSPC now returns HTTP 507

Before the fix, a full data filesystem produced HTTP 500 responses and repeated
server log lines such as:

```text
warning: unhandled exception for /jepsen_zouch/177: error.Io
```

`App.uncaughtError` now recognizes `NoSpaceLeft`, `ReadOnlyFileSystem`,
`FileTooBig` and the poisoned-WAL `Io` error, returning HTTP **507 Insufficient
Storage** with:

```json
{"error":"insufficient_storage","reason":"database storage is full or unavailable"}
```

The server logs `storage error for ...` instead of an unhandled exception. The
disk Jepsen run now reports only `write-http-507` / `cas-http-507` for storage
failures and zero `unhandled exception` lines. The test/compat/diskfull.sh
regression asserts the 507 status and JSON body.

A write that fails while the WAL is poisoned still requires freeing space and
restarting the database before writes resume; this is now explicit in the
client response rather than a silent 500.

## Scope limits

- **Single node only.** Zouch has no cluster membership or leader election, so
  this does not test split-brain or multi-node durability.
- **Replication is eventual, not linearizable.** The replication scenario
  verifies that source and target converge on the same winning revision after
  the faults; it does not provide read-your-writes or cross-node linearizability.
  Transient replication errors during target failures and partitions are
  counted in the scenario output; the final source/target state converged.
- **Client-side partition only.** The iptables scenario blocks the client from
  the HTTP port; it does not test a server-side network partition.
- **No physical power loss in Jepsen.** The disk scenario uses a 64 MiB tmpfs and SIGKILL;
  it does not cut power or emulate torn sector writes. The separate FUSE
  `test/compat/powerloss.sh` harness covers repeated power-cut replay.
- **Replication topologies are bounded.** Push, target-initiated pull,
  continuous `_replicator` and a two-target fan-out are covered; arbitrary
  peer graphs and chained replication are not.
- **Workload shapes are bounded.** The CAS register checks per-document
  linearizability; the attachment suite checks byte durability. Views, Mango
  indexes, `_bulk_docs` and multi-document atomicity (which Zouch does not
  provide) are not Jepsen workloads.
- **Short runs.** Each scenario is bounded to 30 seconds and 12,000 operations;
  this is a fast gate, not a soak test.

## Reproduction

```bash
cd jepsen
./run-matrix.sh
```

Histories, checker output and logs are under `jepsen/store/` and
`jepsen/logs/` (both ignored by git). The matrix is expected to pass every scenario in `run-matrix.sh`
on the current host.
