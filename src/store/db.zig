const std = @import("std");
const tree = @import("../doc/tree.zig");
const Doc = tree.Doc;
const Rev = @import("../doc/rev.zig").Rev;
const fmt = @import("format.zig");
const Crc = @import("../util/checksum.zig");

const MANIFEST_MAGIC = fmt.MANIFEST_MAGIC;
const SNAPSHOT_MAGIC = fmt.SNAPSHOT_MAGIC;
const WAL_HDR = 16; // len u32 | crc u32 | seq u64
const MANIFEST_LEN = 28; // magic 8 | gen u64 | last_seq u64 | crc u32
const SNAP_HDR = 28; // magic 8 | gen u64 | last_seq u64 | count u32

pub const MAX_STORAGE_FILE_BYTES: usize = 1 << 31;

pub const Error = error{
    Corrupt,
    TooLarge,
    FileTooLarge,
    OutOfMemory,
    InvalidRev,
    Conflict,
    NotFound,
    Io,
    DatabaseLocked,
    MemoryLimitExceeded,
    UnsupportedVersion,
};

pub const Local = struct {
    id: []u8,
    rev: u32,
    body: []u8,
};

/// Allocate a local document and take owned copies of `id` and `body`. The
/// caller owns all three allocations; a failure here never leaves a partial
/// local behind.
fn createLocal(alloc: std.mem.Allocator, id: []const u8, rev: u32, body: []const u8) !*Local {
    const l = try alloc.create(Local);
    errdefer alloc.destroy(l);
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_body = try alloc.dupe(u8, body);
    errdefer alloc.free(owned_body);
    l.* = .{ .id = owned_id, .rev = rev, .body = owned_body };
    return l;
}

pub const PutResult = struct {
    rev: Rev,
    seq: u64,
    created: bool,
};

const Manifest = struct { gen: u64, last_seq: u64 };
const SegmentInfo = struct { name: []u8, max_seq: u64 };
const SEGMENT_MAGIC = fmt.SEGMENT_MAGIC;

fn docApproxBytes(doc: *const Doc) usize {
    var n: usize = @sizeOf(Doc) + doc.id.len;
    for (doc.leaves.items) |leaf| {
        n += @sizeOf(tree.Leaf) + leaf.body.len + leaf.ancestry.len * @sizeOf(Rev);
    }
    for (doc.retained.items) |r| {
        n += @sizeOf(tree.Retained) + r.body.len;
    }
    return n;
}

fn localApproxBytes(l: *const Local) usize {
    return @sizeOf(Local) + l.id.len + l.body.len;
}

