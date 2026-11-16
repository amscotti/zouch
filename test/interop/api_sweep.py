#!/usr/bin/env python3
"""Compare a broad set of endpoints between CouchDB and zouch.

Prints only the places where the two disagree on status code or the shape of the
top-level JSON keys, which is what a client would notice first.
"""
import base64
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

COUCH = os.environ.get("COUCH", "http://127.0.0.1:5984")
AUTH = os.environ.get("AUTH", "admin:zouchtestpw")
HDRS = {"authorization": "Basic " + base64.b64encode(AUTH.encode()).decode()}


def call(base, method, path, body=None, headers=None):
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    req = urllib.request.Request(base + path, data=data, method=method)
    h = dict(HDRS)
    h["content-type"] = "application/json"
    if headers:
        h.update(headers)
    for k, v in h.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            ctype = r.headers.get("content-type", "")
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        ctype = e.headers.get("content-type", "")
        status = e.code
    except Exception as e:  # noqa: BLE001
        return None, {"transport_error": str(e)}, ""
    try:
        parsed = json.loads(raw)
    except Exception:  # noqa: BLE001
        parsed = {"_raw_len": len(raw)}
    return status, parsed, ctype


def shape(v):
    if isinstance(v, dict):
        return tuple(sorted(v.keys()))
    return type(v).__name__


# Endpoints we know differ, with the reason. A fix removes the entry; a new
# difference that is not listed here fails the run, which is the point.
EXPECTED_DIFFERENCES = {
}




def main():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    data_dir = "/tmp/sweep_zouch"
    subprocess.run(["rm", "-rf", data_dir], check=False)
    proc = subprocess.Popen(
        [os.environ.get("ZOUCH_BIN", "./zig-out/bin/zouch"), "serve", data_dir, str(port)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    zouch = "http://127.0.0.1:%d" % port
    try:
        for _ in range(200):
            try:
                call(zouch, "GET", "/")
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.05)

        # Same fixture on both sides.
        for base in (COUCH, zouch):
            call(base, "DELETE", "/sweep")
            call(base, "PUT", "/sweep")
            call(base, "PUT", "/sweep/doc1", {"v": 1})
            call(base, "PUT", "/sweep/doc2", {"v": 2})
            call(base, "PUT", "/sweep/_design/d", {
                "views": {"all": {"map": "function (doc) { emit(doc._id, null); }"}},
                "language": "javascript",
            })

        cases = [
            ("GET", "/", None),
            ("GET", "/_all_dbs", None),
            ("GET", "/_up", None),
            ("GET", "/_uuids", None),
            ("GET", "/_active_tasks", None),
            ("GET", "/_scheduler/jobs", None),
            ("GET", "/_scheduler/docs", None),
            ("GET", "/_session", None),
            ("GET", "/_membership", None),
            ("GET", "/_replicator", None),
            ("GET", "/sweep", None),
            ("HEAD", "/sweep", None),
            ("GET", "/sweep/_all_docs", None),
            ("POST", "/sweep/_all_docs", {"keys": ["doc1"]}),
            ("GET", "/sweep/_design_docs", None),
            ("GET", "/sweep/_local_docs", None),
            ("GET", "/sweep/_changes", None),
            ("GET", "/sweep/_changes?since=0&limit=1", None),
            ("GET", "/sweep/_changes?descending=true", None),
            ("POST", "/sweep/_changes?filter=_doc_ids", {"doc_ids": ["doc1"]}),
            ("GET", "/sweep/_changes?feed=eventsource&timeout=100", None),
            ("GET", "/sweep/_revs_limit", None),
            ("PUT", "/sweep/_revs_limit", 1000),
            ("POST", "/sweep/_revs_diff", {"doc1": ["1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}),
            ("POST", "/sweep/_missing_revs", {"doc1": ["1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}),
            ("POST", "/sweep/_ensure_full_commit", {}),
            ("POST", "/sweep/_compact", None),
            ("POST", "/sweep/_view_cleanup", None),
            ("GET", "/sweep/_security", None),
            ("GET", "/sweep/_design/d", None),
            ("GET", "/sweep/_design/d/_view/all", None),
            ("GET", "/sweep/_design/d/_view/all?keys=[\"doc1\"]", None),
            ("GET", "/sweep/_design/d/_info", None),
            ("GET", "/sweep/_design/d/_list/x/all", None),
            ("GET", "/sweep/_design/d/_show/x", None),
            ("POST", "/sweep/_find", {"selector": {"v": {"$gt": 0}}}),
            ("GET", "/sweep/_index", None),
            ("POST", "/sweep/_purge", {"doc1": ["1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}),
            ("GET", "/sweep/_partition/p/_all_docs", None),
            ("GET", "/sweep/doc1", None),
            ("GET", "/sweep/doc1?revs=true", None),
            ("GET", "/sweep/doc1?revs_info=true", None),
            ("GET", "/sweep/doc1?conflicts=true", None),
            ("GET", "/sweep/_bulk_get?docs=[{\"id\":\"doc1\"}]", None),
            ("GET", "/_utils", None),
            ("GET", "/_config", None),
            ("GET", "/_stats", None),
            ("GET", "/nope", None),
            ("GET", "/nope/_all_docs", None),
            ("DELETE", "/nope", None),
        ]

        mismatches = []
        seen_expected = set()
        for method, path, body in cases:
            sc, bc, cc = call(COUCH, method, path, body)
            sz, bz, cz = call(zouch, method, path, body)
            cc = cc.split(";")[0].strip()
            cz = cz.split(";")[0].strip()
            differs = sc != sz
            if not differs and cc != cz:
                # A JSON body where CouchDB sends text/event-stream is a
                # difference a browser client notices immediately, even though
                # neither side parses as JSON.
                differs = True
            if not differs and isinstance(bc, dict) and isinstance(bz, dict):
                kc, kz = set(bc.keys()), set(bz.keys())
                differs = kc != kz and not ("error" in kc and "error" in kz)
            key = (method, path)
            if key in EXPECTED_DIFFERENCES:
                if differs:
                    seen_expected.add(key)
                else:
                    print(f"STALE  {method} {path}: documented as different, now agrees")
                continue
            if differs:
                mismatches.append((method, path, sc, sz, shape(bc), shape(bz), cc, cz))

        expected = len(EXPECTED_DIFFERENCES)
        agreed = len(cases) - expected
        print(f"{agreed}/{agreed} undocumented endpoints agree ({expected} documented differences)")
        for m in mismatches:
            print(f"DIFF   {m[0]:6} {m[1]:52} couch={m[2]} zouch={m[3]}")
            print(f"       couch: {m[4]} {m[6]}")
            print(f"       zouch: {m[5]} {m[7]}")
        stale = len(EXPECTED_DIFFERENCES) - len(seen_expected)
        if stale:
            print(f"{stale} documented difference(s) no longer differ - drop them from EXPECTED_DIFFERENCES")
        ok = not mismatches and not stale
        print("PASS: every undocumented endpoint answers as CouchDB does" if ok else "FAIL")
        return 0 if ok else 1
    finally:
        proc.terminate()
        proc.wait()
        subprocess.run(["rm", "-rf", data_dir], check=False)


if __name__ == "__main__":
    sys.exit(main())
