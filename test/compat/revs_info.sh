#!/usr/bin/env bash
# A revision that stops being a leaf keeps its body until compaction, exactly as
# CouchDB does: `?rev=` still serves it and `_revs_info` says `available`. After
# compaction the body is gone, `?rev=` is 404 and the ancestor is `missing`.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
TMP=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
SPID=""
U="http://127.0.0.1:$PORT"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  pkill -f "zouch serve $DATA" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  curl -fsS "$U/_up" >/dev/null 2>&1 && break
  sleep 0.1
done

curl -fsS -X PUT "$U/rv" >/dev/null
curl -fsS -X PUT "$U/rv/d1" -H 'content-type: application/json' -d '{"v":1}' >/dev/null
OLD=$(curl -fsS "$U/rv/d1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["_rev"])')
curl -fsS -X PUT "$U/rv/d1?rev=$OLD" -H 'content-type: application/json' -d '{"v":2}' >/dev/null

check() { # phase
  BODY=$(curl -fsS "$U/rv/d1?rev=$OLD" 2>/dev/null)
  INFO=$(curl -fsS "$U/rv/d1?revs_info=true" |
    python3 -c 'import json,sys;print(",".join(r["status"] for r in json.load(sys.stdin)["_revs_info"]))')
  BULK=$(curl -fsS -X POST "$U/rv/_bulk_get?revs=true" -H 'content-type: application/json' \
    -d "{\"docs\":[{\"id\":\"d1\",\"rev\":\"$OLD\"}]}" |
    python3 -c 'import json,sys;d=json.load(sys.stdin)["results"][0]["docs"][0];print("ok" if "ok" in d else "error")')
  echo "$1: revs_info=[$INFO] bulk_get=$BULK body=$(printf '%s' "$BODY" | head -c 60)"
}

check "before-compact"
printf '%s' "$BODY" | grep -q '"v":1' || { echo "FAIL: old revision body not served"; exit 1; }
[ "$INFO" = "available,available" ] || { echo "FAIL: expected available,available before compaction"; exit 1; }
[ "$BULK" = "ok" ] || { echo "FAIL: _bulk_get did not serve the old revision"; exit 1; }

curl -fsS -X POST "$U/rv/_compact" >/dev/null
for _ in $(seq 1 50); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$U/rv/d1?rev=$OLD")
  [ "$CODE" = "404" ] && break
  sleep 0.2
done

check "after-compact"
[ "$CODE" = "404" ] || { echo "FAIL: old revision still served after compaction ($CODE)"; exit 1; }
[ "$INFO" = "available,missing" ] || { echo "FAIL: expected available,missing after compaction"; exit 1; }
[ "$BULK" = "error" ] || { echo "FAIL: _bulk_get still serves the compacted revision"; exit 1; }

echo "PASS: old revisions served until compaction drops them"
