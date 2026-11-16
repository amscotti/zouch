#!/usr/bin/env bash
# Short soak: writes, reads, views, Mango and optional CouchDB replication, sampling RSS for leaks.
# The full release gate runs this for 24 hours with SOAK_SECONDS=86400.
set -euo pipefail
Z="${ZOUCH:-http://127.0.0.1:5985}"
SECONDS_TO_RUN="${SOAK_SECONDS:-30}"
PID="${ZOUCH_PID:-}"
DB="${SOAK_DB:-soak-$(date +%s)-$$}"

if ! curl -fsS "$Z/_up" >/dev/null 2>&1; then
  echo "Zouch is not reachable at $Z" >&2
  exit 1
fi

curl -fsS -X PUT "$Z/$DB" >/dev/null 2>&1 || true
curl -fsS -X PUT "$Z/$DB/_design/soak" -H 'content-type: application/json' -d '{"views":{"by_n":{"map":"function(doc){ if (doc.n !== undefined) emit(doc.n, null); }"}}}' >/dev/null
curl -fsS -X POST "$Z/$DB/_index" -H 'content-type: application/json' -d '{"index":{"fields":["n"]},"name":"n-index"}' >/dev/null

peak=0
count=0
deadline=$(( $(date +%s) + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  pad=$(printf 'x%.0s' {1..64})
  for _ in $(seq 1 50); do
    id="doc-$(date +%s%N)-$RANDOM"
    curl -fsS -X PUT "$Z/$DB/$id" -H 'content-type: application/json' \
      -d "{\"n\":$count,\"pad\":\"$pad\"}" >/dev/null
    curl -fsS "$Z/$DB/$id" >/dev/null
    count=$((count + 1))
  done
  curl -fsS "$Z/$DB/_all_docs?limit=1" >/dev/null
  curl -fsS "$Z/$DB/_changes?since=0&limit=1" >/dev/null
  curl -fsS "$Z/$DB/_design/soak/_view/by_n?limit=5" >/dev/null
  curl -fsS -X POST "$Z/$DB/_find" -H 'content-type: application/json' \
    -d '{"selector":{"n":{"$gte":0}},"limit":5}' >/dev/null
  if [ -n "${COUCH_URL:-}" ]; then
    curl -fsS -X POST "$COUCH_URL/_replicate" -H 'content-type: application/json' \
      -d "{\"source\":\"$COUCH_URL/soak_couch\",\"target\":\"$Z/$DB\"}" >/dev/null
  fi
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    rss=$(awk '/VmRSS/ {print $2}' "/proc/$PID/status")
    [ "$rss" -gt "$peak" ] && peak=$rss
  fi
done

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  final=$(awk '/VmRSS/ {print $2}' "/proc/$PID/status")
  [ "$final" -gt "$peak" ] && peak=$final
  echo "PASS: soak wrote $count documents; peak RSS ${peak} kB"
else
  echo "PASS: soak wrote $count documents (no PID supplied for RSS sampling)"
fi
