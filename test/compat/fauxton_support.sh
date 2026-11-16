#!/usr/bin/env bash
# What Fauxton needs beyond the document API: the build itself at /_utils, the
# setup probe it calls on load, the config page, and a session that works when no
# credential is configured - CouchDB's admin party. A fresh server plus Fauxton
# used to deadlock on a login nobody could pass.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=${ZOUCH_BIN:-./zig-out/bin/zouch}
TMP=$(mktemp -d)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
DATA="$TMP/data"
WWW="$TMP/www"
mkdir -p "$WWW/dashboard.assets/js"
printf '<!doctype html><title>Project Fauxton</title><p>build marker\n' > "$WWW/index.html"
printf 'console.log("asset marker");\n' > "$WWW/dashboard.assets/js/bundle.js"
printf 'secret\n' > "$TMP/secret.txt"
SPID=""
U="http://127.0.0.1:$PORT"

cleanup() {
  [ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null
  pkill -f "zouch serve $DATA" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ZOUCH_WWW="$WWW" "$BIN" serve "$DATA" "$PORT" >"$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 1 100); do
  curl -fsS "$U/_up" >/dev/null 2>&1 && break
  sleep 0.1
done

fail() { echo "FAIL: $1"; exit 1; }

# The build is served from ZOUCH_WWW, with a type a browser accepts.
curl -fsS "$U/_utils/" | grep -q 'build marker' || fail "/_utils/ did not serve the build"
[ "$(curl -sS -o /dev/null -w '%{content_type}' "$U/_utils/dashboard.assets/js/bundle.js")" = "text/javascript; charset=utf-8" ] ||
  fail "asset content type"
curl -fsS "$U/_utils/dashboard.assets/js/bundle.js" | grep -q 'asset marker' || fail "nested asset not served"

# A file the override directory does not have comes from the copy embedded in the
# binary, so a bare `zouch serve` carries its own UI.
[ "$(curl -sS -o /dev/null -w '%{content_type}' "$U/_utils/dashboard.assets/fonts/fauxtonicon9.woff2")" = "font/woff2" ] ||
  fail "embedded font asset"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$U/_utils/dashboard.assets/js/bundle.36c4d575204c3cda9131.js")" = "200" ] ||
  fail "embedded bundle"

# No escaping the build directory.
CODE=$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' "$U/_utils/../../secret.txt")
[ "$CODE" = "404" ] || fail "path traversal answered $CODE"

# What Fauxton asks at boot.
[ "$(curl -sS "$U/_cluster_setup")" = '{"state":"single_node_enabled"}' ] || fail "/_cluster_setup state"
curl -fsS "$U/_node/_local/_config" | grep -q "\"database_dir\":\"$DATA\"" || fail "/_node/_local/_config"
curl -fsS "$U/_node/zouch@localhost/_config" | grep -q '"vendor":"Zouch"' || fail "config under the node name Fauxton uses"

# Admin party: no credential configured, so the anonymous caller is the admin.
curl -fsS "$U/_session" | grep -q '"_admin"' || fail "/_session does not report admin party"

# The setup wizard's one meaningful action: setting the admin credential.
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$U/_cluster_setup" -H 'content-type: application/json' \
  -d '{"action":"enable_single_node","username":"boss","password":"pw"}')" = "200" ] || fail "enable_single_node"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$U/_all_dbs")" = "401" ] || fail "credential set but not enforced"
[ "$(curl -sS -u boss:pw -o /dev/null -w '%{http_code}' "$U/_all_dbs")" = "200" ] || fail "credential does not work"

echo "PASS: Fauxton's server side - assets, setup probe, config, admin party"
