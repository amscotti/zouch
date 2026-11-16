#!/usr/bin/env bash
# Conflicts are application-level: a losing leaf stays visible until the
# application explicitly deletes it.
set -euo pipefail

BIN="${ZOUCH_BIN:-./zig-out/bin/zouch}"
PORT="${ZOUCH_CONFLICT_PORT:-6043}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zouch-conflict.XXXXXX")
DATA="$TMP/data"
LOG="$TMP/server.log"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! curl -fsS "http://127.0.0.1:$PORT/_up" >/dev/null 2>&1; then
  cat "$LOG" >&2 || true
  exit 1
fi

B="http://127.0.0.1:$PORT"
curl -fsS -X PUT "$B/conflict_app" >/dev/null
R1=$(curl -fsS -X PUT "$B/conflict_app/doc" -H 'content-type: application/json' \
  -d '{"v":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["rev"])')
H1=${R1#1-}
[ -n "$H1" ]

# Import two gen-2 children of R1. They are siblings, so one becomes the
# winner and the other remains a conflict leaf; R1 is their common ancestor.
curl -fsS -X POST "$B/conflict_app/_bulk_docs" -H 'content-type: application/json' \
  -d "{\"new_edits\":false,\"docs\":[{\"_id\":\"doc\",\"_rev\":\"2-cccccccccccccccccccccccccccccccc\",\"v\":77,\"_revisions\":{\"start\":2,\"ids\":[\"cccccccccccccccccccccccccccccccc\",\"$H1\"]}},{\"_id\":\"doc\",\"_rev\":\"2-dddddddddddddddddddddddddddddddd\",\"v\":78,\"_revisions\":{\"start\":2,\"ids\":[\"dddddddddddddddddddddddddddddddd\",\"$H1\"]}}]}" >/dev/null

DOC=$(curl -fsS "$B/conflict_app/doc?conflicts=true")
[ "$(echo "$DOC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["v"])')" = "78" ]
[ "$(echo "$DOC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["_conflicts"]))')" = "1" ]
[ "$(echo "$DOC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["_conflicts"][0])')" = "2-cccccccccccccccccccccccccccccccc" ]

# The losing revision is still readable.
curl -fsS "$B/conflict_app/doc?rev=2-cccccccccccccccccccccccccccccccc" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["v"] == 77'

# Writing a new winner does not silently discard the conflict.
R2=$(curl -fsS -X PUT "$B/conflict_app/doc" -H 'content-type: application/json' \
  -d "{\"_rev\":\"2-dddddddddddddddddddddddddddddddd\",\"v\":88}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["rev"])')
DOC=$(curl -fsS "$B/conflict_app/doc?conflicts=true")
[ "$(echo "$DOC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["_conflicts"]))')" = "1" ]

# Deleting the losing leaf resolves the conflict in _conflicts while keeping the
# tombstone revision until purged.
TOMB=$(curl -fsS -X DELETE "$B/conflict_app/doc?rev=2-cccccccccccccccccccccccccccccccc" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["rev"])')
DOC=$(curl -fsS "$B/conflict_app/doc?conflicts=true")
[ "$(echo "$DOC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("_conflicts", [])))')" = "0" ]
curl -fsS -X POST "$B/conflict_app/_purge" -H 'content-type: application/json' -d "{\"doc\":[\"$TOMB\"]}" >/dev/null
[ "$(curl -fsS "$B/conflict_app/doc?conflicts=true" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("_conflicts", []))')" = "[]" ]
[ "$(curl -fsS "$B/conflict_app/doc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["v"])')" = "88" ]

echo "PASS: conflicts remain visible until the application resolves them"