pub const Db = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,
    docs: std.StringHashMapUnmanaged(*Doc) = .empty,
    designs: std.StringHashMapUnmanaged(void) = .empty,
    locals: std.StringHashMapUnmanaged(*Local) = .empty,
    seq: u64 = 0,
    gen: u64 = 0,
    wal: std.Io.File,
    wal_size: u64 = 0,
    segments: std.ArrayListUnmanaged(SegmentInfo) = .empty,
    segment_seq: u64 = 0,
    segment_counter: u64 = 0,
    locals_wal: std.Io.File,
    locals_size: u64 = 0,
    locals_limit: u64 = 1024 * 1024,
    wal_limit: u64 = 64 * 1024 * 1024,
    failed: bool = false,
    wal_dirty_tail: bool = false,
    wal_unrecoverable: bool = false,
    approx_bytes: usize = 0,
    live_doc_count: usize = 0,
    deleted_doc_count: usize = 0,
    live_body_bytes: u64 = 0,
    max_memory_bytes: usize = 0,
    max_blob_bytes: usize = 64 * 1024 * 1024,
    uuid: [32]u8 = undefined,
    revs_limit: u32 = 1000,
    purge_seq: u64 = 0,
    security_members: std.StringHashMapUnmanaged(void) = .empty,
    security_admins: std.StringHashMapUnmanaged(void) = .empty,
    security_member_roles: std.StringHashMapUnmanaged(void) = .empty,
    security_admin_roles: std.StringHashMapUnmanaged(void) = .empty,
    security_restricted: bool = false,
    /// The one lock for this database's in-memory state. Every thread that
    /// reads or writes `docs`, `seq`, `locals`, the WAL or the security maps
    /// takes it, through `lock`/`unlock` so a safe build can check ownership.
    mutex: std.Io.Mutex = .init,
    /// Thread that holds `mutex` (safe builds only; 0 when unlocked).
    mutex_owner: std.atomic.Value(usize) = .init(0),
    /// Set by the server once the handle is shared between threads. The CLI
    /// and unit tests use a `Db` from one thread with no lock, so the check
    /// stays off for them.
    lock_checks: bool = false,
    /// Number of active users holding this handle (`acquireDb`, `pinDb`, `hAttGet`)
    /// so `App.deleteDb` waits before closing it. `repl_active` distinguishes an
    /// active replication from ordinary HTTP requests, and `closing` prevents new
    /// acquisitions while a delete drains `pins`. Guarded by the server mutex.
    pins: usize = 0,
    repl_active: bool = false,
    closing: bool = false,

    pub fn lock(self: *Db) void {
        self.mutex.lockUncancelable(self.io);
        if (std.debug.runtime_safety) self.mutex_owner.store(std.Thread.getCurrentId(), .monotonic);
    }

    pub fn unlock(self: *Db) void {
        if (std.debug.runtime_safety) self.mutex_owner.store(0, .monotonic);
        self.mutex.unlock(self.io);
    }

    /// Mutating methods call this: two threads changing one database under
    /// different locks lost fsynced writes (GLM review C1), so a caller that
    /// forgot the lock now fails loudly in safe builds.
    pub fn assertLocked(self: *const Db) void {
        if (!std.debug.runtime_safety or !self.lock_checks) return;
        if (self.mutex_owner.load(.monotonic) != std.Thread.getCurrentId()) {
            @panic("Db mutated without holding db.mutex");
        }
    }

    pub fn open(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !*Db {
        std.Io.Dir.cwd().createDirPath(io, path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        errdefer dir.close(io);
        const lock_file = dir.createFile(io, ".zouch.lock", .{ .truncate = false }) catch
            try dir.openFile(io, ".zouch.lock", .{ .mode = .read_write });
        errdefer lock_file.close(io);
        if (!(try lock_file.tryLock(io, .exclusive))) return error.DatabaseLocked;
        dir.createDirPath(io, "blobs") catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        if (dir.openDir(io, "blobs", .{ .iterate = true })) |bdir_const| {
            var bdir = bdir_const;
            defer bdir.close(io);
            var bit = bdir.iterate();
            while (bit.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.startsWith(u8, entry.name, ".upload-") and std.mem.endsWith(u8, entry.name, ".bin")) {
                    bdir.deleteFile(io, entry.name) catch {};
                }
            }
        } else |_| {}

        const self = try alloc.create(Db);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .io = io, .dir = dir, .lock_file = lock_file, .wal = undefined, .locals_wal = undefined };
        errdefer self.deinitLoaded();

        try self.load();
        {
            var dit = self.docs.iterator();
            while (dit.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, "_design/"))
                    try self.designs.put(self.alloc, entry.key_ptr.*, {});
            }
        }

        self.wal = dir.openFile(io, "wal.log", .{ .mode = .read_write }) catch
            try dir.createFile(io, "wal.log", .{ .truncate = false });
        errdefer self.wal.close(io);
        self.wal_size = try self.wal.length(io);

        self.locals_wal = dir.openFile(io, "locals.log", .{ .mode = .read_write }) catch
            try dir.createFile(io, "locals.log", .{ .truncate = false });
        errdefer self.locals_wal.close(io);
        self.locals_size = try self.locals_wal.length(io);
        try self.loadLocals();
        self.recomputeApproxBytes();
        self.recomputeStats();
        self.revs_limit = self.readRevsLimit();
        self.purge_seq = self.readPurgeSeq();
        try self.loadSecurity();
        try self.loadOrCreateUuid();
        return self;
    }

    pub fn setMaxMemoryBytes(self: *Db, max: usize) void {
        self.max_memory_bytes = max;
    }

    pub fn setMaxBlobBytes(self: *Db, max: usize) void {
        self.max_blob_bytes = max;
    }

    fn loadOrCreateUuid(self: *Db) !void {
        const bytes = self.readFile("uuid", 64) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        if (bytes) |raw| {
            defer self.alloc.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \r\n\t");
            if (validBlobHex(trimmed)) {
                @memcpy(&self.uuid, trimmed);
                return;
            }
        }
        var rnd: [16]u8 = undefined;
        self.io.random(&rnd);
        self.uuid = std.fmt.bytesToHex(rnd, .lower);
        try self.writeAtomic("uuid", &self.uuid);
    }

    pub fn recomputeApproxBytes(self: *Db) void {
        var total: usize = 0;
        var dit = self.docs.valueIterator();
        while (dit.next()) |d| total +|= docApproxBytes(d.*);
        var lit = self.locals.valueIterator();
        while (lit.next()) |l| total +|= localApproxBytes(l.*);
        self.approx_bytes = total;
    }

    fn docBodyBytes(doc: *const Doc) u64 {
        var b: u64 = 0;
        for (doc.leaves.items) |leaf| b += leaf.body.len;
        return b;
    }

    pub fn recomputeStats(self: *Db) void {
        var live: usize = 0;
        var deleted: usize = 0;
        var body_bytes: u64 = 0;
        var dit = self.docs.valueIterator();
        while (dit.next()) |d| {
            if (d.*.winnerLeaf().deleted) deleted += 1 else live += 1;
            body_bytes += docBodyBytes(d.*);
        }
        self.live_doc_count = live;
        self.deleted_doc_count = deleted;
        self.live_body_bytes = body_bytes;
    }

    fn deinitLoaded(self: *Db) void {
        var it = self.docs.valueIterator();
        while (it.next()) |d| d.*.deinit(self.alloc);
        self.docs.deinit(self.alloc);
        self.designs.deinit(self.alloc);
        for (self.segments.items) |seg| self.alloc.free(seg.name);
        self.segments.deinit(self.alloc);
        var lit = self.locals.valueIterator();
        while (lit.next()) |l| {
            self.alloc.free(l.*.id);
            self.alloc.free(l.*.body);
            self.alloc.destroy(l.*);
        }
        self.locals.deinit(self.alloc);
        self.clearSecurity();
    }

    pub fn close(self: *Db) void {
        self.closeInternal(true);
    }

    pub fn closeReadOnly(self: *Db) void {
        self.closeInternal(false);
    }

    fn closeInternal(self: *Db, write_snapshot: bool) void {
        // Closing happens with no other user of the handle (pins are zero).
        self.lock_checks = false;
        if (write_snapshot and !self.failed) self.snapshot() catch {};
        self.wal.close(self.io);
        self.locals_wal.close(self.io);
        var it = self.docs.valueIterator();
        while (it.next()) |d| d.*.deinit(self.alloc);
        self.docs.deinit(self.alloc);
        self.designs.deinit(self.alloc);
        for (self.segments.items) |seg| self.alloc.free(seg.name);
        self.segments.deinit(self.alloc);
        var lit = self.locals.valueIterator();
        while (lit.next()) |l| {
            self.alloc.free(l.*.id);
            self.alloc.free(l.*.body);
            self.alloc.destroy(l.*);
        }
        self.locals.deinit(self.alloc);
        self.clearSecurity();
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.alloc.destroy(self);
    }

    fn fileExists(self: *Db, name: []const u8) bool {
        const f = self.dir.openFile(self.io, name, .{}) catch return false;
        f.close(self.io);
        return true;
    }

    fn load(self: *Db) !void {
        const had_manifest = self.fileExists("MANIFEST_A") or self.fileExists("MANIFEST_B");
        const a = try self.readManifest("MANIFEST_A");
        const b = try self.readManifest("MANIFEST_B");
        var best: ?Manifest = null;
        if (a) |m| best = m;
        if (b) |m| {
            if (best == null or m.gen > best.?.gen) best = m;
        }

        var loaded_snapshot = false;
        if (best) |m| {
            const name = try self.snapName(m.gen);
            defer self.alloc.free(name);
            if (self.readStorageFile(name)) |bytes| {
                defer self.alloc.free(bytes);
                try self.loadSnapshot(bytes, m.gen);
                loaded_snapshot = true;
            } else |e| {
                // A missing snapshot may mean the alternate generation is the
                // usable copy. Any other error (FileTooLarge, OutOfMemory, EIO)
                // must fail closed: silently opening an older or empty view
                // loses acknowledged data.
                if (e != error.FileNotFound) return e;
                const other = if (a != null and a.?.gen == m.gen) b else a;
                if (other) |o| {
                    const oname = try self.snapName(o.gen);
                    defer self.alloc.free(oname);
                    if (self.readStorageFile(oname)) |obytes| {
                        defer self.alloc.free(obytes);
                        try self.loadSnapshot(obytes, o.gen);
                        loaded_snapshot = true;
                    } else |oe| {
                        if (oe != error.FileNotFound) return oe;
                    }
                }
            }
        }

        try self.loadSegments();
        // A valid manifest is written only after its snapshot. If neither
        // snapshot can be loaded and there are no segment files, opening as an
        // empty database would silently discard the acknowledged data.
        if (!loaded_snapshot and self.segments.items.len == 0 and had_manifest) {
            return Error.Corrupt;
        }
        try self.replay();
    }

    fn loadSnapshot(self: *Db, bytes: []const u8, gen: u64) !void {
        if (bytes.len < SNAP_HDR) return Error.Corrupt;
        try fmt.validateHeaderVersion(bytes[0..8], "ZSNP", 8);
        const snap_gen = std.mem.readInt(u64, bytes[8..16], .little);
        const last_seq = std.mem.readInt(u64, bytes[16..24], .little);
        const doc_count = std.mem.readInt(u32, bytes[24..28], .little);
        if (snap_gen != gen) return Error.Corrupt;

        var pos: usize = SNAP_HDR;
        var i: u32 = 0;
        while (i < doc_count) : (i += 1) {
            if (pos + 8 > bytes.len) return Error.Corrupt;
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            pos += 8;
            if (pos + len > bytes.len) return Error.Corrupt;
            const payload = bytes[pos .. pos + len];
            pos += len;
            if (Crc.of(payload) != crc) return Error.Corrupt;
            const doc = try fmt.decodeDoc(self.alloc, payload);
            errdefer doc.deinit(self.alloc);
            if (self.docs.fetchRemove(doc.id)) |kv| kv.value.deinit(self.alloc);
            try self.docs.put(self.alloc, doc.id, doc);
        }
        self.seq = last_seq;
        self.gen = gen;
        self.segment_seq = last_seq;
    }

    fn readStorageFile(self: *Db, name: []const u8) ![]u8 {
        return self.readFile(name, MAX_STORAGE_FILE_BYTES) catch |e| switch (e) {
            error.TooLarge => Error.FileTooLarge,
            else => e,
        };
    }

    fn replay(self: *Db) !void {
        const bytes = self.readStorageFile("wal.log") catch |e| {
            if (e == error.FileNotFound) return;
            return e;
        };
        defer self.alloc.free(bytes);

        var pos: usize = 0;
        var good: usize = 0;
        var max_seq: u64 = 0;
        while (pos + WAL_HDR <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            const seq = std.mem.readInt(u64, bytes[pos + 8 ..][0..8], .little);
            const start = pos + WAL_HDR;
            if (start + len > bytes.len) break;
            const payload = bytes[start .. start + len];
            if (Crc.of(payload) != crc) break;

            const doc = fmt.decodeDoc(self.alloc, payload) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooLarge => return error.TooLarge,
                else => break,
            };
            if (seq > self.seq) {
                if (self.docs.fetchRemove(doc.id)) |kv| kv.value.deinit(self.alloc);
                self.docs.put(self.alloc, doc.id, doc) catch {
                    doc.deinit(self.alloc);
                    return Error.OutOfMemory;
                };
                max_seq = @max(max_seq, seq);
            } else {
                doc.deinit(self.alloc);
            }
            pos = start + len;
            good = pos;
        }

        if (good < bytes.len) {
            try self.walTruncateTo(good);
        }
        if (max_seq > self.seq) self.seq = max_seq;
    }

    fn walTruncateTo(self: *Db, size: u64) !void {
        // The WAL is opened after replay; truncate via a temporary handle.
        const f = try self.dir.openFile(self.io, "wal.log", .{ .mode = .read_write });
        defer f.close(self.io);
        try f.setLength(self.io, size);
        try f.sync(self.io);
    }

    fn loadSegmentBytes(self: *Db, bytes: []const u8) !u64 {
        if (bytes.len < 12) return Error.Corrupt;
        try fmt.validateHeaderVersion(bytes[0..8], "ZSEG", 8);
        const record_count = std.mem.readInt(u32, bytes[8..12], .little);
        const base_seq = self.seq;
        var pos: usize = 12;
        var max_seq: u64 = 0;
        var i: u32 = 0;
        while (i < record_count) : (i += 1) {
            if (pos + 8 > bytes.len) return Error.Corrupt;
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            pos += 8;
            if (pos + len > bytes.len) return Error.Corrupt;
            const payload = bytes[pos .. pos + len];
            pos += len;
            if (Crc.of(payload) != crc) return Error.Corrupt;
            const doc = try fmt.decodeDoc(self.alloc, payload);
            errdefer doc.deinit(self.alloc);
            if (doc.seq > base_seq) {
                if (self.docs.fetchRemove(doc.id)) |kv| kv.value.deinit(self.alloc);
                try self.docs.put(self.alloc, doc.id, doc);
                max_seq = @max(max_seq, doc.seq);
            } else {
                doc.deinit(self.alloc);
            }
        }
        self.seq = @max(self.seq, max_seq);
        return max_seq;
    }

    fn loadSegments(self: *Db) !void {
        const bytes = self.readFile("segments", 1 << 20) catch |e| switch (e) {
            // A missing manifest simply means no segment is registered yet.
            // Any other failure (OutOfMemory, Io) must abort the open: treating
            // it as "no segments" would publish an empty view of a database
            // whose records are still on disk.
            error.FileNotFound => return,
            else => return e,
        };
        defer self.alloc.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const magic = lines.next() orelse return Error.Corrupt;
        try fmt.validateHeaderVersion(magic, "ZSEGS", 8);
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var it = std.mem.splitScalar(u8, line, ' ');
            const name = it.next() orelse continue;
            const seq_s = it.next() orelse continue;
            const info_seq = std.fmt.parseInt(u64, seq_s, 10) catch continue;
            const seg = self.readStorageFile(name) catch |e| switch (e) {
                // Raced with a merge that removed the file: safe to skip.
                error.FileNotFound => continue,
                // Skipping a segment we cannot read would advance segment_seq
                // past records that were never loaded, and the next snapshot
                // would persist that hole.
                else => return e,
            };
            defer self.alloc.free(seg);
            const max_seq = try self.loadSegmentBytes(seg);
            self.segment_seq = @max(self.segment_seq, @max(max_seq, info_seq));
            self.segment_counter += 1;
            const owned = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(owned);
            try self.segments.append(self.alloc, .{ .name = owned, .max_seq = @max(max_seq, info_seq) });
        }
    }

    fn writeSegmentsManifestFor(self: *Db, items: []const SegmentInfo) !void {
        var b: std.ArrayListUnmanaged(u8) = .empty;
        defer b.deinit(self.alloc);
        try b.appendSlice(self.alloc, fmt.SEGMENTS_MAGIC ++ "\n");
        for (items) |seg| {
            const line = try std.fmt.allocPrint(self.alloc, "{s} {d}\n", .{ seg.name, seg.max_seq });
            defer self.alloc.free(line);
            try b.appendSlice(self.alloc, line);
        }
        try self.writeAtomic("segments", b.items);
    }

    fn writeSegmentsManifest(self: *Db) !void {
        try self.writeSegmentsManifestFor(self.segments.items);
    }

    fn mergeSegments(self: *Db, current: ?*const Doc) !void {
        if (self.segments.items.len < 2) return;
        var selected: std.ArrayListUnmanaged(*const Doc) = .empty;
        defer selected.deinit(self.alloc);
        var it = self.docs.valueIterator();
        while (it.next()) |d| {
            if (d.*.seq <= self.segment_seq) {
                selected.append(self.alloc, d.*) catch return Error.OutOfMemory;
            }
        }
        if (current) |c| {
            if (c.seq <= self.segment_seq and self.docs.get(c.id) == null) {
                selected.append(self.alloc, c) catch return Error.OutOfMemory;
            }
        }

        self.segment_counter += 1;
        const name = try std.fmt.allocPrint(self.alloc, "segment-{d:0>6}.bin", .{self.segment_counter});
        errdefer self.alloc.free(name);
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{name});
        defer self.alloc.free(tmp);
        errdefer self.dir.deleteFile(self.io, tmp) catch {};

        var hdr: [SEGMENT_MAGIC.len + 4]u8 = undefined;
        @memcpy(hdr[0..SEGMENT_MAGIC.len], SEGMENT_MAGIC);
        std.mem.writeInt(u32, hdr[SEGMENT_MAGIC.len..][0..4], @intCast(selected.items.len), .little);

        var max_seq: u64 = 0;
        {
            const f = try self.dir.createFile(self.io, tmp, .{ .truncate = true });
            defer f.close(self.io);
            var offset: u64 = 0;
            try f.writePositionalAll(self.io, &hdr, offset);
            offset += hdr.len;

            var rec: std.ArrayListUnmanaged(u8) = .empty;
            defer rec.deinit(self.alloc);
            for (selected.items) |d| {
                rec.clearRetainingCapacity();
                try fmt.encodeDoc(&rec, self.alloc, d);
                try self.writeDocFrame(f, &offset, rec.items);
                max_seq = @max(max_seq, d.seq);
            }
            try f.sync(self.io);
        }
        try std.Io.Dir.rename(self.dir, tmp, self.dir, name, self.io);
        var published = false;
        errdefer if (!published) self.dir.deleteFile(self.io, name) catch {};
        try self.syncParentDir(name);

        const new_info = [_]SegmentInfo{.{ .name = name, .max_seq = max_seq }};
        try self.writeSegmentsManifestFor(&new_info);

        try self.segments.ensureUnusedCapacity(self.alloc, 1);
        for (self.segments.items) |old| {
            self.dir.deleteFile(self.io, old.name) catch {};
            self.alloc.free(old.name);
        }
        self.segments.clearRetainingCapacity();
        self.segments.appendAssumeCapacity(new_info[0]);
        published = true;
        self.segment_seq = @max(self.segment_seq, max_seq);
    }

    fn clearSegments(self: *Db) !void {
        for (self.segments.items) |seg| {
            self.dir.deleteFile(self.io, seg.name) catch {};
            self.alloc.free(seg.name);
        }
        self.segments.clearRetainingCapacity();
        self.segment_seq = self.seq;
        try self.writeSegmentsManifest();
    }

    fn flushSegment(self: *Db, current: ?*const Doc) !void {
        var changed: std.ArrayListUnmanaged(*const Doc) = .empty;
        defer changed.deinit(self.alloc);
        var it = self.docs.valueIterator();
        while (it.next()) |d| {
            if (d.*.seq > self.segment_seq) changed.append(self.alloc, d.*) catch return Error.OutOfMemory;
        }
        if (current) |c| {
            if (c.seq > self.segment_seq and self.docs.get(c.id) == null) {
                changed.append(self.alloc, c) catch return Error.OutOfMemory;
            }
        }
        if (changed.items.len == 0) {
            try self.wal.setLength(self.io, 0);
            try self.wal.sync(self.io);
            self.wal_size = 0;
            return;
        }

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        defer bytes.deinit(self.alloc);
        try bytes.appendSlice(self.alloc, SEGMENT_MAGIC);
        try appendU32(&bytes, self.alloc, @intCast(changed.items.len));
        var max_seq: u64 = 0;
        for (changed.items) |d| {
            var rec: std.ArrayListUnmanaged(u8) = .empty;
            defer rec.deinit(self.alloc);
            try fmt.encodeDoc(&rec, self.alloc, d);
            try appendU32(&bytes, self.alloc, @intCast(rec.items.len));
            try appendU32(&bytes, self.alloc, Crc.of(rec.items));
            try bytes.appendSlice(self.alloc, rec.items);
            max_seq = @max(max_seq, d.seq);
        }

        self.segment_counter += 1;
        const name = try std.fmt.allocPrint(self.alloc, "segment-{d:0>6}.bin", .{self.segment_counter});
        errdefer self.alloc.free(name);
        try self.writeAtomic(name, bytes.items);
        try self.segments.append(self.alloc, .{ .name = name, .max_seq = max_seq });
        try self.writeSegmentsManifest();
        try self.wal.setLength(self.io, 0);
        try self.wal.sync(self.io);
        self.wal_size = 0;
        self.segment_seq = max_seq;
        if (self.segments.items.len >= 8) try self.mergeSegments(current);
    }

    fn validBlobHex(hex: []const u8) bool {
        if (hex.len != 32) return false;
        for (hex) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    pub fn writeBlob(self: *Db, hex: []const u8, data: []const u8) !void {
        if (!validBlobHex(hex)) return error.InvalidBlob;
        if (self.max_memory_bytes > 0 and self.approx_bytes +| data.len > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "blobs/{s}.bin", .{hex}) catch return error.NameTooLong;
        try self.writeAtomic(p, data);
    }

    pub const BlobUpload = struct {
        hex: [32]u8,
        digest: [16]u8,
        len: usize,
    };

    pub fn writeBlobStream(self: *Db, reader: *std.Io.Reader, max: usize) !BlobUpload {
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        var tmp_buf: [96]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "blobs/.upload-{x}.bin", .{std.mem.readInt(u64, &rnd, .little)}) catch return error.NameTooLong;
        var f = self.dir.createFile(self.io, tmp, .{ .truncate = true }) catch |e| return e;
        errdefer self.dir.deleteFile(self.io, tmp) catch {};
        defer f.close(self.io);

        // Stack safety note: allocates ~72 KiB on the caller's stack; safe on
        // 16 MiB HTTP worker and 2 MiB replicator stacks, never call from the
        // 1 MiB feed scheduler thread.
        var write_buf: [64 * 1024]u8 = undefined;
        var file_writer = f.writer(self.io, &write_buf);
        // Bound the copy before it reaches the disk, and hash it on the way
        // through, so a large attachment costs a fixed buffer rather than its
        // own size in memory.
        var limit_buf: [4096]u8 = undefined;
        var limited = reader.limited(.limited(max), &limit_buf);
        var hash_buf: [4096]u8 = undefined;
        var hasher = std.crypto.hash.Md5.init(.{});
        var hashed = limited.interface.hashed(&hasher, &hash_buf);
        const total = hashed.reader.streamRemaining(&file_writer.interface) catch |e| switch (e) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return file_writer.err orelse error.Io,
        };
        if (total == max) {
            if (reader.peekByte()) |_| {
                return error.TooLarge;
            } else |e| switch (e) {
                error.EndOfStream => {},
                error.ReadFailed => return error.ReadFailed,
            }
        }
        file_writer.interface.flush() catch return file_writer.err orelse error.Io;
        try f.sync(self.io);
        var digest: [16]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        var final_buf: [64]u8 = undefined;
        const final = std.fmt.bufPrint(&final_buf, "blobs/{s}.bin", .{hex}) catch return error.NameTooLong;
        try std.Io.Dir.rename(self.dir, tmp, self.dir, final, self.io);
        try self.syncParentDir(final);
        return .{ .hex = hex, .digest = digest, .len = total };
    }

    /// Copy a blob from another database without taking its bytes through
    /// memory. The name is the digest, so the file goes across as it is.
    pub fn copyBlobFrom(self: *Db, source: *Db, hex: []const u8) !void {
        if (!validBlobHex(hex)) return error.InvalidBlob;
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "blobs/{s}.bin", .{hex}) catch return error.NameTooLong;
        if (self.dir.openFile(self.io, p, .{})) |f| {
            f.close(self.io);
            return; // already here; the name is the content
        } else |_| {}
        try std.Io.Dir.copyFile(source.dir, p, self.dir, p, self.io, .{});
        try self.syncParentDir(p);
    }

    /// Open a blob for reading without loading it, so a caller can hand it to
    /// the socket in pieces. `readBlob` costs its own size in memory and refuses
    /// anything past 64MB.
    pub fn openBlob(self: *Db, hex: []const u8) !std.Io.File {
        if (!validBlobHex(hex)) return error.InvalidBlob;
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "blobs/{s}.bin", .{hex}) catch return error.NameTooLong;
        return self.dir.openFile(self.io, p, .{});
    }

    pub fn readBlob(self: *Db, alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
        if (!validBlobHex(hex)) return error.InvalidBlob;
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "blobs/{s}.bin", .{hex}) catch return error.NameTooLong;
        const f = try self.dir.openFile(self.io, p, .{});
        defer f.close(self.io);
        const len = try f.length(self.io);
        if (len > self.max_blob_bytes) return error.TooLarge;
        const out = try alloc.alloc(u8, @intCast(len));
        errdefer alloc.free(out);
        _ = try f.readPositionalAll(self.io, out, 0);
        return out;
    }

    fn snapName(self: *Db, gen: u64) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "snapshot-{d:0>6}.bin", .{gen});
    }

    fn readManifest(self: *Db, name: []const u8) !?Manifest {
        const bytes = self.readFile(name, MANIFEST_LEN) catch |e| switch (e) {
            error.FileNotFound => return null,
            // The caller decides whether an unreadable manifest is fatal. It
            // must not be mistaken for "no manifest": load() would fall back to
            // an older snapshot while the WAL for the newer one is gone.
            else => return e,
        };
        defer self.alloc.free(bytes);
        if (bytes.len != MANIFEST_LEN) return null;
        fmt.validateHeaderVersion(bytes[0..8], "ZMAN", 8) catch |e| switch (e) {
            error.UnsupportedVersion => return Error.UnsupportedVersion,
            else => return null,
        };
        const gen = std.mem.readInt(u64, bytes[8..16], .little);
        const last_seq = std.mem.readInt(u64, bytes[16..24], .little);
        const crc = std.mem.readInt(u32, bytes[24..28], .little);
        if (Crc.of(bytes[0..24]) != crc) return null;
        return .{ .gen = gen, .last_seq = last_seq };
    }

    fn writeManifest(self: *Db) !void {
        var buf: [MANIFEST_LEN]u8 = undefined;
        @memcpy(buf[0..8], MANIFEST_MAGIC);
        std.mem.writeInt(u64, buf[8..16], self.gen, .little);
        std.mem.writeInt(u64, buf[16..24], self.seq, .little);
        std.mem.writeInt(u32, buf[24..28], Crc.of(buf[0..24]), .little);
        const name = if (self.gen % 2 == 1) "MANIFEST_A" else "MANIFEST_B";
        try self.writeAtomic(name, &buf);
    }

    fn readFile(self: *Db, name: []const u8, max: usize) ![]u8 {
        return self.readFileAlloc(self.alloc, name, max);
    }

    /// Read a whole file into `alloc`. Callers that hand the bytes to a
    /// request (or to a short-lived arena) must use this instead of `readFile`
    /// so the buffer is owned by the allocator that will release it.
    fn readFileAlloc(self: *Db, alloc: std.mem.Allocator, name: []const u8, max: usize) ![]u8 {
        const f = self.dir.openFile(self.io, name, .{}) catch |e| return e;
        defer f.close(self.io);
        const len = try f.length(self.io);
        if (len > max) return Error.TooLarge;
        const buf = try alloc.alloc(u8, @intCast(len));
        errdefer alloc.free(buf);
        _ = try f.readPositionalAll(self.io, buf, 0);
        return buf;
    }

    /// Fsync the directory that owns `path` after a rename, so the new entry
    /// survives a power cut rather than only a process kill. The directory must
    /// be opened with `.iterate` because an O_PATH handle rejects fsync.
    fn syncParentDir(self: *Db, path: []const u8) !void {
        if (@import("builtin").os.tag == .windows) return;
        const parent = std.fs.path.dirname(path) orelse ".";
        var dir = self.dir.openDir(self.io, parent, .{ .iterate = true }) catch return Error.Io;
        defer dir.close(self.io);
        while (true) {
            switch (std.posix.errno(std.posix.system.fsync(dir.handle))) {
                .SUCCESS => return,
                .INTR => continue,
                else => return Error.Io,
            }
        }
    }

    fn writeAtomic(self: *Db, name: []const u8, bytes: []const u8) !void {
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{name});
        defer self.alloc.free(tmp);
        {
            const f = self.dir.createFile(self.io, tmp, .{ .truncate = true }) catch |e| return e;
            defer f.close(self.io);
            try f.writePositionalAll(self.io, bytes, 0);
            try f.sync(self.io);
        }
        try std.Io.Dir.rename(self.dir, tmp, self.dir, name, self.io);
        try self.syncParentDir(name);
    }

    fn appendDoc(self: *Db, doc: *const Doc, do_sync: bool) !void {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        try fmt.encodeDoc(&payload, self.alloc, doc);

        const len: u32 = @intCast(payload.items.len);
        var hdr: [WAL_HDR]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], len, .little);
        std.mem.writeInt(u32, hdr[4..8], Crc.of(payload.items), .little);
        std.mem.writeInt(u64, hdr[8..16], doc.seq, .little);

        const total = WAL_HDR + payload.items.len;
        const buf = try self.alloc.alloc(u8, total);
        defer self.alloc.free(buf);
        @memcpy(buf[0..WAL_HDR], &hdr);
        @memcpy(buf[WAL_HDR..], payload.items);

        const prev_wal_size = self.wal_size;
        self.wal.writePositionalAll(self.io, buf, prev_wal_size) catch |e| {
            self.rollbackWal(prev_wal_size);
            return e;
        };
        if (do_sync) {
            self.wal.sync(self.io) catch |e| {
                self.rollbackWal(prev_wal_size);
                return e;
            };
        }
        self.wal_size = prev_wal_size + total;
        if (self.wal_size > self.wal_limit) {
            self.flushSegment(doc) catch |e| {
                // WAL already contains the uncommitted record at self.wal_size
                // (or segments were partially flushed) while Db.docs was not
                // updated; fail closed until reopen/replay.
                self.failed = true;
                self.wal_unrecoverable = true;
                return e;
            };
        }
    }

    fn rollbackWal(self: *Db, prev_size: u64) void {
        self.wal.setLength(self.io, prev_size) catch {
            self.failed = true;
            self.wal_dirty_tail = true;
            return;
        };
        self.wal.sync(self.io) catch {
            self.failed = true;
            self.wal_dirty_tail = true;
            return;
        };
    }

    pub fn syncWal(self: *Db) !void {
        if (self.wal_unrecoverable) {
            self.failed = true;
            return error.Io;
        }
        if (self.wal_dirty_tail) {
            try self.clearFailedIfHealthy();
            return;
        }
        self.wal.sync(self.io) catch |e| {
            self.failed = true;
            return e;
        };
        self.failed = false;
    }

    pub fn clearFailedIfHealthy(self: *Db) !void {
        if (self.wal_unrecoverable) {
            self.failed = true;
            return error.Io;
        }
        if (self.wal_dirty_tail) {
            self.wal.setLength(self.io, self.wal_size) catch |e| {
                self.failed = true;
                return e;
            };
            self.wal_dirty_tail = false;
        }
        self.wal.sync(self.io) catch |e| {
            self.failed = true;
            return e;
        };
        const len = self.wal.length(self.io) catch |e| {
            self.failed = true;
            return e;
        };
        if (len != self.wal_size) {
            self.failed = true;
            return Error.Corrupt;
        }
        self.failed = false;
    }

    pub fn putLocal(
        self: *Db,
        id: []const u8,
        body: []const u8,
        parent: ?Rev,
        deleted: bool,
    ) !PutResult {
        return self.putLocalMode(id, body, parent, deleted, true);
    }

    pub fn putLocalBatch(
        self: *Db,
        id: []const u8,
        body: []const u8,
        parent: ?Rev,
        deleted: bool,
    ) !PutResult {
        return self.putLocalMode(id, body, parent, deleted, false);
    }

    fn cloneDoc(alloc: std.mem.Allocator, src: *const Doc) !*Doc {
        const dst = try tree.create(alloc, src.id);
        errdefer dst.deinit(alloc);
        dst.winner = src.winner;
        dst.seq = src.seq;
        try dst.leaves.ensureTotalCapacity(alloc, src.leaves.items.len);
        for (src.leaves.items) |leaf| {
            const body = try alloc.dupe(u8, leaf.body);
            errdefer alloc.free(body);
            const anc = try alloc.dupe(Rev, leaf.ancestry);
            dst.leaves.appendAssumeCapacity(.{
                .rev = leaf.rev,
                .deleted = leaf.deleted,
                .body = body,
                .ancestry = anc,
            });
        }
        try dst.retained.ensureTotalCapacity(alloc, src.retained.items.len);
        for (src.retained.items) |ret| {
            const body = try alloc.dupe(u8, ret.body);
            dst.retained.appendAssumeCapacity(.{
                .rev = ret.rev,
                .deleted = ret.deleted,
                .body = body,
            });
        }
        return dst;
    }

    fn commitStagedDoc(self: *Db, id: []const u8, existing: ?*Doc, staging: *Doc, seq: u64) void {
        self.seq = seq;
        const new_deleted = staging.winnerLeaf().deleted;
        const new_bytes = docBodyBytes(staging);
        if (existing) |old| {
            if (old.winnerLeaf().deleted) self.deleted_doc_count -= 1 else self.live_doc_count -= 1;
            self.live_body_bytes -= docBodyBytes(old);
            const entry = self.docs.getEntry(id).?;
            entry.key_ptr.* = staging.id;
            entry.value_ptr.* = staging;
            if (self.designs.fetchRemove(old.id)) |_| self.designs.putAssumeCapacity(staging.id, {});
            old.deinit(self.alloc);
        } else {
            self.docs.putAssumeCapacity(staging.id, staging);
            if (std.mem.startsWith(u8, staging.id, "_design/")) self.designs.putAssumeCapacity(staging.id, {});
        }
        if (new_deleted) self.deleted_doc_count += 1 else self.live_doc_count += 1;
        self.live_body_bytes += new_bytes;
    }

    fn putLocalMode(
        self: *Db,
        id: []const u8,
        body: []const u8,
        parent: ?Rev,
        deleted: bool,
        do_sync: bool,
    ) !PutResult {
        self.assertLocked();
        if (self.failed) return error.Io;
        const existing = self.docs.get(id);
        const created = existing == null;
        const staging = if (existing) |e| try cloneDoc(self.alloc, e) else try tree.create(self.alloc, id);
        var committed = false;
        errdefer if (!committed) staging.deinit(self.alloc);

        staging.revs_limit = self.revs_limit;
        const rev = try tree.applyLocalWithLimit(staging, self.alloc, body, parent, deleted, self.revs_limit);
        const seq = self.seq + 1;
        staging.seq = seq;
        self.trimAncestry(staging, rev);

        const old_bytes: usize = if (existing) |e| docApproxBytes(e) else 0;
        const new_bytes = docApproxBytes(staging);
        const projected = (self.approx_bytes - @min(self.approx_bytes, old_bytes)) +| new_bytes;
        if (self.max_memory_bytes > 0 and projected > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }

        if (created) {
            try self.docs.ensureUnusedCapacity(self.alloc, 1);
            if (std.mem.startsWith(u8, staging.id, "_design/"))
                try self.designs.ensureUnusedCapacity(self.alloc, 1);
        }
        try self.appendDoc(staging, do_sync);
        self.commitStagedDoc(id, existing, staging, seq);
        self.approx_bytes = projected;
        committed = true;
        return .{ .rev = rev, .seq = seq, .created = created };
    }

    pub fn putImported(
        self: *Db,
        id: []const u8,
        rev: Rev,
        ancestry: []const Rev,
        body: []const u8,
        deleted: bool,
    ) !PutResult {
        return self.putImportedMode(id, rev, ancestry, body, deleted, true);
    }

    pub fn putImportedBatch(
        self: *Db,
        id: []const u8,
        rev: Rev,
        ancestry: []const Rev,
        body: []const u8,
        deleted: bool,
    ) !PutResult {
        return self.putImportedMode(id, rev, ancestry, body, deleted, false);
    }

    fn putImportedMode(
        self: *Db,
        id: []const u8,
        rev: Rev,
        ancestry: []const Rev,
        body: []const u8,
        deleted: bool,
        do_sync: bool,
    ) !PutResult {
        self.assertLocked();
        if (self.failed) return error.Io;
        const existing = self.docs.get(id);
        if (existing) |e| {
            if (e.findLeaf(rev) != null) return .{ .rev = rev, .seq = e.seq, .created = false };
        }
        const created = existing == null;
        const staging = if (existing) |e| try cloneDoc(self.alloc, e) else try tree.create(self.alloc, id);
        var committed = false;
        errdefer if (!committed) staging.deinit(self.alloc);

        staging.revs_limit = self.revs_limit;
        const added = try tree.applyImportedWithLimit(staging, self.alloc, rev, ancestry, body, deleted, self.revs_limit);
        if (!added) {
            const seq = if (existing) |e| e.seq else 0;
            staging.deinit(self.alloc);
            committed = true;
            return .{ .rev = rev, .seq = seq, .created = false };
        }
        const seq = self.seq + 1;
        staging.seq = seq;
        self.trimAncestry(staging, rev);

        const old_bytes: usize = if (existing) |e| docApproxBytes(e) else 0;
        const new_bytes = docApproxBytes(staging);
        const projected = (self.approx_bytes - @min(self.approx_bytes, old_bytes)) +| new_bytes;
        if (self.max_memory_bytes > 0 and projected > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }

        if (created) {
            try self.docs.ensureUnusedCapacity(self.alloc, 1);
            if (std.mem.startsWith(u8, staging.id, "_design/"))
                try self.designs.ensureUnusedCapacity(self.alloc, 1);
        }
        try self.appendDoc(staging, do_sync);
        self.commitStagedDoc(id, existing, staging, seq);
        self.approx_bytes = projected;
        committed = true;
        return .{ .rev = rev, .seq = seq, .created = true };
    }

    pub fn get(self: *Db, id: []const u8) ?*Doc {
        return self.docs.get(id);
    }

    fn trimAncestry(self: *Db, doc: *Doc, rev: Rev) void {
        for (doc.leaves.items) |*leaf| {
            if (!leaf.rev.eql(rev)) continue;
            if (leaf.ancestry.len <= self.revs_limit) return;
            leaf.ancestry = self.alloc.realloc(leaf.ancestry, self.revs_limit) catch return;
            return;
        }
    }

    fn readPurgeSeq(self: *Db) u64 {
        const bytes = self.readFile("purge_seq", 8) catch return 0;
        defer self.alloc.free(bytes);
        if (bytes.len < 8) return 0;
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    pub fn bumpPurgeSeq(self: *Db) !u64 {
        self.assertLocked();
        self.purge_seq += 1;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.purge_seq, .little);
        try self.writeAtomic("purge_seq", &buf);
        return self.purge_seq;
    }

    fn readRevsLimit(self: *Db) u32 {
        const bytes = self.readFile("revs_limit", 8) catch return 1000;
        defer self.alloc.free(bytes);
        if (bytes.len < 4) return 1000;
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    pub fn setRevsLimit(self: *Db, limit: u32) !void {
        self.assertLocked();
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, limit, .little);
        try self.writeAtomic("revs_limit", &buf);
        self.revs_limit = limit;
        var it = self.docs.valueIterator();
        while (it.next()) |doc| {
            for (doc.*.leaves.items) |*leaf| {
                if (leaf.ancestry.len > limit) {
                    leaf.ancestry = self.alloc.realloc(leaf.ancestry, limit) catch continue;
                }
            }
        }
        self.recomputeApproxBytes();
    }

    fn loadLocals(self: *Db) !void {
        const bytes = self.readFile("locals.log", 1 << 30) catch |e| switch (e) {
            error.FileNotFound => return,
            // Dropping local documents on a transient read failure loses
            // replication checkpoints, so fail the open instead.
            else => return e,
        };
        defer self.alloc.free(bytes);
        var pos: usize = 0;
        var valid: usize = 0;
        while (pos + 8 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            const total = 8 + @as(usize, len);
            if (pos + total > bytes.len) break;
            const payload = bytes[pos + 8 .. pos + total];
            if (Crc.Crc32c.hash(payload) != crc) break;
            if (payload.len < 13) break;
            const id_len = std.mem.readInt(u32, payload[0..4], .little);
            const rev = std.mem.readInt(u32, payload[4..8], .little);
            const flags = payload[8];
            const body_len = std.mem.readInt(u32, payload[9..13], .little);
            if (13 + @as(usize, id_len) + @as(usize, body_len) > payload.len) break;
            const id = payload[13 .. 13 + id_len];
            const body = payload[13 + id_len .. 13 + id_len + body_len];
            if (flags & 1 != 0) {
                if (self.locals.fetchRemove(id)) |kv| {
                    const l = kv.value;
                    self.alloc.free(l.id);
                    self.alloc.free(l.body);
                    self.alloc.destroy(l);
                }
            } else if (self.locals.get(id)) |l| {
                const nb = try self.alloc.dupe(u8, body);
                self.alloc.free(l.body);
                l.body = nb;
                l.rev = rev;
            } else {
                const l = try createLocal(self.alloc, id, rev, body);
                self.locals.put(self.alloc, l.id, l) catch |e| {
                    self.alloc.free(l.id);
                    self.alloc.free(l.body);
                    self.alloc.destroy(l);
                    return e;
                };
            }
            pos += total;
            valid = pos;
        }
        if (valid < bytes.len) {
            try self.locals_wal.setLength(self.io, valid);
        }
        self.locals_size = valid;
    }

    fn encodeLocalRecord(rec: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, id: []const u8, rev: u32, flags: u8, body: []const u8) !void {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(alloc);
        try appendU32(&payload, alloc, @intCast(id.len));
        try appendU32(&payload, alloc, rev);
        try payload.append(alloc, flags);
        try appendU32(&payload, alloc, @intCast(body.len));
        try payload.appendSlice(alloc, id);
        try payload.appendSlice(alloc, body);

        try appendU32(rec, alloc, @intCast(payload.items.len));
        try appendU32(rec, alloc, Crc.Crc32c.hash(payload.items));
        try rec.appendSlice(alloc, payload.items);
    }

    fn appendLocal(self: *Db, id: []const u8, rev: u32, flags: u8, body: []const u8) !void {
        var rec: std.ArrayListUnmanaged(u8) = .empty;
        defer rec.deinit(self.alloc);
        try encodeLocalRecord(&rec, self.alloc, id, rev, flags, body);
        const prev_size = self.locals_size;
        self.locals_wal.writePositionalAll(self.io, rec.items, prev_size) catch |e| {
            self.locals_wal.setLength(self.io, prev_size) catch {
                self.failed = true;
            };
            return e;
        };
        self.locals_wal.sync(self.io) catch |e| {
            self.locals_wal.setLength(self.io, prev_size) catch {
                self.failed = true;
            };
            return e;
        };
        self.locals_size = prev_size + rec.items.len;
    }

    fn localsLiveBytes(self: *const Db) u64 {
        var total: u64 = 0;
        var it = self.locals.valueIterator();
        while (it.next()) |lp| {
            const l = lp.*;
            total +|= 32 + l.id.len + l.body.len;
        }
        return total;
    }

    pub fn compactLocals(self: *Db) !void {
        const tmp = "locals.log.tmp";
        errdefer self.dir.deleteFile(self.io, tmp) catch {};
        var offset: u64 = 0;
        const f = try self.dir.createFile(self.io, tmp, .{ .truncate = true, .read = true });
        var swapped = false;
        errdefer if (!swapped) f.close(self.io);
        {
            var rec: std.ArrayListUnmanaged(u8) = .empty;
            defer rec.deinit(self.alloc);
            var it = self.locals.valueIterator();
            while (it.next()) |lp| {
                const l = lp.*;
                rec.clearRetainingCapacity();
                try encodeLocalRecord(&rec, self.alloc, l.id, l.rev, 0, l.body);
                try f.writePositionalAll(self.io, rec.items, offset);
                offset += rec.items.len;
            }
            try f.sync(self.io);
        }
        try std.Io.Dir.rename(self.dir, tmp, self.dir, "locals.log", self.io);
        self.locals_wal.close(self.io);
        self.locals_wal = f;
        self.locals_size = offset;
        swapped = true;
        try self.syncParentDir("locals.log");
    }

    pub fn readViewIndex(self: *Db, alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
        var d = self.dir.openDir(self.io, "views", .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return e,
        };
        defer d.close(self.io);
        const f = d.openFile(self.io, name, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer f.close(self.io);
        const len = try f.length(self.io);
        if (len > MAX_STORAGE_FILE_BYTES) return null;
        const buf = try alloc.alloc(u8, @intCast(len));
        errdefer alloc.free(buf);
        _ = try f.readPositionalAll(self.io, buf, 0);
        return buf;
    }

    pub fn writeViewIndex(self: *Db, name: []const u8, bytes: []const u8) !void {
        self.dir.createDirPath(self.io, "views") catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const path = try std.fmt.allocPrint(self.alloc, "views/{s}", .{name});
        defer self.alloc.free(path);
        const f = try self.dir.createFile(self.io, path, .{ .truncate = true });
        defer f.close(self.io);
        try f.writePositionalAll(self.io, bytes, 0);
        try f.sync(self.io);
    }

    pub fn readVectorIndex(self: *Db) !?[]u8 {
        return self.readFile("vectors.idx", 512 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound, error.TooLarge => null,
            else => return e,
        };
    }

    pub fn writeVectorIndex(self: *Db, bytes: []const u8) !void {
        try self.writeAtomic("vectors.idx", bytes);
    }

    pub fn readHnswIndex(self: *Db) !?[]u8 {
        return self.readFile("hnsw.idx", 1024 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound, error.TooLarge => null,
            else => return e,
        };
    }

    pub fn writeHnswIndex(self: *Db, bytes: []const u8) !void {
        try self.writeAtomic("hnsw.idx", bytes);
    }

    pub fn readTextIndex(self: *Db) !?[]u8 {
        return self.readFile("text.idx", 1024 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound, error.TooLarge => null,
            else => return e,
        };
    }

    pub fn writeTextIndex(self: *Db, bytes: []const u8) !void {
        try self.writeAtomic("text.idx", bytes);
    }

    pub fn readMangoIndex(self: *Db, alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
        var d = self.dir.openDir(self.io, "indexes", .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return null,
            else => return e,
        };
        defer d.close(self.io);
        const f = d.openFile(self.io, name, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer f.close(self.io);
        const len = try f.length(self.io);
        if (len > MAX_STORAGE_FILE_BYTES) return null;
        const buf = try alloc.alloc(u8, @intCast(len));
        errdefer alloc.free(buf);
        _ = try f.readPositionalAll(self.io, buf, 0);
        return buf;
    }

    pub fn writeMangoIndex(self: *Db, name: []const u8, bytes: []const u8) !void {
        self.dir.createDirPath(self.io, "indexes") catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const path = try std.fmt.allocPrint(self.alloc, "indexes/{s}", .{name});
        defer self.alloc.free(path);
        try self.writeAtomic(path, bytes);
    }

    pub fn deleteMangoIndex(self: *Db, name: []const u8) void {
        var d = self.dir.openDir(self.io, "indexes", .{}) catch return;
        defer d.close(self.io);
        d.deleteFile(self.io, name) catch {};
    }

    pub fn clearSearchIndexes(self: *Db) void {
        for ([_][]const u8{ "vectors.idx", "hnsw.idx", "text.idx" }) |f| {
            self.dir.deleteFile(self.io, f) catch {};
        }
        var d = self.dir.openDir(self.io, "indexes", .{ .iterate = true }) catch return;
        defer d.close(self.io);
        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .file) d.deleteFile(self.io, entry.name) catch {};
        }
    }

    pub fn clearViewIndexes(self: *Db) void {
        var d = self.dir.openDir(self.io, "views", .{ .iterate = true }) catch return;
        defer d.close(self.io);
        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .file) d.deleteFile(self.io, entry.name) catch {};
        }
    }

    pub fn deleteLocalDoc(self: *Db, id: []const u8, parent: u32) !u32 {
        self.assertLocked();
        const l = self.locals.get(id) orelse return error.NotFound;
        if (l.rev != parent) return error.Conflict;
        const next = l.rev + 1;
        try self.appendLocal(id, next, 1, "");
        _ = self.locals.fetchRemove(id);
        self.approx_bytes -|= localApproxBytes(l);
        self.alloc.free(l.id);
        self.alloc.free(l.body);
        self.alloc.destroy(l);
        const threshold = @max(@as(u64, 64 * 1024), self.localsLiveBytes() *| 4);
        if (self.locals_size > @min(threshold, self.locals_limit)) try self.compactLocals();
        return next;
    }

    const SecuritySets = struct {
        members: std.StringHashMapUnmanaged(void) = .empty,
        admins: std.StringHashMapUnmanaged(void) = .empty,
        member_roles: std.StringHashMapUnmanaged(void) = .empty,
        admin_roles: std.StringHashMapUnmanaged(void) = .empty,
        restricted: bool = false,

        fn freeMap(alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void)) void {
            var it = map.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            map.deinit(alloc);
            map.* = .empty;
        }

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            freeMap(alloc, &self.members);
            freeMap(alloc, &self.admins);
            freeMap(alloc, &self.member_roles);
            freeMap(alloc, &self.admin_roles);
            self.restricted = false;
        }
    };

    fn clearSecurity(self: *Db) void {
        var cur: SecuritySets = .{
            .members = self.security_members,
            .admins = self.security_admins,
            .member_roles = self.security_member_roles,
            .admin_roles = self.security_admin_roles,
            .restricted = self.security_restricted,
        };
        cur.deinit(self.alloc);
        self.security_members = .empty;
        self.security_admins = .empty;
        self.security_member_roles = .empty;
        self.security_admin_roles = .empty;
        self.security_restricted = false;
    }

    fn addSecurityEntries(
        self: *Db,
        map: *std.StringHashMapUnmanaged(void),
        arr_val: std.json.Value,
        restricted: *bool,
        mark_restricted: bool,
    ) !void {
        if (arr_val != .array) return;
        for (arr_val.array.items) |item| {
            if (item != .string) continue;
            if (map.contains(item.string)) continue;
            const key = try self.alloc.dupe(u8, item.string);
            errdefer self.alloc.free(key);
            try map.put(self.alloc, key, {});
            if (mark_restricted) restricted.* = true;
        }
    }

    fn parseSecuritySets(self: *Db, root: std.json.Value) !SecuritySets {
        if (root != .object) return error.Corrupt;
        var out: SecuritySets = .{};
        errdefer out.deinit(self.alloc);
        if (root.object.get("members")) |mv| {
            if (mv == .object) {
                if (mv.object.get("names")) |nv| try self.addSecurityEntries(&out.members, nv, &out.restricted, true);
                if (mv.object.get("roles")) |rv| try self.addSecurityEntries(&out.member_roles, rv, &out.restricted, true);
            }
        }
        if (root.object.get("admins")) |av| {
            if (av == .object) {
                if (av.object.get("names")) |nv| try self.addSecurityEntries(&out.admins, nv, &out.restricted, false);
                if (av.object.get("roles")) |rv| try self.addSecurityEntries(&out.admin_roles, rv, &out.restricted, false);
            }
        }
        return out;
    }

    fn applySecuritySets(self: *Db, sets: SecuritySets) void {
        self.clearSecurity();
        self.security_members = sets.members;
        self.security_admins = sets.admins;
        self.security_member_roles = sets.member_roles;
        self.security_admin_roles = sets.admin_roles;
        self.security_restricted = sets.restricted;
    }

    fn applySecurity(self: *Db, root: std.json.Value) !void {
        const sets = try self.parseSecuritySets(root);
        self.applySecuritySets(sets);
    }

    fn loadSecurity(self: *Db) !void {
        const bytes = self.readFile("security.json", 1 << 20) catch |e| switch (e) {
            error.FileNotFound => return,
            // security_restricted defaults to false; opening as unrestricted
            // because the file could not be read would be an auth bypass.
            else => return e,
        };
        defer self.alloc.free(bytes);
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, bytes, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };
        defer parsed.deinit();
        try self.applySecurity(parsed.value);
    }

    pub fn securityRestricted(self: *const Db) bool {
        return self.security_restricted;
    }

    pub fn securityAdmin(self: *const Db, user: []const u8, roles: []const u8) bool {
        if (!self.security_restricted) return true;
        var it = std.mem.splitScalar(u8, roles, ',');
        while (it.next()) |role| {
            if (std.mem.eql(u8, role, "_admin")) return true;
            if (role.len != 0 and self.security_admin_roles.contains(role)) return true;
        }
        return self.security_admins.contains(user);
    }

    pub fn securityAllows(self: *const Db, user: []const u8, roles: []const u8) bool {
        if (!self.security_restricted) return true;
        var admin_it = std.mem.splitScalar(u8, roles, ',');
        while (admin_it.next()) |role| {
            if (std.mem.eql(u8, role, "_admin")) return true;
        }
        if (self.security_admins.contains(user)) return true;
        if (self.security_members.contains(user)) return true;
        var it = std.mem.splitScalar(u8, roles, ',');
        while (it.next()) |role| {
            if (role.len == 0) continue;
            if (self.security_admin_roles.contains(role)) return true;
            if (self.security_member_roles.contains(role)) return true;
        }
        return false;
    }

    pub fn readSecurity(self: *Db, alloc: std.mem.Allocator) ![]u8 {
        // CouchDB answers with the two sections even when nothing is set; a
        // client reading `admins.names` would otherwise have to special-case {}.
        return self.readFileAlloc(alloc, "security.json", 1 << 20) catch |e| switch (e) {
            error.FileNotFound => try alloc.dupe(
                u8,
                "{\"admins\":{\"names\":[],\"roles\":[]},\"members\":{\"names\":[],\"roles\":[]}}",
            ),
            else => return e,
        };
    }

    pub fn writeSecurity(self: *Db, bytes: []const u8) !void {
        self.assertLocked();
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, bytes, .{}) catch return error.InvalidSecurity;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSecurity;
        var next_sec = try self.parseSecuritySets(parsed.value);
        errdefer next_sec.deinit(self.alloc);
        try self.writeAtomic("security.json", bytes);
        self.applySecuritySets(next_sec);
    }

    pub fn getRevsLimit(self: *const Db) u32 {
        return self.revs_limit;
    }

    pub fn getLocal(self: *Db, id: []const u8) ?*Local {
        return self.locals.get(id);
    }

    pub fn putLocalDoc(self: *Db, id: []const u8, body: []const u8, parent: ?u32) !u32 {
        self.assertLocked();
        if (self.locals.get(id)) |l| {
            if (parent == null or parent.? != l.rev) return error.Conflict;
            const old_bytes = localApproxBytes(l);
            const new_bytes = @sizeOf(Local) + l.id.len + body.len;
            const projected = (self.approx_bytes - @min(self.approx_bytes, old_bytes)) +| new_bytes;
            if (self.max_memory_bytes > 0 and projected > self.max_memory_bytes) {
                return error.MemoryLimitExceeded;
            }
            const nb = try self.alloc.dupe(u8, body);
            errdefer self.alloc.free(nb);
            const next_rev = l.rev + 1;
            try self.appendLocal(id, next_rev, 0, body);
            self.alloc.free(l.body);
            l.body = nb;
            l.rev = next_rev;
            self.approx_bytes = projected;
            if (self.locals_size > @min(@max(@as(u64, 64 * 1024), self.localsLiveBytes() *| 4), self.locals_limit)) try self.compactLocals();
            return next_rev;
        }
        // CouchDB accepts a checkpoint creation carrying any `0-N` rev; it is a
        // hint, not a conflict, when no local document exists yet.
        const new_bytes = @sizeOf(Local) + id.len + body.len;
        const projected = self.approx_bytes +| new_bytes;
        if (self.max_memory_bytes > 0 and projected > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }
        const rev: u32 = if (parent) |p| (std.math.add(u32, p, 1) catch return error.InvalidRev) else 1;
        const l = try createLocal(self.alloc, id, rev, body);
        errdefer {
            self.alloc.free(l.id);
            self.alloc.free(l.body);
            self.alloc.destroy(l);
        }
        try self.locals.ensureUnusedCapacity(self.alloc, 1);
        try self.appendLocal(id, rev, 0, body);
        self.locals.putAssumeCapacity(l.id, l);
        self.approx_bytes = projected;
        if (self.locals_size > @min(@max(@as(u64, 64 * 1024), self.localsLiveBytes() *| 4), self.locals_limit)) try self.compactLocals();
        return rev;
    }

    pub fn count(self: *const Db) usize {
        return self.docs.count();
    }

    pub fn gcBlobs(self: *Db) !void {
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var kit = keep.keyIterator();
            while (kit.next()) |k| self.alloc.free(k.*);
            keep.deinit(self.alloc);
        }

        var it = self.docs.valueIterator();
        while (it.next()) |d| {
            for (d.*.leaves.items) |leaf| {
                const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, leaf.body, .{}) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Corrupt,
                };
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const atts = parsed.value.object.get("_attachments") orelse continue;
                if (atts != .object) continue;
                for (atts.object.values()) |av| {
                    if (av != .object) continue;
                    const bv = av.object.get("blob") orelse continue;
                    if (bv != .string or bv.string.len != 32) continue;
                    if (keep.contains(bv.string)) continue;
                    const owned = try self.alloc.dupe(u8, bv.string);
                    keep.put(self.alloc, owned, {}) catch |e| {
                        self.alloc.free(owned);
                        return e;
                    };
                }
            }
        }

        var d = self.dir.openDir(self.io, "blobs", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer d.close(self.io);
        var dit = d.iterate();
        while (try dit.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
            const hex = entry.name[0 .. entry.name.len - 4];
            if (hex.len != 32) continue;
            if (!keep.contains(hex)) {
                d.deleteFile(self.io, entry.name) catch |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                };
            }
        }
    }

    fn writeDocFrame(self: *Db, f: std.Io.File, offset: *u64, rec: []const u8) !void {
        var rec_hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, rec_hdr[0..4], @intCast(rec.len), .little);
        std.mem.writeInt(u32, rec_hdr[4..8], Crc.of(rec), .little);
        if (offset.* + rec_hdr.len + rec.len > MAX_STORAGE_FILE_BYTES) return Error.FileTooLarge;
        try f.writePositionalAll(self.io, &rec_hdr, offset.*);
        offset.* += rec_hdr.len;
        try f.writePositionalAll(self.io, rec, offset.*);
        offset.* += rec.len;
    }

    fn writeAtomicDocs(self: *Db, name: []const u8, header: []const u8, drop_retained: bool) !u64 {
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{name});
        defer self.alloc.free(tmp);
        errdefer self.dir.deleteFile(self.io, tmp) catch {};

        var max_seq: u64 = 0;
        {
            const f = try self.dir.createFile(self.io, tmp, .{ .truncate = true });
            defer f.close(self.io);
            var offset: u64 = 0;
            try f.writePositionalAll(self.io, header, offset);
            offset += header.len;

            var rec: std.ArrayListUnmanaged(u8) = .empty;
            defer rec.deinit(self.alloc);

            var it = self.docs.valueIterator();
            while (it.next()) |d| {
                if (drop_retained) d.*.dropRetained(self.alloc);
                rec.clearRetainingCapacity();
                try fmt.encodeDoc(&rec, self.alloc, d.*);
                try self.writeDocFrame(f, &offset, rec.items);
                max_seq = @max(max_seq, d.*.seq);
            }
            try f.sync(self.io);
        }
        try std.Io.Dir.rename(self.dir, tmp, self.dir, name, self.io);
        try self.syncParentDir(name);
        return max_seq;
    }

    pub fn compactSegments(self: *Db) !void {
        self.assertLocked();
        var hdr: [SEGMENT_MAGIC.len + 4]u8 = undefined;
        @memcpy(hdr[0..SEGMENT_MAGIC.len], SEGMENT_MAGIC);
        std.mem.writeInt(u32, hdr[SEGMENT_MAGIC.len..][0..4], @intCast(self.docs.count()), .little);

        self.segment_counter += 1;
        const name = try std.fmt.allocPrint(self.alloc, "segment-{d:0>6}.bin", .{self.segment_counter});
        errdefer self.alloc.free(name);
        const max_seq = try self.writeAtomicDocs(name, &hdr, true);
        const new_info = [_]SegmentInfo{.{ .name = name, .max_seq = max_seq }};
        try self.writeSegmentsManifestFor(&new_info);

        // A compacted database is represented by the segment alone. Remove both
        // snapshot candidates before publishing the new manifest, so a reopen
        // cannot load an old snapshot above the compacted segment.
        const old_a = try self.readManifest("MANIFEST_A");
        const old_b = try self.readManifest("MANIFEST_B");
        if (old_a) |m| {
            const old = try self.snapName(m.gen);
            defer self.alloc.free(old);
            self.dir.deleteFile(self.io, old) catch {};
        }
        if (old_b) |m| {
            const old = try self.snapName(m.gen);
            defer self.alloc.free(old);
            self.dir.deleteFile(self.io, old) catch {};
        }

        self.gen += 1;
        try self.writeManifest();
        try self.wal.setLength(self.io, 0);
        try self.wal.sync(self.io);
        self.wal_size = 0;

        for (self.segments.items) |old| {
            self.dir.deleteFile(self.io, old.name) catch {};
            self.alloc.free(old.name);
        }
        self.segments.clearRetainingCapacity();
        try self.segments.append(self.alloc, new_info[0]);
        self.segment_seq = max_seq;
        self.recomputeApproxBytes();
        try self.compactLocals();
        try self.gcBlobs();
    }

    pub fn snapshot(self: *Db) !void {
        self.assertLocked();
        const next_gen = self.gen + 1;
        var hdr: [SNAP_HDR]u8 = undefined;
        @memcpy(hdr[0..SNAPSHOT_MAGIC.len], SNAPSHOT_MAGIC);
        std.mem.writeInt(u64, hdr[8..16], next_gen, .little);
        std.mem.writeInt(u64, hdr[16..24], self.seq, .little);
        std.mem.writeInt(u32, hdr[24..28], @intCast(self.docs.count()), .little);

        const name = try self.snapName(next_gen);
        defer self.alloc.free(name);
        _ = try self.writeAtomicDocs(name, &hdr, false);

        self.gen = next_gen;
        try self.writeManifest();

        try self.wal.setLength(self.io, 0);
        try self.wal.sync(self.io);
        self.wal_size = 0;

        if (self.gen > 1) {
            const old = try self.snapName(self.gen - 1);
            defer self.alloc.free(old);
            self.dir.deleteFile(self.io, old) catch {};
        }
        try self.clearSegments();
    }

    pub fn deleteDb(io: std.Io, path: []const u8) !void {
        try std.Io.Dir.cwd().deleteTree(io, path);
    }
};

