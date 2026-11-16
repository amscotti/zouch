#!/usr/bin/env python3
"""A CouchDB-shaped source that answers slowly on purpose: N documents, each
document GET delayed by DELAY seconds. Used by pull_concurrency.sh to make a
replication last long enough to measure what else can happen during it."""
import base64, hashlib, json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

N = int(sys.argv[1]) if len(sys.argv) > 1 else 200
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 0.02
# "bad-digest" makes every document carry an attachment whose declared digest
# is not the digest of its data, which the pull must refuse.
MODE = sys.argv[4] if len(sys.argv) > 4 else ""


# Documents served so far. A test that interrupts a pull reads this instead of
# asking the target, because a request can land on the worker running the pull
# and wait for the whole copy.
SERVED = 0
SERVED_LOCK = threading.Lock()


def rev_of(i):
    return "1-" + hashlib.md5(str(i).encode()).hexdigest()


def doc_of(i):
    doc = {"_id": "s%03d" % i, "_rev": rev_of(i), "_revisions": {"start": 1, "ids": [rev_of(i)[2:]]}, "n": i}
    if MODE == "bad-digest":
        doc["_attachments"] = {"a.txt": {
            "content_type": "text/plain",
            "data": base64.b64encode(b"payload").decode(),
            "digest": "md5-" + base64.b64encode(b"\x00" * 16).decode(),
            "length": 7,
            "revpos": 1,
        }}
    return doc


CHANGES = {"results": [{"seq": i + 1, "id": "s%03d" % i, "changes": [{"rev": rev_of(i)}]} for i in range(N)],
           "last_seq": N, "pending": 0}
EMPTY = {"results": [], "last_seq": N, "pending": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global SERVED
        if self.path.startswith("/_stats"):
            with SERVED_LOCK:
                self._json({"served": SERVED})
            return
        if "/_changes" in self.path:
            since = self.path.split("since=")[1].split("&")[0] if "since=" in self.path else "0"
            try:
                start = int(since)
            except ValueError:
                start = 0
            limit = N
            if "limit=" in self.path:
                try:
                    limit = int(self.path.split("limit=")[1].split("&")[0])
                except ValueError:
                    pass
            # Honour both since and limit so a pull walks the feed in pages, the
            # way a real source makes it.
            rows = [row for row in CHANGES["results"] if row["seq"] > start][:limit]
            if not rows:
                self._json(EMPTY)
                return
            self._json({"results": rows, "last_seq": rows[-1]["seq"], "pending": 0})
            return
        for i in range(N):
            if "/s%03d?" % i in self.path:
                time.sleep(DELAY)
                with SERVED_LOCK:
                    SERVED += 1
                self._json(doc_of(i))
                return
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()


port = int(sys.argv[3]) if len(sys.argv) > 3 else 0
server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
