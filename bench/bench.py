#!/usr/bin/env python3
"""Reproducible benchmark suite for Zouch (and optionally CouchDB).

Uses Python 3 standard library only.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import datetime
import http.client
import json
import os
import platform
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse


SCALES = {
    "small": {
        "put_seq": 200,
        "put_conc": 400,
        "get_seq": 200,
        "get_conc": 400,
        "bulk_batches": 20,
        "bulk_size": 100,
        "all_docs_iters": 15,
        "changes_iters": 15,
        "mango_scan_iters": 15,
        "mango_index_iters": 20,
        "view_warm_iters": 25,
        "replicate_docs": 500,
    },
    "medium": {
        "put_seq": 1000,
        "put_conc": 2000,
        "get_seq": 1000,
        "get_conc": 2000,
        "bulk_batches": 100,
        "bulk_size": 100,
        "all_docs_iters": 40,
        "changes_iters": 40,
        "mango_scan_iters": 40,
        "mango_index_iters": 60,
        "view_warm_iters": 80,
        "replicate_docs": 2000,
    },
}


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def summarize(latencies_ms, total_ms, ops, docs=None):
    s = sorted(latencies_ms)
    total_s = max(total_ms / 1000.0, 1e-9)
    res = {
        "ops": ops,
        "total_ms": round(total_ms, 2),
        "ops_per_sec": round(ops / total_s, 1),
        "p50_ms": round(percentile(s, 50), 2),
        "p95_ms": round(percentile(s, 95), 2),
        "p99_ms": round(percentile(s, 99), 2),
        "mean_ms": round(statistics.mean(s), 2) if s else 0.0,
    }
    if docs is not None:
        res["docs"] = docs
        res["docs_per_sec"] = round(docs / total_s, 1)
    return res


class Client:
    """Thread-safe HTTP client with per-thread keep-alive connections."""

    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")
        p = urllib.parse.urlparse(self.base_url)
        self.scheme = p.scheme or "http"
        self.host = p.hostname or "127.0.0.1"
        self.port = p.port or (443 if self.scheme == "https" else 80)
        self.base_path = p.path.rstrip("/")
        self.auth_header = None
        if p.username is not None:
            pair = f"{p.username}:{p.password or ''}".encode()
            self.auth_header = "Basic " + base64.b64encode(pair).decode()
        self._local = threading.local()

    def _conn(self):
        conn = getattr(self._local, "conn", None)
        if conn is None:
            cls = (
                http.client.HTTPSConnection
                if self.scheme == "https"
                else http.client.HTTPConnection
            )
            conn = cls(self.host, self.port, timeout=120)
            self._local.conn = conn
        return conn

    def _reset_conn(self):
        conn = getattr(self._local, "conn", None)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
            self._local.conn = None

    def request(self, method, path, body=None, expect=None):
        full_path = self.base_path + path
        headers = {}
        data = None
        if body is not None:
            data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
            headers["Content-Type"] = "application/json"
        if self.auth_header:
            headers["Authorization"] = self.auth_header

        for attempt in range(2):
            conn = self._conn()
            try:
                conn.request(method, full_path, body=data, headers=headers)
                resp = conn.getresponse()
                raw = resp.read()
                if expect is not None and resp.status not in expect:
                    raise RuntimeError(
                        f"{method} {path} -> HTTP {resp.status}: {raw[:200]!r}"
                    )
                return resp.status, raw
            except (http.client.HTTPException, OSError):
                self._reset_conn()
                if attempt == 1:
                    raise

    def reset_db(self, name):
        self.request("DELETE", f"/{name}")
        self.request("PUT", f"/{name}", expect=(201, 202))

    def delete_db(self, name):
        self.request("DELETE", f"/{name}")


def make_doc(i):
    return {
        "_id": f"doc_{i:06d}",
        "cat": f"c{i % 10}",
        "n": i,
        "flag": (i % 2 == 0),
        "payload": "x" * 64,
    }


def run_workloads(client, cfg, threads, is_couch=False, couch_self_url=None):
    results = {}
    tag = f"bench_{int(time.time())}"
    seq_db = f"{tag}_seq"
    conc_db = f"{tag}_conc"
    bulk_db = f"{tag}_bulk"
    rep_src = f"{tag}_rsrc"
    rep_tgt = f"{tag}_rtgt"
    created_dbs = [seq_db, conc_db, bulk_db, rep_src, rep_tgt]

    try:
        # 1. put_seq
        client.reset_db(seq_db)
        lats = []
        t0 = time.perf_counter()
        for i in range(cfg["put_seq"]):
            s = time.perf_counter()
            client.request("PUT", f"/{seq_db}/doc_{i:06d}", make_doc(i), expect=(201, 202))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["put_seq"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["put_seq"], cfg["put_seq"])

        # 2. put_conc
        client.reset_db(conc_db)
        def put_one(i):
            s = time.perf_counter()
            client.request("PUT", f"/{conc_db}/doc_{i:06d}", make_doc(i), expect=(201, 202))
            return (time.perf_counter() - s) * 1000.0

        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=threads) as ex:
            lats = list(ex.map(put_one, range(cfg["put_conc"])))
        results["put_conc"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["put_conc"], cfg["put_conc"])

        # 3. get_seq
        lats = []
        t0 = time.perf_counter()
        for i in range(cfg["get_seq"]):
            doc_id = f"doc_{i % cfg['put_seq']:06d}"
            s = time.perf_counter()
            client.request("GET", f"/{seq_db}/{doc_id}", expect=(200,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["get_seq"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["get_seq"])

        # 4. get_conc
        def get_one(i):
            doc_id = f"doc_{i % cfg['put_conc']:06d}"
            s = time.perf_counter()
            client.request("GET", f"/{conc_db}/{doc_id}", expect=(200,))
            return (time.perf_counter() - s) * 1000.0

        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=threads) as ex:
            lats = list(ex.map(get_one, range(cfg["get_conc"])))
        results["get_conc"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["get_conc"])

        # 5. bulk_docs
        client.reset_db(bulk_db)
        lats = []
        bsize = cfg["bulk_size"]
        total_bulk = cfg["bulk_batches"] * bsize
        t0 = time.perf_counter()
        for b in range(cfg["bulk_batches"]):
            docs = [make_doc(b * bsize + j) for j in range(bsize)]
            s = time.perf_counter()
            client.request("POST", f"/{bulk_db}/_bulk_docs", {"docs": docs}, expect=(201,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["bulk_docs"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["bulk_batches"], total_bulk)

        # 6. all_docs
        lats = []
        t0 = time.perf_counter()
        for _ in range(cfg["all_docs_iters"]):
            s = time.perf_counter()
            client.request("GET", f"/{bulk_db}/_all_docs?include_docs=true", expect=(200,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["all_docs"] = summarize(
            lats,
            (time.perf_counter() - t0) * 1000.0,
            cfg["all_docs_iters"],
            cfg["all_docs_iters"] * total_bulk,
        )

        # 7. changes
        lats = []
        t0 = time.perf_counter()
        for _ in range(cfg["changes_iters"]):
            s = time.perf_counter()
            client.request("GET", f"/{bulk_db}/_changes", expect=(200,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["changes"] = summarize(
            lats,
            (time.perf_counter() - t0) * 1000.0,
            cfg["changes_iters"],
            cfg["changes_iters"] * total_bulk,
        )

        # 8. mango_scan (no index)
        scan_query = {"selector": {"cat": "c3", "n": {"$gte": 50}}, "limit": 50}
        lats = []
        t0 = time.perf_counter()
        for _ in range(cfg["mango_scan_iters"]):
            s = time.perf_counter()
            client.request("POST", f"/{bulk_db}/_find", scan_query, expect=(200,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["mango_scan"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["mango_scan_iters"])

        # 9. mango_index (create index + indexed queries)
        idx_lats = []
        t0 = time.perf_counter()
        s = time.perf_counter()
        client.request(
            "POST",
            f"/{bulk_db}/_index",
            {"index": {"fields": ["cat", "n"]}, "ddoc": "bench_idx", "name": "cat_n"},
            expect=(200,),
        )
        idx_lats.append((time.perf_counter() - s) * 1000.0)
        idx_query = {
            "selector": {"cat": "c3", "n": {"$gte": 50}},
            "use_index": ["bench_idx", "cat_n"],
            "limit": 50,
        }
        for _ in range(cfg["mango_index_iters"]):
            s = time.perf_counter()
            client.request("POST", f"/{bulk_db}/_find", idx_query, expect=(200,))
            idx_lats.append((time.perf_counter() - s) * 1000.0)
        results["mango_index"] = summarize(
            idx_lats, (time.perf_counter() - t0) * 1000.0, 1 + cfg["mango_index_iters"]
        )

        # 10. view_cold & 11. view_warm
        ddoc = {
            "views": {
                "by_cat": {
                    "map": "function(doc) { if (doc.cat) emit(doc.cat, doc.n); }"
                }
            }
        }
        client.request("PUT", f"/{bulk_db}/_design/bench", ddoc, expect=(201, 202))
        t0 = time.perf_counter()
        client.request("GET", f"/{bulk_db}/_design/bench/_view/by_cat?key=%22c3%22&limit=50", expect=(200,))
        cold_ms = (time.perf_counter() - t0) * 1000.0
        results["view_cold"] = summarize([cold_ms], cold_ms, 1, total_bulk)

        lats = []
        t0 = time.perf_counter()
        for _ in range(cfg["view_warm_iters"]):
            s = time.perf_counter()
            client.request("GET", f"/{bulk_db}/_design/bench/_view/by_cat?key=%22c3%22&limit=50", expect=(200,))
            lats.append((time.perf_counter() - s) * 1000.0)
        results["view_warm"] = summarize(lats, (time.perf_counter() - t0) * 1000.0, cfg["view_warm_iters"])

        # 12. replicate_local
        client.reset_db(rep_src)
        client.reset_db(rep_tgt)
        rep_n = cfg["replicate_docs"]
        for b in range(0, rep_n, 100):
            docs = [make_doc(b + j) for j in range(min(100, rep_n - b))]
            client.request("POST", f"/{rep_src}/_bulk_docs", {"docs": docs}, expect=(201,))
        if is_couch:
            self_base = (couch_self_url or client.base_url).rstrip("/")
            src_ref = f"{self_base}/{rep_src}"
            tgt_ref = f"{self_base}/{rep_tgt}"
        else:
            src_ref = rep_src
            tgt_ref = rep_tgt
        t0 = time.perf_counter()
        client.request("POST", "/_replicate", {"source": src_ref, "target": tgt_ref}, expect=(200,))
        rep_ms = (time.perf_counter() - t0) * 1000.0
        results["replicate_local"] = summarize([rep_ms], rep_ms, 1, rep_n)
    finally:
        for db in created_dbs:
            client.delete_db(db)

    return results


def run_cross_replication(zouch_client, couch_client, cfg):
    results = {}
    tag = f"benchx_{int(time.time())}"
    c_src = f"{tag}_csrc"
    z_tgt = f"{tag}_ztgt"
    z_src = f"{tag}_zsrc"
    c_tgt = f"{tag}_ctgt"
    n = cfg["replicate_docs"]

    try:
        couch_client.reset_db(c_src)
        zouch_client.reset_db(z_tgt)
        for b in range(0, n, 100):
            docs = [make_doc(b + j) for j in range(min(100, n - b))]
            couch_client.request("POST", f"/{c_src}/_bulk_docs", {"docs": docs}, expect=(201,))

        t0 = time.perf_counter()
        zouch_client.request(
            "POST",
            "/_replicate",
            {"source": f"{couch_client.base_url}/{c_src}", "target": z_tgt},
            expect=(200,),
        )
        ms = (time.perf_counter() - t0) * 1000.0
        results["replicate_from_couch"] = summarize([ms], ms, 1, n)

        zouch_client.reset_db(z_src)
        couch_client.reset_db(c_tgt)
        for b in range(0, n, 100):
            docs = [make_doc(b + j) for j in range(min(100, n - b))]
            zouch_client.request("POST", f"/{z_src}/_bulk_docs", {"docs": docs}, expect=(201,))

        t0 = time.perf_counter()
        zouch_client.request(
            "POST",
            "/_replicate",
            {"source": z_src, "target": f"{couch_client.base_url}/{c_tgt}"},
            expect=(200,),
        )
        ms = (time.perf_counter() - t0) * 1000.0
        results["replicate_to_couch"] = summarize([ms], ms, 1, n)
    finally:
        couch_client.delete_db(c_src)
        couch_client.delete_db(c_tgt)
        zouch_client.delete_db(z_src)
        zouch_client.delete_db(z_tgt)

    return results


def start_zouch(bin_path, data_dir, port):
    proc = subprocess.Popen(
        [bin_path, "serve", data_dir, str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    url = f"http://127.0.0.1:{port}"
    c = Client(url)
    for _ in range(100):
        try:
            st, _ = c.request("GET", "/_up")
            if st == 200:
                return proc, url
        except Exception:
            time.sleep(0.05)
    err = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
    proc.kill()
    raise RuntimeError(f"zouch failed to start on port {port}: {err}")


def start_docker_couch(port):
    name = f"zouch-bench-couch-{port}"
    subprocess.run(
        [
            "docker", "run", "-d", "--rm", "--name", name,
            "-p", f"{port}:5984",
            "-e", "COUCHDB_USER=admin",
            "-e", "COUCHDB_PASSWORD=zouchtestpw",
            "couchdb:3.5.3",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    url = f"http://admin:zouchtestpw@127.0.0.1:{port}"
    c = Client(url)
    ready = False
    for _ in range(60):
        try:
            st, _ = c.request("GET", "/")
            if st == 200:
                ready = True
                break
        except Exception:
            time.sleep(0.5)
    if not ready:
        subprocess.run(["docker", "stop", name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise RuntimeError("Docker CouchDB failed to become ready")
    for sysdb in ("_users", "_replicator", "_global_changes"):
        c.request("PUT", f"/{sysdb}", expect=(201, 412))
    return name, url


def git_commit():
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def print_single_table(zouch_res):
    print("\n=== Zouch Benchmark Results ===")
    hdr = f"{'Workload':<22} {'Ops':>6} {'Total(ms)':>10} {'Ops/s':>10} {'Docs/s':>10} {'p50(ms)':>9} {'p95(ms)':>9} {'p99(ms)':>9}"
    print(hdr)
    print("-" * len(hdr))
    for k, m in zouch_res.items():
        docs_s = f"{m['docs_per_sec']:.1f}" if "docs_per_sec" in m else "-"
        print(
            f"{k:<22} {m['ops']:>6} {m['total_ms']:>10.1f} {m['ops_per_sec']:>10.1f} "
            f"{docs_s:>10} {m['p50_ms']:>9.2f} {m['p95_ms']:>9.2f} {m['p99_ms']:>9.2f}"
        )


def print_comparison_table(zouch_res, couch_res):
    print("\n=== Zouch vs CouchDB Comparison ===")
    hdr = f"{'Workload':<22} {'Zouch Ops/s':>12} {'Couch Ops/s':>12} {'Speedup':>9} {'Z p50':>8} {'C p50':>8} {'Z p95':>8} {'C p95':>8}"
    print(hdr)
    print("-" * len(hdr))
    for k, zm in zouch_res.items():
        cm = couch_res.get(k)
        if cm:
            speedup = zm["ops_per_sec"] / cm["ops_per_sec"] if cm["ops_per_sec"] > 0 else 0.0
            print(
                f"{k:<22} {zm['ops_per_sec']:>12.1f} {cm['ops_per_sec']:>12.1f} {speedup:>8.2f}x "
                f"{zm['p50_ms']:>8.2f} {cm['p50_ms']:>8.2f} {zm['p95_ms']:>8.2f} {cm['p95_ms']:>8.2f}"
            )
        else:
            print(
                f"{k:<22} {zm['ops_per_sec']:>12.1f} {'-':>12} {'-':>9} "
                f"{zm['p50_ms']:>8.2f} {'-':>8} {zm['p95_ms']:>8.2f} {'-':>8}"
            )


def print_baseline_diff(zouch_res, baseline_path):
    with open(baseline_path, "r", encoding="utf-8") as f:
        base = json.load(f)
    base_z = base.get("zouch", {})
    print(f"\n=== Baseline Comparison (vs {baseline_path}, commit={base.get('git_commit', '?')}) ===")
    hdr = f"{'Workload':<22} {'Base Ops/s':>11} {'Curr Ops/s':>11} {'Delta':>9} {'Base p95':>9} {'Curr p95':>9}"
    print(hdr)
    print("-" * len(hdr))
    for k, zm in zouch_res.items():
        bm = base_z.get(k)
        if not bm:
            continue
        b_ops = bm.get("ops_per_sec", 0.0)
        delta = ((zm["ops_per_sec"] - b_ops) / b_ops * 100.0) if b_ops > 0 else 0.0
        sign = "+" if delta >= 0 else ""
        print(
            f"{k:<22} {b_ops:>11.1f} {zm['ops_per_sec']:>11.1f} {sign}{delta:>7.1f}% "
            f"{bm.get('p95_ms', 0.0):>9.2f} {zm['p95_ms']:>9.2f}"
        )


def main():
    ap = argparse.ArgumentParser(description="Zouch reproducible benchmark suite")
    ap.add_argument("--zouch-bin", default="./zig-out/bin/zouch", help="Path to zouch binary")
    ap.add_argument("--zouch-url", default=None, help="Existing Zouch URL (skip auto-start)")
    ap.add_argument("--couch-url", default=None, help="Existing CouchDB URL (with credentials)")
    ap.add_argument("--docker-couch", action="store_true", help="Start ephemeral couchdb:3.5.3 container")
    ap.add_argument("--scale", choices=sorted(SCALES.keys()), default="small", help="Workload scale")
    ap.add_argument("--threads", type=int, default=8, help="Concurrent worker threads")
    ap.add_argument("--save", default=None, help="Save results JSON to path")
    ap.add_argument("--baseline", default=None, help="Compare Zouch results against saved JSON")
    args = ap.parse_args()

    cfg = SCALES[args.scale]
    zouch_proc = None
    zouch_tmp = None
    docker_name = None

    try:
        if args.zouch_url:
            zouch_url = args.zouch_url
        else:
            zouch_tmp = tempfile.mkdtemp(prefix="zouch-bench-")
            z_port = free_port()
            zouch_proc, zouch_url = start_zouch(args.zouch_bin, zouch_tmp, z_port)

        couch_url = args.couch_url
        couch_self_url = None
        if args.docker_couch and not couch_url:
            c_port = free_port()
            docker_name, couch_url = start_docker_couch(c_port)
            couch_self_url = "http://admin:zouchtestpw@127.0.0.1:5984"

        print(f"Running benchmark (scale={args.scale}, threads={args.threads}, zouch={zouch_url}" +
              (f", couch={couch_url.split('@')[-1]}" if couch_url else "") + ")", flush=True)

        zouch_client = Client(zouch_url)
        zouch_res = run_workloads(zouch_client, cfg, args.threads, is_couch=False)

        couch_res = None
        if couch_url:
            couch_client = Client(couch_url)
            couch_res = run_workloads(couch_client, cfg, args.threads, is_couch=True, couch_self_url=couch_self_url)
            cross_res = run_cross_replication(zouch_client, couch_client, cfg)
            zouch_res.update(cross_res)

        print_single_table(zouch_res)
        if couch_res is not None:
            print_comparison_table(zouch_res, couch_res)
        if args.baseline:
            print_baseline_diff(zouch_res, args.baseline)

        if args.save:
            payload = {
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "git_commit": git_commit(),
                "scale": args.scale,
                "threads": args.threads,
                "system": {
                    "platform": platform.platform(),
                    "machine": platform.machine(),
                    "python": platform.python_version(),
                    "cpu_count": os.cpu_count(),
                },
                "zouch": zouch_res,
            }
            if couch_res is not None:
                payload["couchdb"] = couch_res
            os.makedirs(os.path.dirname(os.path.abspath(args.save)), exist_ok=True)
            with open(args.save, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2)
            print(f"\nSaved benchmark results to {args.save}")
    finally:
        if zouch_proc is not None:
            zouch_proc.terminate()
            try:
                zouch_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                zouch_proc.kill()
        if zouch_tmp is not None:
            shutil.rmtree(zouch_tmp, ignore_errors=True)
        if docker_name is not None:
            subprocess.run(["docker", "stop", docker_name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    return 0


if __name__ == "__main__":
    sys.exit(main())