fn appendU32(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    try list.appendSlice(alloc, std.mem.asBytes(&v));
}

fn appendU64(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    try list.appendSlice(alloc, std.mem.asBytes(&v));
}

test "put, reopen, recover" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-db-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        const r1 = try db.putLocal("a", "{\"v\":1}", null, false);
        _ = try db.putLocal("a", "{\"v\":2}", r1.rev, false);
        try std.testing.expectEqual(@as(usize, 1), db.count());
        try std.testing.expectEqual(@as(u64, 2), db.seq);
        db.close();
    }

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        const d = db.get("a") orelse return error.NotFound;
        try std.testing.expectEqual(@as(usize, 1), d.leaves.items.len);
        try std.testing.expectEqualStrings("{\"v\":2}", d.winnerLeaf().body);
        try std.testing.expectEqual(@as(u64, 2), db.seq);
    }
}

test "segment flush and recovery" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-segment-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        db.wal_limit = 256;
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            const body = try std.fmt.allocPrint(alloc, "{{\"i\":{d},\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}}", .{i});
            defer alloc.free(body);
            const id = try std.fmt.allocPrint(alloc, "doc-{d}", .{i});
            defer alloc.free(id);
            _ = try db.putLocal(id, body, null, false);
        }
        try std.testing.expect(db.segments.items.len > 0);
        try std.testing.expect(db.segments.items.len <= 8);
        db.failed = true;
        db.close();
    }

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        try std.testing.expectEqual(@as(usize, 30), db.count());
        try std.testing.expect(db.get("doc-29") != null);
    }
}

