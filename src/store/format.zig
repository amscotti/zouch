const std = @import("std");
const Doc = @import("../doc/tree.zig").Doc;
const Leaf = @import("../doc/tree.zig").Leaf;
const Rev = @import("../doc/rev.zig").Rev;

pub const Error = error{
    Corrupt,
    TooLarge,
    OutOfMemory,
    UnsupportedVersion,
};

pub const FORMAT_VERSION: u32 = 1;
pub const MANIFEST_MAGIC = "ZMAN0001";
pub const SNAPSHOT_MAGIC = "ZSNP0001";
pub const SEGMENT_MAGIC = "ZSEG0001";
pub const SEGMENTS_MAGIC = "ZSEGS001";

/// Validate a fixed-width versioned magic header (e.g. "ZSNP0001" with prefix
/// "ZSNP", or "ZSEGS001" with prefix "ZSEGS"). Returns `Error.UnsupportedVersion`
/// when the prefix matches and the version suffix is a valid integer other than
/// `FORMAT_VERSION`, or `Error.Corrupt` when the header is malformed.
pub fn validateHeaderVersion(header: []const u8, prefix: []const u8, expected_len: usize) Error!void {
    if (header.len != expected_len or prefix.len >= expected_len) return Error.Corrupt;
    if (!std.mem.eql(u8, header[0..prefix.len], prefix)) return Error.Corrupt;
    const version = std.fmt.parseInt(u32, header[prefix.len..], 10) catch return Error.Corrupt;
    if (version != FORMAT_VERSION) return Error.UnsupportedVersion;
}

fn putU32(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    try list.appendSlice(alloc, std.mem.asBytes(&v));
}

fn putU64(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    try list.appendSlice(alloc, std.mem.asBytes(&v));
}

pub fn encodeDoc(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, doc: *const Doc) !void {
    try putU32(list, alloc, @intCast(doc.id.len));
    try list.appendSlice(alloc, doc.id);
    try putU64(list, alloc, doc.seq);
    try putU32(list, alloc, @intCast(doc.leaves.items.len));

    for (doc.leaves.items) |leaf| {
        try putU32(list, alloc, leaf.rev.gen);
        try list.appendSlice(alloc, &leaf.rev.hash);
        try list.append(alloc, if (leaf.deleted) 1 else 0);
        try putU32(list, alloc, @intCast(leaf.body.len));
        try list.appendSlice(alloc, leaf.body);
        try putU32(list, alloc, @intCast(leaf.ancestry.len));
        for (leaf.ancestry) |anc| {
            try putU32(list, alloc, anc.gen);
            try list.appendSlice(alloc, &anc.hash);
        }
    }

    // Bodies of revisions that stopped being leaves, written after the leaves so
    // a record from before this existed still decodes (it simply ends here).
    try putU32(list, alloc, @intCast(doc.retained.items.len));
    for (doc.retained.items) |r| {
        try putU32(list, alloc, r.rev.gen);
        try list.appendSlice(alloc, &r.rev.hash);
        try list.append(alloc, if (r.deleted) 1 else 0);
        try putU32(list, alloc, @intCast(r.body.len));
        try list.appendSlice(alloc, r.body);
        try putU32(list, alloc, 0);
    }
}

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return Error.Corrupt;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn readU32(self: *Reader) Error!u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }
};

