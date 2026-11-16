//! Deterministic in-memory HNSW index.
//!
//! This is the graph layer used by `_vector_search` when the caller asks for the
//! approximate engine. It is deliberately independent of storage: callers own the
//! vectors, and the index only stores normalised copies plus adjacency lists.
//! Persistence and incremental updates remain the caller's responsibility.

const std = @import("std");

const Candidate = struct {
    id: u32,
    dist: f32,
};

pub const Hit = struct {
    id: u32,
    score: f32,
};

pub const Index = struct {
    alloc: std.mem.Allocator,
    dim: usize,
    m: usize = 16,
    m0: usize = 32,
    ef_construction: usize = 100,
    vecs: std.ArrayListUnmanaged([]f32) = .empty,
    levels: std.ArrayListUnmanaged(u16) = .empty,
    links: std.ArrayListUnmanaged([]std.ArrayListUnmanaged(u32)) = .empty,
    deleted: std.ArrayListUnmanaged(bool) = .empty,
    entry: ?u32 = null,
    max_level: usize = 0,

    pub fn init(alloc: std.mem.Allocator, dim: usize) Index {
        return .{ .alloc = alloc, .dim = dim };
    }

    pub fn deinit(self: *Index) void {
        for (self.vecs.items) |v| self.alloc.free(v);
        for (self.links.items) |level_links| {
            for (level_links) |*list| list.deinit(self.alloc);
            self.alloc.free(level_links);
        }
        self.vecs.deinit(self.alloc);
        self.levels.deinit(self.alloc);
        self.links.deinit(self.alloc);
        self.deleted.deinit(self.alloc);
    }

    pub fn count(self: *const Index) usize {
        return self.vecs.items.len;
    }

    pub fn activeCount(self: *const Index) usize {
        var n: usize = 0;
        for (self.deleted.items) |d| {
            if (!d) n += 1;
        }
        return n;
    }

    pub fn delete(self: *Index, id: u32) void {
        if (id < self.deleted.items.len) {
            self.deleted.items[id] = true;
        }
    }

    pub fn isDeleted(self: *const Index, id: u32) bool {
        return id < self.deleted.items.len and self.deleted.items[id];
    }

    fn levelFor(id: u32) usize {
        var h = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, std.mem.asBytes(&id));
        var level: usize = 0;
        while (level < 12 and (h & 0xf) == 0) {
            level += 1;
            h >>= 4;
        }
        return level;
    }

    fn normalize(self: *Index, raw: []const f32) ![]f32 {
        if (raw.len != self.dim) return error.DimensionMismatch;
        var norm: f32 = 0;
        for (raw) |x| norm += x * x;
        if (norm == 0 or !std.math.isFinite(norm)) return error.InvalidVector;
        const scale = 1.0 / @sqrt(norm);
        const v = try self.alloc.alloc(f32, self.dim);
        for (raw, 0..) |x, i| v[i] = x * scale;
        return v;
    }

    fn dist(a: []const f32, b: []const f32) f32 {
        var dot: f32 = 0;
        for (a, b) |x, y| dot += x * y;
        return 1.0 - dot;
    }

    fn insertCandidate(list: *std.ArrayListUnmanaged(Candidate), alloc: std.mem.Allocator, item: Candidate) !void {
        var pos: usize = list.items.len;
        while (pos > 0 and list.items[pos - 1].dist > item.dist) pos -= 1;
        try list.insert(alloc, pos, item);
    }

    fn greedy(self: *Index, q: []const f32, start: u32, level: usize) u32 {
        var best = start;
        var best_dist = dist(q, self.vecs.items[best]);
        var changed = true;
        while (changed) {
            changed = false;
            if (level >= self.links.items[best].len) break;
            for (self.links.items[best][level].items) |next| {
                const d = dist(q, self.vecs.items[next]);
                if (d < best_dist) {
                    best_dist = d;
                    best = next;
                    changed = true;
                }
            }
        }
        return best;
    }

    fn searchLayer(
        self: *Index,
        q: []const f32,
        start: u32,
        ef: usize,
        level: usize,
        skip_deleted: bool,
    ) !std.ArrayListUnmanaged(Candidate) {
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(self.alloc);
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        defer candidates.deinit(self.alloc);
        var results: std.ArrayListUnmanaged(Candidate) = .empty;
        errdefer results.deinit(self.alloc);

        try visited.put(self.alloc, start, {});
        const start_item = Candidate{ .id = start, .dist = dist(q, self.vecs.items[start]) };
        try insertCandidate(&candidates, self.alloc, start_item);
        if (!skip_deleted or !self.deleted.items[start]) {
            try insertCandidate(&results, self.alloc, start_item);
        }

        while (candidates.items.len > 0) {
            const current = candidates.orderedRemove(0);
            if (results.items.len >= ef and current.dist > results.items[results.items.len - 1].dist) break;
            if (level >= self.links.items[current.id].len) continue;
            for (self.links.items[current.id][level].items) |next| {
                if (visited.contains(next)) continue;
                try visited.put(self.alloc, next, {});
                const d = dist(q, self.vecs.items[next]);
                if (results.items.len < ef or d < results.items[results.items.len - 1].dist) {
                    const item = Candidate{ .id = next, .dist = d };
                    try insertCandidate(&candidates, self.alloc, item);
                    if (!skip_deleted or !self.deleted.items[next]) {
                        try insertCandidate(&results, self.alloc, item);
                        if (results.items.len > ef) results.shrinkRetainingCapacity(ef);
                    }
                }
            }
        }
        return results;
    }

    fn addLink(self: *Index, from: u32, to: u32, level: usize) !void {
        if (from == to) return;
        if (level >= self.links.items[from].len) return;
        const list = &self.links.items[from][level];
        for (list.items) |existing| if (existing == to) return;
        try list.append(self.alloc, to);
        const max_links = if (level == 0) self.m0 else self.m;
        if (list.items.len > max_links) try self.pruneLinks(from, level, max_links);
    }

    /// Select up to `max_links` neighbors using the HNSW diversity heuristic
    /// (Malkov & Yashunin 2018, Algorithm 4), falling back to closest pruned
    /// candidates when fewer than `max_links` diverse neighbors exist.
    fn pruneLinks(self: *Index, node: u32, level: usize, max_links: usize) !void {
        const list = &self.links.items[node][level];
        if (list.items.len <= max_links) return;

        const owner_vec = self.vecs.items[node];
        const Ctx = struct {
            idx: *Index,
            owner: []const f32,
            fn less(ctx: @This(), a: u32, b: u32) bool {
                return dist(ctx.owner, ctx.idx.vecs.items[a]) <
                    dist(ctx.owner, ctx.idx.vecs.items[b]);
            }
        };
        std.mem.sort(u32, list.items, Ctx{ .idx = self, .owner = owner_vec }, Ctx.less);

        var selected: std.ArrayListUnmanaged(u32) = .empty;
        defer selected.deinit(self.alloc);
        var discarded: std.ArrayListUnmanaged(u32) = .empty;
        defer discarded.deinit(self.alloc);

        for (list.items) |cand| {
            if (selected.items.len >= max_links) break;
            const d_oc = dist(owner_vec, self.vecs.items[cand]);
            var diverse = true;
            for (selected.items) |sel| {
                if (dist(self.vecs.items[cand], self.vecs.items[sel]) < d_oc) {
                    diverse = false;
                    break;
                }
            }
            if (diverse) {
                try selected.append(self.alloc, cand);
            } else {
                try discarded.append(self.alloc, cand);
            }
        }

        for (discarded.items) |cand| {
            if (selected.items.len >= max_links) break;
            try selected.append(self.alloc, cand);
        }

        @memcpy(list.items[0..selected.items.len], selected.items);
        list.shrinkRetainingCapacity(selected.items.len);
    }

    pub fn insert(self: *Index, id: u32, raw: []const f32) !void {
        if (id != self.vecs.items.len) return error.NonSequentialId;
        const v = try self.normalize(raw);
        var owns_v = true;
        errdefer if (owns_v) self.alloc.free(v);

        const level = levelFor(id);
        const level_links = try self.alloc.alloc(std.ArrayListUnmanaged(u32), level + 1);
        var owns_links = true;
        errdefer if (owns_links) {
            for (level_links) |*list| list.deinit(self.alloc);
            self.alloc.free(level_links);
        };
        for (level_links) |*list| list.* = .empty;

        // Commit the parallel arrays together so an allocation failure
        // cannot leave a vector in `vecs` that `deinit` frees twice.
        try self.vecs.ensureUnusedCapacity(self.alloc, 1);
        try self.levels.ensureUnusedCapacity(self.alloc, 1);
        try self.links.ensureUnusedCapacity(self.alloc, 1);
        try self.deleted.ensureUnusedCapacity(self.alloc, 1);
        self.vecs.appendAssumeCapacity(v);
        owns_v = false;
        self.levels.appendAssumeCapacity(@intCast(level));
        self.links.appendAssumeCapacity(level_links);
        owns_links = false;
        self.deleted.appendAssumeCapacity(false);

        if (self.entry == null) {
            self.entry = id;
            self.max_level = level;
            return;
        }

        var ep = self.entry.?;
        var cur = self.max_level;
        while (cur > level) {
            ep = self.greedy(v, ep, cur);
            cur -= 1;
        }

        var current_level: isize = @intCast(@min(level, self.max_level));
        while (current_level >= 0) : (current_level -= 1) {
            const l: usize = @intCast(current_level);
            var candidates = try self.searchLayer(v, ep, self.ef_construction, l, false);
            defer candidates.deinit(self.alloc);
            const keep = @min(candidates.items.len, if (l == 0) self.m0 else self.m);
            for (candidates.items[0..keep]) |c| {
                try self.addLink(id, c.id, l);
                try self.addLink(c.id, id, l);
            }
            if (candidates.items.len > 0) ep = candidates.items[0].id;
        }
        if (level > self.max_level) {
            self.max_level = level;
            self.entry = id;
        }
    }

    const MAGIC_V1 = "ZHNSW001";
    const MAGIC_V2 = "ZHNSW002";

    fn appendU16(b: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .little);
        try b.appendSlice(alloc, &buf);
    }

    fn appendU32(b: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try b.appendSlice(alloc, &buf);
    }

    fn readU16(bytes: []const u8, pos: *usize) !u16 {
        if (pos.* + 2 > bytes.len) return error.CorruptIndex;
        const v = std.mem.readInt(u16, bytes[pos.*..][0..2], .little);
        pos.* += 2;
        return v;
    }

    fn readU32(bytes: []const u8, pos: *usize) !u32 {
        if (pos.* + 4 > bytes.len) return error.CorruptIndex;
        const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
        pos.* += 4;
        return v;
    }

    /// Serialize the graph, parameters, tombstones, and normalised vectors. The caller owns the result.
    pub fn serialize(self: *const Index, alloc: std.mem.Allocator) ![]u8 {
        var b: std.ArrayListUnmanaged(u8) = .empty;
        errdefer b.deinit(alloc);
        try b.appendSlice(alloc, MAGIC_V2);
        try appendU32(&b, alloc, @intCast(self.dim));
        try appendU32(&b, alloc, @intCast(self.vecs.items.len));
        try appendU32(&b, alloc, self.entry orelse 0xFFFFFFFF);
        try appendU32(&b, alloc, @intCast(self.max_level));
        try appendU32(&b, alloc, @intCast(self.m));
        try appendU32(&b, alloc, @intCast(self.m0));
        try appendU32(&b, alloc, @intCast(self.ef_construction));

        const bitset_len = (self.vecs.items.len + 7) / 8;
        const bitset_start = b.items.len;
        try b.appendNTimes(alloc, 0, bitset_len);
        for (self.deleted.items, 0..) |is_del, i| {
            if (is_del) {
                b.items[bitset_start + (i >> 3)] |= @as(u8, 1) << @intCast(i & 7);
            }
        }

        for (self.vecs.items, 0..) |vec, i| {
            try appendU16(&b, alloc, self.levels.items[i]);
            for (vec) |x| try appendU32(&b, alloc, @bitCast(x));
            for (self.links.items[i]) |list| {
                try appendU32(&b, alloc, @intCast(list.items.len));
                for (list.items) |id| try appendU32(&b, alloc, id);
            }
        }
        return b.toOwnedSlice(alloc);
    }

    /// Rebuild an index from `serialize` output (supports both `ZHNSW001` and
    /// `ZHNSW002` formats). `dim` must match the stored dimension; corrupt or
    /// truncated payloads return `error.CorruptIndex`.
    pub fn deserialize(alloc: std.mem.Allocator, bytes: []const u8, dim: usize) !Index {
        if (bytes.len < MAGIC_V1.len + 16) return error.CorruptIndex;
        const is_v2 = std.mem.eql(u8, bytes[0..MAGIC_V2.len], MAGIC_V2);
        const is_v1 = !is_v2 and std.mem.eql(u8, bytes[0..MAGIC_V1.len], MAGIC_V1);
        if (!is_v1 and !is_v2) return error.CorruptIndex;

        var pos: usize = MAGIC_V1.len;
        const stored_dim = try readU32(bytes, &pos);
        if (stored_dim != dim) return error.DimensionMismatch;
        const node_count = try readU32(bytes, &pos);
        const entry_raw = try readU32(bytes, &pos);
        const max_level = try readU32(bytes, &pos);
        if (node_count > 50_000_000) return error.CorruptIndex;
        if (entry_raw != 0xFFFFFFFF and entry_raw >= node_count) return error.CorruptIndex;
        if (max_level > 64) return error.CorruptIndex;

        var idx = Index.init(alloc, dim);
        errdefer idx.deinit();
        idx.entry = if (entry_raw == 0xFFFFFFFF) null else entry_raw;
        idx.max_level = max_level;

        var bitset_slice: []const u8 = &.{};
        if (is_v2) {
            const m = try readU32(bytes, &pos);
            const m0 = try readU32(bytes, &pos);
            const ef_construction = try readU32(bytes, &pos);
            if (m < 2 or m > 1024 or m0 < m or m0 > 4096 or ef_construction == 0 or ef_construction > 100_000) {
                return error.CorruptIndex;
            }
            idx.m = m;
            idx.m0 = m0;
            idx.ef_construction = ef_construction;

            const bitset_len = (node_count + 7) / 8;
            if (pos + bitset_len > bytes.len) return error.CorruptIndex;
            bitset_slice = bytes[pos .. pos + bitset_len];
            pos += bitset_len;
        }

        var i: u32 = 0;
        while (i < node_count) : (i += 1) {
            const level = try readU16(bytes, &pos);
            if (level > 64) return error.CorruptIndex;
            if (pos + dim * 4 > bytes.len) return error.CorruptIndex;
            const vec = try alloc.alloc(f32, dim);
            var owns_vec = true;
            errdefer if (owns_vec) alloc.free(vec);
            for (vec, 0..) |*x, j| {
                const bits = std.mem.readInt(u32, bytes[pos + j * 4 ..][0..4], .little);
                const val: f32 = @bitCast(bits);
                if (!std.math.isFinite(val)) return error.CorruptIndex;
                x.* = val;
            }
            pos += dim * 4;
            const level_links = try alloc.alloc(std.ArrayListUnmanaged(u32), level + 1);
            for (level_links) |*list| list.* = .empty;
            var owns_links = true;
            errdefer if (owns_links) {
                for (level_links) |*list| list.deinit(alloc);
                alloc.free(level_links);
            };
            for (level_links) |*list| {
                const n = try readU32(bytes, &pos);
                if (n > 1024 * 1024) return error.CorruptIndex;
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    const id = try readU32(bytes, &pos);
                    if (id >= node_count or id == i) return error.CorruptIndex;
                    try list.append(alloc, id);
                }
            }
            const is_del = if (is_v2) (bitset_slice[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0 else false;

            try idx.vecs.ensureUnusedCapacity(alloc, 1);
            try idx.levels.ensureUnusedCapacity(alloc, 1);
            try idx.links.ensureUnusedCapacity(alloc, 1);
            try idx.deleted.ensureUnusedCapacity(alloc, 1);
            idx.vecs.appendAssumeCapacity(vec);
            owns_vec = false;
            idx.levels.appendAssumeCapacity(level);
            idx.links.appendAssumeCapacity(level_links);
            owns_links = false;
            idx.deleted.appendAssumeCapacity(is_del);
        }
        if (pos != bytes.len) return error.CorruptIndex;
        return idx;
    }

    /// Search returns hits sorted nearest-first. Caller frees the returned slice
    /// with the allocator passed to `init`.
    pub fn search(self: *Index, raw: []const f32, k: usize, ef: usize) ![]Hit {
        if (self.entry == null or k == 0) return self.alloc.alloc(Hit, 0);
        const q = try self.normalize(raw);
        defer self.alloc.free(q);
        var ep = self.entry.?;
        var cur = self.max_level;
        while (cur > 0) {
            ep = self.greedy(q, ep, cur);
            cur -= 1;
        }
        var candidates = try self.searchLayer(q, ep, @max(ef, k), 0, true);
        defer candidates.deinit(self.alloc);
        const n = @min(k, candidates.items.len);
        const hits = try self.alloc.alloc(Hit, n);
        for (candidates.items[0..n], 0..) |c, i| {
            hits[i] = .{ .id = c.id, .score = 1.0 - c.dist };
        }
        return hits;
    }
};

