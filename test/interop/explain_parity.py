#!/usr/bin/env python3
"""Compare the shape of _explain between CouchDB and zouch.

The explanation is diagnostic, so the test asserts the structure a client reads:
the same top-level keys, the same `index` keys, the same `opts` keys, and
`_all_docs` when no index applies. Values that name our own storage (ddoc ids,
index names for a created index) are compared as "present", not equal.
"""
import base64, json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

COUCH = os.environ.get("COUCH", "http://127.0.0.1:5984")
AUTH_PAIR = os.environ.get("AUTH", "admin:zouchtestpw")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def req(base, method, path, body=None, auth=None):
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    r = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        r.add_header("content-type", "application/json")
    if auth:
        r.add_header("authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def seed(base, db, auth):
    req(base, "DELETE", f"/{db}", auth=auth)
    req(base, "PUT", f"/{db}", auth=auth)
    for i in range(3):
        req(base, "PUT", f"/{db}/d{i}", {"n": i, "kind": "x"}, auth=auth)


def main():
    port = free_port()
    zouch = f"http://127.0.0.1:{port}"
    tmp = tempfile.mkdtemp()
    proc = subprocess.Popen([os.environ.get("ZOUCH_BIN", "./zig-out/bin/zouch"), "serve",
                             os.path.join(tmp, "data"), str(port)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            try:
                req(zouch, "GET", "/"); break
            except Exception:
                time.sleep(0.05)
        seed(COUCH, "ex_c", AUTH_PAIR)
        seed(zouch, "ex_z", AUTH_PAIR)

        fails = 0
        for label, body in [("no index", {"selector": {"kind": "x"}}),
                            ("no index, 2 fields", {"selector": {"kind": "x", "n": {"$gt": 0}}, "limit": 5})]:
            sc, bc = req(COUCH, "POST", "/ex_c/_explain", body, auth=AUTH_PAIR)
            sz, bz = req(zouch, "POST", "/ex_z/_explain", body, auth=AUTH_PAIR)
            problems = []
            if sc != sz:
                problems.append(f"status {sc} vs {sz}")
            missing_top = set(bc) - set(bz)
            if missing_top:
                problems.append(f"missing top-level keys {sorted(missing_top)}")
            for section in ("index", "opts"):
                missing = set(bc.get(section, {})) - set(bz.get(section, {}))
                if missing:
                    problems.append(f"missing {section} keys {sorted(missing)}")
            if bc["index"]["name"] == "_all_docs" and bz["index"]["name"] != "_all_docs":
                problems.append(f"index name {bz['index']['name']} where CouchDB says _all_docs")
            if bc.get("fields") != bz.get("fields"):
                problems.append(f"fields {bc.get('fields')} vs {bz.get('fields')}")
            print(f"{label:18} {'same shape' if not problems else 'DIFF: ' + '; '.join(problems)}")
            fails += bool(problems)

            # limit/skip must be echoed, not defaulted
            if body.get("limit") and bz.get("limit") != body["limit"]:
                print(f"  limit not echoed: {bz.get('limit')}")
                fails += 1
        # With a created index, CouchDB reports the index's own name and the
        # design document that holds it; ours is _design/zouch.
        for base, db in ((COUCH, "ex_c"), (zouch, "ex_z")):
            req(base, "POST", f"/{db}/_index", {"index": {"fields": ["kind"]}, "name": "kind-idx", "type": "json"}, auth=AUTH_PAIR)
        body = {"selector": {"kind": "x"}}
        sc, bc = req(COUCH, "POST", "/ex_c/_explain", body, auth=AUTH_PAIR)
        sz, bz = req(zouch, "POST", "/ex_z/_explain", body, auth=AUTH_PAIR)
        problems = []
        if sz != sc:
            problems.append(f"status {sc} vs {sz}")
        if bz["index"].get("name") != bc["index"].get("name"):
            problems.append(f"index name {bc['index'].get('name')!r} vs {bz['index'].get('name')!r}")
        if not bz["index"].get("ddoc"):
            problems.append("index ddoc is null")
        if bz["index"].get("def") != bc["index"].get("def"):
            problems.append(f"index def {bc['index'].get('def')} vs {bz['index'].get('def')}")
        print(f"{'created index':18} {'same shape' if not problems else 'DIFF: ' + '; '.join(problems)}")
        fails += bool(problems)
        total = 3
        print(f"{total - fails}/{total} _explain cases match CouchDB's shape")
        return 1 if fails else 0
    finally:
        proc.terminate(); proc.wait(timeout=10); shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
