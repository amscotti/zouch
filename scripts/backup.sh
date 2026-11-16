#!/usr/bin/env bash
# Take a stopped-server backup of one Zouch data directory and verify the archive.
set -euo pipefail
DATA=${1:-/var/lib/zouch}
DEST=${2:-/var/backups}
BIN=${ZOUCH_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zouch}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="zouch-$(basename "$DATA")-$STAMP.tar.gz"

[ -d "$DATA" ] || { echo "no such data directory: $DATA" >&2; exit 1; }
mkdir -p "$DEST"

# Refuse to back up a database that fails its own recovery check.
"$BIN" check "$DATA" >/dev/null

tar -C "$(dirname "$DATA")" -czf "$DEST/$NAME" "$(basename "$DATA")"
tar -tzf "$DEST/$NAME" >/dev/null
sha256sum "$DEST/$NAME" >"$DEST/$NAME.sha256"
echo "$DEST/$NAME"
