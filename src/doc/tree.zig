const std = @import("std");
const Rev = @import("rev.zig").Rev;
const revmod = @import("rev.zig");

pub const Error = error{
    InvalidRev,
    Conflict,
    NotFound,
    OutOfMemory,
};

pub const Leaf = struct {
    rev: Rev,
    deleted: bool,
    body: []u8,
    ancestry: []Rev,

    pub fn deinit(self: *Leaf, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.ancestry);
    }
};

/// A body kept for a revision that is no longer a leaf. CouchDB serves old
/// revisions this way until compaction drops the bodies it no longer needs.
/// Ancestry is derived from the active leaf that subsumed it rather than stored
/// per retained entry, avoiding quadratic memory and WAL growth.
pub const Retained = struct {
    rev: Rev,
    deleted: bool,
    body: []u8,
};

pub const default_revs_limit: u32 = 1000;
pub const max_retained_count: usize = 100;
pub const max_retained_bytes: usize = 1 * 1024 * 1024;

pub const Doc = struct {
    id: []u8,
    leaves: std.ArrayListUnmanaged(Leaf) = .empty,
    /// Bodies of superseded revisions, newest last. Dropped at compaction.
    retained: std.ArrayListUnmanaged(Retained) = .empty,
    winner: usize = 0,
    seq: u64 = 0,
    revs_limit: u32 = default_revs_limit,

    pub fn deinit(self: *Doc, alloc: std.mem.Allocator) void {
        for (self.leaves.items) |*leaf| leaf.deinit(alloc);
        self.leaves.deinit(alloc);
        for (self.retained.items) |r| {
            alloc.free(r.body);
        }
        self.retained.deinit(alloc);
        alloc.free(self.id);
        alloc.destroy(self);
    }

    /// The body stored for `rev`, whether it is a leaf or an older revision.
    pub fn bodyFor(self: *const Doc, rev: Rev) ?struct { body: []const u8, deleted: bool } {
        if (self.findLeaf(rev)) |idx| {
            const leaf = &self.leaves.items[idx];
            return .{ .body = leaf.body, .deleted = leaf.deleted };
        }
        for (self.retained.items) |r| {
            if (r.rev.eql(rev)) return .{ .body = r.body, .deleted = r.deleted };
        }
        return null;
    }

    /// Drop the retained bodies: compaction's contract, since only leaves are
    /// needed to answer for the current document.
    pub fn retainedFor(self: *const Doc, rev: Rev) ?*const Retained {
        for (self.retained.items) |*r| {
            if (r.rev.eql(rev)) return r;
        }
        return null;
    }

    pub fn dropRetained(self: *Doc, alloc: std.mem.Allocator) void {
        for (self.retained.items) |r| {
            alloc.free(r.body);
        }
        self.retained.clearRetainingCapacity();
    }

    pub fn ancestryFor(self: *const Doc, rev: Rev) ?[]const Rev {
        for (self.leaves.items) |leaf| {
            for (leaf.ancestry, 0..) |a, idx| {
                if (a.eql(rev)) return leaf.ancestry[idx..];
            }
        }
        return null;
    }

    pub fn winnerLeaf(self: *const Doc) *const Leaf {
        return &self.leaves.items[self.winner];
    }

    pub fn findLeaf(self: *const Doc, rev: Rev) ?usize {
        for (self.leaves.items, 0..) |leaf, i| {
            if (leaf.rev.eql(rev)) return i;
        }
        return null;
    }

    /// Index of a leaf whose ancestry contains `rev`, if any. This is how a
    /// request for an old revision is recognised as ancestry rather than as a
    /// revision we have never seen: CouchDB can serve the old body, we keep
    /// leaves only, so `latest` is what turns it into an answer.
    pub fn findDescendantOf(self: *const Doc, rev: Rev) ?usize {
        for (self.leaves.items, 0..) |leaf, i| {
            for (leaf.ancestry) |a| {
                if (a.eql(rev)) return i;
            }
        }
        return null;
    }

    pub fn recomputeWinner(self: *Doc) void {
        if (self.leaves.items.len == 0) {
            self.winner = 0;
            return;
        }
        var best: usize = 0;
        for (self.leaves.items[1..], 1..) |leaf, i| {
            const cur = self.leaves.items[best];
            if (!leaf.deleted and cur.deleted) {
                best = i;
            } else if (leaf.deleted == cur.deleted and Rev.order(leaf.rev, cur.rev) == .gt) {
                best = i;
            }
        }
        self.winner = best;
    }

    fn addLeaf(self: *Doc, alloc: std.mem.Allocator, leaf: Leaf) !bool {
        if (self.findLeaf(leaf.rev) != null) return false;

        // Reserve before destroying ancestors so an OOM cannot lose leaves.
        try self.leaves.ensureUnusedCapacity(alloc, 1);

        // The new leaf subsumes any existing leaf that appears in its ancestry.
        var i: usize = 0;
        while (i < self.leaves.items.len) {
            const existing = self.leaves.items[i].rev;
            var is_ancestor = false;
            for (leaf.ancestry[1..]) |anc| {
                if (anc.eql(existing)) {
                    is_ancestor = true;
                    break;
                }
            }
            if (is_ancestor) {
                const removed = self.leaves.orderedRemove(i);
                alloc.free(removed.ancestry);
                // Keep the body: CouchDB still serves a revision that stopped
                // being a leaf, until compaction.
                _ = self.retained.append(alloc, .{
                    .rev = removed.rev,
                    .deleted = removed.deleted,
                    .body = removed.body,
                }) catch {
                    alloc.free(removed.body);
                    return error.OutOfMemory;
                };
            } else {
                i += 1;
            }
        }

        self.leaves.appendAssumeCapacity(leaf);
        self.recomputeWinner();
        var ret_bytes: usize = 0;
        for (self.retained.items) |r| ret_bytes +|= r.body.len;
        while (self.retained.items.len > max_retained_count or (self.retained.items.len > 0 and ret_bytes > max_retained_bytes)) {
            const oldest = self.retained.orderedRemove(0);
            ret_bytes -|= oldest.body.len;
            alloc.free(oldest.body);
        }
        return true;
    }
};

