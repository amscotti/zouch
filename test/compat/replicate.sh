#!/usr/bin/env bash
# End-to-end replication checks against a real CouchDB.
# Requires CouchDB on :5984 (admin:zouchtestpw by default) and Zouch on :5985.
set -euo pipefail

ZOUCH="${ZOUCH:-http://127.0.0.1:5985}"
COUCH="${COUCH:-http://127.0.0.1:5984}"
AUTH="${AUTH:-admin:zouchtestpw}"

need() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
need curl
need python3

wait_for() {
  local url=$1
  for _ in $(seq 1 50); do
    curl -fsS -m 1 "$url" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "not reachable: $url"
  return 1
}

wait_for "$ZOUCH/"
wait_for "$COUCH/"

jqget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "== pull: Zouch -> CouchDB =="
curl -fsS -X DELETE "$ZOUCH/pull_test" >/dev/null 2>&1 || true
curl -fsS -X PUT "$ZOUCH/pull_test" >/dev/null
curl -fsS -X PUT "$ZOUCH/pull_test/a" -H 'content-type: application/json' \
  -d '{"text":"hello","n":1}' >/dev/null
curl -fsS -u "$AUTH" -X DELETE "$COUCH/pull_target" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/pull_target" >/dev/null
REP=$(curl -fsS -u "$AUTH" -X POST "$COUCH/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$ZOUCH/pull_test\",\"target\":\"pull_target\"}")
echo "$REP" | jqget 'd["history"][0]["docs_written"]' | grep -qx 1
[ "$(curl -fsS -u "$AUTH" "$COUCH/pull_target/a" | jqget 'd["text"]')" = "hello" ]

echo "== idempotent checkpoint =="
REP=$(curl -fsS -u "$AUTH" -X POST "$COUCH/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$ZOUCH/pull_test\",\"target\":\"pull_target\"}")
echo "$REP" | jqget 'bool(d.get("no_changes")) or d["history"][-1]["docs_written"] == 0' | grep -qx True

echo "== push: CouchDB -> Zouch =="
curl -fsS -u "$AUTH" -X DELETE "$COUCH/push_source" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/push_source" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/push_source/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"p1","v":1},{"_id":"p2","v":2},{"_id":"p3","v":3}]}' >/dev/null
curl -fsS -X DELETE "$ZOUCH/push_target" >/dev/null 2>&1 || true
curl -fsS -X PUT "$ZOUCH/push_target" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"push_source\",\"target\":\"$ZOUCH/push_target\"}" >/dev/null
[ "$(curl -fsS "$ZOUCH/push_target/_all_docs" | jqget 'd["total_rows"]')" = "3" ]

echo "== conflict: two leaves =="
curl -fsS -X DELETE "$ZOUCH/conf_test" >/dev/null 2>&1 || true
curl -fsS -X PUT "$ZOUCH/conf_test" >/dev/null
curl -fsS -X POST "$ZOUCH/conf_test/_bulk_docs" -H 'content-type: application/json' -d '{
  "new_edits": false,
  "docs": [
    {"_id":"c","_rev":"2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
     "_revisions":{"start":2,"ids":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","11111111111111111111111111111111"]},
     "side":"a"},
    {"_id":"c","_rev":"2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     "_revisions":{"start":2,"ids":["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","11111111111111111111111111111111"]},
     "side":"b"}
  ]}' >/dev/null
curl -fsS -u "$AUTH" -X DELETE "$COUCH/conf_target" >/dev/null 2>&1 || true
curl -fsS -u "$AUTH" -X PUT "$COUCH/conf_target" >/dev/null
curl -fsS -u "$AUTH" -X POST "$COUCH/_replicate" -H 'content-type: application/json' \
  -d "{\"source\":\"$ZOUCH/conf_test\",\"target\":\"conf_target\"}" >/dev/null
CONF=$(curl -fsS -u "$AUTH" "$COUCH/conf_target/c?conflicts=true")
[ "$(echo "$CONF" | jqget 'd["_rev"]')" = "2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
[ "$(echo "$CONF" | jqget 'd["_conflicts"][0]')" = "2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]

echo "PASS: pull, push, conflict and checkpoint idempotency"
