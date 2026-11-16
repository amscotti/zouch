# Deployment

Zouch listens on loopback by default. Put Caddy in front for TLS and HTTP/2, and run it under
systemd so it restarts after a crash.

## Install

```bash
zig build -Doptimize=ReleaseSafe
sudo install -m 0755 zig-out/bin/zouch /usr/local/bin/zouch
sudo useradd --system --home /var/lib/zouch --shell /usr/sbin/nologin zouch
sudo install -d -o zouch -g zouch /var/lib/zouch
sudo install -m 0644 packaging/zouch.service /etc/systemd/system/zouch.service
sudo systemctl daemon-reload
sudo systemctl enable --now zouch
curl http://127.0.0.1:5985/_up
```

## Authentication

Set a single admin credential in `/etc/zouch.env`:

```bash
ZOUCH_AUTH=user:password
# or, per database:
# ZOUCH_AUTH_FILE=/etc/zouch/auth
# ZOUCH_MAX_FEEDS=256
# ZOUCH_ROLES=alice:dev,ops;bob:ops
sudo chmod 0600 /etc/zouch.env
sudo systemctl restart zouch
```

With `ZOUCH_AUTH`, every request needs HTTP Basic auth. The credential is stored in plain text in
the environment file, so use a strong password and terminate TLS at Caddy. Without it, Zouch is
unauthenticated. `ZOUCH_MAX_FEEDS` sets the detached longpoll/continuous worker cap (default 256,
clamped to 4096). For per-database credentials, put lines of `database:user:password` in a file
readable only by the service user and
set `ZOUCH_AUTH_FILE`; a database with an entry requires that credential, while databases without
one fall back to the global credential (or no auth). `POST /_session` with `name` and `password`
returns an in-memory `AuthSession` cookie scoped to the credential that matched; sessions are lost on
restart. CouchDB/PouchDB replication can use
`https://user:password@zouch.example.com/db`.

## Caddy

```bash
sudo install -m 0644 packaging/Caddyfile /etc/caddy/Caddyfile   # edit the hostname
sudo systemctl reload caddy
```

Caddy terminates TLS and forwards HTTP/1.1 to Zouch. CouchDB and PouchDB replication clients can
use `https://zouch.example.com/db`.

## Backups

The database is a directory per database under `/var/lib/zouch`:

```
wal.log
MANIFEST_A
MANIFEST_B
snapshot-*.bin
```

For a consistent copy, stop Zouch and run `scripts/backup.sh`; it verifies recovery first and writes
a SHA-256 sidecar. See `docs/operations.md` for restore, compaction and upgrade steps. A copy of a
running directory is only crash-consistent if the WAL is included.

Do not copy only `snapshot-*` or only a manifest: recovery needs the manifest that references the
snapshot and the WAL that follows it.

## Limits and caveats

- The server binds `127.0.0.1` unless a bind address is passed explicitly
  (`zouch serve /var/lib/zouch 5985 0.0.0.0`); keep the default and put Caddy or an SSH tunnel in
  front.
- The HTTP server preallocates eight 1 MiB body buffers and four worker-pool threads, not 16 × the
  64 MiB maximum body size. A fresh process idles around 19 MB RSS; large bodies allocate dynamically.
- Authentication supports a global credential (`ZOUCH_AUTH`) or a `database:user:password` file
  (`ZOUCH_AUTH_FILE`). Passwords are stored as plain text in that file, so mode `0600` is required.
  Do not expose port 5985 directly to the internet.
- The store snapshots the whole database at 64 MiB of WAL; large databases will see a pause. See
  `docs/operations.md` for backup, restore and compaction procedures.
- `_local` replication checkpoints are durable in `locals.log` and survive a restart.
