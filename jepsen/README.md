# Zouch Jepsen tests

This is a fault-injection suite for Zouch. It uses Jepsen's linearizable
CAS-register workload: independent documents are read, written and
compare-and-set concurrently, and Knossos checks the recorded history. The
replication scenario adds a second Zouch node and a convergence checker.

The scenarios are deliberately small enough to run on a laptop. They are meant
to surface durability, availability and recovery problems before a release,
not to certify a production cluster.

## Requirements

- Java 21 and Leiningen;
- a running SSH server for `localhost` (Jepsen uses SSH even for one node);
- an RSA key at `~/.ssh/jepsen_rsa` authorized for `ubuntu`;
- passwordless `sudo` for the partition and disk scenarios;
- `iptables`, `fallocate`, `mount`, `curl`, `start-stop-daemon`.

Create the test key if needed:

```bash
ssh-keygen -t rsa -b 3072 -m PEM -f ~/.ssh/jepsen_rsa -N ''
cat ~/.ssh/jepsen_rsa.pub >> ~/.ssh/authorized_keys
```

If your username is not `ubuntu`, update `:username` and `:private-key-path` in
`src/zouch/jepsen.clj`.

## Run

```bash
cd jepsen
lein run smoke       # no faults
lein run kill        # repeated SIGKILL and restart
lein run pause       # repeated SIGSTOP and SIGCONT
lein run partition   # block and restore the Zouch HTTP port
lein run disk        # fill a 64 MiB tmpfs, free it, then crash/restart
lein run replication # two Zouch nodes, push replication and source/target faults
lein run attachments # attachment writes, raw reads and inline reads under all local faults
lein run pull        # target-initiated pull replication under faults
lein run continuous  # _replicator continuous replication under faults
lein run multipeer   # one source pushing to two targets under faults
```

Or run every scenario sequentially:

```bash
./run-matrix.sh
```

The first run downloads Clojure and Jepsen from Maven/Clojars. Each scenario
creates and removes `jepsen_zouch`; histories and checker output are written
under `store/` and are ignored by git.

`JEPSEN_PORT` changes the source/server port (default 5985); the replication
target uses `JEPSEN_TARGET_PORT` (default 5991), and a second target peer uses
`JEPSEN_TARGET2_PORT` (default 5992). `SUITES` limits the matrix, for example
`SUITES="kill pause" ./run-matrix.sh`.

## What each scenario exercises

- **smoke** — establishes the client, generator and checker with no faults.
- **kill** — the nemesis sends `SIGKILL` and restarts Zouch every few seconds.
  This exercises WAL replay, segment recovery and acknowledged-write durability.
- **pause** — pauses the server process with `SIGSTOP` for two seconds, then
  resumes it. This approximates a long stop-the-world pause and exercises
  client timeouts and post-resume behavior.
- **partition** — drops traffic to and from port 5985 with `iptables`, then
  removes the rules. Because Zouch is single-node, this tests client
  availability and recovery, not split-brain behavior.
- **disk** — mounts a 64 MiB tmpfs for the data directory, fills it, frees it,
  then kills and restarts the server. This exercises ENOSPC handling and
  recovery on a constrained filesystem.
- **replication** — starts a source and an asynchronous push target, writes only
  to the source, and runs a convergence checker over the final source/target
  revisions. It kills and restarts the target, partitions its port, then kills
  and restarts the source. This tests retry and eventual convergence, not
  cross-node linearizability.
- **attachments** — writes documents whose `_attachments.blob` is a
  deterministic byte string (0 B to 2 KiB, including non-UTF-8 data), then reads
  the raw attachment endpoint and the `?attachments=true` representation back
  and compares bytes and content type. The same 4,000-id cycle is rewritten
  through normal `_rev` CAS. The fault schedule covers all four local classes in
  one run: SIGSTOP/SIGCONT, iptables partition/heal, SIGKILL/restart, and
  tmpfs fill/free. A final-state checker re-reads every acknowledged write and
  fails on missing data or any byte/content-type mismatch; indeterminate
  (`:info`) writes are excluded, as required.
- **pull** — the target initiates `/_replicate` against the source, with the
  source paused/partitioned/killed and the target killed/restarted. The checker
  verifies source/target revision and value convergence.
- **continuous** — creates `_replicator` jobs with `continuous:true` and leaves
  retries to the server scheduler while the source and target are faulted.
- **multipeer** — one source pushes to two independent targets, including a
  target kill and source faults, and checks each peer converges independently.

## Interpreting a result

A green run ends with `Everything looks good!` and `Jepsen valid? true`; its
history should contain the requested nemesis operations. `:info` operations are
indeterminate results caused by a fault, not model failures. A non-green run
needs the history and server log investigated; do not treat it as flaky without
first checking that the fault was actually applied.

The checker validates per-document linearizability on the source and, for the
replication scenarios, eventual convergence. It does not validate multi-document
transactions (Zouch does not provide them), view/index consistency, or physical
power-loss behavior. The attachment suite covers byte-exact attachment
durability, including zero-length attachments. Pull, continuous `_replicator`
and multi-peer suites have clean recorded runs; they still do not provide
cross-node linearizability.