pub fn create(alloc: std.mem.Allocator, id: []const u8) !*Doc {
    const doc = try alloc.create(Doc);
    errdefer alloc.destroy(doc);
    doc.* = .{ .id = try alloc.dupe(u8, id) };
    return doc;
}

/// Apply a local edit using `doc.revs_limit`. `parent` is the `_rev` the client edited; null creates a new document.
pub fn applyLocal(
    doc: *Doc,
    alloc: std.mem.Allocator,
    body: []const u8,
    parent: ?Rev,
    deleted: bool,
) !Rev {
    return applyLocalWithLimit(doc, alloc, body, parent, deleted, doc.revs_limit);
}

/// Apply a local edit with an explicit `revs_limit`.
pub fn applyLocalWithLimit(
    doc: *Doc,
    alloc: std.mem.Allocator,
    body: []const u8,
    parent: ?Rev,
    deleted: bool,
    revs_limit: u32,
) !Rev {
    const limit: usize = @max(revs_limit, 1);
    var gen: u32 = 1;
    var ancestry: []Rev = undefined;

    if (parent) |p| {
        const idx = doc.findLeaf(p) orelse return Error.Conflict;
        gen = std.math.add(u32, p.gen, 1) catch return Error.InvalidRev;
        // A tombstone is a valid parent: recreate the document with a new
        // generation, as CouchDB does.
        const parent_anc = doc.leaves.items[idx].ancestry;
        const n = @min(parent_anc.len + 1, limit);
        ancestry = try alloc.alloc(Rev, n);
    } else {
        var any_live = false;
        var max_deleted_gen: u32 = 0;
        for (doc.leaves.items) |leaf| {
            if (!leaf.deleted) {
                any_live = true;
                break;
            }
            max_deleted_gen = @max(max_deleted_gen, leaf.rev.gen);
        }
        if (any_live) return Error.Conflict;
        gen = std.math.add(u32, max_deleted_gen, 1) catch return Error.InvalidRev;
        ancestry = try alloc.alloc(Rev, 1);
    }
    errdefer alloc.free(ancestry);

    var parent_buf: [64]u8 = undefined;
    const parent_str: ?[]const u8 = if (parent) |p| p.write(&parent_buf) else null;
    const rev = revmod.newRev(gen, body, parent_str);
    ancestry[0] = rev;
    if (parent) |_| {
        const parent_anc = doc.leaves.items[doc.findLeaf(parent.?).?].ancestry;
        const n = @min(parent_anc.len, ancestry.len - 1);
        @memcpy(ancestry[1 .. 1 + n], parent_anc[0..n]);
    }

    const body_copy = try alloc.dupe(u8, body);
    errdefer alloc.free(body_copy);

    const added = try doc.addLeaf(alloc, .{
        .rev = rev,
        .deleted = deleted,
        .body = body_copy,
        .ancestry = ancestry,
    });
    if (!added) return Error.Conflict;
    return rev;
}

