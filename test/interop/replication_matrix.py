#!/usr/bin/env python3
"""Replication interop matrix: Zouch <-> CouchDB, both directions.

Each scenario creates fresh databases on both sides and is torn down at the end.
Run with a built binary present: python3 test/interop/replication_matrix.py
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ZOUCH = os.environ.get("ZOUCH", "http://127.0.0.1:7090")
COUCH = os.environ.get("COUCH", "http://127.0.0.1:5984")
_zouch_parsed = urllib.parse.urlparse(ZOUCH)
_couch_parsed = urllib.parse.urlparse(COUCH)
_use_docker_host = (
    "ZOUCH_FOR_COUCH" not in os.environ
    and sys.platform == "darwin"
    and _zouch_parsed.hostname in ("127.0.0.1", "localhost")
    and _couch_parsed.hostname in ("127.0.0.1", "localhost")
)
ZOUCH_FOR_COUCH = os.environ.get(
    "ZOUCH_FOR_COUCH",
    ("http://host.docker.internal:%d" % (_zouch_parsed.port or 7090)) if _use_docker_host else ZOUCH,
)
AUTH_PAIR = os.environ.get("AUTH", "admin:zouchtestpw")
USER, PASSWORD = AUTH_PAIR.split(":", 1) if ":" in AUTH_PAIR else ("admin", "zouchtestpw")
AUTH = {"authorization": "Basic " + base64.b64encode(("%s:%s" % (USER, PASSWORD)).encode()).decode()}
CRED = COUCH.replace("http://", "http://%s:%s@" % (USER, PASSWORD))
TAG = "zzm" + str(int(time.time()))[-6:]

results = []


def http(method, url, body=None, headers=None, timeout=240, raw=False):
    data = None
    if body is not None:
        data = body if raw else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if body is not None and not raw:
        req.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def couch(method, path, body=None, raw=False):
    return http(method, COUCH + path, body, AUTH, raw=raw)


def z(method, path, body=None):
    return http(method, ZOUCH + path, body)


def j(payload):
    try:
        return json.loads(payload)
    except Exception:
        return {}


def fresh_couch(name):
    couch("DELETE", "/" + name)
    st, b = couch("PUT", "/" + name)
    assert st in (201, 202, 412), "create couch %s -> %d %s" % (name, st, b[:120])
    return name


def fresh_z(name):
    z("DELETE", "/" + name)
    st, b = z("PUT", "/" + name)
    assert st in (201, 202, 412), "create zouch %s -> %d %s" % (name, st, b[:120])
    return name


def put_couch(db, doc_id, fields, attachment=None):
    st, b = couch("PUT", "/%s/%s" % (db, urllib.parse.quote(doc_id, safe="")), fields)
    assert st in (201, 202), "put %s/%s -> %d %s" % (db, doc_id, st, b[:160])
    rev = j(b)["rev"]
    if attachment:
        name, ctype, data = attachment
        st, b = http("PUT", "%s/%s/%s/%s?rev=%s" % (COUCH, db, urllib.parse.quote(doc_id, safe=""),
                                                   urllib.parse.quote(name, safe=""), rev),
                     data, dict(AUTH, **{"content-type": ctype}), raw=True)
        assert st in (201, 202), "attachment %s -> %d %s" % (name, st, b[:160])
        rev = j(b)["rev"]
    return rev


def pull_into(source_url, target):
    st, b = z("POST", "/_replicate", {"source": source_url, "target": target})
    return st, j(b), b


def push_from(source, target_url):
    st, b = z("POST", "/_replicate", {"source": source, "target": target_url})
    return st, j(b), b


def s_couch_drives_push():
    src, tgt = fresh_couch(TAG + "_d1"), fresh_z(TAG + "_t1")
    for i in range(5):
        put_couch(src, "doc%d" % i, {"n": i})
    st, b = couch("POST", "/_replicate", {"source": CRED + "/" + src, "target": ZOUCH_FOR_COUCH + "/" + tgt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:300])
    st, b = z("GET", "/" + tgt)
    assert j(b).get("doc_count") == 5, "target has %s docs" % j(b).get("doc_count")
    st, b = z("GET", "/%s/doc3" % tgt)
    assert j(b).get("n") == 3, "doc3 body wrong: %s" % b[:160]
    return "5 docs, body intact"


def s_couch_drives_pull():
    src, tgt = fresh_z(TAG + "_s2"), fresh_couch(TAG + "_d2")
    for i in range(5):
        st, b = z("PUT", "/%s/doc%d" % (src, i), {"n": i})
        assert st in (201, 202), "zouch put -> %d %s" % (st, b[:120])
    st, b = couch("POST", "/_replicate", {"source": ZOUCH_FOR_COUCH + "/" + src, "target": CRED + "/" + tgt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:300])
    st, b = couch("GET", "/" + tgt)
    assert j(b).get("doc_count") == 5, "couch target has %s docs (rep: %s)" % (j(b).get("doc_count"), b[:300])
    st, b = couch("GET", "/%s/doc3" % tgt)
    assert j(b).get("n") == 3, "doc3 wrong: %s" % b[:160]
    return "5 docs pulled by couchdb"


def s_pull_attachments():
    src, tgt = fresh_couch(TAG + "_d3"), fresh_z(TAG + "_t3")
    text = ("compressible line\n" * 300).encode()
    binary = bytes(range(256)) * 400
    rev = put_couch(src, "att", {"k": "v"}, attachment=("t.txt", "text/plain", text))
    st, b = couch("PUT", "/%s/att/bin.dat?rev=%s" % (src, rev), binary, raw=True)
    assert st in (201, 202), "bin attach -> %d %s" % (st, b[:120])
    st, rep, raw = pull_into(CRED + "/" + src, tgt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    st, b = z("GET", "/%s/att/t.txt" % tgt)
    assert b == text, "text attachment differs (%d vs %d bytes)" % (len(b), len(text))
    st, b = z("GET", "/%s/att/bin.dat" % tgt)
    assert b == binary, "binary attachment differs (%d vs %d)" % (len(b), len(binary))
    st, b = z("GET", "/%s/att" % tgt)
    atts = j(b).get("_attachments", {})
    assert set(atts) == {"t.txt", "bin.dat"}, "attachment names: %s" % list(atts)
    for name, meta in atts.items():
        expected = len(text) if name == "t.txt" else len(binary)
        assert meta.get("length") == expected, "%s length %s != %s" % (name, meta.get("length"), expected)
    return "2 attachments byte-identical"


def s_push_attachments():
    src, tgt = fresh_couch(TAG + "_d4"), fresh_couch(TAG + "_d4b")
    payload = os.urandom(512 * 1024)
    put_couch(src, "big", {"k": "v"}, attachment=("blob.bin", "application/octet-stream", payload))
    zt = fresh_z(TAG + "_t4")
    st, rep, raw = pull_into(CRED + "/" + src, zt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    st, rep, raw = push_from(zt, CRED + "/" + tgt)
    assert st == 200, "push -> %d %s" % (st, raw[:300])
    st, b = couch("GET", "/%s/big/blob.bin" % tgt)
    assert b == payload, "pushed attachment differs (%d vs %d)" % (len(b), len(payload))
    return "512KB attachment round-tripped"


def s_deletions():
    src, tgt = fresh_couch(TAG + "_d5"), fresh_z(TAG + "_t5")
    put_couch(src, "keep", {"k": 1})
    rev = put_couch(src, "kill", {"k": 2})
    couch("DELETE", "/%s/kill?rev=%s" % (src, rev))
    st, rep, raw = pull_into(CRED + "/" + src, tgt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    assert z("GET", "/%s/keep" % tgt)[0] == 200, "keep missing"
    assert z("GET", "/%s/kill" % tgt)[0] == 404, "deleted doc resurrected in zouch"
    rev = j(z("GET", "/%s/keep" % tgt)[1])["_rev"]
    st, b = z("DELETE", "/%s/keep?rev=%s" % (tgt, rev))
    assert st in (200, 202), "zouch delete -> %d %s" % (st, b[:120])
    c2 = fresh_couch(TAG + "_d5b")
    st, rep, raw = push_from(tgt, CRED + "/" + c2)
    assert st == 200, "push -> %d %s" % (st, raw[:300])
    assert couch("GET", "/%s/keep" % c2)[0] == 404, "delete did not reach couchdb"
    return "tombstones both ways"


def make_conflict_couch(db, doc_id="c1"):
    """Two sibling revisions of one document: the only way CouchDB lets a client
    create a conflict, since a PUT against a non-leaf revision is refused."""
    rev = put_couch(db, doc_id, {"v": "base"})
    parent = rev.split("-", 1)[1]
    a, b = "a" * 32, "b" * 32
    st, body = couch("POST", "/%s/_bulk_docs" % db, {"new_edits": False, "docs": [
        {"_id": doc_id, "_rev": "2-" + a, "v": "a", "_revisions": {"start": 2, "ids": [a, parent]}},
        {"_id": doc_id, "_rev": "2-" + b, "v": "b", "_revisions": {"start": 2, "ids": [b, parent]}},
    ]})
    assert st in (201, 202), "conflict bulk -> %d %s" % (st, body[:200])
    return rev


def s_conflicts():
    src = fresh_couch(TAG + "_d6")
    make_conflict_couch(src)
    zt = fresh_z(TAG + "_t6")
    st, rep, raw = pull_into(CRED + "/" + src, zt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    st, b = z("GET", "/%s/c1?conflicts=true" % zt)
    body = j(b)
    assert len(body.get("_conflicts", [])) >= 1, "zouch lost the conflict: %s" % json.dumps(body)[:250]
    c2 = fresh_couch(TAG + "_d6b")
    st, rep, raw = push_from(zt, CRED + "/" + c2)
    assert st == 200, "push -> %d %s" % (st, raw[:300])
    st, b = couch("GET", "/%s/c1?conflicts=true" % c2)
    body = j(b)
    assert len(body.get("_conflicts", [])) >= 1, "conflict lost on push: %s" % json.dumps(body)[:250]
    return "both leaves survive"


def s_history():
    src, tgt = fresh_couch(TAG + "_d7"), fresh_couch(TAG + "_d7b")
    rev = put_couch(src, "h", {"n": 0})
    for i in range(1, 6):
        st, b = couch("PUT", "/%s/h?rev=%s" % (src, rev), {"n": i})
        assert st in (201, 202), "update %d -> %d %s" % (i, st, b[:120])
        rev = j(b)["rev"]
    zt = fresh_z(TAG + "_t7")
    st, rep, raw = pull_into(CRED + "/" + src, zt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    st, rep, raw = push_from(zt, CRED + "/" + tgt)
    assert st == 200, "push -> %d %s" % (st, raw[:300])
    st, b = couch("GET", "/%s/h?revs=true" % tgt)
    body = j(b)
    depth = body.get("_revisions", {}).get("start", 0)
    assert depth >= 6, "history depth is %s (expected 6)" % depth
    assert body.get("_rev") == rev, "revision changed in transit: %s vs %s" % (body.get("_rev"), rev)
    return "6-revision chain intact"


def s_design_docs():
    src, tgt = fresh_couch(TAG + "_d8"), fresh_z(TAG + "_t8")
    st, b = couch("PUT", "/%s/_design/ddoc" % src,
                  {"views": {"v": {"map": "function(doc){emit(doc._id,null)}"}}})
    assert st in (201, 202), "design doc -> %d %s" % (st, b[:120])
    st, rep, raw = pull_into(CRED + "/" + src, tgt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    st, b = z("GET", "/%s/_design/ddoc" % tgt)
    assert st == 200, "design doc missing from zouch: %d %s" % (st, b[:160])
    assert "views" in j(b), "design body lost: %s" % b[:160]
    return "design doc copied"


def s_local_docs():
    src, tgt = fresh_z(TAG + "_s9"), fresh_z(TAG + "_t9")
    z("PUT", "/%s/real" % src, {"k": 1})
    st, b = z("PUT", "/%s/_local/checkpoint" % src, {"since": 5})
    assert st in (201, 202), "put _local -> %d %s" % (st, b[:120])
    st, rep, raw = pull_into(ZOUCH + "/" + src, tgt)
    assert st == 200, "pull -> %d %s" % (st, raw[:300])
    assert z("GET", "/%s/_local/checkpoint" % tgt)[0] == 404, "_local doc replicated"
    return "_local stayed local"


def s_odd_ids():
    src, tgt = fresh_z(TAG + "_s10"), fresh_couch(TAG + "_d10")
    ids = ["with space", "with/slash", "ünïcode-ñame", "percent%25", "dots.and-dashes_1"]
    for i, doc_id in enumerate(ids):
        st, b = z("PUT", "/%s/%s" % (src, urllib.parse.quote(doc_id, safe="")), {"i": i})
        assert st in (201, 202), "put %r -> %d %s" % (doc_id, st, b[:120])
    st, rep, raw = push_from(src, CRED + "/" + tgt)
    assert st == 200, "push -> %d %s" % (st, raw[:300])
    st, b = couch("GET", "/" + tgt)
    assert j(b).get("doc_count") == len(ids), "couchdb has %s docs, expected %d" % (j(b).get("doc_count"), len(ids))
    for doc_id in ids:
        st, b = couch("GET", "/%s/%s" % (tgt, urllib.parse.quote(doc_id, safe="")))
        assert st == 200, "missing %r on couchdb: %d %s" % (doc_id, st, b[:120])
    return "%d odd ids round-tripped" % len(ids)


def s_bulk():
    src, mid, tgt = fresh_couch(TAG + "_d11"), fresh_z(TAG + "_t11"), fresh_couch(TAG + "_d11b")
    docs = [{"_id": "b%04d" % i, "n": i, "pad": "x" * 100} for i in range(1000)]
    for start in range(0, 1000, 250):
        st, b = couch("POST", "/%s/_bulk_docs" % src, {"docs": docs[start:start + 250]})
        assert st in (201, 202), "bulk -> %d %s" % (st, b[:120])
    st, rep, raw = pull_into(CRED + "/" + src, mid)
    assert rep.get("documents") == 1000, "pull copied %s docs (%s)" % (rep.get("documents"), raw[:200])
    assert j(z("GET", "/" + mid)[1]).get("doc_count") == 1000, "zouch doc_count wrong"
    st, rep, raw = push_from(mid, CRED + "/" + tgt)
    assert rep.get("documents") == 1000, "push copied %s docs (%s)" % (rep.get("documents"), raw[:200])
    assert j(couch("GET", "/" + tgt)[1]).get("doc_count") == 1000, "couch doc_count wrong"
    st, b = couch("GET", "/%s/b0500" % tgt)
    assert j(b).get("n") == 500, "spot check failed: %s" % b[:120]
    return "1000 docs each way"


def s_checkpoints():
    src, tgt = fresh_couch(TAG + "_d12"), fresh_z(TAG + "_t12")
    for i in range(20):
        put_couch(src, "cp%d" % i, {"n": i})
    st, rep, _ = pull_into(CRED + "/" + src, tgt)
    assert rep.get("documents") == 20, "first pull: %s" % rep
    st, rep, _ = pull_into(CRED + "/" + src, tgt)
    assert rep.get("documents") == 0, "repeat pulled %s" % rep
    put_couch(src, "cp_new", {"n": 99})
    st, rep, _ = pull_into(CRED + "/" + src, tgt)
    assert rep.get("documents") == 1, "incremental pulled %s" % rep
    return "20 then 0 then 1"


def s_continuous():
    src, tgt = fresh_couch(TAG + "_d13"), fresh_z(TAG + "_t13")
    put_couch(src, "first", {"n": 1})
    # A replication document may not name a local endpoint - CouchDB refuses it
    # and so does zouch - so a continuous job into a local database is started
    # through the transient API.
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt, "continuous": True})
    assert st in (200, 202), "continuous job -> %d %s" % (st, b[:160])
    deadline = time.time() + 25
    while time.time() < deadline and z("GET", "/%s/first" % tgt)[0] != 200:
        time.sleep(0.5)
    assert z("GET", "/%s/first" % tgt)[0] == 200, "continuous job never copied the first doc"
    put_couch(src, "second", {"n": 2})
    deadline = time.time() + 25
    while time.time() < deadline and z("GET", "/%s/second" % tgt)[0] != 200:
        time.sleep(0.5)
    assert z("GET", "/%s/second" % tgt)[0] == 200, "continuous job missed a later document"
    return "continuous picked up a later write"


def s_couch_drives_attachments():
    src, tgt = fresh_couch(TAG + "_d14"), fresh_z(TAG + "_t14")
    payload = os.urandom(256 * 1024)
    text = ("line\n" * 500).encode()
    rev = put_couch(src, "a1", {"k": 1}, attachment=("bin.dat", "application/octet-stream", payload))
    st, b = couch("PUT", "/%s/a1/t.txt?rev=%s" % (src, rev), text, raw=True)
    assert st in (201, 202), "text attach -> %d" % st
    st, b = couch("POST", "/_replicate", {"source": CRED + "/" + src, "target": ZOUCH_FOR_COUCH + "/" + tgt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:250])
    st, b = z("GET", "/%s/a1/bin.dat" % tgt)
    assert b == payload, "binary attachment differs after couchdb-driven push (%d vs %d)" % (len(b), len(payload))
    st, b = z("GET", "/%s/a1/t.txt" % tgt)
    assert b == text, "text attachment differs after couchdb-driven push (%d vs %d)" % (len(b), len(text))
    return "couchdb pushed 2 attachments into zouch"


def s_couch_drives_attachments_out():
    src, tgt = fresh_z(TAG + "_s15"), fresh_couch(TAG + "_d15")
    payload = os.urandom(128 * 1024)
    st, b = z("PUT", "/%s/z1" % src, {"k": 1})
    assert st in (201, 202), "zouch put -> %d %s" % (st, b[:120])
    rev = j(z("GET", "/%s/z1" % src)[1])["_rev"]
    st, b = http("PUT", "%s/%s/z1/blob.bin?rev=%s" % (ZOUCH, src, rev), payload,
                 {"content-type": "application/octet-stream"}, raw=True)
    assert st in (201, 202), "zouch attachment -> %d %s" % (st, b[:160])
    st, b = couch("POST", "/_replicate", {"source": ZOUCH_FOR_COUCH + "/" + src, "target": CRED + "/" + tgt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:300])
    st, b = couch("GET", "/%s/z1/blob.bin" % tgt)
    assert b == payload, "attachment differs after couchdb-driven pull (%d vs %d)" % (len(b), len(payload))
    st, b = couch("GET", "/%s/z1" % tgt)
    meta = j(b).get("_attachments", {}).get("blob.bin", {})
    assert meta.get("length") == len(payload), "couchdb recorded length %s" % meta.get("length")
    assert meta.get("digest"), "couchdb stored no digest"
    return "couchdb pulled a 128KB attachment out of zouch"


def s_couch_drives_deletes():
    src, tgt = fresh_couch(TAG + "_d16"), fresh_z(TAG + "_t16")
    put_couch(src, "stay", {"k": 1})
    rev = put_couch(src, "bye", {"k": 2})
    couch("DELETE", "/%s/bye?rev=%s" % (src, rev))
    st, b = couch("POST", "/_replicate", {"source": CRED + "/" + src, "target": ZOUCH_FOR_COUCH + "/" + tgt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:250])
    assert z("GET", "/%s/stay" % tgt)[0] == 200, "live doc missing"
    assert z("GET", "/%s/bye" % tgt)[0] == 404, "deletion did not arrive through couchdb"
    return "tombstone travelled with couchdb driving"


def s_couch_drives_conflicts():
    src = fresh_couch(TAG + "_d17")
    make_conflict_couch(src, "k1")
    zt = fresh_z(TAG + "_t17")
    st, b = couch("POST", "/_replicate", {"source": CRED + "/" + src, "target": ZOUCH_FOR_COUCH + "/" + zt})
    assert st in (200, 202), "couch replicate -> %d %s" % (st, b[:300])
    st, b = z("GET", "/%s/k1?conflicts=true" % zt)
    body = j(b)
    assert len(body.get("_conflicts", [])) >= 1, "conflict lost when couchdb pushed: %s" % json.dumps(body)[:250]
    return "conflict arrived from couchdb"


def s_couch_continuous_from_zouch():
    src, tgt = fresh_z(TAG + "_s18"), fresh_couch(TAG + "_d18")
    z("PUT", "/%s/first" % src, {"n": 1})
    st, b = couch("POST", "/_replicate", {
        "source": ZOUCH_FOR_COUCH + "/" + src,
        "target": CRED + "/" + tgt,
        "continuous": True,
    })
    assert st in (200, 202), "continuous start -> %d %s" % (st, b[:300])
    deadline = time.time() + 20
    while time.time() < deadline and couch("GET", "/%s/first" % tgt)[0] != 200:
        time.sleep(0.5)
    assert couch("GET", "/%s/first" % tgt)[0] == 200, "couchdb never saw the first document"
    z("PUT", "/%s/second" % src, {"n": 2})
    # Zouch hands a new change to an open feed in about 45ms (measured), but
    # CouchDB's replicator only asks again after its own longpoll timeout, which
    # is 25s, so a fixed 25s window raced it and failed about one run in three.
    deadline = time.time() + 40
    while time.time() < deadline and couch("GET", "/%s/second" % tgt)[0] != 200:
        time.sleep(0.5)
    assert couch("GET", "/%s/second" % tgt)[0] == 200, (
        "couchdb's continuous feed from zouch missed a later write")
    return "couchdb held a continuous feed from zouch and saw a later write"


def s_doc_ids():
    src, tgt = fresh_couch(TAG + "_d19"), fresh_z(TAG + "_t19")
    for i in range(5):
        put_couch(src, "d%d" % i, {"n": i})
    st, raw = z("POST", "/_replicate", {
        "source": CRED + "/" + src, "target": tgt, "doc_ids": ["d1", "d3"]})
    rep = j(raw)
    assert st == 200, "doc_ids pull -> %d %s" % (st, raw[:250])
    assert rep.get("documents") == 2, "copied %s documents, expected 2" % rep.get("documents")
    assert j(z("GET", "/" + tgt)[1]).get("doc_count") == 2, "target holds %s docs" % j(z("GET", "/" + tgt)[1]).get("doc_count")
    assert z("GET", "/%s/d1" % tgt)[0] == 200, "requested document missing"
    assert z("GET", "/%s/d0" % tgt)[0] == 404, "document outside doc_ids was copied"

    zsrc, ctgt = fresh_z(TAG + "_s19"), fresh_couch(TAG + "_d19b")
    for i in range(5):
        z("PUT", "/%s/p%d" % (zsrc, i), {"n": i})
    st, raw = z("POST", "/_replicate", {
        "source": zsrc, "target": CRED + "/" + ctgt, "doc_ids": ["p2", "p4"]})
    rep = j(raw)
    assert st == 200, "doc_ids push -> %d %s" % (st, raw[:250])
    assert rep.get("documents") == 2, "pushed %s documents, expected 2" % rep.get("documents")
    assert j(couch("GET", "/" + ctgt)[1]).get("doc_count") == 2, "couch target holds %s docs" % j(couch("GET", "/" + ctgt)[1]).get("doc_count")

    lsrc, ltgt = fresh_z(TAG + "_s19c"), fresh_z(TAG + "_t19c")
    for i in range(4):
        z("PUT", "/%s/q%d" % (lsrc, i), {"n": i})
    st, raw = z("POST", "/_replicate", {
        "source": lsrc, "target": ltgt, "doc_ids": ["q1"]})
    rep = j(raw)
    assert st == 200, "doc_ids local -> %d %s" % (st, raw[:250])
    assert j(z("GET", "/" + ltgt)[1]).get("doc_count") == 1, "local doc_ids copied %s docs" % j(z("GET", "/" + ltgt)[1]).get("doc_count")
    return "doc_ids honoured for pull, push and local copy"


def s_replicate_options_refused():
    src, tgt = fresh_couch(TAG + "_d20"), fresh_z(TAG + "_t20")
    put_couch(src, "x", {"n": 1})
    for body, expect in (
        ({"source": CRED + "/" + src, "target": tgt, "selector": {"n": {"$bogus": 1}}}, "invalid_operator"),
        ({"source": CRED + "/" + src, "target": tgt, "doc_ids": "nope"}, "bad_request"),
        ({"source": CRED + "/" + src, "target": tgt, "since_seq": [1]}, "bad_request"),
    ):
        st, b = z("POST", "/_replicate", body)
        assert st == 400, "%s -> %d %s" % (list(body), st, b[:200])
        assert j(b).get("error") == expect, "%s -> %s" % (list(body), b[:200])
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                      "doc_ids": ["x"], "selector": {"n": {"$gt": 0}}})
    assert st == 400 and j(b).get("error") == "bad_request", "doc_ids+selector -> %d %s" % (st, b[:160])
    # a filter that does not exist on a local source is a 404, not a silent full copy
    st, b = z("POST", "/_replicate", {"source": tgt, "target": CRED + "/" + src, "filter": "ddoc/f"})
    assert st == 404 and j(b).get("error") == "not_found", "missing filter -> %d %s" % (st, b[:160])
    return "unsupported or missing options answer 400/404 instead of copying everything"


def s_couch_drives_doc_ids():
    src, tgt = fresh_z(TAG + "_s21"), fresh_couch(TAG + "_d21")
    for i in range(3):
        z("PUT", "/%s/f%d" % (src, i), {"n": i})
    st, b = couch("POST", "/_replicate", {
        "source": ZOUCH_FOR_COUCH + "/" + src, "target": CRED + "/" + tgt, "doc_ids": ["f1"]})
    assert st in (200, 202), "couch replicate with doc_ids -> %d %s" % (st, b[:300])
    assert "error" not in j(b), "couchdb rejected the filtered pull: %s" % b[:300]
    deadline = time.time() + 20
    while time.time() < deadline and j(couch("GET", "/" + tgt)[1]).get("doc_count") != 1:
        time.sleep(0.5)
    assert j(couch("GET", "/" + tgt)[1]).get("doc_count") == 1, "couchdb got %s docs" % j(couch("GET", "/" + tgt)[1]).get("doc_count")
    assert couch("GET", "/%s/f1" % tgt)[0] == 200, "requested doc missing"
    assert couch("GET", "/%s/f0" % tgt)[0] == 404, "doc outside doc_ids copied"
    return "couchdb drove a doc_ids pull from zouch"


def s_changes_doc_ids_filter():
    src = fresh_z(TAG + "_s22")
    for i in range(4):
        z("PUT", "/%s/c%d" % (src, i), {"n": i})
    st, b = http("POST", ZOUCH + "/%s/_changes?filter=_doc_ids" % src,
                 {"doc_ids": ["c1", "c3"]}, {"content-type": "application/json"})
    assert st == 200, "post _changes -> %d %s" % (st, b[:200])
    ids = [row.get("id") for row in j(b).get("results", [])]
    assert ids == ["c1", "c3"], "filtered feed returned %s" % ids
    st, b = z("GET", "/%s/_changes?filter=_doc_ids" % src)
    assert st == 400, "GET without a body should be refused, got %d" % st
    return "POST _changes?filter=_doc_ids selects by id"


def s_selector():
    src, tgt = fresh_couch(TAG + "_d23"), fresh_z(TAG + "_t23")
    for i in range(5):
        put_couch(src, "s%d" % i, {"n": i})
    st, raw = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                        "selector": {"n": {"$gte": 3}}})
    assert st == 200, "selector pull -> %d %s" % (st, raw[:250])
    assert j(z("GET", "/" + tgt)[1]).get("doc_count") == 2, "selector pull copied %s docs" % j(z("GET", "/" + tgt)[1]).get("doc_count")
    assert z("GET", "/%s/s4" % tgt)[0] == 200, "matching doc missing"
    assert z("GET", "/%s/s0" % tgt)[0] == 404, "non-matching doc copied"

    zsrc, ctgt = fresh_z(TAG + "_s23"), fresh_couch(TAG + "_d23b")
    for i in range(5):
        z("PUT", "/%s/p%d" % (zsrc, i), {"n": i})
    st, raw = z("POST", "/_replicate", {"source": zsrc, "target": CRED + "/" + ctgt,
                                        "selector": {"n": {"$lt": 2}}})
    assert st == 200, "selector push -> %d %s" % (st, raw[:250])
    assert j(couch("GET", "/" + ctgt)[1]).get("doc_count") == 2, "selector push wrote %s docs" % j(couch("GET", "/" + ctgt)[1]).get("doc_count")

    c2 = fresh_couch(TAG + "_d23c")
    st, b = couch("POST", "/_replicate", {"source": ZOUCH_FOR_COUCH + "/" + zsrc, "target": CRED + "/" + c2,
                                          "selector": {"n": {"$eq": 3}}})
    assert st in (200, 202), "couch selector replicate -> %d %s" % (st, b[:300])
    deadline = time.time() + 20
    while time.time() < deadline and j(couch("GET", "/" + c2)[1]).get("doc_count") != 1:
        time.sleep(0.5)
    assert j(couch("GET", "/" + c2)[1]).get("doc_count") == 1, "couchdb selector pull got %s docs" % j(couch("GET", "/" + c2)[1]).get("doc_count")
    st, b = z("GET", "/%s/p3" % zsrc)
    assert st == 200
    return "selector honoured for pull, push and couchdb-driven pull"


def s_changes_selector_filter():
    src = fresh_z(TAG + "_s24")
    for i in range(4):
        z("PUT", "/%s/v%d" % (src, i), {"n": i})
    st, b = http("POST", ZOUCH + "/%s/_changes?filter=_selector" % src,
                 {"selector": {"n": {"$gt": 1}}}, {"content-type": "application/json"})
    assert st == 200, "post _changes selector -> %d %s" % (st, b[:200])
    ids = [row.get("id") for row in j(b).get("results", [])]
    assert ids == ["v2", "v3"], "selector feed returned %s" % ids
    return "POST _changes?filter=_selector matches like _find"


def s_continuous_selection():
    src, tgt = fresh_couch(TAG + "_d28"), fresh_z(TAG + "_t28")
    for i in range(4):
        put_couch(src, "d%d" % i, {"n": i})
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                      "continuous": True, "doc_ids": ["d1", "d3"]})
    assert st == 202, "continuous doc_ids -> %d %s" % (st, b[:200])
    job = j(b)["_local_id"]
    deadline = time.time() + 25
    while time.time() < deadline and j(z("GET", "/" + tgt)[1]).get("doc_count") != 2:
        time.sleep(0.5)
    count = j(z("GET", "/" + tgt)[1]).get("doc_count")
    assert count == 2, "continuous doc_ids copied %s docs, expected 2" % count
    put_couch(src, "d4", {"n": 4})
    time.sleep(6)
    assert z("GET", "/%s/d4" % tgt)[0] == 404, "a document outside doc_ids arrived"
    # The selection applies to later writes to a selected document too.
    rev = j(z("GET", "/%s/d1" % tgt)[1])["_rev"]
    assert z("GET", "/%s/d1" % tgt)[0] == 200
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                      "continuous": True, "doc_ids": ["d1", "d3"], "cancel": True})
    assert st == 200, "cancel -> %d" % st

    s2, t2 = fresh_couch(TAG + "_d28b"), fresh_z(TAG + "_t28b")
    for i in range(6):
        put_couch(s2, "q%d" % i, {"n": i})
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + s2, "target": t2,
                                      "continuous": True, "selector": {"n": {"$gte": 4}}})
    assert st == 202, "continuous selector -> %d %s" % (st, b[:200])
    deadline = time.time() + 25
    while time.time() < deadline and j(z("GET", "/" + t2)[1]).get("doc_count") != 2:
        time.sleep(0.5)
    count = j(z("GET", "/" + t2)[1]).get("doc_count")
    assert count == 2, "a continuous selector copied %s docs, expected the 2 matching ones" % count
    z("POST", "/_replicate", {"source": CRED + "/" + s2, "target": t2,
                              "continuous": True, "selector": {"n": {"$gte": 4}}, "cancel": True})
    return "continuous jobs honour doc_ids and selector"


def s_continuous_cancel():
    src, tgt = fresh_couch(TAG + "_d27"), fresh_z(TAG + "_t27")
    put_couch(src, "one", {"n": 1})
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt, "continuous": True})
    body = j(b)
    assert st == 202, "continuous start -> %d %s" % (st, b[:200])
    job = body.get("_local_id")
    assert job, "no _local_id: %s" % b[:200]
    deadline = time.time() + 20
    while time.time() < deadline and z("GET", "/%s/one" % tgt)[0] != 200:
        time.sleep(0.5)
    assert z("GET", "/%s/one" % tgt)[0] == 200, "the job never copied"
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                      "continuous": True, "cancel": True})
    assert st == 200 and j(b).get("ok") is True, "cancel -> %d %s" % (st, b[:200])
    st, b = z("GET", "/_replicator/" + job)
    assert st == 404 or j(b).get("_deleted"), "job still present after cancel: %d %s" % (st, b[:160])
    # A write after the cancel must not arrive.
    put_couch(src, "two", {"n": 2})
    time.sleep(4)
    assert z("GET", "/%s/two" % tgt)[0] == 404, "a cancelled job kept replicating"
    st, b = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": tgt,
                                      "continuous": True, "cancel": True})
    assert st == 404, "cancelling twice should say not_found, got %d" % st
    return "continuous job created, cancelled and stopped"


def s_since_seq():
    src = fresh_couch(TAG + "_d25")
    put_couch(src, "a", {"n": 1})
    put_couch(src, "b", {"n": 2})
    first = fresh_z(TAG + "_t25a")
    st, raw = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": first})
    rep = j(raw)
    assert st == 200, "pull -> %d %s" % (st, raw[:200])
    seq = rep.get("source_last_seq")
    assert seq, "the response carried no source_last_seq: %s" % raw[:250]
    for i in range(3):
        put_couch(src, "c%d" % i, {"n": i})
    second = fresh_z(TAG + "_t25b")
    st, raw = z("POST", "/_replicate", {"source": CRED + "/" + src, "target": second, "since_seq": seq})
    assert st == 200, "since_seq pull -> %d %s" % (st, raw[:250])
    count = j(z("GET", "/" + second)[1]).get("doc_count")
    assert count == 3, "since_seq copied %s docs, expected the 3 newer ones" % count
    return "since_seq started at the given sequence"


def s_filter_push():
    zsrc, ctgt = fresh_z(TAG + "_s26"), fresh_couch(TAG + "_d26")
    st, b = z("PUT", "/%s/_design/f" % zsrc,
              {"filters": {"ok": "function(doc){ return doc.keep === true; }"}})
    assert st in (201, 202), "design doc -> %d %s" % (st, b[:160])
    for i in range(3):
        z("PUT", "/%s/k%d" % (zsrc, i), {"keep": True, "n": i})
    for i in range(2):
        z("PUT", "/%s/x%d" % (zsrc, i), {"keep": False, "n": i})
    st, raw = z("POST", "/_replicate", {"source": zsrc, "target": CRED + "/" + ctgt, "filter": "f/ok"})
    assert st == 200, "filtered push -> %d %s" % (st, raw[:250])
    count = j(couch("GET", "/" + ctgt)[1]).get("doc_count")
    assert count == 3, "filtered push wrote %s docs, expected 3" % count
    return "a design-doc filter selected what a push copied"


SCENARIOS = [
    ("couchdb drives: push into zouch", s_couch_drives_push),
    ("couchdb drives: pull from zouch", s_couch_drives_pull),
    ("zouch pull: attachments", s_pull_attachments),
    ("zouch push: attachments", s_push_attachments),
    ("deletions both ways", s_deletions),
    ("conflicts both ways", s_conflicts),
    ("revision history", s_history),
    ("design documents", s_design_docs),
    ("local docs stay local", s_local_docs),
    ("odd document ids", s_odd_ids),
    ("bulk 1000 both ways", s_bulk),
    ("checkpoints", s_checkpoints),
    ("continuous job", s_continuous),
    ("couchdb drives: attachments in", s_couch_drives_attachments),
    ("couchdb drives: attachments out", s_couch_drives_attachments_out),
    ("couchdb drives: deletes", s_couch_drives_deletes),
    ("couchdb drives: conflicts", s_couch_drives_conflicts),
    ("couchdb continuous from zouch", s_couch_continuous_from_zouch),
    ("doc_ids narrowing", s_doc_ids),
    ("unsupported options refused", s_replicate_options_refused),
    ("couchdb drives: doc_ids", s_couch_drives_doc_ids),
    ("changes _doc_ids filter", s_changes_doc_ids_filter),
    ("selector narrowing", s_selector),
    ("changes _selector filter", s_changes_selector_filter),
    ("since_seq start", s_since_seq),
    ("filter on a push", s_filter_push),
    ("continuous cancel", s_continuous_cancel),
    ("continuous selection", s_continuous_selection),
]


def main():
    port = ZOUCH.rsplit(":", 1)[1]
    data = "/tmp/interop-" + TAG
    bin_path = os.environ.get("ZOUCH_BIN", "./zig-out/bin/zouch")
    bind_args = ["0.0.0.0"] if ZOUCH_FOR_COUCH != ZOUCH else []
    proc = subprocess.Popen([bin_path, "serve", data, port] + bind_args,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            if http("GET", ZOUCH + "/_up", timeout=2)[0] == 200:
                break
        except Exception:
            time.sleep(0.1)
    print("zouch=%s couch=%s tag=%s\n" % (ZOUCH, COUCH, TAG), flush=True)
    failures = 0
    try:
        for name, fn in SCENARIOS:
            t0 = time.time()
            try:
                detail = fn() or ""
                state = "PASS"
            except AssertionError as e:
                detail, state = str(e), "FAIL"
                failures += 1
            except Exception as e:  # noqa: BLE001
                detail, state = "%s: %s" % (type(e).__name__, e), "ERROR"
                failures += 1
            print("%-32s %-5s %6.1fs  %s" % (name, state, time.time() - t0, detail[:150]), flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        subprocess.run(["rm", "-rf", data])
        rc, out = couch("GET", "/_all_dbs")
        for db in j(out):
            if isinstance(db, str) and db.startswith(TAG):
                couch("DELETE", "/" + db)
    print("\n%d/%d scenarios passed" % (len(SCENARIOS) - failures, len(SCENARIOS)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