test "hnsw returns the exact nearest neighbour" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 8);
    defer idx.deinit();

    var data: [64][8]f32 = undefined;
    for (0..64) |i| {
        for (0..8) |j| {
            data[i][j] = @sin(@as(f32, @floatFromInt(i * 17 + j * 5))) + @as(f32, @floatFromInt(i)) * 0.01;
        }
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    const hits = try idx.search(&data[37], 1, 32);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u32, 37), hits[0].id);
}

test "hnsw recall against a brute-force scan" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 6);
    defer idx.deinit();

    var data: [128][6]f32 = undefined;
    for (0..128) |i| {
        for (0..6) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 13 + j * 7))) + 0.3;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    var normed: [128][6]f32 = undefined;
    for (data, 0..) |v, i| {
        var n: f32 = 0;
        for (v) |x| n += x * x;
        const scale = 1.0 / @sqrt(n);
        for (v, 0..) |x, j| normed[i][j] = x * scale;
    }

    var found: usize = 0;
    for (0..16) |qi| {
        const q = normed[qi * 7];
        var best: usize = 0;
        var best_d: f32 = std.math.inf(f32);
        for (normed, 0..) |v, i| {
            const d = Index.dist(&q, &v);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        const hits = try idx.search(&q, 5, 48);
        defer alloc.free(hits);
        for (hits) |h| {
            if (h.id == best) {
                found += 1;
                break;
            }
        }
    }
    try std.testing.expect(found >= 15);
}