/// Insert a revision received from a peer, preserving its ancestry chain up to `doc.revs_limit`.
pub fn applyImported(
    doc: *Doc,
    alloc: std.mem.Allocator,
    rev: Rev,
    ancestry_in: []const Rev,
    body: []const u8,
    deleted: bool,
) !bool {
    return applyImportedWithLimit(doc, alloc, rev, ancestry_in, body, deleted, doc.revs_limit);
}

/// Insert a revision received from a peer with an explicit `revs_limit`.
pub fn applyImportedWithLimit(
    doc: *Doc,
    alloc: std.mem.Allocator,
    rev: Rev,
    ancestry_in: []const Rev,
    body: []const u8,
    deleted: bool,
    revs_limit: u32,
) !bool {
    if (doc.findLeaf(rev) != null or doc.findDescendantOf(rev) != null or doc.retainedFor(rev) != null) {
        return false;
    }

    const limit: usize = @max(revs_limit, 1);
    var ancestry: []Rev = undefined;
    if (ancestry_in.len == 0) {
        ancestry = try alloc.alloc(Rev, 1);
        ancestry[0] = rev;
    } else if (ancestry_in[0].eql(rev)) {
        const n = @min(ancestry_in.len, limit);
        ancestry = try alloc.alloc(Rev, n);
        @memcpy(ancestry, ancestry_in[0..n]);
    } else {
        // The chain must start at the leaf; insert it.
        const n = @min(ancestry_in.len + 1, limit);
        ancestry = try alloc.alloc(Rev, n);
        ancestry[0] = rev;
        if (n > 1) @memcpy(ancestry[1..n], ancestry_in[0 .. n - 1]);
    }
    errdefer alloc.free(ancestry);

    const body_copy = try alloc.dupe(u8, body);
    errdefer alloc.free(body_copy);

    return doc.addLeaf(alloc, .{
        .rev = rev,
        .deleted = deleted,
        .body = body_copy,
        .ancestry = ancestry,
    });
}

test "linear history" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const r1 = try applyLocal(doc, alloc, "{\"v\":1}", null, false);
    const r2 = try applyLocal(doc, alloc, "{\"v\":2}", r1, false);
    try std.testing.expectEqual(@as(u32, 2), r2.gen);
    try std.testing.expectEqual(@as(usize, 1), doc.leaves.items.len);
    try std.testing.expectEqual(@as(usize, 2), doc.leaves.items[0].ancestry.len);
    try std.testing.expect(r2.eql(doc.winnerLeaf().rev));
}