pub fn decodeDoc(alloc: std.mem.Allocator, buf: []const u8) !*Doc {
    var r = Reader{ .buf = buf };
    const id_len = try r.readU32();
    if (id_len > 1024 * 1024) return Error.TooLarge;
    const id = try r.take(id_len);
    const seq = try r.readU64();
    const leaf_count = try r.readU32();
    if (leaf_count > 100_000) return Error.TooLarge;

    const doc = try alloc.create(Doc);
    var owns_doc = false;
    errdefer if (owns_doc) doc.deinit(alloc) else alloc.destroy(doc);
    doc.* = .{ .id = try alloc.dupe(u8, id), .seq = seq };
    owns_doc = true;

    var i: u32 = 0;
    while (i < leaf_count) : (i += 1) {
        const gen = try r.readU32();
        const hash = try r.take(32);
        var h: [32]u8 = undefined;
        @memcpy(&h, hash);
        const deleted = (try r.take(1))[0] != 0;
        const body_len = try r.readU32();
        if (body_len > 64 * 1024 * 1024) return Error.TooLarge;
        const body = try r.take(body_len);
        const anc_len = try r.readU32();
        if (anc_len > 100_000) return Error.TooLarge;
        const ancestry = try alloc.alloc(Rev, anc_len);
        errdefer alloc.free(ancestry);
        var j: u32 = 0;
        while (j < anc_len) : (j += 1) {
            const agen = try r.readU32();
            const ahash = try r.take(32);
            var ah: [32]u8 = undefined;
            @memcpy(&ah, ahash);
            ancestry[j] = .{ .gen = agen, .hash = ah };
        }

        const body_copy = try alloc.dupe(u8, body);
        errdefer alloc.free(body_copy);

        try doc.leaves.append(alloc, .{
            .rev = .{ .gen = gen, .hash = h },
            .deleted = deleted,
            .body = body_copy,
            .ancestry = ancestry,
        });
    }

    if (r.pos < buf.len) {
        const retained_count = try r.readU32();
        if (retained_count > 100_000) return Error.TooLarge;
        var k: u32 = 0;
        while (k < retained_count) : (k += 1) {
            const rgen = try r.readU32();
            const rhash = try r.take(32);
            var rh: [32]u8 = undefined;
            @memcpy(&rh, rhash);
            const rdeleted = (try r.take(1))[0] != 0;
            const rbody_len = try r.readU32();
            if (rbody_len > 64 * 1024 * 1024) return Error.TooLarge;
            const rbody = try r.take(rbody_len);
            const copy = try alloc.dupe(u8, rbody);
            errdefer alloc.free(copy);
            const ranc_len = try r.readU32();
            if (ranc_len > 100_000) return Error.TooLarge;
            // Older records wrote a full ancestry chain per retained entry; skip it.
            _ = try r.take(@as(usize, ranc_len) * 36);
            try doc.retained.append(alloc, .{ .rev = .{ .gen = rgen, .hash = rh }, .deleted = rdeleted, .body = copy });
        }
    }

    doc.recomputeWinner();
    return doc;
}

fn putRetainedSize(doc: *const Doc) usize {
    var n: usize = 4;
    for (doc.retained.items) |r| n += 4 + 32 + 1 + 4 + r.body.len + 4;
    return n;
}

pub fn docSize(doc: *const Doc) usize {
    var n: usize = 4 + doc.id.len + 8 + 4;
    for (doc.leaves.items) |leaf| {
        n += 4 + 32 + 1 + 4 + leaf.body.len + 4;
        n += leaf.ancestry.len * 36;
    }
    n += putRetainedSize(doc);
    return n;
}

test "round trip" {
    const alloc = std.testing.allocator;
    const tree = @import("../doc/tree.zig");
    const doc = try tree.create(alloc, "doc-1");
    defer doc.deinit(alloc);
    const r1 = try tree.applyLocal(doc, alloc, "{\"v\":1}", null, false);
    _ = try tree.applyLocal(doc, alloc, "{\"v\":2}", r1, false);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try encodeDoc(&buf, alloc, doc);

    const copy = try decodeDoc(alloc, buf.items);
    defer copy.deinit(alloc);
    try std.testing.expectEqualStrings(doc.id, copy.id);
    try std.testing.expectEqual(doc.seq, copy.seq);
    try std.testing.expectEqual(doc.leaves.items.len, copy.leaves.items.len);
    try std.testing.expectEqualStrings(doc.winnerLeaf().body, copy.winnerLeaf().body);
    try std.testing.expectEqual(doc.winnerLeaf().ancestry.len, copy.winnerLeaf().ancestry.len);
}

test "header version validation" {
    try validateHeaderVersion(MANIFEST_MAGIC, "ZMAN", 8);
    try validateHeaderVersion(SNAPSHOT_MAGIC, "ZSNP", 8);
    try validateHeaderVersion(SEGMENT_MAGIC, "ZSEG", 8);
    try validateHeaderVersion(SEGMENTS_MAGIC, "ZSEGS", 8);
    try std.testing.expectError(Error.UnsupportedVersion, validateHeaderVersion("ZSNP0002", "ZSNP", 8));
    try std.testing.expectError(Error.UnsupportedVersion, validateHeaderVersion("ZSEGS002", "ZSEGS", 8));
    try std.testing.expectError(Error.Corrupt, validateHeaderVersion("BAD!0001", "ZSNP", 8));
    try std.testing.expectError(Error.Corrupt, validateHeaderVersion("ZSNPxxxx", "ZSNP", 8));
    try std.testing.expectError(Error.Corrupt, validateHeaderVersion("ZSNP001", "ZSNP", 8));
}