test "hnsw serialization round trip" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 4);
    defer idx.deinit();
    var data: [20][4]f32 = undefined;
    for (0..20) |i| {
        for (0..4) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 11 + j * 3))) + 1.0;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    const bytes = try idx.serialize(alloc);
    defer alloc.free(bytes);
    var restored = try Index.deserialize(alloc, bytes, 4);
    defer restored.deinit();
    try std.testing.expectEqual(idx.count(), restored.count());
    try std.testing.expectEqual(idx.entry, restored.entry);
    try std.testing.expectEqual(idx.max_level, restored.max_level);
    const hits = try restored.search(&data[13], 3, 32);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(u32, 13), hits[0].id);
}

test "hnsw recall gate at 1024 vectors" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 8);
    defer idx.deinit();

    var data: [1024][8]f32 = undefined;
    for (0..data.len) |i| {
        for (0..8) |j| {
            data[i][j] = @sin(@as(f32, @floatFromInt(i * 31 + j * 17))) +
                @cos(@as(f32, @floatFromInt(i * 7 + j * 3))) * 0.5;
        }
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    var normed: [1024][8]f32 = undefined;
    for (data, 0..) |v, i| {
        var n: f32 = 0;
        for (v) |x| n += x * x;
        const scale = 1.0 / @sqrt(n);
        for (v, 0..) |x, j| normed[i][j] = x * scale;
    }

    var found: usize = 0;
    var queries: usize = 0;
    for (0..32) |qi| {
        const q = normed[(qi * 29) % normed.len];
        var best: usize = 0;
        var best_d: f32 = std.math.inf(f32);
        for (normed, 0..) |v, i| {
            const d = Index.dist(&q, &v);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        const hits = try idx.search(&q, 10, 64);
        defer alloc.free(hits);
        queries += 1;
        for (hits) |h| {
            if (h.id == best) {
                found += 1;
                break;
            }
        }
    }
    try std.testing.expect(queries == 32);
    try std.testing.expect(found * 100 >= queries * 80);
}

fn oomWorkload(alloc: std.mem.Allocator) !void {
    var idx = Index.init(alloc, 4);
    defer idx.deinit();
    var data: [12][4]f32 = undefined;
    for (0..data.len) |i| {
        for (0..4) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 13 + j * 7))) + 0.25;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);
    const hits = try idx.search(&data[7], 3, 16);
    defer alloc.free(hits);
}