test "conflict winner is highest generation then hash" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const a = try Rev.parse("2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const b = try Rev.parse("2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    _ = try applyImported(doc, alloc, a, &.{a}, "{\"side\":\"a\"}", false);
    _ = try applyImported(doc, alloc, b, &.{b}, "{\"side\":\"b\"}", false);
    try std.testing.expect(b.eql(doc.winnerLeaf().rev));

    const c = try Rev.parse("1-ffffffffffffffffffffffffffffffff");
    _ = try applyImported(doc, alloc, c, &.{c}, "{\"side\":\"c\"}", false);
    try std.testing.expect(b.eql(doc.winnerLeaf().rev));
    try std.testing.expectEqual(@as(usize, 3), doc.leaves.items.len);
}

test "imported ancestry is preserved and idempotent" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const r3 = try Rev.parse("3-33333333333333333333333333333333");
    const r2 = try Rev.parse("2-22222222222222222222222222222222");
    const r1 = try Rev.parse("1-11111111111111111111111111111111");
    try std.testing.expect(try applyImported(doc, alloc, r3, &.{ r3, r2, r1 }, "{}", false));
    try std.testing.expect(!(try applyImported(doc, alloc, r3, &.{ r3, r2, r1 }, "{}", false)));
    try std.testing.expectEqual(@as(usize, 3), doc.winnerLeaf().ancestry.len);
    try std.testing.expect(r1.eql(doc.winnerLeaf().ancestry[2]));
}

test "stale parent is a conflict" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const r1 = try applyLocal(doc, alloc, "{}", null, false);
    _ = try applyLocal(doc, alloc, "{}", r1, false);
    try std.testing.expectError(Error.Conflict, applyLocal(doc, alloc, "{}", r1, false));
}

test "a tombstone can be recreated" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const r1 = try applyLocal(doc, alloc, "{\"v\":1}", null, false);
    const r2 = try applyLocal(doc, alloc, "{\"_deleted\":true}", r1, true);
    try std.testing.expect(doc.winnerLeaf().deleted);
    const r3 = try applyLocal(doc, alloc, "{\"v\":2}", r2, false);
    try std.testing.expectEqual(@as(u32, 3), r3.gen);
    try std.testing.expect(!doc.winnerLeaf().deleted);
}

fn oomWorkload(alloc: std.mem.Allocator) !void {
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);
    const r1 = try applyLocal(doc, alloc, "{\"v\":1}", null, false);
    _ = try applyLocal(doc, alloc, "{\"v\":2}", r1, false);
}

test "allocation failures do not leak or corrupt the tree" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomWorkload, .{});
}

fn oomImportedWorkload(alloc: std.mem.Allocator) !void {
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);
    const r2 = try Rev.parse("2-22222222222222222222222222222222");
    const r1 = try Rev.parse("1-11111111111111111111111111111111");
    _ = try applyImported(doc, alloc, r2, &.{r1}, "{\"v\":1}", false);
}

test "imported allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomImportedWorkload, .{});
}

test "live leaf beats higher-gen deleted leaf" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const live = try Rev.parse("1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const del_high = try Rev.parse("5-ffffffffffffffffffffffffffffffff");
    const del_low = try Rev.parse("2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    _ = try applyImported(doc, alloc, del_high, &.{del_high}, "{\"_deleted\":true}", true);
    try std.testing.expect(del_high.eql(doc.winnerLeaf().rev));

    _ = try applyImported(doc, alloc, live, &.{live}, "{\"v\":1}", false);
    try std.testing.expect(live.eql(doc.winnerLeaf().rev));
    try std.testing.expect(!doc.winnerLeaf().deleted);

    _ = try applyImported(doc, alloc, del_low, &.{del_low}, "{\"_deleted\":true}", true);
    try std.testing.expect(live.eql(doc.winnerLeaf().rev));
}

test "importing an ancestor rev does not create a conflict" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);

    const r3 = try Rev.parse("3-33333333333333333333333333333333");
    const r2 = try Rev.parse("2-22222222222222222222222222222222");
    const r1 = try Rev.parse("1-11111111111111111111111111111111");

    try std.testing.expect(try applyImported(doc, alloc, r3, &.{ r3, r2, r1 }, "{\"v\":3}", false));
    try std.testing.expect(!(try applyImported(doc, alloc, r2, &.{ r2, r1 }, "{\"v\":2}", false)));
    try std.testing.expect(!(try applyImported(doc, alloc, r1, &.{r1}, "{\"v\":1}", false)));
    try std.testing.expectEqual(@as(usize, 1), doc.leaves.items.len);
    try std.testing.expect(r3.eql(doc.winnerLeaf().rev));
}