test "torn WAL tails recover every complete prefix" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "zig-cache/zouch-torn-base";
    const case = "zig-cache/zouch-torn-case";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.cwd().deleteTree(io, case) catch {};

    var wal_bytes: []u8 = undefined;
    {
        const db = try Db.open(alloc, io, base);
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const id = try std.fmt.allocPrint(alloc, "doc-{d}", .{i});
            defer alloc.free(id);
            const body = try std.fmt.allocPrint(alloc, "{{\"i\":{d}}}", .{i});
            defer alloc.free(body);
            _ = try db.putLocal(id, body, null, false);
        }
        db.failed = true;
        db.close();
        const f = try std.Io.Dir.cwd().openFile(io, base ++ "/wal.log", .{});
        defer f.close(io);
        const len = try f.length(io);
        wal_bytes = try alloc.alloc(u8, @intCast(len));
        _ = try f.readPositionalAll(io, wal_bytes, 0);
    }
    defer alloc.free(wal_bytes);

    var cut: usize = 0;
    while (cut <= wal_bytes.len) : (cut += 1) {
        std.Io.Dir.cwd().deleteTree(io, case) catch {};
        try std.Io.Dir.cwd().createDirPath(io, case);
        const f = try std.Io.Dir.cwd().createFile(io, case ++ "/wal.log", .{ .truncate = true });
        try f.writePositionalAll(io, wal_bytes[0..cut], 0);
        f.close(io);

        const db = try Db.open(alloc, io, case);
        try std.testing.expect(db.count() <= 5);
        db.failed = true;
        db.close();
    }
}