test "hnsw survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomWorkload, .{});
}

fn oomDeserializeWorkload(alloc: std.mem.Allocator, bytes: []const u8, dim: usize) !void {
    var idx = try Index.deserialize(alloc, bytes, dim);
    defer idx.deinit();
}

test "hnsw deserialize survives allocation failures" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 4);
    defer idx.deinit();
    var data: [16][4]f32 = undefined;
    for (0..data.len) |i| {
        for (0..4) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 11 + j * 3))) + 1.0;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);
    const bytes = try idx.serialize(alloc);
    defer alloc.free(bytes);

    std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        oomDeserializeWorkload,
        .{ bytes, 4 },
    ) catch |e| {
        std.debug.print("hnsw deserialize oom gate: {t}\n", .{e});
        return e;
    };
}

test "hnsw tombstones exclude deleted vectors and round-trip" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 4);
    idx.m = 8;
    idx.m0 = 16;
    idx.ef_construction = 40;
    defer idx.deinit();

    var data: [10][4]f32 = undefined;
    for (0..10) |i| {
        for (0..4) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 11 + j * 3))) + 1.0;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    idx.delete(3);
    try std.testing.expect(idx.isDeleted(3));
    try std.testing.expect(!idx.isDeleted(4));
    try std.testing.expectEqual(@as(usize, 10), idx.count());
    try std.testing.expectEqual(@as(usize, 9), idx.activeCount());

    const hits = try idx.search(&data[3], 3, 16);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    for (hits) |h| try std.testing.expect(h.id != 3);

    const bytes = try idx.serialize(alloc);
    defer alloc.free(bytes);
    var restored = try Index.deserialize(alloc, bytes, 4);
    defer restored.deinit();

    try std.testing.expectEqual(@as(usize, 8), restored.m);
    try std.testing.expectEqual(@as(usize, 16), restored.m0);
    try std.testing.expectEqual(@as(usize, 40), restored.ef_construction);
    try std.testing.expect(restored.isDeleted(3));
    try std.testing.expectEqual(@as(usize, 9), restored.activeCount());

    const hits2 = try restored.search(&data[3], 3, 16);
    defer alloc.free(hits2);
    for (hits2) |h| try std.testing.expect(h.id != 3);
}

