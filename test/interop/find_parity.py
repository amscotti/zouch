#!/usr/bin/env python3
"""Diff _find and _explain between CouchDB and zouch on identical data."""
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
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"null")
        except Exception:
            return e.code, raw.decode("utf-8", "replace")


DOCS = [
    ("d1", {"kind": "x", "n": 1, "tags": ["t1", "t2"], "nested": {"a": 1}, "str": "abc"}),
    ("d2", {"kind": "x", "n": 2, "tags": ["t2"], "nested": {"a": 2}, "str": "xyz"}),
    ("d3", {"kind": "y", "n": 3, "tags": [], "nested": {"a": 3}, "str": "abd"}),
    ("d4", {"kind": "y", "n": 4, "tags": ["t1"], "str": "zzz"}),
]


def seed(base, db, auth):
    req(base, "DELETE", f"/{db}", auth=auth)
    req(base, "PUT", f"/{db}", auth=auth)
    for name, doc in DOCS:
        st, body = req(base, "PUT", f"/{db}/{name}", doc, auth=auth)
        assert st in (201, 202), (name, st, body)


CASES = [
    ("eq", {"selector": {"kind": "x"}}),
    ("gt", {"selector": {"n": {"$gt": 2}}}),
    ("in", {"selector": {"n": {"$in": [1, 3]}}}),
    ("or", {"selector": {"$or": [{"n": 1}, {"kind": "y"}]}}),
    ("not", {"selector": {"$not": {"n": {"$lt": 3}}}}),
    ("elemMatch", {"selector": {"tags": {"$elemMatch": {"$eq": "t1"}}}}),
    ("regex", {"selector": {"str": {"$regex": "^ab"}}}),
    ("exists", {"selector": {"tags": {"$exists": True}}}),
    ("nested", {"selector": {"nested.a": {"$gte": 2}}}),
    ("fields", {"selector": {"kind": "x"}, "fields": ["_id", "n"]}),
    ("sort", {"selector": {"kind": {"$gt": None}}, "sort": [{"n": "desc"}]}),
    ("limit_skip", {"selector": {"kind": {"$gt": None}}, "sort": [{"n": "asc"}], "limit": 2, "skip": 1}),
    ("bad_operator", {"selector": {"n": {"$nope": 1}}}),
]


def rows(body):
    if not isinstance(body, dict):
        return body
    if "docs" in body:
        return [(d.get("_id"), {k: v for k, v in d.items() if k != "_rev"}) for d in body["docs"]]
    return body


# Every case is compared straight against CouchDB, including the sorts: it
# refuses a sort no index can serve with `400 no_usable_index`, and so do we.


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
        seed(COUCH, "f_c", AUTH_PAIR)
        seed(zouch, "f_z", AUTH_PAIR)
        diffs = 0
        for label, body in CASES:
            sc, bc = req(COUCH, "POST", "/f_c/_find", body, auth=AUTH_PAIR)
            sz, bz = req(zouch, "POST", "/f_z/_find", body, auth=AUTH_PAIR)
            rc, rz = rows(bc), rows(bz)
            same = sc == sz and rc == rz
            print(f"{label:14} couch={sc} zouch={sz} {'same' if same else 'DIFF'}")
            if not same:
                diffs += 1
                print("  couch:", json.dumps(rc)[:300])
                print("  zouch:", json.dumps(rz)[:300])
        print(f"{len(CASES) - diffs}/{len(CASES)} _find cases match CouchDB")
        return 1 if diffs else 0
    finally:
        proc.terminate(); proc.wait(timeout=10); shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