test "blob GC keeps referenced payloads and removes orphans" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-blob-gc-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const db = try Db.open(alloc, io, path);
    defer db.close();

    const referenced = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const orphan = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try db.writeBlob(referenced, "keep");
    try db.writeBlob(orphan, "drop");
    const body = try std.fmt.allocPrint(alloc, "{{\"_attachments\":{{\"f\":{{\"blob\":\"{s}\",\"stub\":true}}}}}}", .{referenced});
    defer alloc.free(body);
    _ = try db.putLocal("doc", body, null, false);
    try db.gcBlobs();

    const f = db.dir.openFile(io, "blobs/" ++ referenced ++ ".bin", .{}) catch return error.TestUnexpectedResult;
    f.close(io);
    try std.testing.expectError(error.FileNotFound, db.dir.openFile(io, "blobs/" ++ orphan ++ ".bin", .{}));
}

test "segment-only compaction preserves documents across reopen" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-segment-compact-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        db.wal_limit = 256;
        var i: usize = 0;
        while (i < 24) : (i += 1) {
            const id = try std.fmt.allocPrint(alloc, "doc-{d}", .{i});
            defer alloc.free(id);
            const body = try std.fmt.allocPrint(alloc, "{{\"i\":{d},\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}}", .{i});
            defer alloc.free(body);
            _ = try db.putLocal(id, body, null, false);
        }
        try db.compactSegments();
        try std.testing.expectEqual(@as(usize, 1), db.segments.items.len);
        try std.testing.expectEqual(@as(usize, 24), db.count());
        db.failed = true;
        db.close();
    }

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        try std.testing.expectEqual(@as(usize, 24), db.count());
        try std.testing.expect(db.get("doc-23") != null);
        try std.testing.expectEqual(@as(usize, 1), db.segments.items.len);
    }
}

