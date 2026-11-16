#!/usr/bin/env python3
"""Generate test/README.md from the test scripts themselves.

A hand-kept list of tests rots: a script gets renamed, a new one is added and the
docs still describe the old set. This reads each script's header comment for what
it proves and how it is started, so the catalog cannot drift from the directory.
`--check` exits 1 when the committed file is stale; `scripts/ci.sh` runs it.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test" / "README.md"

GROUPS = (
    ("Self-contained", "each starts its own server on a private port and needs nothing running"),
    ("Needs a running Zouch", "set `ZOUCH` (default `http://127.0.0.1:5985`); none of these start one"),
    ("Needs CouchDB", "a real CouchDB answers too; `COUCH`/`AUTH` or `COUCH_URL`, plus a Zouch"),
)


def header(path: Path) -> str:
    """The first comment block after the shebang, as one sentence."""
    text = path.read_text(errors="replace").splitlines()
    parts: list[str] = []
    for line in text[1:]:
        stripped = line.strip()
        if stripped.startswith("#"):
            parts.append(stripped.lstrip("# ").strip())
        elif parts:
            break
        elif stripped and not stripped.startswith("#!"):
            break
    joined = " ".join(parts).strip()
    # One sentence is enough for a catalog; keep the first one if it is long
    # enough to say something, otherwise keep the whole line.
    end = joined.find(". ")
    if end >= 40:
        joined = joined[: end + 1]
    return joined or "(no description)"


def group_of(path: Path) -> int:
    text = path.read_text(errors="replace")
    # A script that only reaches for CouchDB when `COUCH_URL` happens to be set
    # (soak.sh) belongs with the ones that just need a Zouch.
    optional_couch = "COUCH_URL:-" in text and "COUCH:-" not in text
    if "COUCH" in text and not optional_couch:
        return 2
    if "BIN=" in text:
        return 0
    return 1


def build() -> str:
    scripts = sorted((ROOT / "test" / "compat").glob("*.sh"))
    grouped: list[list[tuple[str, str]]] = [[], [], []]
    for path in scripts:
        grouped[group_of(path)].append((f"test/compat/{path.name}", header(path)))

    interop = sorted((ROOT / "test" / "interop").glob("*.py"))
    interop_rows = []
    for path in interop:
        doc = (path.read_text(errors="replace").split('"""')[1] if '"""' in path.read_text(errors="replace") else "").strip()
        first = doc.split("\n")[0].strip() or "(no description)"
        interop_rows.append((f"test/interop/{path.name}", first))

    lines = [
        "# Tests",
        "",
        "Generated from the scripts by `scripts/test_index.py` — run it after adding, renaming",
        "or removing one. `scripts/ci.sh` fails when this file is out of date.",
        "",
        "The two gates are the ones to run before trusting a change:",
        "",
        "```bash",
        "./scripts/ci.sh            # formatting, ReleaseSafe build, unit tests, HTTP smoke (~9 min)",
        "./scripts/integration.sh   # CouchDB-backed replication and parity suites (~12 min)",
        "```",
        "",
        "Everything below is a single script you can run on its own.",
        "",
    ]
    for (title, blurb), rows in zip(GROUPS, grouped):
        lines += [f"## {title}", "", f"{blurb[0].upper()}{blurb[1:]}.", "",
                  "| Script | What it proves |", "| --- | --- |"]
        lines += [f"| `{name}` | {desc.replace('|', '/')} |" for name, desc in rows]
        lines.append("")

    lines += [
        "## Cross-implementation suites (`test/interop/`)",
        "",
        "These drive both servers and compare answers; they need CouchDB, and most need a",
        "Zouch on `:5985` as well (each prints its endpoint when it cannot reach one).",
        "",
        "| Script | What it compares |",
        "| --- | --- |",
    ]
    lines += [f"| `{name}` | {desc.replace('|', '/')} |" for name, desc in interop_rows]
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    text = build()
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != text:
            print(f"{OUT.relative_to(ROOT)} is stale: run python3 scripts/test_index.py")
            return 1
        print(f"{OUT.relative_to(ROOT)} is current")
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
