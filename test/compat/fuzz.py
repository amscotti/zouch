#!/usr/bin/env python3
"""Small deterministic fuzz driver for the HTTP, JSON, multipart and rev surfaces.

It is not a coverage-guided fuzzer; it is a fast crash/leak smoke test that can run
against a live Zouch process.  The release gate runs each category for ten minutes.
"""
import http.client
import json
import os
import random
import sys
import time

HOST = os.environ.get("ZOUCH_HOST", "127.0.0.1")
PORT = int(os.environ.get("ZOUCH_PORT", "5985"))
SECONDS = float(os.environ.get("FUZZ_SECONDS", "20"))
SEED = int(os.environ.get("FUZZ_SEED", "1"))
CATEGORY = os.environ.get("FUZZ_CATEGORY", "all")
if CATEGORY not in ("all", "http", "json", "multipart", "rev"):
    raise SystemExit("FUZZ_CATEGORY must be all, http, json, multipart or rev")
random.seed(SEED)

PATHS = [
    "/",
    "/_all_dbs",
    "/fuzz",
    "/fuzz/doc",
    "/fuzz/doc?rev=1-abc&revs=true&open_revs=all",
    "/fuzz/doc/att",
    "/fuzz/_all_docs?keys=%5B%22a%22%2C%22b%22%5D",
    "/fuzz/_changes?since=0&limit=5&style=all_docs",
    "/fuzz/_changes?feed=longpoll&since=now&timeout=1",
    "/fuzz/_revs_diff",
    "/fuzz/_bulk_get",
    "/fuzz/_bulk_docs",
    "/fuzz/_find",
    "/fuzz/_index",
    "/fuzz/_local/checkpoint",
    "/fuzz/_design/f/_view/by_id",
    "/fuzz/_design/f/_view/by_id?key=%22a%22",
    "/fuzz/_purge",
    "/fuzz/_compact",
    "/fuzz/%2e%2e/%00/%ff",
]

BODIES = [
    b"",
    b"null",
    b"[]",
    b"{}",
    b'{"_id":"x"}',
    b'{"_id":"x","_rev":"0-1","_revisions":{"start":999999999999999999999,"ids":["x"]}}',
    b'{"docs":[{"_id":"a"},{"_id":"b","_rev":"bad"}]}',
    b'{"docs":[{"_id":"a","_attachments":{"f":{"content_type":"text/plain","data":"%%%"}}}]}',
    b'{"selector":{"$or":[]},"limit":-1,"skip":-1}',
    b'{"keys":[1,true,null,{}]}',
    b'{"missing":["1-zzz"],"x":[{"bad":true}]}',
    b'{"start":-1,"ids":[""]}',
    b"\x00\x01\x02\xff",
    b'{"x":"' + b"a" * 4096 + b'"}',
]

MULTIPART = (
    b'--b\r\nContent-Type: application/json\r\n\r\n{"_id":"mp","_attachments":{"f":{"content_type":"text/plain","length":3}}}\r\n'
    b'--b\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nabc\r\n--b--\r\n'
)


def request(method, path, body=None, headers=None):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


def main():
    request("PUT", "/fuzz")
    deadline = time.time() + SECONDS
    i = 0
    while time.time() < deadline:
        i += 1
        if CATEGORY == "http":
            path = random.choice(PATHS)
            method = random.choice(["GET", "HEAD", "POST", "PUT", "DELETE"])
            body = b""
            headers = {"content-type": random.choice(["application/json", "text/plain", "multipart/related; boundary=b"])}
        elif CATEGORY == "json":
            path = random.choice(["/fuzz/_bulk_docs", "/fuzz/_bulk_get", "/fuzz/_revs_diff", "/fuzz/_find", "/fuzz/_index", "/fuzz/doc", "/fuzz/_all_docs"])
            method = "POST" if path.split("/")[-1].startswith("_") else "PUT"
            body = random.choice(BODIES)
            headers = {"content-type": "application/json"}
        elif CATEGORY == "multipart":
            path = random.choice(["/fuzz/doc", "/fuzz/doc/att", "/fuzz/_design/f/_view/by_id"])
            method = "PUT" if not path.endswith("_view/by_id") else "GET"
            body = MULTIPART
            headers = {"content-type": "multipart/related; boundary=b"}
        elif CATEGORY == "rev":
            path = random.choice(["/fuzz/doc?rev=1-abc&revs=true", "/fuzz/doc?open_revs=all", "/fuzz/_revs_diff", "/fuzz/_bulk_docs"])
            method = "GET" if "open_revs" in path else "POST"
            body = random.choice([b'{"docs":[{"_id":"a","_rev":"bad"}]}', b'{"missing":["1-zzz","0-1"]}', b'{"_rev":"1-abc","_revisions":{"start":1,"ids":["abc"]}}', b'{"docs":[{"_id":"x","_rev":"1-"}]}'])
            headers = {"content-type": "application/json"}
        else:
            path = random.choice(PATHS)
            method = random.choice(["GET", "HEAD", "POST", "PUT", "DELETE"])
            if path.endswith("_bulk_docs") or path.endswith("_bulk_get") or path.endswith("_revs_diff") or path.endswith("_find") or path.endswith("_index"):
                method = "POST"
            if random.random() < 0.15:
                body = MULTIPART
                headers = {"content-type": "multipart/related; boundary=b"}
            else:
                body = random.choice(BODIES)
                headers = {"content-type": "application/json"}
        try:
            status = request(method, path, body, headers)
        except Exception as e:
            print(f"FAIL: {method} {path} raised {e!r}", file=sys.stderr)
            return 1
        if status >= 600:
            print(f"FAIL: invalid status {status} for {method} {path}", file=sys.stderr)
            return 1
        if i % 50 == 0:
            try:
                if request("GET", "/_up") != 200:
                    print("FAIL: server did not answer /_up", file=sys.stderr)
                    return 1
            except Exception as e:
                print(f"FAIL: server unreachable after {i} cases: {e!r}", file=sys.stderr)
                return 1
    print(f"PASS: {CATEGORY} fuzz: {i} cases, server still healthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