test "compaction clears segments and preserves documents" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-compact-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        db.wal_limit = 256;
        var i: usize = 0;
        while (i < 24) : (i += 1) {
            const id = try std.fmt.allocPrint(alloc, "doc-{d}", .{i});
            defer alloc.free(id);
            const body = try std.fmt.allocPrint(alloc, "{{\"i\":{d},\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}}", .{i});
            defer alloc.free(body);
            _ = try db.putLocal(id, body, null, false);
        }
        try std.testing.expect(db.segments.items.len > 0);
        try db.snapshot();
        try std.testing.expectEqual(@as(usize, 0), db.segments.items.len);
        try std.testing.expectEqual(@as(usize, 24), db.count());
        const d = db.get("doc-7") orelse return error.NotFound;
        try std.testing.expect(std.mem.indexOf(u8, d.winnerLeaf().body, "\"i\":7") != null);
        db.close();
    }

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        try std.testing.expectEqual(@as(usize, 24), db.count());
        try std.testing.expect(db.get("doc-23") != null);
        try std.testing.expectEqual(@as(usize, 0), db.segments.items.len);
    }
}

test "batched WAL writes become durable with one sync" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-cache/zouch-batch-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        _ = try db.putLocalBatch("a", "{\"v\":1}", null, false);
        _ = try db.putLocalBatch("b", "{\"v\":2}", null, false);
        try db.syncWal();
        db.close();
    }

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        try std.testing.expectEqual(@as(usize, 2), db.count());
        try std.testing.expect(db.get("a") != null);
        try std.testing.expect(db.get("b") != null);
    }
}