test "hnsw deserialize rejects non-finite vector elements" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 2);
    defer idx.deinit();
    try idx.insert(0, &.{ 1.0, 0.0 });

    const bytes = try idx.serialize(alloc);
    defer alloc.free(bytes);

    // Header (8 magic + 28 u32s) + bitset (1 byte) + level (2 bytes) = 39 bytes before vec[0].
    const vec_offset = 8 + 28 + 1 + 2;
    const nan_bits: u32 = @bitCast(std.math.nan(f32));
    std.mem.writeInt(u32, bytes[vec_offset..][0..4], nan_bits, .little);

    try std.testing.expectError(error.CorruptIndex, Index.deserialize(alloc, bytes, 2));
}

test "hnsw search traverses through deleted entry node and supports ZHNSW001" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 4);
    defer idx.deinit();

    var data: [24][4]f32 = undefined;
    for (0..24) |i| {
        for (0..4) |j| data[i][j] = @sin(@as(f32, @floatFromInt(i * 17 + j * 5))) + @as(f32, @floatFromInt(i)) * 0.05;
    }
    for (data, 0..) |v, i| try idx.insert(@intCast(i), &v);

    // Delete the entry node itself and several neighbors; search must still
    // traverse through them to reach live nodes.
    const entry_id = idx.entry.?;
    idx.delete(entry_id);
    for (0..6) |i| idx.delete(@intCast(i));

    const target: usize = 20;
    const hits = try idx.search(&data[target], 3, 24);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expectEqual(@as(u32, target), hits[0].id);
    for (hits) |h| try std.testing.expect(!idx.isDeleted(h.id));

    // Construct a minimal ZHNSW001 payload (single node, 2D) and verify backward-compatible load.
    var v1: std.ArrayListUnmanaged(u8) = .empty;
    defer v1.deinit(alloc);
    try v1.appendSlice(alloc, "ZHNSW001");
    try Index.appendU32(&v1, alloc, 2); // dim
    try Index.appendU32(&v1, alloc, 1); // node_count
    try Index.appendU32(&v1, alloc, 0); // entry
    try Index.appendU32(&v1, alloc, 0); // max_level
    try Index.appendU16(&v1, alloc, 0); // node 0 level
    try Index.appendU32(&v1, alloc, @bitCast(@as(f32, 1.0)));
    try Index.appendU32(&v1, alloc, @bitCast(@as(f32, 0.0)));
    try Index.appendU32(&v1, alloc, 0); // 0 links at level 0

    var v1_idx = try Index.deserialize(alloc, v1.items, 2);
    defer v1_idx.deinit();
    try std.testing.expectEqual(@as(usize, 16), v1_idx.m);
    try std.testing.expectEqual(@as(usize, 32), v1_idx.m0);
    try std.testing.expectEqual(@as(usize, 100), v1_idx.ef_construction);
    try std.testing.expectEqual(@as(usize, 1), v1_idx.activeCount());
}