test "revs_limit trims ancestry in applyLocal and applyImported" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "a");
    defer doc.deinit(alloc);
    doc.revs_limit = 3;

    const r1 = try applyLocal(doc, alloc, "{\"v\":1}", null, false);
    const r2 = try applyLocal(doc, alloc, "{\"v\":2}", r1, false);
    const r3 = try applyLocal(doc, alloc, "{\"v\":3}", r2, false);
    const r4 = try applyLocal(doc, alloc, "{\"v\":4}", r3, false);
    try std.testing.expectEqual(@as(usize, 3), doc.winnerLeaf().ancestry.len);
    try std.testing.expect(r4.eql(doc.winnerLeaf().ancestry[0]));
    try std.testing.expect(r3.eql(doc.winnerLeaf().ancestry[1]));
    try std.testing.expect(r2.eql(doc.winnerLeaf().ancestry[2]));

    // r3 is in active leaf ancestry and r1 was retained before trimming:
    // importing either again must be ignored without creating a conflict.
    try std.testing.expect(!(try applyImported(doc, alloc, r3, &.{r3}, "{\"v\":3}", false)));
    try std.testing.expect(!(try applyImported(doc, alloc, r1, &.{r1}, "{\"v\":1}", false)));
    try std.testing.expectEqual(@as(usize, 1), doc.leaves.items.len);

    const doc2 = try create(alloc, "b");
    defer doc2.deinit(alloc);
    doc2.revs_limit = 2;
    const imp4 = try Rev.parse("4-44444444444444444444444444444444");
    const imp3 = try Rev.parse("3-33333333333333333333333333333333");
    const imp2 = try Rev.parse("2-22222222222222222222222222222222");
    const imp1 = try Rev.parse("1-11111111111111111111111111111111");
    try std.testing.expect(try applyImported(doc2, alloc, imp4, &.{ imp3, imp2, imp1 }, "{\"v\":4}", false));
    try std.testing.expectEqual(@as(usize, 2), doc2.winnerLeaf().ancestry.len);
    try std.testing.expect(imp4.eql(doc2.winnerLeaf().ancestry[0]));
    try std.testing.expect(imp3.eql(doc2.winnerLeaf().ancestry[1]));
}

