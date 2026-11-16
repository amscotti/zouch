#!/usr/bin/env python3
"""Compare _bulk_get between CouchDB and zouch on identical data.

The point is parity, not our own idea of correct: every case is sent to a real
CouchDB and to a zouch holding the same documents, and the two responses must
agree except where the values are legitimately opaque.

Opaque values:
  _rev / rev        the revision hash is CouchDB's canonical-form hash; ours is
                    ours. The generation number is not opaque and is compared.
  digest            CouchDB digests the gzip-compressed body (Erlang gzip
                    header), so it is an implementation detail, not a hash of
                    the bytes the client sent.
  _revisions.ids    the same hashes as _rev, in a bare list.

Usage: COUCH=http://127.0.0.1:5984 AUTH=admin:pw python3 bulk_get_parity.py
Exits non-zero on any difference, and prints both sides for each.
"""
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

COUCH = os.environ.get("COUCH", "http://127.0.0.1:5984")
AUTH_PAIR = os.environ.get("AUTH", "admin:zouchtestpw")
REV_HASH = re.compile(r"^\d+-[0-9a-f]{20,}$")


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def req(base, method, path, body=None, ctype="application/json", auth=None, headers=None):
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
    r = urllib.request.Request(base + path, data=body, method=method)
    if body is not None:
        r.add_header("content-type", ctype)
    if auth:
        r.add_header("authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read(), resp.headers.get("content-type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("content-type", "")


def norm(v):
    """Drop the values that are implementation detail, keep the shape."""
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k in ("_rev", "rev") and isinstance(x, str):
                out[k] = "<rev>"
            elif k == "digest" and isinstance(x, str):
                out[k] = "<digest>"
            elif k == "_revisions" and isinstance(x, dict):
                out[k] = {"start": x.get("start"), "ids": "<ids>"}
            else:
                out[k] = norm(x)
        return out
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, str) and REV_HASH.match(v):
        return "<rev>"
    return v


def seed(base, db, auth):
    """Same edits on both servers: `a` with an attachment, `b`, and `d` with two
    revisions so ancestry exists."""
    req(base, "DELETE", f"/{db}", auth=auth)
    status, _, _ = req(base, "PUT", f"/{db}", auth=auth)
    assert status in (201, 202), (base, status)
    _, body, _ = req(base, "PUT", f"/{db}/a", {"n": 1}, auth=auth)
    rev = json.loads(body)["rev"]
    _, body, _ = req(base, "PUT", f"/{db}/a/att.txt?rev={rev}", b"hello attachment body\n",
                     ctype="text/plain", auth=auth)
    rev = json.loads(body)["rev"]
    req(base, "PUT", f"/{db}/b", {"n": 2}, auth=auth)
    _, body, _ = req(base, "PUT", f"/{db}/d", {"n": 1}, auth=auth)
    d1 = json.loads(body)["rev"]
    _, body, _ = req(base, "PUT", f"/{db}/d?rev={d1}", {"n": 2}, auth=auth)
    return rev, d1


CASES = [
    ("stubs", "/{db}/_bulk_get",
     {"docs": [{"id": "a", "rev": "__REV__"}, {"id": "b"}, {"id": "nope"}]}),
    ("attachments", "/{db}/_bulk_get?attachments=true", {"docs": [{"id": "a", "rev": "__REV__"}]}),
    ("no attachments", "/{db}/_bulk_get?attachments=false", {"docs": [{"id": "a", "rev": "__REV__"}]}),
    ("revs", "/{db}/_bulk_get?revs=true", {"docs": [{"id": "a", "rev": "__REV__"}]}),
    ("unknown rev", "/{db}/_bulk_get", {"docs": [{"id": "a", "rev": "9-deadbeefdeadbeefdeadbeefdeadbeef"}]}),
    ("unknown+latest", "/{db}/_bulk_get?latest=true",
     {"docs": [{"id": "a", "rev": "9-deadbeefdeadbeefdeadbeefdeadbeef"}]}),
    ("ancestor", "/{db}/_bulk_get", {"docs": [{"id": "d", "rev": "__D1__"}]}),
    ("ancestor latest", "/{db}/_bulk_get?latest=true", {"docs": [{"id": "d", "rev": "__D1__"}]}),
]

# Every case is compared with CouchDB. The ancestor case used to be a documented
# divergence - not_found, because only leaves were stored - and now matches:
# bodies are kept until compaction, as CouchDB keeps them.
DIVERGENT: dict[str, str] = {}


def main() -> int:
    port = free_port()
    zouch = f"http://127.0.0.1:{port}"
    tmp = tempfile.mkdtemp()
    binary = os.environ.get("ZOUCH_BIN", "./zig-out/bin/zouch")
    proc = subprocess.Popen([binary, "serve", os.path.join(tmp, "data"), str(port)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            try:
                req(zouch, "GET", "/")
                break
            except Exception:
                time.sleep(0.05)
        else:
            print("FAIL: zouch did not start")
            return 1

        rev_c, d1_c = seed(COUCH, "bg_c", AUTH_PAIR)
        rev_z, d1_z = seed(zouch, "bg_z", AUTH_PAIR)

        diffs = 0
        for label, path, body in CASES:
            body_c = json.loads(json.dumps(body).replace("__REV__", rev_c).replace("__D1__", d1_c))
            body_z = json.loads(json.dumps(body).replace("__REV__", rev_z).replace("__D1__", d1_z))
            sc, bc, _ = req(COUCH, "POST", path.format(db="bg_c"), body_c, auth=AUTH_PAIR)
            sz, bz, _ = req(zouch, "POST", path.format(db="bg_z"), body_z, auth=AUTH_PAIR)
            same = sc == sz and norm(json.loads(bc or b"null")) == norm(json.loads(bz or b"null"))
            expected = DIVERGENT.get(label)
            if expected is not None:
                try:
                    zbody = json.loads(bz or b"null")
                    got = zbody["results"][0]["docs"][0]["error"]["error"]
                except Exception:
                    got = None
                same = sc == 200 and sz == 200 and got == expected
                print(f"{label:16} couch={sc} zouch={sz} "
                      f"{'documented divergence' if same else 'DIFF (divergence not as documented)'}")
            else:
                print(f"{label:16} couch={sc} zouch={sz} {'same' if same else 'DIFF'}")
            if not same:
                diffs += 1
                print("  couch:", json.dumps(json.loads(bc or b"null"))[:500])
                print("  zouch:", json.dumps(json.loads(bz or b"null"))[:500])
        print(f"{len(CASES) - diffs}/{len(CASES)} _bulk_get cases match CouchDB")
        return 1 if diffs else 0
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