fn oomDatabaseWorkload(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const db = try Db.open(alloc, io, path);
    defer {
        // Skip the best-effort close snapshot so this test measures the
        // open/write path rather than an intentionally swallowed snapshot OOM.
        db.failed = true;
        db.close();
    }
    _ = try db.putLocal("oom", "{\"v\":1}", null, false);
}

test "database open and write survive allocation failures" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        oomDatabaseWorkload,
        .{ threaded.io(), "zig-cache/zouch-oom-db" },
    ) catch |e| {
        std.debug.print("db oom gate: {t}\n", .{e});
        return e;
    };
}

test "missing snapshot is not treated as an empty database" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-missing-snapshot";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        _ = try db.putLocal("a", "{\"v\":1}", null, false);
        db.close();
    }

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "snapshot-"))
            try dir.deleteFile(io, entry.name);
    }

    try std.testing.expectError(error.Corrupt, Db.open(alloc, io, path));
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "live database refuses a second writer" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-lock-test";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const db = try Db.open(alloc, io, path);
    defer db.close();
    try std.testing.expectError(error.DatabaseLocked, Db.open(alloc, io, path));
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn reopenSegmentOnly(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const db = try Db.open(alloc, io, path);
    defer {
        // The open path is under test; skip the closing snapshot so the
        // template stays segment-only.
        db.failed = true;
        db.close();
    }
    // A failed allocation must abort the open, never produce a database that
    // silently lost the segments it could not read.
    try std.testing.expectEqual(@as(usize, 12), db.count());
}

test "segment recovery fails closed on allocation failure" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-segment-oom";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    {
        const db = try Db.open(alloc, io, path);
        db.wal_limit = 256;
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            const id = try std.fmt.allocPrint(alloc, "doc-{d}", .{i});
            defer alloc.free(id);
            _ = try db.putLocal(id, "{\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", null, false);
        }
        try std.testing.expect(db.segments.items.len > 0);
        db.failed = true;
        db.close();
    }
    std.testing.checkAllAllocationFailures(alloc, reopenSegmentOnly, .{ io, path }) catch |e| {
        std.debug.print("segment reopen oom gate: {t}\n", .{e});
        return e;
    };
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn writeCheckpointWorkload(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    // Start from a clean directory: a surviving locals.log would turn the
    // create into an update and change which allocations are exercised.
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const db = try Db.open(alloc, io, path);
    defer {
        db.failed = true;
        db.close();
    }
    _ = try db.putLocalDoc("checkpoint", "{\"since\":\"1\"}", null);
}

test "local checkpoint creation survives allocation failures" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writeCheckpointWorkload,
        .{ threaded.io(), "zig-cache/zouch-local-oom" },
    ) catch |e| {
        std.debug.print("local checkpoint oom gate: {t}\n", .{e});
        return e;
    };
}

