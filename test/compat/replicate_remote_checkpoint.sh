#!/usr/bin/env bash
# A remote-to-remote job drops its staging database, so the checkpoint has to
# live on the target - which is where CouchDB keeps it. Without one, every run
# re-reads the whole source; with one, the second run starts where the first
# stopped. The `_local` revision advancing is the evidence.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
TMP=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
SPID=""
COUCH=${COUCH:-http://127.0.0.1:5984}
AUTH=${AUTH:-admin:zouchtestpw}
SRC=zouch_remote_cp_src
TGT=zouch_remote_cp_tgt

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  pkill -f "zouch serve $DATA" 2>/dev/null
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$SRC" >/dev/null 2>&1
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$TGT" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

for db in "$SRC" "$TGT"; do
  curl -fsS -u "$AUTH" -X DELETE "$COUCH/$db" >/dev/null 2>&1
  curl -fsS -u "$AUTH" -X PUT "$COUCH/$db" >/dev/null || { echo "FAIL: no CouchDB at $COUCH"; exit 1; }
done
curl -fsS -u "$AUTH" -X POST "$COUCH/$SRC/_bulk_docs" -H 'content-type: application/json' \
  -d '{"docs":[{"_id":"c1"},{"_id":"c2"}]}' >/dev/null

"$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
Z="http://127.0.0.1:$PORT"
for _ in $(seq 1 100); do
  curl -fsS "$Z/_up" >/dev/null 2>&1 && break
  sleep 0.05
done

run_job() {
  curl -fsS -X PUT "$Z/_replicator/$1" -H 'content-type: application/json' \
    -d "{\"source\":\"http://$AUTH@${COUCH#http://}/$SRC\",\"target\":\"http://$AUTH@${COUCH#http://}/$TGT\"}" >/dev/null
  for _ in $(seq 1 80); do
    state=$(curl -sS "$Z/_replicator/$1" | jq -r '._replication_state // "pending"')
    [ "$state" != "pending" ] && break
    sleep 0.5
  done
  [ "$state" = "completed" ] || { echo "FAIL: $1 state '$state'"; curl -sS "$Z/_replicator/$1"; exit 1; }
}

checkpoints() {
  curl -sS -u "$AUTH" "$COUCH/$TGT/_local_docs" | jq -r '[.rows[] | "\(.id) \(.value.rev)"] | join(",")'
}

run_job first
docs=$(curl -sS -u "$AUTH" "$COUCH/$TGT/_all_docs" | jq -r .total_rows)
[ "$docs" = "2" ] || { echo "FAIL: target has $docs documents, expected 2"; exit 1; }

cp=$(checkpoints)
case "$cp" in
  *_local/zouch-pull-*) ;;
  *) echo "FAIL: no checkpoint on the target, saw '$cp'"; exit 1 ;;
esac
rev1=$(echo "$cp" | awk '{print $NF}')
[ "$rev1" = "0-1" ] || { echo "FAIL: first checkpoint is '$rev1', expected 0-1"; exit 1; }

# A second job over the same source and target must resume from that checkpoint,
# which means writing a new revision of the same document rather than leaving the
# stale one behind.
curl -fsS -u "$AUTH" -X PUT "$COUCH/$SRC/c3" -H 'content-type: application/json' -d '{"v":3}' >/dev/null
run_job second
docs=$(curl -sS -u "$AUTH" "$COUCH/$TGT/_all_docs" | jq -r .total_rows)
[ "$docs" = "3" ] || { echo "FAIL: target has $docs documents after the second job, expected 3"; exit 1; }
cp=$(checkpoints)
rev2=$(echo "$cp" | awk '{print $NF}')
[ "$rev2" = "0-2" ] || { echo "FAIL: checkpoint did not advance, saw '$cp'"; exit 1; }

echo "PASS: a remote-to-remote job checkpoints on the target and resumes"