test "hnsw recall and correctness under delete and re-insert updates" {
    const alloc = std.testing.allocator;
    var idx = Index.init(alloc, 8);
    defer idx.deinit();

    var data: [64][8]f32 = undefined;
    for (0..64) |i| {
        for (0..8) |j| {
            data[i][j] = @sin(@as(f32, @floatFromInt(i * 19 + j * 7))) + @as(f32, @floatFromInt(i)) * 0.03;
        }
        try idx.insert(@intCast(i), &data[i]);
    }

    // Simulate updating docs 0..16: tombstone old IDs and insert new vectors at 64..80.
    var updated: [16][8]f32 = undefined;
    for (0..16) |i| {
        idx.delete(@intCast(i));
        for (0..8) |j| {
            updated[i][j] = @cos(@as(f32, @floatFromInt((i + 100) * 23 + j * 11))) + 0.5;
        }
        try idx.insert(@intCast(64 + i), &updated[i]);
    }

    try std.testing.expectEqual(@as(usize, 80), idx.count());
    try std.testing.expectEqual(@as(usize, 64), idx.activeCount());

    for (0..16) |i| {
        const hits = try idx.search(&updated[i], 3, 32);
        defer alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(@as(u32, @intCast(64 + i)), hits[0].id);
        for (hits) |h| try std.testing.expect(!idx.isDeleted(h.id));
    }
}