test "security read uses the caller allocator" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-security-alloc";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const db = try Db.open(alloc, io, path);
    defer db.close();
    try db.writeSecurity("{\"members\":{\"names\":[\"alice\"]}}");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const bytes = try db.readSecurity(arena.allocator());
    try std.testing.expectEqualStrings("{\"members\":{\"names\":[\"alice\"]}}", bytes);
    // A buffer allocated on Db.alloc would outlive arena.deinit() and be
    // reported as a leak by the testing allocator.
}

test "locals.log compacts when exceeding locals_limit and preserves latest state" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-locals-compact";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();
        db.locals_limit = 200;
        var rev = try db.putLocalDoc("_local/cp", "{\"seq\":0}", null);
        var i: usize = 1;
        while (i <= 25) : (i += 1) {
            const body = try std.fmt.allocPrint(alloc, "{{\"seq\":{d}}}", .{i});
            defer alloc.free(body);
            rev = try db.putLocalDoc("_local/cp", body, rev);
        }
        try std.testing.expectEqual(@as(u32, 26), rev);
        try std.testing.expect(db.locals_size <= db.locals_limit);
    }

    const db = try Db.open(alloc, io, path);
    defer db.close();
    const l = db.getLocal("_local/cp") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 26), l.rev);
    try std.testing.expectEqualStrings("{\"seq\":25}", l.body);
}

test "loadSecurity fails closed on corrupt security.json" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-corrupt-security";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        db.close();
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        const f = try dir.createFile(io, "security.json", .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, "{not valid json", 0);
    }
    try std.testing.expectError(error.Corrupt, Db.open(alloc, io, path));
}

test "gcBlobs fails on corrupt document body instead of deleting blobs" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-gc-corrupt";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const db = try Db.open(alloc, io, path);
    defer db.close();
    const blob_id = "cccccccccccccccccccccccccccccccc";
    try db.writeBlob(blob_id, "payload");
    _ = try db.putLocal("bad", "{corrupt", null, false);
    try std.testing.expectError(error.Corrupt, db.gcBlobs());

    const f = try db.dir.openFile(io, "blobs/" ++ blob_id ++ ".bin", .{});
    f.close(io);
}

fn updateWorkload(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const db = try Db.open(alloc, io, path);
    defer {
        db.failed = true;
        db.close();
    }
    const r1 = try db.putLocal("d", "{\"v\":1}", null, false);
    _ = try db.putLocal("d", "{\"v\":2}", r1.rev, false);
    const l1 = try db.putLocalDoc("cp", "{\"s\":1}", null);
    _ = try db.putLocalDoc("cp", "{\"s\":2}", l1);
}

test "doc and local updates survive allocation failures" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        updateWorkload,
        .{ threaded.io(), "zig-cache/zouch-update-oom" },
    ) catch |e| {
        std.debug.print("update oom gate: {t}\n", .{e});
        return e;
    };
}

test "WAL failure does not expose uncommitted mutations in Db.get or Db.getLocal" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-wal-rollback";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const db = try Db.open(alloc, io, path);
    defer db.close();

    const r1 = try db.putLocal("doc1", "{\"v\":1}", null, false);
    const l1 = try db.putLocalDoc("cp1", "{\"s\":1}", null);
    const base_seq = db.seq;

    var fail_idx: usize = 0;
    while (true) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_idx });
        db.alloc = fa.allocator();
        const res = db.putLocal("doc1", "{\"v\":2}", r1.rev, false);
        db.alloc = alloc;
        if (res) |_| {
            break;
        } else |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            try std.testing.expect(!db.failed);
            const d = db.get("doc1") orelse return error.TestUnexpectedResult;
            try std.testing.expect(d.winnerLeaf().rev.eql(r1.rev));
            try std.testing.expectEqualStrings("{\"v\":1}", d.winnerLeaf().body);
            try std.testing.expectEqual(base_seq, db.seq);
        }
    }

    fail_idx = 0;
    while (true) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_idx });
        db.alloc = fa.allocator();
        const res = db.putLocalDoc("cp1", "{\"s\":2}", l1);
        db.alloc = alloc;
        if (res) |_| {
            break;
        } else |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            const l = db.getLocal("cp1") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(l1, l.rev);
            try std.testing.expectEqualStrings("{\"s\":1}", l.body);
        }
    }
}

test "full reopen recovery across conflicts, attachments, locals, compaction, and snapshot" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-full-recovery";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const blob_hex = "dddddddddddddddddddddddddddddddd";
    var expected_seq: u64 = 0;
    var expected_count: usize = 0;
    var expected_cp_rev: u32 = 0;

    {
        const db = try Db.open(alloc, io, path);
        defer db.close();

        const r1 = try db.putLocal("doc-a", "{\"v\":1}", null, false);
        _ = try db.putLocal("doc-a", "{\"v\":2}", r1.rev, false);
        const peer_rev = Rev{ .gen = 2, .hash = @splat(0xab) };
        _ = try db.putImported("doc-a", peer_rev, &.{ peer_rev, r1.rev }, "{\"v\":\"conflict\"}", false);

        try db.writeBlob(blob_hex, "attachment-bytes");
        const doc_b_body = try std.fmt.allocPrint(
            alloc,
            "{{\"_attachments\":{{\"att\":{{\"blob\":\"{s}\",\"stub\":true}}}}}}",
            .{blob_hex},
        );
        defer alloc.free(doc_b_body);
        _ = try db.putLocal("doc-b", doc_b_body, null, false);

        var cp_rev = try db.putLocalDoc("_local/cp1", "{\"seq\":1}", null);
        cp_rev = try db.putLocalDoc("_local/cp1", "{\"seq\":2}", cp_rev);
        const cp2_rev = try db.putLocalDoc("_local/cp2", "{\"seq\":9}", null);
        _ = try db.deleteLocalDoc("_local/cp2", cp2_rev);

        expected_seq = db.seq;
        expected_count = db.count();
        expected_cp_rev = cp_rev;

        try db.compactSegments();
        try db.snapshot();
        try db.compactLocals();
    }

    const db = try Db.open(alloc, io, path);
    defer db.close();
    try std.testing.expectEqual(expected_count, db.count());
    try std.testing.expectEqual(expected_seq, db.seq);

    const doc_a = db.get("doc-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), doc_a.leaves.items.len);

    const blob_data = try db.readBlob(alloc, blob_hex);
    defer alloc.free(blob_data);
    try std.testing.expectEqualStrings("attachment-bytes", blob_data);

    const cp1 = db.getLocal("_local/cp1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected_cp_rev, cp1.rev);
    try std.testing.expectEqualStrings("{\"seq\":2}", cp1.body);
    try std.testing.expect(db.getLocal("_local/cp2") == null);
}

test "transient WAL failure recovery and syncWal retry" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-transient-recovery";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const db = try Db.open(alloc, io, path);
    defer db.close();

    const r1 = try db.putLocal("doc1", "{\"v\":1}", null, false);
    // Simulate a transient OOM inside appendDoc: Db.failed must remain false
    // and subsequent writes must succeed without manual reset.
    var fail_idx: usize = 0;
    var saw_oom = false;
    while (true) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_idx });
        db.alloc = fa.allocator();
        const res = db.putLocal("doc1", "{\"v\":2}", r1.rev, false);
        db.alloc = alloc;
        if (res) |_| {
            break;
        } else |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            saw_oom = true;
            try std.testing.expect(!db.failed);
        }
    }
    try std.testing.expect(saw_oom);

    // Simulate a transient syncWal failure that sets db.failed = true, then
    // verify syncWal() retry and clearFailedIfHealthy() restore normal writes.
    _ = try db.putLocalBatch("doc2", "{\"v\":1}", null, false);
    db.failed = true;
    try std.testing.expectError(error.Io, db.putLocal("doc3", "{\"v\":1}", null, false));
    try db.syncWal();
    try std.testing.expect(!db.failed);

    db.failed = true;
    try db.clearFailedIfHealthy();
    try std.testing.expect(!db.failed);
    _ = try db.putLocal("doc3", "{\"v\":1}", null, false);
    try std.testing.expect(db.get("doc3") != null);

    // When wal_unrecoverable is set, clearFailedIfHealthy must keep failed = true.
    db.failed = true;
    db.wal_unrecoverable = true;
    try std.testing.expectError(error.Io, db.clearFailedIfHealthy());
    try std.testing.expect(db.failed);
    db.wal_unrecoverable = false;
}

test "max_memory_bytes enforces MemoryLimitExceeded before OOM" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-mem-limit";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    const db = try Db.open(alloc, io, path);
    defer db.close();

    try std.testing.expectEqual(@as(usize, 0), db.approx_bytes);
    const r1 = try db.putLocal("doc1", "{\"v\":1}", null, false);
    const after_first = db.approx_bytes;
    try std.testing.expect(after_first > 0);

    // Set budget just above current usage so a small local doc fits, but a
    // larger doc/local/blob write is rejected with MemoryLimitExceeded.
    db.setMaxMemoryBytes(after_first + 200);
    try std.testing.expectError(
        error.MemoryLimitExceeded,
        db.putLocal("doc2", "{\"payload\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", null, false),
    );
    try std.testing.expect(db.get("doc2") == null);

    const peer_rev = Rev{ .gen = 1, .hash = @splat(0x22) };
    try std.testing.expectError(
        error.MemoryLimitExceeded,
        db.putImported("doc3", peer_rev, &.{peer_rev}, "{\"payload\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", false),
    );
    try std.testing.expect(db.get("doc3") == null);

    try std.testing.expectError(
        error.MemoryLimitExceeded,
        db.putLocalDoc("cp1", "{\"payload\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", null),
    );
    try std.testing.expect(db.getLocal("cp1") == null);

    const blob_data: [256]u8 = @splat('x');
    try std.testing.expectError(
        error.MemoryLimitExceeded,
        db.writeBlob("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &blob_data),
    );

    // Small local doc fits, and deleting it reclaims approx_bytes.
    const lrev = try db.putLocalDoc("cp-ok", "{\"s\":1}", null);
    try std.testing.expect(db.approx_bytes > after_first);
    _ = try db.deleteLocalDoc("cp-ok", lrev);
    try std.testing.expectEqual(after_first, db.approx_bytes);

    // Retaining old revisions increases approx_bytes, and compactSegments drops
    // retained bodies and reduces approx_bytes.
    db.setMaxMemoryBytes(0);
    _ = try db.putLocal("doc1", "{\"v\":\"longer-body-for-v2-retained\"}", r1.rev, false);
    const before_compact = db.approx_bytes;
    try db.compactSegments();
    try std.testing.expect(db.approx_bytes < before_compact);
}

test "storage format version validation rejects unsupported future versions" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-cache/zouch-version-check";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};

    {
        const db = try Db.open(alloc, io, path);
        _ = try db.putLocal("doc1", "{\"v\":1}", null, false);
        try db.snapshot();
        db.closeReadOnly();
    }

    // Overwrite snapshot header version from ZSNP0001 -> ZSNP0002.
    {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        const f = try dir.openFile(io, "snapshot-000001.bin", .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, "ZSNP0002", 0);
        try f.sync(io);
    }

    try std.testing.expectError(Error.UnsupportedVersion, Db.open(alloc, io, path));
}
