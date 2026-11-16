#!/usr/bin/env bash
# CouchDB-backed integration gate. Requires a running CouchDB at $COUCH
# (default http://127.0.0.1:5984) with the default test credential.
# COUCH_URL=http://user:pass@host:5984 is accepted as an alternative, because
# docs/migration.md uses that spelling for the same endpoint.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${COUCH_URL:-}" ] && [ -z "${COUCH:-}" ]; then
  case "$COUCH_URL" in
    *://*@*)
      # Split embedded credentials: the suites want COUCH and AUTH separately.
      _creds=${COUCH_URL#*://}
      _creds=${_creds%%@*}
      : "${AUTH:=$_creds}"
      COUCH="$(python3 - "$COUCH_URL" <<'PY'
import sys, urllib.parse as u
p = u.urlparse(sys.argv[1])
port = p.port or 5984
print(f"{p.scheme}://{p.hostname}:{port}")
PY
)"
      export COUCH
      ;;
    *) COUCH="$COUCH_URL" ;;
  esac
fi
: "${COUCH:=http://127.0.0.1:5984}"
: "${AUTH:=admin:zouchtestpw}"
export COUCH AUTH

# Fail with instructions instead of letting the first suite die on a bare
# `curl: (7) Failed to connect` that mentions neither CouchDB nor the variable.
for _ in $(seq 1 10); do
  curl -fsS -m 1 "$COUCH/" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -fsS -m 1 "$COUCH/" >/dev/null 2>&1; then
  cat >&2 <<EOF
integration: no CouchDB answering at $COUCH

The replication suites need a CouchDB peer. Start one with:

  docker run -d --name zouch-couch -p 5984:5984 \\
    -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=zouchtestpw couchdb:3.5.3

or point at an existing server with COUCH=http://host:5984 AUTH=user:pass,
or with a single credentialed COUCH_URL=http://user:pass@host:5984.
EOF
  exit 1
fi

# Fresh couchdb:3.5.3 containers start without system databases until
# single-node setup runs; ensure _replicator, _users, and _global_changes
# exist so /_replicator and /_scheduler/docs behave as a configured node.
for sysdb in _replicator _users _global_changes; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT "$COUCH/$sysdb")
  if [ "$code" != "201" ] && [ "$code" != "412" ]; then
    echo "integration: failed to ensure $sysdb on $COUCH (HTTP $code)" >&2
    exit 1
  fi
done

for suite in \
  replicate_pull.sh \
  replicate_scheduler.sh \
  replicate_continuous.sh \
  replicate_retry.sh \
  replicate_push.sh \
  replicate_attachments.sh \
  replicate_knobs.sh \
  replicate_remote_checkpoint.sh \
  replicate_bulk_get.sh
do
  echo "== $suite =="
  "./test/compat/$suite"
done

# The interop matrix drives replication from both ends: Zouch calling
# POST /_replicate, and CouchDB holding the replication with Zouch as source or
# target. The shell suites above only cover the first.
echo "== replication_matrix.py =="
python3 test/interop/bulk_get_parity.py
python3 test/interop/find_parity.py
python3 test/interop/explain_parity.py
python3 test/interop/api_sweep.py
python3 test/interop/replication_matrix.py

echo "integration checks passed"
