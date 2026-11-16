#!/usr/bin/env python3
"""Regenerate src/www_assets.zig from the Fauxton build in www/.

The bundle names its chunks and fonts by hash, so the file list is read from the
directory rather than written out by hand. Run after replacing www/.
"""
import os

ROOT = "src/www"
OUT = "src/www_assets.zig"

files = sorted(
    os.path.relpath(os.path.join(dp, fn), ROOT)
    for dp, _, fns in os.walk(ROOT)
    for fn in fns
    if fn not in ("README.md", "LICENSE")
)

lines = [
    "//! The Fauxton build served at `/_utils`, embedded so a single binary carries",
    "//! its own UI. Generated from `src/www/` (see its README) by `scripts/embed_www.py`;",
    "//! do not edit by hand.",
    "",
    'const std = @import("std");',
    "",
    "pub const Asset = struct { path: []const u8, bytes: []const u8 };",
    "",
    "pub const assets = [_]Asset{",
]
for rel in files:
    lines.append(f'    .{{ .path = "{rel}", .bytes = @embedFile("www/{rel}") }},')
lines += [
    "};",
    "",
    "pub fn find(path: []const u8) ?[]const u8 {",
    "    for (&assets) |*a| {",
    "        if (std.mem.eql(u8, a.path, path)) return a.bytes;",
    "    }",
    "    return null;",
    "}",
    "",
]
with open(OUT, "w") as fh:
    fh.write("\n".join(lines))
print(f"{len(files)} assets -> {OUT}")
