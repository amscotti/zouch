#!/usr/bin/env bash
# Local/CI quality gate: formatting, ReleaseSafe build, unit tests, shell syntax,
# and the local HTTP compatibility smoke test.
set -euo pipefail
cd "$(dirname "$0")/.."

# The version is declared twice: build.zig.zon (package metadata) and
# src/version.zig (what GET / and `zouch --version` report). Catch drift here
# rather than after a release.
zon_version=$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",$/\1/p' build.zig.zon)
code_version=$(sed -n 's/^pub const string = "\(.*\)";$/\1/p' src/version.zig)
if [ -z "$zon_version" ] || [ "$zon_version" != "$code_version" ]; then
  echo "version mismatch: build.zig.zon='$zon_version' src/version.zig='$code_version'" >&2
  exit 1
fi

zig fmt --check build.zig src
python3 scripts/test_index.py --check
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe --summary all

for script in scripts/*.sh test/compat/*.sh; do
  bash -n "$script"
done

DATA=$(mktemp -d "${TMPDIR:-/tmp}/zouch-ci.XXXXXX")
LOG="$DATA/server.log"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT

./zig-out/bin/zouch serve "$DATA" 5985 >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do
  if curl -fsS http://127.0.0.1:5985/_up >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! curl -fsS http://127.0.0.1:5985/_up >/dev/null 2>&1; then
  echo "zouch did not become ready" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

./test/compat/http.sh
./test/compat/conflict_app.sh
./test/compat/bulk_multipart.sh
./test/compat/pull_concurrency.sh
./test/compat/replicate_local.sh
./test/compat/session_persistence.sh
./test/compat/auth.sh
./test/compat/fauxton_support.sh
./test/compat/revs_info.sh
./test/compat/replicate_resilience.sh
./test/compat/attachment_memory.sh
./test/compat/security.sh
./test/compat/validate.sh
./test/compat/compact.sh
./test/compat/blob.sh
./test/compat/bulk.sh
./test/compat/mango.sh
./test/compat/vector_hnsw.sh
./test/compat/security_enforce.sh
./test/compat/security_roles.sh
./test/compat/users.sh
./test/compat/feeds.sh
./test/compat/feeds_continuous.sh
./test/compat/auto_compact.sh
./test/compat/crash.sh
./test/compat/crash_requests.sh
echo "CI checks passed"