test "CouchDB three-way conflict merge, live-over-deleted, and tie-breaking" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "merge");
    defer doc.deinit(alloc);

    const r1 = try Rev.parse("1-11111111111111111111111111111111");
    const r2a = try Rev.parse("2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const r2b = try Rev.parse("2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const r3a = try Rev.parse("3-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const r3b = try Rev.parse("3-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const r4a_del = try Rev.parse("4-ffffffffffffffffffffffffffffffff");
    const r4b_del = try Rev.parse("4-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");

    try std.testing.expect(try applyImported(doc, alloc, r1, &.{r1}, "{\"v\":1}", false));
    try std.testing.expect(try applyImported(doc, alloc, r2a, &.{ r2a, r1 }, "{\"branch\":\"a\"}", false));
    try std.testing.expect(try applyImported(doc, alloc, r2b, &.{ r2b, r1 }, "{\"branch\":\"b\"}", false));
    try std.testing.expectEqual(@as(usize, 2), doc.leaves.items.len);
    try std.testing.expect(r2b.eql(doc.winnerLeaf().rev));

    // Advance both branches: equal-gen live tie-break goes to r3b > r3a.
    try std.testing.expect(try applyImported(doc, alloc, r3a, &.{ r3a, r2a, r1 }, "{\"branch\":\"a3\"}", false));
    try std.testing.expect(try applyImported(doc, alloc, r3b, &.{ r3b, r2b, r1 }, "{\"branch\":\"b3\"}", false));
    try std.testing.expect(r3b.eql(doc.winnerLeaf().rev));

    // Deleting branch b (r4b_del, gen 4) lets lower-gen live branch r3a (gen 3) win.
    try std.testing.expect(try applyImported(doc, alloc, r4b_del, &.{ r4b_del, r3b, r2b, r1 }, "{\"_deleted\":true}", true));
    try std.testing.expect(r3a.eql(doc.winnerLeaf().rev));
    try std.testing.expect(!doc.winnerLeaf().deleted);

    // Deleting branch a as well leaves only tombstones; higher-hash r4a_del beats r4b_del.
    try std.testing.expect(try applyImported(doc, alloc, r4a_del, &.{ r4a_del, r3a, r2a, r1 }, "{\"_deleted\":true}", true));
    try std.testing.expect(r4a_del.eql(doc.winnerLeaf().rev));
    try std.testing.expect(doc.winnerLeaf().deleted);
}

test "revs_limit stemming and compaction affect bodyFor/retainedFor (_revs_info)" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "stem");
    defer doc.deinit(alloc);
    doc.revs_limit = 2;

    const r1 = try applyLocal(doc, alloc, "{\"v\":1}", null, false);
    const r2 = try applyLocal(doc, alloc, "{\"v\":2}", r1, false);
    const r3 = try applyLocal(doc, alloc, "{\"v\":3}", r2, false);
    const r4 = try applyLocal(doc, alloc, "{\"v\":4}", r3, false);

    // Ancestry is stemmed to 2 revisions: [r4, r3].
    try std.testing.expectEqual(@as(usize, 2), doc.winnerLeaf().ancestry.len);
    try std.testing.expect(doc.findDescendantOf(r4) != null);
    try std.testing.expect(doc.findDescendantOf(r3) != null);
    try std.testing.expect(doc.findDescendantOf(r2) == null);
    try std.testing.expect(doc.findDescendantOf(r1) == null);

    // Before compaction, retained bodies are still available for _revs_info / old rev GETs.
    try std.testing.expect(doc.retainedFor(r1) != null);
    try std.testing.expect(doc.bodyFor(r1) != null);
    try std.testing.expect(doc.bodyFor(r4) != null);

    // Compaction drops retained bodies (they become "missing" in _revs_info), leaving winner available.
    doc.dropRetained(alloc);
    try std.testing.expect(doc.retainedFor(r1) == null);
    try std.testing.expect(doc.bodyFor(r1) == null);
    try std.testing.expect(doc.bodyFor(r4) != null);
}

test "retained bounds and ancestryFor" {
    const alloc = std.testing.allocator;
    const doc = try create(alloc, "bounded");
    defer doc.deinit(alloc);

    var prev: ?Rev = null;
    var first_rev: Rev = undefined;
    var recent_rev: Rev = undefined;
    for (0..150) |i| {
        const body = try std.fmt.allocPrint(alloc, "{{\"v\":{d}}}", .{i});
        defer alloc.free(body);
        prev = try applyLocal(doc, alloc, body, prev, false);
        if (i == 0) first_rev = prev.?;
        if (i == 148) recent_rev = prev.?;
    }

    try std.testing.expect(doc.retained.items.len <= max_retained_count);
    try std.testing.expect(doc.retainedFor(first_rev) == null);
    try std.testing.expect(doc.retainedFor(recent_rev) != null);

    const anc = doc.ancestryFor(recent_rev).?;
    try std.testing.expect(anc[0].eql(recent_rev));
    try std.testing.expectEqual(@as(usize, doc.winnerLeaf().ancestry.len - 1), anc.len);
}