test "hnsw high-dimensionality and boundary cases" {
    const alloc = std.testing.allocator;

    // 256-dimensional vectors + serialization round-trip.
    var hi = Index.init(alloc, 256);
    defer hi.deinit();
    var vecs: [16][256]f32 = undefined;
    for (0..16) |i| {
        for (0..256) |j| {
            vecs[i][j] = @sin(@as(f32, @floatFromInt(i * 37 + j * 13))) + @as(f32, @floatFromInt(i)) * 0.02;
        }
        try hi.insert(@intCast(i), &vecs[i]);
    }
    const bytes = try hi.serialize(alloc);
    defer alloc.free(bytes);
    var hi2 = try Index.deserialize(alloc, bytes, 256);
    defer hi2.deinit();

    const hits = try hi2.search(&vecs[11], 1, 16);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u32, 11), hits[0].id);

    // Invalid inputs: zero vector, NaN vector, dimension mismatch, k = 0.
    const zero_vec: [256]f32 = @splat(0);
    try std.testing.expectError(error.InvalidVector, hi.insert(16, &zero_vec));
    var nan_vec: [256]f32 = @splat(1.0);
    nan_vec[7] = std.math.nan(f32);
    try std.testing.expectError(error.InvalidVector, hi.insert(16, &nan_vec));
    try std.testing.expectError(error.DimensionMismatch, hi.insert(16, &.{ 1.0, 2.0 }));

    const empty_hits = try hi.search(&vecs[0], 0, 16);
    defer alloc.free(empty_hits);
    try std.testing.expectEqual(@as(usize, 0), empty_hits.len);
}
