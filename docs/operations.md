# Operations

How to run, back up, restore, compact and upgrade a single Zouch node.

## Health and logs

```bash
curl -fsS http://127.0.0.1:5985/_up
zouch check /var/lib/zouch        # recover every database and print ok
journalctl -u zouch -f
```

`zouch check` opens each database, replays the snapshot, segments and WAL, and exits non-zero if a
database cannot be recovered; a failure prints the database name and its directory. A database held
open by a running server is reported as `skipped` and does not fail the check, so stop the service
to check every database. It is safe to run against a stopped server and is also a useful
pre-backup gate. `GET /_active_tasks` is currently a stub that returns an empty list; use the
server log and `test/compat/` probes for visibility into feeds and compaction.

## Backups

Stop the service, then use the backup script. It runs `zouch check` first, archives the whole data
directory (manifests, snapshots, segments, WAL and local checkpoints), verifies the archive can be
listed, and writes a SHA-256 sidecar:

```bash
sudo systemctl stop zouch
sudo scripts/backup.sh /var/lib/zouch /var/backups
sudo systemctl start zouch
```

A running server may have dirty pages and an in-flight WAL append, so do not treat a hot copy as a
consistent backup. If a stop is unacceptable, replicate the database to a second node or take a
filesystem snapshot that includes the entire directory and its WAL.

Do not copy only `snapshot-*` or one manifest. Recovery needs the manifest that references the
snapshot and the WAL/segments that follow it.

## Restore

```bash
sudo systemctl stop zouch
sudo mv /var/lib/zouch /var/lib/zouch.bad
sudo mkdir -p /var/lib
sudo tar -xzf /var/backups/zouch-zouch-data-YYYYMMDDTHHMMSSZ.tar.gz -C /var/lib
sudo chown -R zouch:zouch /var/lib/zouch
zouch check /var/lib/zouch
sudo systemctl start zouch
```

Keep the previous directory until the restored node answers `_up` and a known document reads back.
The database directory names are the database names; a restore cannot merge two nodes' copies of the
same database.

## Compaction

```bash
curl -X POST http://127.0.0.1:5985/notes/_compact
```

Compaction writes one segment containing every current document, fsyncs it, atomically replaces the
segment manifest, deletes old segments and both snapshot candidates, writes a new manifest and
truncates the WAL. It preserves every live document, every leaf revision, attachments and views. It
is synchronous: the request returns `202` after the rewrite, and the server holds the database lock
for the duration. A background scheduler compacts a changed database every hour by default; set
`ZOUCH_AUTO_COMPACT_SECS` to tune the interval or `0` to disable it.

Disk use before compaction is roughly the current snapshot plus all segments plus the WAL. Check
free space for at least one more copy of the database. Blob payloads are not part of the segment; compaction removes
blobs that no leaf revision references.

## Authentication and rotation

Credentials are read at process start from `ZOUCH_AUTH` or `ZOUCH_AUTH_FILE` (`database:user:password`
lines, mode `0600`). `_security` objects can be stored with `PUT /{db}/_security`; when auth is configured,
`members.names`, `admins.names`, `members.roles` and `admins.roles` are enforced. Roles come from
`_users` user documents, or from `ZOUCH_ROLES` (`alice:dev,ops;bob:ops`) when a static credential is
in use. To rotate:

1. Write the new file to a temporary path with mode `0600`.
2. Atomically rename it over the configured path.
3. Restart Zouch.

In-memory cookie sessions are lost at restart; clients must log in again. CouchDB/PouchDB
replication should use Basic auth in the source/target URL, not a browser cookie.

## Upgrade

```bash
zig build -Doptimize=ReleaseSafe
sudo systemctl stop zouch
sudo install -m 0755 zig-out/bin/zouch /usr/local/bin/zouch
sudo systemctl start zouch
curl -fsS http://127.0.0.1:5985/_up
zouch check /var/lib/zouch
```

Take a backup before upgrading. Zouch's on-disk format currently has no migration tool: a newer
binary must read the format written by the old one. Check `docs/storage-format.md` and release notes
before replacing a binary that wrote a newer format.

## Capacity and failure behaviour

- The WAL is capped at 64 MiB per database; crossing the cap flushes a segment and may merge eight
  segments into one.
- `_bulk_docs` writes all WAL records and fsyncs once before replying. A failed fsync returns a JSON
  error and the batch must not be treated as durable.
- The HTTP server uses four worker threads and eight 1 MiB body buffers; expect about 19 MB idle RSS.
  Documents larger than the buffer pool allocate dynamically, up to the 64 MiB body cap.
- `_local` replication checkpoints are durable in `locals.log`; a restart does not force a full
  rescan.
- `test/compat/diskfull.sh` fills a small tmpfs and remounts it read-only; requests fail with JSON,
  the process survives and `zouch check` still recovers the database.
- `test/compat/soak.sh` exercises writes, reads, a MapReduce view, Mango and optional CouchDB
  replication while sampling RSS; `SOAK_SECONDS=86400` is the release-gate duration.
- `test/compat/powerloss.sh` runs Zouch on a FUSE disk that only persists fsynced bytes: acknowledged
  writes survive a simulated cut, while an in-flight bulk write whose fsync never completed does not.
- Filtered `_changes` evaluates design-document filters for normal, longpoll and continuous feeds.
- Recovery fails closed. If a manifest, segment, `locals.log` or `security.json` cannot be read for
  a reason other than "absent" (for example a transient out-of-memory during `open`), the database
  refuses to open instead of serving a partial or unrestricted view. Retry once memory is available;
  do not delete files to force a start.
- Deleting a database (`DELETE /{db}`) closes its live feeds first and blocks new feeds for the
  duration of the delete. Expect an open `_changes` request to end with a `409`.
- There is no clustering, no cross-node quorum and no built-in TLS. Bind to loopback and terminate TLS
  at Caddy or nginx.

## Migration from CouchDB

See `docs/migration.md` for the one-shot replication runbook, verification queries and rollback.

## Corruption and partial recovery

`zouch check` reports the first database that cannot be recovered. Work on a copy, never on the only
data directory:

1. Stop Zouch and copy the entire directory, including `MANIFEST_*`, `snapshot-*.bin`, `segments`,
   `segment-*.bin`, `wal.log` and `locals.log`.
2. Run `zouch check` on the copy and record the failing database and the directory it prints.
3. A torn WAL **tail** is normal after a power cut: recovery ignores the incomplete record and keeps
   all complete records before it. A missing or corrupt segment, snapshot or manifest is not normal;
   restore the last verified backup rather than deleting files to make startup succeed.
4. If only one database is damaged, restore that directory from backup and leave the other databases
   in place. A database directory name is the database name.
5. Never delete `wal.log` to “reset” a database: it may be the only copy of acknowledged writes.

## Incident checklist

1. Stop writes or put the proxy in maintenance mode.
2. Preserve `journalctl -u zouch` output and the failing data directory.
3. Run `zouch check` against a copy, never the only copy.
4. Restore the last verified backup if recovery reports corruption.
5. Re-enable CouchDB/PouchDB replication only after `_up` and read checks pass.
