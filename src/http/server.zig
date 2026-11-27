const std = @import("std");
const httpz = @import("httpz");
const tree = @import("../doc/tree.zig");
const Doc = tree.Doc;
const Leaf = tree.Leaf;
const Rev = @import("../doc/rev.zig").Rev;
const Db = @import("../store/db.zig").Db;
const jsonw = @import("jsonw.zig");
const qjs = @import("../views/quickjs.zig");
const collate = @import("../views/collate.zig");
const Hnsw = @import("../views/hnsw.zig").Index;
const replicator = @import("../replicator.zig");
const version = @import("../version.zig");
const www_assets = @import("../www_assets.zig");
const flate = std.compress.flate;

extern fn zouch_regex_match(pattern: [*]const u8, plen: usize, text: [*]const u8, tlen: usize) c_int;

const Io = std.Io;

// Dispatch resolves the request identity before invoking a handler. Handlers
// run synchronously on the same worker, so thread-local context is the least
// invasive way to pass it into validate_doc_update calls.
threadlocal var validate_user: []const u8 = "";
threadlocal var validate_roles: []const u8 = "";
threadlocal var validate_admin: bool = false;

const VectorCache = struct {
    seq: u64,
    dim: usize,
    index: Hnsw,
    /// Owned copies of the document ids. They deliberately do not borrow
    /// `Doc.id`: the documents can be purged (or their database deleted) while
    /// the cache is still alive, and a borrowed id would then be read after
    /// free by `appendNewHnswDocs`.
    ids: std.ArrayListUnmanaged([]const u8) = .empty,
    revs: std.ArrayListUnmanaged(Rev) = .empty,
};

/// Release a vector cache and everything it owns.
fn destroyVectorCache(alloc: std.mem.Allocator, cache: *VectorCache) void {
    cache.index.deinit();
    for (cache.ids.items) |id| alloc.free(id);
    cache.ids.deinit(alloc);
    cache.revs.deinit(alloc);
    alloc.destroy(cache);
}

const TextCache = struct {
    alloc: std.mem.Allocator,
    seq: u64,
    index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    keys: std.ArrayListUnmanaged([]u8) = .empty,
    ids: std.ArrayListUnmanaged([]u8) = .empty,
    owns_ids: bool = false,

    fn deinit(self: *TextCache) void {
        var it = self.index.valueIterator();
        while (it.next()) |list| list.deinit(self.alloc);
        self.index.deinit(self.alloc);
        for (self.keys.items) |key| self.alloc.free(key);
        self.keys.deinit(self.alloc);
        if (self.owns_ids) {
            for (self.ids.items) |id| self.alloc.free(id);
        }
        self.ids.deinit(self.alloc);
    }
};

const HNSW_FILE_MAGIC = "ZHNSWF01";

fn loadHnswFile(alloc: std.mem.Allocator, bytes: []const u8, dim: usize) !*VectorCache {
    if (bytes.len < HNSW_FILE_MAGIC.len + 12 or !std.mem.eql(u8, bytes[0..HNSW_FILE_MAGIC.len], HNSW_FILE_MAGIC)) return error.CorruptIndex;
    var pos: usize = HNSW_FILE_MAGIC.len;
    const seq = std.mem.readInt(u64, bytes[pos..][0..8], .little);
    pos += 8;
    const count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;
    if (count > 50_000_000) return error.CorruptIndex;

    const cache = try alloc.create(VectorCache);
    cache.* = .{ .seq = seq, .dim = dim, .index = Hnsw.init(alloc, dim) };
    errdefer destroyVectorCache(alloc, cache);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > bytes.len) return error.CorruptIndex;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (len == 0 or pos + len > bytes.len) return error.CorruptIndex;
        const id = try alloc.dupe(u8, bytes[pos .. pos + len]);
        errdefer alloc.free(id);
        try cache.ids.append(alloc, id);
        pos += len;
    }
    cache.index = try Hnsw.deserialize(alloc, bytes[pos..], dim);
    return cache;
}

const ReplicationRetry = struct {
    failures: u32,
    next_tick: u64,
};

const ActiveTask = struct {
    pid: u64,
    task_type: []u8,
    database: []u8,
    design_document: ?[]u8 = null,
    source: ?[]u8 = null,
    target: ?[]u8 = null,
    doc_id: ?[]u8 = null,
    started_on: i64,
    updated_on: i64,
    progress: u8 = 0,
    changes_done: u64 = 0,
    total_changes: u64 = 0,
};

fn envUsize(name: [*:0]const u8) ?usize {
    const raw = std.c.getenv(name) orelse return null;
    const s = std.mem.sliceTo(raw, 0);
    if (s.len == 0) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub const App = struct {
    alloc: std.mem.Allocator,
    io: Io,
    root: []const u8,
    /// A Fauxton build to serve at `/_utils`, when one is installed.
    www_dir: ?[]u8 = null,
    auth_header: ?[]u8 = null,
    auth_db: std.StringHashMapUnmanaged([]u8) = .empty,
    sessions: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Signing key for `AuthSession` cookies, persisted beside the data so a
    /// restart does not log every client out. CouchDB keeps its equivalent in
    /// `couch_httpd_auth.secret`.
    session_secret: ?[32]u8 = null,
    /// CouchDB's `uuid` for this installation, kept in the data directory.
    server_uuid: ?[16]u8 = null,
    /// Cookie lifetime, CouchDB's default.
    session_timeout: u64 = 600,
    user_roles: std.StringHashMapUnmanaged([]u8) = .empty,
    auth_mutex: Io.Mutex = .init,
    session_mutex: Io.Mutex = .init,
    dbs: std.StringHashMapUnmanaged(*Db) = .empty,
    vector_cache: std.StringHashMapUnmanaged(*VectorCache) = .empty,
    text_cache: std.StringHashMapUnmanaged(*TextCache) = .empty,
    view_cache: std.StringHashMapUnmanaged(*ViewCache) = .empty,
    view_cache_mutex: Io.Mutex = .init,
    repl_done: std.StringHashMapUnmanaged(Rev) = .empty,
    /// Jobs running right now on the bounded replicator worker pool (up to 4).
    repl_running: std.ArrayListUnmanaged(RunningJob) = .empty,
    repl_retry: std.StringHashMapUnmanaged(ReplicationRetry) = .empty,
    auto_compact_secs: u64 = 3600,
    auto_compact_seq: std.StringHashMapUnmanaged(u64) = .empty,
    auto_compact_tick: std.StringHashMapUnmanaged(u64) = .empty,
    /// Lock order: feed_mutex -> db.mutex; feed_mutex -> app.mutex; db.mutex -> app.mutex.
    /// Never hold app.mutex while taking db.mutex, and never hold two db.mutexes at once.
    mutex: Io.Mutex = .init,
    users_present_cached: std.atomic.Value(i8) = .init(-1),
    feed_threads: std.atomic.Value(u32) = .init(0),
    max_feeds: u32 = 256,
    longpolls: std.ArrayListUnmanaged(*LongpollCtx) = .empty,
    continuous: std.ArrayListUnmanaged(*ContinuousCtx) = .empty,
    feed_mutex: Io.Mutex = .init,
    max_body_bytes: usize = 64 * 1024 * 1024,
    max_db_bytes: usize = 0,
    vector_index_mb: usize = 256,
    active_tasks: std.ArrayListUnmanaged(ActiveTask) = .empty,
    active_tasks_next_pid: u64 = 1,
    active_tasks_mutex: Io.Mutex = .init,

    pub fn setRoles(self: *App, spec: []const u8) !void {
        var entries = std.mem.splitScalar(u8, spec, ';');
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidRoles;
            const user = std.mem.trim(u8, entry[0..colon], " \t");
            const roles = std.mem.trim(u8, entry[colon + 1 ..], " \t");
            if (user.len == 0) return error.InvalidRoles;
            const value = try self.alloc.dupe(u8, roles);
            errdefer self.alloc.free(value);
            // Replace in place so an allocation failure keeps the existing
            // mapping instead of dropping the user's roles.
            if (self.user_roles.getPtr(user)) |value_ptr| {
                self.alloc.free(value_ptr.*);
                value_ptr.* = value;
                continue;
            }
            const key = try self.alloc.dupe(u8, user);
            errdefer self.alloc.free(key);
            try self.user_roles.put(self.alloc, key, value);
        }
    }

    fn rolesFor(self: *const App, user: []const u8) []const u8 {
        return self.user_roles.get(user) orelse "";
    }

    pub fn setMaxFeeds(self: *App, value: u32) void {
        self.max_feeds = @min(@max(value, 1), 4096);
    }

    pub fn setMaxBodyMb(self: *App, mb: usize) void {
        self.max_body_bytes = if (mb == 0) 64 * 1024 * 1024 else std.math.mul(usize, mb, 1024 * 1024) catch std.math.maxInt(usize);
        if (@hasDecl(Db, "setMaxBlobBytes")) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.dbs.valueIterator();
            while (it.next()) |dbp| {
                dbp.*.setMaxBlobBytes(self.max_body_bytes);
            }
        }
    }

    pub fn setMaxDbMb(self: *App, mb: usize) void {
        self.max_db_bytes = std.math.mul(usize, mb, 1024 * 1024) catch std.math.maxInt(usize);
        if (@hasDecl(Db, "setMaxMemoryBytes")) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.dbs.valueIterator();
            while (it.next()) |dbp| {
                dbp.*.setMaxMemoryBytes(self.max_db_bytes);
            }
        }
    }

    pub fn setVectorIndexMb(self: *App, mb: usize) void {
        self.vector_index_mb = mb;
    }

    fn applyDbMemoryCap(self: *App, db: *Db) void {
        if (@hasDecl(Db, "setMaxMemoryBytes") and self.max_db_bytes > 0) {
            db.setMaxMemoryBytes(self.max_db_bytes);
        }
        if (@hasDecl(Db, "setMaxBlobBytes")) {
            db.setMaxBlobBytes(self.max_body_bytes);
        }
    }

    fn freeTask(alloc: std.mem.Allocator, t: ActiveTask) void {
        alloc.free(t.task_type);
        alloc.free(t.database);
        if (t.design_document) |s| alloc.free(s);
        if (t.source) |s| alloc.free(s);
        if (t.target) |s| alloc.free(s);
        if (t.doc_id) |s| alloc.free(s);
    }

    fn beginTask(
        self: *App,
        task_type: []const u8,
        database: []const u8,
        design_document: ?[]const u8,
        source: ?[]const u8,
        target: ?[]const u8,
        doc_id: ?[]const u8,
        total_changes: u64,
    ) u64 {
        const tt = self.alloc.dupe(u8, task_type) catch return 0;
        errdefer self.alloc.free(tt);
        const db_s = self.alloc.dupe(u8, database) catch return 0;
        errdefer self.alloc.free(db_s);
        const dd_s = if (design_document) |s| (self.alloc.dupe(u8, s) catch return 0) else null;
        errdefer if (dd_s) |s| self.alloc.free(s);
        const src_s = if (source) |s| (self.alloc.dupe(u8, s) catch return 0) else null;
        errdefer if (src_s) |s| self.alloc.free(s);
        const tgt_s = if (target) |s| (self.alloc.dupe(u8, s) catch return 0) else null;
        errdefer if (tgt_s) |s| self.alloc.free(s);
        const doc_s = if (doc_id) |s| (self.alloc.dupe(u8, s) catch return 0) else null;
        errdefer if (doc_s) |s| self.alloc.free(s);

        const now_s: i64 = @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
        self.active_tasks_mutex.lockUncancelable(self.io);
        defer self.active_tasks_mutex.unlock(self.io);
        const pid = self.active_tasks_next_pid;
        self.active_tasks_next_pid += 1;
        self.active_tasks.append(self.alloc, .{
            .pid = pid,
            .task_type = tt,
            .database = db_s,
            .design_document = dd_s,
            .source = src_s,
            .target = tgt_s,
            .doc_id = doc_s,
            .started_on = now_s,
            .updated_on = now_s,
            .total_changes = total_changes,
        }) catch {
            freeTask(self.alloc, .{
                .pid = pid,
                .task_type = tt,
                .database = db_s,
                .design_document = dd_s,
                .source = src_s,
                .target = tgt_s,
                .doc_id = doc_s,
                .started_on = now_s,
                .updated_on = now_s,
            });
            return 0;
        };
        return pid;
    }

    fn updateTask(self: *App, pid: u64, changes_done: u64, total_changes: u64) void {
        if (pid == 0) return;
        const now_s: i64 = @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
        self.active_tasks_mutex.lockUncancelable(self.io);
        defer self.active_tasks_mutex.unlock(self.io);
        for (self.active_tasks.items) |*t| {
            if (t.pid == pid) {
                t.changes_done = changes_done;
                t.total_changes = total_changes;
                t.updated_on = now_s;
                t.progress = if (total_changes > 0) @intCast(@min(100, (changes_done * 100) / total_changes)) else 0;
                break;
            }
        }
    }

    fn endTask(self: *App, pid: u64) void {
        if (pid == 0) return;
        self.active_tasks_mutex.lockUncancelable(self.io);
        defer self.active_tasks_mutex.unlock(self.io);
        for (self.active_tasks.items, 0..) |t, i| {
            if (t.pid == pid) {
                const removed = self.active_tasks.swapRemove(i);
                freeTask(self.alloc, removed);
                break;
            }
        }
    }

    pub fn setAutoCompact(self: *App, seconds: u64) void {
        self.auto_compact_secs = @min(seconds, 7 * 24 * 60 * 60);
    }

    fn recordAutoCompact(self: *App, name: []const u8, seq: u64, tick: u64) void {
        if (self.auto_compact_seq.getPtr(name)) |p| {
            p.* = seq;
            if (self.auto_compact_tick.getPtr(name)) |tp| tp.* = tick;
            return;
        }
        const key = self.alloc.dupe(u8, name) catch return;
        self.auto_compact_seq.put(self.alloc, key, seq) catch {
            self.alloc.free(key);
            return;
        };
        self.auto_compact_tick.put(self.alloc, key, tick) catch {};
    }

    pub fn init(alloc: std.mem.Allocator, io: Io, root: []const u8) !*App {
        try Io.Dir.cwd().createDirPath(io, root);
        const self = try alloc.create(App);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .io = io, .root = try alloc.dupe(u8, root) };
        if (envUsize("ZOUCH_MAX_BODY_MB")) |mb| self.setMaxBodyMb(mb);
        if (envUsize("ZOUCH_MAX_DB_MB")) |mb| self.setMaxDbMb(mb);
        if (envUsize("ZOUCH_VECTOR_INDEX_MB")) |mb| self.setVectorIndexMb(mb);
        return self;
    }

    pub fn notFound(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
        if (std.mem.startsWith(u8, req.url.path, "/_utils/")) {
            if (serveAsset(app, res, req.url.path["/_utils/".len..])) return;
        }
        res.status = 404;
        res.content_type = .JSON;
        res.body = "{\"error\":\"not_found\",\"reason\":\"missing\"}";
    }

    pub fn uncaughtError(_: *App, req: *httpz.Request, res: *httpz.Response, e: anyerror) void {
        // Storage failures are expected operational states, not internal
        // programming errors. Return a retryable 507 instead of masking them
        // as a generic 500 and logging an "unhandled" exception.
        if (e == error.TooLarge) {
            err(res, 413, "too_large", "Request body exceeds ZOUCH_MAX_BODY_MB") catch {};
            return;
        }
        if (e == error.FileTooLarge) {
            err(res, 507, "insufficient_storage", "Database file exceeds maximum supported size (2 GiB)") catch {};
            return;
        }
        if (e == error.BadGzip) {
            err(res, 400, "bad_request", "invalid gzip attachment") catch {};
            return;
        }
        if (e == error.MemoryLimitExceeded or e == error.VectorIndexLimitExceeded or e == error.NoSpaceLeft) {
            const msg = if (e == error.VectorIndexLimitExceeded)
                "Vector index memory budget (ZOUCH_VECTOR_INDEX_MB) exceeded"
            else if (e == error.MemoryLimitExceeded)
                "Database memory limit (ZOUCH_MAX_DB_MB) exceeded"
            else
                "Insufficient storage space";
            err(res, 507, "insufficient_storage", msg) catch {};
            return;
        }
        if (e == error.ServiceUnavailable) {
            err(res, 503, "service_unavailable", "Service temporarily unavailable") catch {};
            return;
        }
        if (e == error.DatabaseLocked or e == error.Corrupt or e == error.CorruptIndex or e == error.OutOfMemory) {
            // Name these three instead of collapsing them into
            // `internal_server_error`: "another process has the lock", "the
            // data is damaged" and "retry later" need different reactions from
            // the client and from whoever reads the log.
            const db_name = req.params.get("db") orelse "";
            if (e == error.DatabaseLocked) {
                const reason = std.fmt.allocPrint(
                    res.arena,
                    "database '{s}' is open in another process; stop that server or use a different data directory",
                    .{db_name},
                ) catch "database is open in another process";
                err(res, 409, "database_locked", reason) catch {};
                std.log.warn("locked database '{s}' while serving {s}", .{ db_name, req.url.raw });
                return;
            }
            if (e == error.OutOfMemory) {
                err(res, 503, "out_of_memory", "the server is out of memory; retry after freeing capacity") catch {};
                std.log.warn("out of memory serving {s}", .{req.url.raw});
                return;
            }
            const reason = std.fmt.allocPrint(
                res.arena,
                "database '{s}' failed recovery; stop the server, run 'zouch check' on a copy, and restore the last verified backup (docs/operations.md)",
                .{db_name},
            ) catch "database data is damaged";
            err(res, 500, "corrupt_database", reason) catch {};
            std.log.warn("corrupt database '{s}' while serving {s}: {}", .{ db_name, req.url.raw, e });
            return;
        }
        if (e == error.ReadOnlyFileSystem or
            e == error.FileTooBig or
            e == error.Io)
        {
            res.status = 507;
            res.content_type = .JSON;
            res.body = "{\"error\":\"insufficient_storage\",\"reason\":\"database storage is full or unavailable\"}";
            std.log.warn("storage error for {s}: {}", .{ req.url.raw, e });
            return;
        }
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"internal_server_error\",\"reason\":\"request failed\"}";
        std.log.warn("unhandled exception for {s}: {}", .{ req.url.raw, e });
    }

    pub fn setAuthFile(self: *App, file_path: []const u8) !void {
        const f = try Io.Dir.cwd().openFile(self.io, file_path, .{});
        defer f.close(self.io);
        const len = try f.length(self.io);
        if (len > 1024 * 1024) return error.AuthFileTooLarge;
        const bytes = try self.alloc.alloc(u8, @intCast(len));
        defer self.alloc.free(bytes);
        _ = try f.readPositionalAll(self.io, bytes, 0);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const first = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidAuthLine;
            const second_rel = std.mem.indexOfScalar(u8, line[first + 1 ..], ':') orelse return error.InvalidAuthLine;
            const second = first + 1 + second_rel;
            const db = line[0..first];
            const credential = line[first + 1 ..];
            if (db.len == 0 or second == first + 1 or second + 1 >= line.len) return error.InvalidAuthLine;
            try self.setDbAuth(db, credential);
        }
    }

    fn setDbAuth(self: *App, db: []const u8, credentials: []const u8) !void {
        const enc = std.base64.standard.Encoder;
        const buf = try self.alloc.alloc(u8, enc.calcSize(credentials.len));
        defer self.alloc.free(buf);
        _ = enc.encode(buf, credentials);
        const header = try std.fmt.allocPrint(self.alloc, "Basic {s}", .{buf});
        errdefer self.alloc.free(header);
        // Replace in place when the database is already configured: an
        // allocation failure must leave the old credential in force rather
        // than removing it and then failing.
        if (self.auth_db.getPtr(db)) |value_ptr| {
            self.alloc.free(value_ptr.*);
            value_ptr.* = header;
            return;
        }
        const key = try self.alloc.dupe(u8, db);
        errdefer self.alloc.free(key);
        try self.auth_db.put(self.alloc, key, header);
    }

    pub fn setWww(self: *App, dir: []const u8) !void {
        const copy = try self.alloc.dupe(u8, dir);
        if (self.www_dir) |old| self.alloc.free(old);
        self.www_dir = copy;
    }

    pub fn setAuth(self: *App, credentials: []const u8) !void {
        if (std.mem.indexOfScalar(u8, credentials, ':') == null) return error.InvalidAuth;
        const enc = std.base64.standard.Encoder;
        const buf = try self.alloc.alloc(u8, enc.calcSize(credentials.len));
        defer self.alloc.free(buf);
        _ = enc.encode(buf, credentials);
        // Build the replacement before releasing the old header: a failed
        // allocation must not silently disable authentication.
        const header = try std.fmt.allocPrint(self.alloc, "Basic {s}", .{buf});
        self.auth_mutex.lockUncancelable(self.io);
        defer self.auth_mutex.unlock(self.io);
        if (self.auth_header) |old| self.alloc.free(old);
        self.auth_header = header;
    }

    fn basicHeader(self: *App, credentials: []const u8) ![]u8 {
        const enc = std.base64.standard.Encoder;
        const buf = try self.alloc.alloc(u8, enc.calcSize(credentials.len));
        defer self.alloc.free(buf);
        _ = enc.encode(buf, credentials);
        return std.fmt.allocPrint(self.alloc, "Basic {s}", .{buf});
    }

    fn createSession(self: *App, name: []const u8, password: []const u8, arena: std.mem.Allocator, out_roles: *[]const u8) !?[]u8 {
        out_roles.* = "_admin";
        const creds = try std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ name, password });
        defer self.alloc.free(creds);
        const candidate = try self.basicHeader(creds);
        defer self.alloc.free(candidate);

        var ok = false;
        var has_configured_auth = false;
        var scope_list: std.ArrayListUnmanaged(u8) = .empty;
        {
            self.auth_mutex.lockUncancelable(self.io);
            defer self.auth_mutex.unlock(self.io);
            has_configured_auth = self.auth_header != null or self.auth_db.count() > 0;
            if (self.auth_header) |h| ok = headerEql(h, candidate);
            if (!ok) {
                var it = self.auth_db.iterator();
                while (it.next()) |entry| {
                    if (headerEql(entry.value_ptr.*, candidate)) {
                        if (scope_list.items.len > 0) try scope_list.append(arena, '\n');
                        try scope_list.appendSlice(arena, entry.key_ptr.*);
                        ok = true;
                    }
                }
            }
        }
        if (!ok and !has_configured_auth) {
            if (try self.acquireDb("_users")) |udb| {
                defer self.releaseDb(udb);
                if (udb.docs.count() > 0) {
                    var ubuf: [512]u8 = undefined;
                    var pbuf: [512]u8 = undefined;
                    if (basicCredentials(candidate, &ubuf, &pbuf)) |ucreds| {
                        if (verifyUserDoc(arena, udb, ucreds)) |ua| {
                            ok = true;
                            out_roles.* = ua.roles;
                        }
                    }
                }
            }
        }
        if (!ok) return null;

        return try self.makeSession(arena, name, out_roles.*, scope_list.items);
    }

    /// The key the cookie is signed with, read from the data directory once and
    /// created there if it is not there yet.
    fn sessionSecret(self: *App) [32]u8 {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        if (self.session_secret) |s| return s;

        var key: [32]u8 = undefined;
        var path_buf: [512]u8 = undefined;
        const secret_path = std.fmt.bufPrint(&path_buf, "{s}/.session-secret", .{self.root}) catch {
            self.io.random(&key);
            return key;
        };
        if (std.Io.Dir.cwd().openFile(self.io, secret_path, .{})) |f| {
            defer f.close(self.io);
            const len = f.length(self.io) catch 0;
            if (len == @sizeOf(@TypeOf(key))) {
                if (f.readPositionalAll(self.io, &key, 0) catch 0 == key.len) {
                    self.session_secret = key;
                    return key;
                }
            }
        } else |_| {}
        self.io.random(&key);
        if (std.Io.Dir.cwd().createFile(self.io, secret_path, .{ .permissions = .fromMode(0o600) })) |f| {
            f.setPermissions(self.io, .fromMode(0o600)) catch {};
            f.writePositionalAll(self.io, &key, 0) catch {};
            f.close(self.io);
        } else |_| {}
        self.session_secret = key;
        return key;
    }

    /// CouchDB's `uuid`: 16 random bytes kept in the data directory, so the
    /// value survives restarts and identifies this installation.
    fn serverUuid(self: *App) [16]u8 {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        if (self.server_uuid) |u| return u;

        var bytes: [16]u8 = undefined;
        var path_buf: [512]u8 = undefined;
        const uuid_path = std.fmt.bufPrint(&path_buf, "{s}/.server-uuid", .{self.root}) catch {
            self.io.random(&bytes);
            return bytes;
        };
        if (std.Io.Dir.cwd().openFile(self.io, uuid_path, .{})) |f| {
            defer f.close(self.io);
            if (f.readPositionalAll(self.io, &bytes, 0) catch 0 == bytes.len) {
                self.server_uuid = bytes;
                return bytes;
            }
        } else |_| {}
        self.io.random(&bytes);
        if (std.Io.Dir.cwd().createFile(self.io, uuid_path, .{})) |f| {
            f.writePositionalAll(self.io, &bytes, 0) catch {};
            f.close(self.io);
        } else |_| {}
        self.server_uuid = bytes;
        return bytes;
    }

    /// The uuid as the 32 hex characters CouchDB prints.
    fn serverUuidHex(self: *App, out: *[32]u8) []const u8 {
        const bytes = self.serverUuid();
        const hex = "0123456789abcdef";
        for (bytes, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0x0f];
        }
        return out;
    }

    fn nowSeconds(self: *App) u64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
    }

    /// `base64url(user:roles:scope:HEXEXPIRY:mac)`. The signature covers the rest, so
    /// the roles and scope cannot be edited, and nothing secret is written to disk.
    fn makeSession(self: *App, alloc: std.mem.Allocator, user: []const u8, roles: []const u8, db_scope: []const u8) ![]u8 {
        const key = self.sessionSecret();
        const expiry = self.nowSeconds() + self.session_timeout;
        var payload_buf: [640]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "{s}:{s}:{s}:{x}", .{ user, roles, db_scope, expiry });
        var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, payload, &key);
        var raw: [768]u8 = undefined;
        const joined = try std.fmt.bufPrint(&raw, "{s}:{s}", .{ payload, mac[0..] });
        const out = try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(joined.len));
        _ = std.base64.url_safe_no_pad.Encoder.encode(out, joined);
        return out;
    }

    fn scopeContains(scope: []const u8, db: []const u8) bool {
        var it = std.mem.splitScalar(u8, scope, '\n');
        while (it.next()) |item| {
            if (std.mem.eql(u8, item, db)) return true;
        }
        return false;
    }

    /// The user a cookie names, if the signature checks out and it has not
    /// expired. `scratch` holds the decoded value, so the returned slice is
    /// valid for as long as the caller's buffer.
    fn sessionUser(self: *App, token: []const u8, scratch: []u8, out_roles: *[]const u8, out_scope: *[]const u8) ?[]const u8 {
        const need = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(token) catch return null;
        if (need > scratch.len) return null;
        std.base64.url_safe_no_pad.Decoder.decode(scratch[0..need], token) catch return null;
        const bytes = scratch[0..need];

        // The MAC is raw bytes and may itself contain ':', so its position is
        // fixed at the end of the value rather than found by searching: a
        // lastIndexOf(':') truncated roughly one cookie in eight.
        const mac_len = std.crypto.auth.hmac.sha2.HmacSha256.mac_length;
        if (bytes.len < mac_len + 1) return null;
        if (bytes[bytes.len - mac_len - 1] != ':') return null;
        const rest = bytes[0 .. bytes.len - mac_len - 1];
        const mac_got = bytes[bytes.len - mac_len ..];
        const exp_at = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
        const scope_at = std.mem.lastIndexOfScalar(u8, rest[0..exp_at], ':') orelse return null;
        const body = rest[0..scope_at];
        const expiry = std.fmt.parseInt(u64, rest[exp_at + 1 ..], 16) catch return null;
        const roles_at = std.mem.indexOfScalar(u8, body, ':') orelse return null;

        const key = self.sessionSecret();
        var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, rest, &key);
        var diff: u8 = 0;
        for (mac, mac_got) |a, b| diff |= a ^ b;
        if (diff != 0) return null;
        if (self.nowSeconds() > expiry) return null;

        out_scope.* = rest[scope_at + 1 .. exp_at];
        out_roles.* = body[roles_at + 1 ..];
        return body[0..roles_at];
    }

    pub fn dispatch(self: *App, action: httpz.Action(*App), req: *httpz.Request, res: *httpz.Response) !void {
        // PouchDB's node-fetch agent reuses a connection as soon as it sees a response; a
        // server-side close without the matching header turns its checkpoint request into
        // ECONNRESET. Advertise the close explicitly.
        // PouchDB sends `Connection: close`; httpz closes the socket after the response,
        // so the response must say so or node-fetch reuses it and reports ECONNRESET.
        if (!req.canKeepAlive()) res.header("connection", "close");
        if (req.header("content-length")) |cl| {
            if (std.fmt.parseInt(usize, std.mem.trim(u8, cl, " \t"), 10) catch null) |len| {
                if (len > self.max_body_bytes) {
                    return err(res, 413, "too_large", "Request body exceeds ZOUCH_MAX_BODY_MB");
                }
            }
        }
        if (req.body_len > self.max_body_bytes) {
            return err(res, 413, "too_large", "Request body exceeds ZOUCH_MAX_BODY_MB");
        }
        if (std.mem.eql(u8, req.url.path, "/_session")) return action(self, req, res);
        if (std.mem.eql(u8, req.url.path, "/_up")) return action(self, req, res);
        if (std.mem.eql(u8, req.url.path, "/_utils") or std.mem.startsWith(u8, req.url.path, "/_utils/")) return action(self, req, res);
        const db_name = req.params.get("db");
        var has_auth_db = false;
        const expected_auth: ?[]const u8 = blk: {
            self.auth_mutex.lockUncancelable(self.io);
            defer self.auth_mutex.unlock(self.io);
            has_auth_db = self.auth_db.count() > 0;
            const raw = if (db_name) |n| (self.auth_db.get(n) orelse self.auth_header) else self.auth_header;
            break :blk if (raw) |h| try res.arena.dupe(u8, h) else null;
        };
        var cookie_scratch: [1024]u8 = undefined;
        var cookie_user: ?[]const u8 = null;
        var cookie_roles: []const u8 = "";
        var cookie_scope: []const u8 = "";
        if (req.header("cookie")) |cookies| {
            var cit = std.mem.splitScalar(u8, cookies, ';');
            while (cit.next()) |part| {
                const c = std.mem.trim(u8, part, " ");
                if (!std.mem.startsWith(u8, c, "AuthSession=")) continue;
                cookie_user = self.sessionUser(c["AuthSession=".len..], &cookie_scratch, &cookie_roles, &cookie_scope);
                if (cookie_user != null) break;
            }
        }

        const is_protected_global = db_name == null and (std.mem.eql(u8, req.url.path, "/_all_dbs") or
            std.mem.eql(u8, req.url.path, "/_replicate") or
            std.mem.eql(u8, req.url.path, "/_create_user") or
            std.mem.eql(u8, req.url.path, "/_cluster_setup") or
            std.mem.startsWith(u8, req.url.path, "/_scheduler/") or
            std.mem.startsWith(u8, req.url.path, "/_node/"));
        const is_replicator_db = db_name != null and std.mem.eql(u8, db_name.?, "_replicator");

        var auth_required = expected_auth != null or (has_auth_db and (is_protected_global or is_replicator_db));
        var auth_ok = false;
        var auth_user: []const u8 = "";
        var auth_roles: []const u8 = "";
        var user_buf: [512]u8 = undefined;
        var pass_buf: [512]u8 = undefined;
        var users_auth = false;
        if (expected_auth == null) {
            users_auth = self.hasUsersPresent() catch {
                res.status = 503;
                res.content_type = .JSON;
                res.body = "{\"error\":\"service_unavailable\",\"reason\":\"Authentication database unavailable\"}";
                return;
            };
            if (users_auth) auth_required = true;
        }

        if (expected_auth) |expected| {
            var auth_value: ?[]const u8 = null;
            if (req.header("authorization")) |got| {
                auth_value = got;
                auth_ok = headerEql(got, expected);
            }
            if (!auth_ok) {
                if (cookie_user) |cu| {
                    // The credential that guards *this* database: a per-database
                    // entry when there is one, the server admin otherwise. The
                    // cookie was minted from that same credential, so its user
                    // is the one that may match - testing only the server admin
                    // made sessions useless with ZOUCH_AUTH_FILE.
                    const owner = basicUser(expected, &user_buf) orelse "";
                    const scope_ok = cookie_scope.len == 0 or (db_name != null and scopeContains(cookie_scope, db_name.?));
                    if (cu.len > 0 and std.mem.eql(u8, cu, owner) and scope_ok) {
                        auth_user = cu;
                        auth_roles = self.rolesFor(cu);
                        auth_ok = true;
                    }
                }
            }
            if (auth_ok) {
                if (auth_value) |av| auth_user = basicUser(av, &user_buf) orelse "";
                auth_roles = self.rolesFor(auth_user);
            }
        } else if (has_auth_db and (is_protected_global or is_replicator_db)) {
            if (cookie_user) |cu| {
                if (cookie_scope.len == 0) {
                    auth_ok = true;
                    auth_user = cu;
                    auth_roles = cookie_roles;
                }
            }
            if (!auth_ok) {
                if (req.header("authorization")) |hv| {
                    {
                        self.auth_mutex.lockUncancelable(self.io);
                        defer self.auth_mutex.unlock(self.io);
                        var it = self.auth_db.valueIterator();
                        while (it.next()) |h| {
                            if (headerEql(hv, h.*)) {
                                auth_ok = true;
                                auth_user = basicUser(hv, &user_buf) orelse "";
                                auth_roles = self.rolesFor(auth_user);
                                break;
                            }
                        }
                    }
                    if (!auth_ok and users_auth) {
                        if (basicCredentials(hv, &user_buf, &pass_buf)) |creds| {
                            const users_db = self.acquireDb("_users") catch {
                                res.status = 503;
                                res.content_type = .JSON;
                                res.body = "{\"error\":\"service_unavailable\",\"reason\":\"Authentication database unavailable\"}";
                                return;
                            };
                            if (users_db) |udb| {
                                defer self.releaseDb(udb);
                                if (verifyUserDoc(res.arena, udb, creds)) |ua| {
                                    auth_ok = true;
                                    auth_user = ua.user;
                                    auth_roles = ua.roles;
                                }
                            }
                        }
                    }
                }
            }
        } else if (users_auth) {
            if (cookie_user) |cu| {
                if (cookie_scope.len == 0) {
                    // Minted only after a password check against `_users`; the
                    // roles travel inside the signature.
                    auth_ok = true;
                    auth_user = cu;
                    auth_roles = cookie_roles;
                }
            }
            const provided = req.header("authorization");
            if (provided) |hv| {
                if (basicCredentials(hv, &user_buf, &pass_buf)) |creds| {
                    const users_db = self.acquireDb("_users") catch {
                        res.status = 503;
                        res.content_type = .JSON;
                        res.body = "{\"error\":\"service_unavailable\",\"reason\":\"Authentication database unavailable\"}";
                        return;
                    };
                    if (users_db) |udb| {
                        defer self.releaseDb(udb);
                        if (verifyUserDoc(res.arena, udb, creds)) |ua| {
                            auth_ok = true;
                            auth_user = ua.user;
                            auth_roles = ua.roles;
                        }
                    }
                }
            }
        } else {
            auth_ok = true;
        }

        if (auth_required and !auth_ok) {
            res.status = 401;
            res.content_type = .JSON;
            res.body = "{\"error\":\"unauthorized\",\"reason\":\"Authentication required\"}";
            return;
        }
        if (auth_required) {
            if (db_name) |n| {
                if (std.mem.eql(u8, n, "_users") and expected_auth == null and !hasCsvRole(auth_roles, "_admin")) {
                    res.status = 403;
                    res.content_type = .JSON;
                    res.body = "{\"error\":\"forbidden\",\"reason\":\"Only _admin users may access _users\"}";
                    return;
                }
                if (std.mem.eql(u8, n, "_replicator") and expected_auth == null and !hasCsvRole(auth_roles, "_admin")) {
                    res.status = 403;
                    res.content_type = .JSON;
                    res.body = "{\"error\":\"forbidden\",\"reason\":\"Only _admin users may access _replicator\"}";
                    return;
                }
                if (self.acquireDb(n) catch null) |db| {
                    defer self.releaseDb(db);
                    if (db.securityRestricted()) {
                        if (!db.securityAllows(auth_user, auth_roles)) {
                            res.status = 403;
                            res.content_type = .JSON;
                            res.body = "{\"error\":\"forbidden\",\"reason\":\"You are not a member of this database\"}";
                            return;
                        }
                    }
                }
            }
        }
        validate_user = auth_user;
        validate_roles = auth_roles;
        validate_admin = if (expected_auth != null)
            (auth_ok and (cookie_user == null or cookie_scope.len == 0 or (db_name != null and scopeContains(cookie_scope, db_name.?))))
        else if (users_auth)
            (auth_ok and hasCsvRole(auth_roles, "_admin") and (cookie_user == null or cookie_scope.len == 0))
        else
            !has_auth_db;
        // The slices above borrow this frame's credential buffer and the
        // response arena. Clear them before either goes away so a later
        // request on this worker cannot observe (or dereference) them.
        defer {
            validate_user = "";
            validate_roles = "";
            validate_admin = false;
        }
        return action(self, req, res) catch |e| switch (e) {
            error.TooLarge => return err(res, 413, "too_large", "Request body exceeds ZOUCH_MAX_BODY_MB"),
            error.MemoryLimitExceeded => return err(res, 507, "insufficient_storage", "Database memory limit (ZOUCH_MAX_DB_MB) exceeded"),
            error.VectorIndexLimitExceeded => return err(res, 507, "insufficient_storage", "Vector index memory budget (ZOUCH_VECTOR_INDEX_MB) exceeded"),
            error.NoSpaceLeft => return err(res, 507, "insufficient_storage", "Insufficient storage space"),
            error.ServiceUnavailable => return err(res, 503, "service_unavailable", "Service temporarily unavailable"),
            else => return e,
        };
    }

    pub fn deinit(self: *App) void {
        // Feed contexts own streams and are not tied to a request lifetime;
        // release them (and their list storage) before the databases and the
        // App they point at disappear.
        self.feed_mutex.lockUncancelable(self.io);
        self.closeFeedsForLocked(null);
        self.longpolls.deinit(self.alloc);
        self.continuous.deinit(self.alloc);
        self.feed_mutex.unlock(self.io);
        var it = self.dbs.valueIterator();
        while (it.next()) |db| db.*.close();
        var kit = self.dbs.keyIterator();
        while (kit.next()) |k| self.alloc.free(k.*);
        self.dbs.deinit(self.alloc);
        var ait = self.auth_db.iterator();
        while (ait.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.auth_db.deinit(self.alloc);
        var rit = self.user_roles.iterator();
        while (rit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.user_roles.deinit(self.alloc);
        var sit = self.sessions.iterator();
        while (sit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.sessions.deinit(self.alloc);
        var rdit = self.repl_done.keyIterator();
        while (rdit.next()) |key| self.alloc.free(key.*);
        self.repl_done.deinit(self.alloc);
        for (self.repl_running.items) |r| freeRunningJob(self.alloc, r);
        self.repl_running.deinit(self.alloc);
        var rrit = self.repl_retry.keyIterator();
        while (rrit.next()) |key| self.alloc.free(key.*);
        self.repl_retry.deinit(self.alloc);
        var acit = self.auto_compact_seq.keyIterator();
        while (acit.next()) |key| self.alloc.free(key.*);
        self.auto_compact_seq.deinit(self.alloc);
        self.auto_compact_tick.deinit(self.alloc);
        var vit = self.vector_cache.iterator();
        while (vit.next()) |entry| {
            destroyVectorCache(self.alloc, entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.vector_cache.deinit(self.alloc);
        var t_it = self.text_cache.iterator();
        while (t_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.text_cache.deinit(self.alloc);
        self.view_cache_mutex.lockUncancelable(self.io);
        var vw_it = self.view_cache.iterator();
        while (vw_it.next()) |entry| {
            releaseViewCache(self.alloc, entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
        self.view_cache.deinit(self.alloc);
        self.view_cache_mutex.unlock(self.io);
        self.active_tasks_mutex.lockUncancelable(self.io);
        for (self.active_tasks.items) |t| freeTask(self.alloc, t);
        self.active_tasks.deinit(self.alloc);
        self.active_tasks_mutex.unlock(self.io);
        if (self.auth_header) |h| self.alloc.free(h);
        if (self.www_dir) |d| self.alloc.free(d);
        self.alloc.free(self.root);
        self.alloc.destroy(self);
    }

    fn path(self: *App, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.root, name });
    }

    fn getDb(self: *App, name: []const u8) !?*Db {
        if (self.dbs.get(name)) |db| return db;
        if (!validName(name)) return null;
        const p = try self.path(name);
        defer self.alloc.free(p);
        var d = Io.Dir.cwd().openDir(self.io, p, .{}) catch return null;
        d.close(self.io);
        const db = try Db.open(self.alloc, self.io, p);
        errdefer db.close();
        db.lock_checks = true;
        self.applyDbMemoryCap(db);
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        try self.dbs.put(self.alloc, key, db);
        return db;
    }

    fn createDb(self: *App, name: []const u8) !*Db {
        if (!validName(name)) return error.InvalidName;
        if (self.dbs.get(name)) |db| {
            if (db.closing) return error.DatabaseInUse;
            return db;
        }
        const p = try self.path(name);
        defer self.alloc.free(p);
        const db = try Db.open(self.alloc, self.io, p);
        errdefer db.close();
        db.lock_checks = true;
        self.applyDbMemoryCap(db);
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        try self.dbs.put(self.alloc, key, db);
        return db;
    }

    fn dbExists(self: *App, name: []const u8) bool {
        if (self.dbs.get(name) != null) return true;
        const p = self.path(name) catch return false;
        defer self.alloc.free(p);
        var d = Io.Dir.cwd().openDir(self.io, p, .{}) catch return false;
        d.close(self.io);
        return true;
    }

    /// Resolve and pin a database for a replication that runs with the mutex
    /// released. `deleteDb` refuses while `repl_active` is true, and waits for
    /// non-replication pins to drain; caller must release with `unpinReplication`.
    fn pinDb(self: *App, name: []const u8) !*Db {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const db = (try self.getDb(name)) orelse return error.DatabaseNotFound;
        if (db.closing) return error.DatabaseNotFound;
        if (db.repl_active) return error.DatabaseInUse;
        db.repl_active = true;
        db.pins += 1;
        return db;
    }

    fn unpinDb(self: *App, db: *Db) void {
        self.mutex.lockUncancelable(self.io);
        db.pins -= 1;
        self.mutex.unlock(self.io);
    }

    fn unpinReplication(self: *App, db: *Db) void {
        self.mutex.lockUncancelable(self.io);
        db.repl_active = false;
        db.pins -= 1;
        self.mutex.unlock(self.io);
    }

    /// Look up `name` under `self.mutex`, pin it so `deleteDb` cannot close it,
    /// release `self.mutex`, and acquire `db.mutex`. Lock order: `self.mutex` is
    /// never held while waiting on `db.mutex`.
    fn acquireDb(self: *App, name: []const u8) !?*Db {
        self.mutex.lockUncancelable(self.io);
        const maybe_db = self.getDb(name) catch |e| {
            self.mutex.unlock(self.io);
            return e;
        };
        const db = maybe_db orelse {
            self.mutex.unlock(self.io);
            return null;
        };
        if (db.closing) {
            self.mutex.unlock(self.io);
            return null;
        }
        db.pins += 1;
        self.mutex.unlock(self.io);
        db.lock();
        return db;
    }

    fn releaseDb(self: *App, db: *Db) void {
        db.unlock();
        self.unpinDb(db);
    }

    /// Create the system database CouchDB ships with, so code written against
    /// its replication documentation (`PUT /_replicator/job`, without creating
    /// the database first) works on a fresh data directory instead of
    /// answering 404. `_users` is deliberately left alone: its presence moves
    /// requestAuth onto the per-user path, so creating it here would make an
    /// unauthenticated server start demanding credentials.
    fn ensureSystemDbs(self: *App) void {
        if (self.dbs.get("_replicator") != null) return;
        _ = self.createDb("_replicator") catch |e| {
            std.log.warn("could not create _replicator: {s}", .{@errorName(e)});
        };
    }

    /// Remove and release every feed context that belongs to `db`, or every
    /// feed when `db` is null. The caller must hold `feed_mutex`; that is what
    /// keeps a freshly built context from being appended while the database it
    /// points at is torn down.
    fn closeFeedsForLocked(self: *App, db: ?*Db) void {
        var i: usize = 0;
        while (i < self.longpolls.items.len) {
            const ctx = self.longpolls.items[i];
            if (db != null and ctx.db != db.?) {
                i += 1;
                continue;
            }
            if (ctx.in_flight) {
                // Scheduler holds this ctx outside feed_mutex; shut down its
                // socket and let Phase 3 retire and free it.
                ctx.closing = true;
                if (@import("builtin").os.tag != .windows) ctx.stream.shutdown(ctx.io, .both) catch {};
                i += 1;
                continue;
            }
            _ = self.longpolls.orderedRemove(i);
            ctx.stream.close(ctx.io);
            if (ctx.filter_spec) |f| ctx.alloc.free(f);
            if (ctx.filter_query_json) |fq| ctx.alloc.free(fq);
            ctx.alloc.destroy(ctx);
            _ = self.feed_threads.fetchSub(1, .monotonic);
        }
        var ci: usize = 0;
        while (ci < self.continuous.items.len) {
            const ctx = self.continuous.items[ci];
            if (db != null and ctx.db != db.?) {
                ci += 1;
                continue;
            }
            if (ctx.in_flight) {
                ctx.closing = true;
                if (@import("builtin").os.tag != .windows) ctx.stream.shutdown(ctx.io, .both) catch {};
                ci += 1;
                continue;
            }
            _ = self.continuous.orderedRemove(ci);
            if (@import("builtin").os.tag != .windows) ctx.stream.shutdown(ctx.io, .both) catch {};
            ctx.stream.close(ctx.io);
            if (ctx.filter_spec) |f| ctx.alloc.free(f);
            if (ctx.filter_query_json) |fq| ctx.alloc.free(fq);
            ctx.alloc.destroy(ctx);
            _ = self.feed_threads.fetchSub(1, .monotonic);
        }
    }

    /// Search caches are keyed by database name and hold document ids. Drop
    /// them together with the database, or a same-named database created later
    /// would be searched against rows that belonged to the deleted one.
    fn dropSearchCaches(self: *App, name: []const u8) void {
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}\x00", .{name}) catch null;
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.alloc);
        var vit = self.vector_cache.keyIterator();
        while (vit.next()) |kp| {
            if (std.mem.eql(u8, kp.*, name) or (prefix != null and std.mem.startsWith(u8, kp.*, prefix.?))) {
                to_remove.append(self.alloc, kp.*) catch {};
            }
        }
        for (to_remove.items) |k| {
            if (self.vector_cache.fetchRemove(k)) |old| {
                destroyVectorCache(self.alloc, old.value);
                self.alloc.free(old.key);
            }
        }
        if (self.text_cache.fetchRemove(name)) |old| {
            old.value.deinit();
            self.alloc.destroy(old.value);
            self.alloc.free(old.key);
        }
        self.view_cache_mutex.lockUncancelable(self.io);
        defer self.view_cache_mutex.unlock(self.io);
        var vw_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer vw_remove.deinit(self.alloc);
        var vw_it = self.view_cache.keyIterator();
        while (vw_it.next()) |kp| {
            if (prefix != null and std.mem.startsWith(u8, kp.*, prefix.?)) {
                vw_remove.append(self.alloc, kp.*) catch {};
            }
        }
        for (vw_remove.items) |k| {
            if (self.view_cache.fetchRemove(k)) |old| {
                releaseViewCache(self.alloc, old.value);
                self.alloc.free(old.key);
            }
        }
    }

    fn invalidateUsersCache(self: *App) void {
        self.users_present_cached.store(-1, .release);
    }

    fn hasUsersPresent(self: *App) !bool {
        const cached = self.users_present_cached.load(.acquire);
        if (cached >= 0) return cached != 0;
        const users_db = try self.acquireDb("_users");
        const present = if (users_db) |udb| blk: {
            defer self.releaseDb(udb);
            break :blk udb.docs.count() > 0;
        } else false;
        self.users_present_cached.store(if (present) 1 else 0, .release);
        return present;
    }

    /// Delete database `name`. Caller must NOT hold `self.mutex` or `self.feed_mutex`.
    fn deleteDb(self: *App, name: []const u8) !bool {
        if (!validName(name)) return false;
        const p = try self.path(name);
        defer self.alloc.free(p);

        // Phase 1: refuse if replication owns this db; otherwise mark closing
        // and wait for in-flight HTTP pins to drain without holding `feed_mutex`
        // (prevents `feed_mutex` <-> `pins` inversion with feed registration).
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var i_set_closing = false;
            var waited_ms: usize = 0;
            while (self.dbs.get(name)) |db| {
                if (db.repl_active) {
                    if (i_set_closing) db.closing = false;
                    return error.DatabaseInUse;
                }
                if (!db.closing) {
                    db.closing = true;
                    i_set_closing = true;
                }
                if (db.pins == 0) break;
                if (waited_ms >= 5000) {
                    if (i_set_closing) db.closing = false;
                    return error.DatabaseInUse;
                }
                self.mutex.unlock(self.io);
                sleepMs(self.io, 5);
                waited_ms += 5;
                self.mutex.lockUncancelable(self.io);
            }
        }

        // Phase 2: close remaining feeds, drop caches, closeReadOnly (no snapshot),
        // and rename directory aside under `feed_mutex` -> `app.mutex`.
        var trash_path: ?[]u8 = null;
        defer if (trash_path) |tp| self.alloc.free(tp);
        var delete_target: []const u8 = p;
        {
            self.feed_mutex.lockUncancelable(self.io);
            defer self.feed_mutex.unlock(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.dropSearchCaches(name);
            if (std.mem.eql(u8, name, "_users")) self.invalidateUsersCache();
            if (self.dbs.fetchRemove(name)) |kv| {
                self.closeFeedsForLocked(kv.value);
                kv.value.closeReadOnly();
                self.alloc.free(kv.key);
            } else {
                var d = Io.Dir.cwd().openDir(self.io, p, .{}) catch return false;
                d.close(self.io);
            }

            var rnd: [8]u8 = undefined;
            self.io.random(&rnd);
            const hex = std.fmt.bytesToHex(rnd, .lower);
            const tp = try std.fmt.allocPrint(self.alloc, "{s}.__deleting_{s}", .{ p, &hex });
            trash_path = tp;
            if (Io.Dir.rename(Io.Dir.cwd(), p, Io.Dir.cwd(), tp, self.io)) |_| {
                delete_target = tp;
            } else |_| {}
        }

        // Phase 3: delete the directory tree with global mutexes released.
        try Db.deleteDb(self.io, delete_target);
        return true;
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    if (std.mem.eql(u8, name, "_users") or std.mem.eql(u8, name, "_replicator")) return true;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '$' or c == '(' or c == ')' or c == '+' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validDocId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id[0] == '_') {
        return std.mem.startsWith(u8, id, "_design/") and id.len > "_design/".len;
    }
    return true;
}

fn hasCsvRole(roles: []const u8, wanted: []const u8) bool {
    var it = std.mem.splitScalar(u8, roles, ',');
    while (it.next()) |role| {
        if (std.mem.eql(u8, role, wanted)) return true;
    }
    return false;
}

fn headerEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn basicUser(header: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, header, "Basic ")) return null;
    const encoded = header["Basic ".len..];
    const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    if (n > buf.len) return null;
    std.base64.standard.Decoder.decode(buf[0..n], encoded) catch return null;
    const colon = std.mem.indexOfScalar(u8, buf[0..n], ':') orelse return null;
    return buf[0..colon];
}
const Credentials = struct {
    user: []const u8,
    password: []const u8,
};

fn basicCredentials(header: []const u8, user_buf: []u8, pass_buf: []u8) ?Credentials {
    if (!std.mem.startsWith(u8, header, "Basic ")) return null;
    const encoded = header["Basic ".len..];
    var decoded: [1024]u8 = undefined;
    const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    if (n > decoded.len) return null;
    std.base64.standard.Decoder.decode(decoded[0..n], encoded) catch return null;
    const colon = std.mem.indexOfScalar(u8, decoded[0..n], ':') orelse return null;
    const user = decoded[0..colon];
    const pass = decoded[colon + 1 .. n];
    if (user.len > user_buf.len or pass.len > pass_buf.len) return null;
    @memcpy(user_buf[0..user.len], user);
    @memcpy(pass_buf[0..pass.len], pass);
    return .{ .user = user_buf[0..user.len], .password = pass_buf[0..pass.len] };
}

const UserAuth = struct {
    user: []const u8,
    roles: []const u8,
};
fn validateUserDoc(root: std.json.Value, id: []const u8) !void {
    if (root != .object) return error.InvalidUserDoc;
    const obj = root.object;
    const name_v = obj.get("name") orelse return error.InvalidUserDoc;
    const type_v = obj.get("type") orelse return error.InvalidUserDoc;
    if (name_v != .string or type_v != .string or !std.mem.eql(u8, type_v.string, "user")) return error.InvalidUserDoc;
    if (name_v.string.len == 0 or std.mem.indexOfScalar(u8, name_v.string, ':') != null) return error.InvalidUserDoc;
    const prefix = "org.couchdb.user:";
    if (!std.mem.startsWith(u8, id, prefix) or !std.mem.eql(u8, id[prefix.len..], name_v.string)) return error.InvalidUserDoc;
    if (obj.get("roles")) |roles| {
        if (roles != .array) return error.InvalidUserDoc;
        for (roles.array.items) |role| {
            if (role != .string) return error.InvalidUserDoc;
            if (std.mem.indexOfScalar(u8, role.string, ',') != null) return error.InvalidUserDoc;
        }
    }
    if (obj.get("password")) |pw| {
        if (pw != .string or pw.string.len == 0) return error.InvalidUserDoc;
    }
}

fn hashUserPassword(app: *App, res: *httpz.Response, root: *std.json.Value, id: []const u8) !void {
    if (!std.mem.startsWith(u8, id, "org.couchdb.user:")) return error.InvalidUserId;
    const pw_v = root.object.get("password") orelse return error.MissingPassword;
    if (pw_v != .string) return error.InvalidPassword;
    const password = pw_v.string;

    var salt: [16]u8 = undefined;
    app.io.random(&salt);
    var derived: [20]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&derived, password, &salt, 10, std.crypto.auth.hmac.HmacSha1);
    const salt_hex = std.fmt.bytesToHex(salt, .lower);
    const key_hex = std.fmt.bytesToHex(derived, .lower);

    var out: std.json.ObjectMap = .empty;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "password")) continue;
        try out.put(res.arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    try out.put(res.arena, "password_scheme", .{ .string = "pbkdf2" });
    try out.put(res.arena, "iterations", .{ .integer = 10 });
    try out.put(res.arena, "derived_key", .{ .string = try res.arena.dupe(u8, &key_hex) });
    try out.put(res.arena, "salt", .{ .string = try res.arena.dupe(u8, &salt_hex) });
    root.* = .{ .object = out };
}

fn verifyUserDoc(
    alloc: std.mem.Allocator,
    db: *Db,
    creds: Credentials,
) ?UserAuth {
    const id = std.fmt.allocPrint(alloc, "org.couchdb.user:{s}", .{creds.user}) catch return null;
    defer alloc.free(id);
    const doc = db.get(id) orelse return null;
    const leaf = doc.winnerLeaf();
    if (leaf.deleted) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, leaf.body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const scheme_v = root.get("password_scheme");
    if (scheme_v == null or scheme_v.? != .string or !std.mem.eql(u8, scheme_v.?.string, "pbkdf2")) return null;
    const salt_v = root.get("salt") orelse return null;
    const key_v = root.get("derived_key") orelse return null;
    const iter_v = root.get("iterations") orelse return null;
    if (salt_v != .string or key_v != .string or iter_v != .integer) return null;
    if (iter_v.integer < 1 or iter_v.integer > 1_000_000) return null;
    if (key_v.string.len == 0 or key_v.string.len > 64 or (key_v.string.len & 1) != 0) return null;

    var salt_buf: [64]u8 = undefined;
    var key_buf: [64]u8 = undefined;
    const salt = std.fmt.hexToBytes(&salt_buf, salt_v.string) catch return null;
    const expected = std.fmt.hexToBytes(&key_buf, key_v.string) catch return null;
    if (salt.len > salt_buf.len or expected.len > key_buf.len) return null;

    var derived_buf: [64]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        derived_buf[0..expected.len],
        creds.password,
        salt,
        @intCast(iter_v.integer),
        std.crypto.auth.hmac.HmacSha1,
    ) catch return null;
    if (!headerEql(derived_buf[0..expected.len], expected)) return null;

    var roles: std.ArrayListUnmanaged(u8) = .empty;
    if (root.get("roles")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.indexOfScalar(u8, item.string, ',') != null) continue;
                if (roles.items.len > 0) roles.append(alloc, ',') catch return null;
                roles.appendSlice(alloc, item.string) catch return null;
            }
        }
    }
    const user_copy = alloc.dupe(u8, creds.user) catch return null;
    return .{ .user = user_copy, .roles = roles.items };
}

fn err(res: *httpz.Response, status: u16, code: []const u8, reason: []const u8) !void {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"error\":");
    try jsonw.writeString(&l, res.arena, code);
    try l.appendSlice(res.arena, ",\"reason\":");
    try jsonw.writeString(&l, res.arena, reason);
    try l.append(res.arena, '}');
    res.status = status;
    res.content_type = .JSON;
    res.body = l.items;
}

/// Turn a replication failure plus its diagnostics into a response that says
/// what actually went wrong. `error.SourceHttpError` alone hides the status
/// code, the URL and the remote's own error object.
fn replicationError(res: *httpz.Response, e: anyerror, diag: *const replicator.Diag) !void {
    const reason = diag.message orelse @errorName(e);
    return err(res, 502, "replication_failed", reason);
}

fn okIdRev(res: *httpz.Response, id: []const u8, rev: []const u8) !void {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, rev);
    try l.append(res.arena, '}');
    res.status = 201;
    res.content_type = .JSON;
    res.body = l.items;
}

fn fullBody(req: *httpz.Request, alloc: std.mem.Allocator, max_bytes: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var r = try req.reader(30_000);
    // Stack safety note (§5.2 #15): 64 KiB buffer; only called from 16 MiB HTTP
    // worker threads, never from the 1 MiB feed scheduler thread.
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try r.read(&buf);
        if (n == 0) break;
        if (n > max_bytes or out.items.len > max_bytes - n) return error.TooLarge;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn q(req: *httpz.Request, name: []const u8) ?[]const u8 {
    const qs = req.query() catch return null;
    return qs.get(name);
}

fn percentDecode(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return raw;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                try out.append(alloc, raw[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                try out.append(alloc, raw[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(alloc, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseBody(res: *httpz.Response, body: []const u8) !std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch
        return error.BadJson;
    return parsed.value;
}

fn metaKey(k: []const u8) bool {
    return std.mem.eql(u8, k, "_id") or std.mem.eql(u8, k, "_rev") or
        std.mem.eql(u8, k, "_revisions") or std.mem.eql(u8, k, "_deleted") or
        std.mem.eql(u8, k, "_conflicts") or std.mem.eql(u8, k, "_attachments");
}

fn md5Hex(data: []const u8, out: *[32]u8) []const u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &hex);
    return out;
}

fn attachmentRaw(db: *Db, alloc: std.mem.Allocator, entry: std.json.Value) !?[]u8 {
    if (entry != .object) return null;
    if (entry.object.get("data")) |data_v| {
        if (data_v == .string) {
            const n = std.base64.standard.Decoder.calcSizeForSlice(data_v.string) catch return null;
            const raw = try alloc.alloc(u8, n);
            std.base64.standard.Decoder.decode(raw, data_v.string) catch {
                alloc.free(raw);
                return null;
            };
            return raw;
        }
    }
    if (entry.object.get("blob")) |blob_v| {
        if (blob_v == .string) return db.readBlob(alloc, blob_v.string) catch |e| switch (e) {
            error.FileNotFound, error.InvalidBlob => return null,
            else => return e,
        };
    }
    return null;
}

fn externalizeAttachments(db: *Db, alloc: std.mem.Allocator, atts: *std.json.Value) !void {
    if (atts.* != .object) return;
    var i: usize = 0;
    const keys = atts.object.keys();
    while (i < keys.len) : (i += 1) {
        const name = keys[i];
        const one = atts.object.getPtr(name) orelse continue;
        if (one.* != .object) continue;
        const data_v = one.object.get("data") orelse continue;
        if (data_v != .string) continue;
        const raw = (try attachmentRaw(db, alloc, one.*)) orelse continue;
        var digest_bytes: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(raw, &digest_bytes, .{});
        // The name has to outlive this iteration: the next attachment reuses
        // this stack slot, and every stub would then point at the last blob.
        const hex = try alloc.dupe(u8, &std.fmt.bytesToHex(digest_bytes, .lower));
        var dbuf: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&dbuf, &digest_bytes);
        const digest_str = try std.fmt.allocPrint(alloc, "md5-{s}", .{dbuf});
        try db.writeBlob(hex, raw);
        if (one.object.getPtr("data")) |dv| dv.* = .null;
        try one.object.put(alloc, "blob", .{ .string = hex });
        try one.object.put(alloc, "digest", .{ .string = digest_str });
        try one.object.put(alloc, "stub", .{ .bool = true });
        if (one.object.get("encoding") != null and one.object.get("encoded_length") == null) {
            try one.object.put(alloc, "encoded_length", .{ .integer = @intCast(raw.len) });
        }
        if (one.object.get("length") == null) try one.object.put(alloc, "length", .{ .integer = @intCast(raw.len) });
    }
}

fn externalizeBody(db: *Db, alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, body, "_attachments") == null) return body;
    var root = (std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return body).value;
    if (root != .object) return body;
    if (root.object.getPtr("_attachments")) |attp| try externalizeAttachments(db, alloc, attp);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, alloc, root);
    return out.items;
}

const AttachmentOutput = enum { inline_data, stub, follows };

fn writeAttachments(
    db: *Db,
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    atts: std.json.Value,
    gen: u32,
    mode: AttachmentOutput,
) !void {
    if (atts != .object) return;
    var tmp: std.ArrayListUnmanaged(u8) = .empty;
    defer tmp.deinit(alloc);
    var first = true;
    const keys = atts.object.keys();
    const vals = atts.object.values();
    for (keys, vals) |name, av| {
        if (av != .object) continue;
        const ct = if (av.object.get("content_type")) |cv|
            (if (cv == .string) cv.string else "application/octet-stream")
        else
            "application/octet-stream";
        const revpos: u32 = if (av.object.get("revpos")) |rv|
            (if (rv == .integer and rv.integer > 0) (std.math.cast(u32, rv.integer) orelse gen) else gen)
        else
            gen;
        const enc_v = av.object.get("encoding");
        const has_enc = enc_v != null and enc_v.? == .string;
        const stored_digest: ?[]const u8 = if (av.object.get("digest")) |dv| (if (dv == .string) dv.string else null) else null;
        const stored_len: ?usize = if (av.object.get("length")) |lv| (if (lv == .integer and lv.integer >= 0) @intCast(lv.integer) else null) else null;
        const stored_enc_len: ?usize = if (av.object.get("encoded_length")) |elv| (if (elv == .integer and elv.integer >= 0) @intCast(elv.integer) else null) else null;

        var raw_opt: ?[]u8 = null;
        var digest_str: []const u8 = undefined;
        var digest_buf: [28]u8 = undefined;
        var orig_len: usize = 0;
        var enc_len: usize = 0;

        if (mode != .inline_data and stored_digest != null and stored_len != null and (!has_enc or stored_enc_len != null)) {
            digest_str = stored_digest.?;
            orig_len = stored_len.?;
            enc_len = if (has_enc) stored_enc_len.? else orig_len;
        } else {
            const raw = (try attachmentRaw(db, alloc, av)) orelse continue;
            raw_opt = raw;
            if (stored_digest) |sd| {
                digest_str = sd;
            } else {
                var digest: [16]u8 = undefined;
                std.crypto.hash.Md5.hash(raw, &digest, .{});
                var dbuf: [24]u8 = undefined;
                _ = std.base64.standard.Encoder.encode(&dbuf, &digest);
                @memcpy(digest_buf[0..4], "md5-");
                @memcpy(digest_buf[4..28], &dbuf);
                digest_str = &digest_buf;
            }
            orig_len = stored_len orelse raw.len;
            enc_len = stored_enc_len orelse raw.len;
        }

        if (!first) try tmp.append(alloc, ',');
        first = false;
        try jsonw.writeString(&tmp, alloc, name);
        try tmp.appendSlice(alloc, ":{\"content_type\":");
        try jsonw.writeString(&tmp, alloc, ct);
        try tmp.appendSlice(alloc, ",\"revpos\":");
        var nbuf: [24]u8 = undefined;
        try tmp.appendSlice(alloc, std.fmt.bufPrint(&nbuf, "{d}", .{revpos}) catch "0");
        try tmp.appendSlice(alloc, ",\"digest\":");
        try jsonw.writeString(&tmp, alloc, digest_str);
        if (has_enc) {
            try tmp.appendSlice(alloc, ",\"encoding\":");
            try jsonw.writeString(&tmp, alloc, enc_v.?.string);
        }
        if (mode == .inline_data) {
            const raw = raw_opt.?;
            const b64len = std.base64.standard.Encoder.calcSize(raw.len);
            const b64 = try alloc.alloc(u8, b64len);
            _ = std.base64.standard.Encoder.encode(b64, raw);
            try tmp.appendSlice(alloc, ",\"data\":\"");
            try tmp.appendSlice(alloc, b64);
            try tmp.append(alloc, '"');
        } else {
            try tmp.appendSlice(alloc, ",\"length\":");
            try tmp.appendSlice(alloc, std.fmt.bufPrint(&nbuf, "{d}", .{orig_len}) catch "0");
            if (has_enc) {
                try tmp.appendSlice(alloc, ",\"encoded_length\":");
                try tmp.appendSlice(alloc, std.fmt.bufPrint(&nbuf, "{d}", .{enc_len}) catch "0");
            }
            try tmp.appendSlice(alloc, if (mode == .follows) ",\"follows\":true" else ",\"stub\":true");
        }
        try tmp.append(alloc, '}');
    }
    if (tmp.items.len > 0) {
        try list.appendSlice(alloc, ",\"_attachments\":{");
        try list.appendSlice(alloc, tmp.items);
        try list.append(alloc, '}');
    }
}

fn writeDocMode(
    db: *Db,
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    doc: *const Doc,
    leaf_idx: usize,
    include_revs: bool,
    include_conflicts: bool,
    att_mode: AttachmentOutput,
) !void {
    const leaf = doc.leaves.items[leaf_idx];
    var revbuf: [64]u8 = undefined;
    const revstr = leaf.rev.write(&revbuf);

    try list.append(alloc, '{');
    try jsonw.fieldString(list, alloc, "_id", doc.id);
    try list.append(alloc, ',');
    try jsonw.fieldString(list, alloc, "_rev", revstr);
    if (leaf.deleted) {
        try list.appendSlice(alloc, ",\"_deleted\":true");
    }
    if (include_revs) {
        try list.appendSlice(alloc, ",\"_revisions\":{\"start\":");
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d}", .{leaf.rev.gen}) catch "0";
        try list.appendSlice(alloc, ns);
        try list.appendSlice(alloc, ",\"ids\":[");
        for (leaf.ancestry, 0..) |anc, i| {
            if (i != 0) try list.append(alloc, ',');
            try jsonw.writeString(list, alloc, anc.hash[0..]);
        }
        try list.appendSlice(alloc, "]}");
    }
    if (include_conflicts and doc.leaves.items.len > 1) {
        var first = true;
        for (doc.leaves.items, 0..) |other, i| {
            if (i == leaf_idx or other.deleted) continue;
            if (first) {
                try list.appendSlice(alloc, ",\"_conflicts\":[");
                first = false;
            } else {
                try list.append(alloc, ',');
            }
            var ob: [64]u8 = undefined;
            try jsonw.writeString(list, alloc, other.rev.write(&ob));
        }
        if (!first) try list.append(alloc, ']');
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, leaf.body, .{}) catch null;
    // The parse owns an arena of its own; a handler passes a request arena that
    // would free it anyway, but a general allocator - a test, a background task -
    // leaks the whole body without this.
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| {
        switch (p.value) {
            .object => |obj| {
                const keys = obj.keys();
                const vals = obj.values();
                for (keys, vals) |k, v| {
                    if (metaKey(k)) continue;
                    try list.append(alloc, ',');
                    try jsonw.writeString(list, alloc, k);
                    try list.append(alloc, ':');
                    try jsonw.writeValue(list, alloc, v);
                }
            },
            else => {},
        }
        if (p.value == .object) {
            try writeAttachments(db, list, alloc, p.value.object.get("_attachments") orelse .null, leaf.rev.gen, att_mode);
        }
    }
    try list.append(alloc, '}');
}

fn writeDoc(
    db: *Db,
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    doc: *const Doc,
    leaf_idx: usize,
    include_revs: bool,
    include_conflicts: bool,
    inline_atts: bool,
) !void {
    try writeDocMode(db, list, alloc, doc, leaf_idx, include_revs, include_conflicts, if (inline_atts) .inline_data else .stub);
}

pub fn serve(app: *App, port: u16, bind_all: bool) !void {
    app.ensureSystemDbs();
    // Feed scheduler runs with a 1 MiB stack and must NOT call large-stack
    // I/O helpers like `fullBody`, `writeBlobStream`, or `sendBlob`.
    const feed_thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, longpollScheduler, .{app});
    feed_thread.detach();
    const repl_thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, replicatorScheduler, .{app});
    repl_thread.detach();
    const compact_thread = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, compactionScheduler, .{app});
    compact_thread.detach();

    var server = try httpz.Server(*App).init(app.io, app.alloc, .{
        .address = if (bind_all) .all(port) else .localhost(port),
        .request = .{ .max_body_size = app.max_body_bytes, .lazy_read_size = 1024 * 1024 },
        .workers = .{ .large_buffer_count = 8, .large_buffer_size = 1024 * 1024 },
        // Each worker accepts and serves its own connections, so a request
        // that lands on a worker busy with a long replication waits for it.
        // Eight leaves room for a replication in flight without holding up
        // everything else; the cost is one thread and its buffers per worker.
        .thread_pool = .{ .count = 8 },
    }, app);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/", hRoot, .{});
    router.get("/_up", hUp, .{});
    router.get("/_uuids", hUuids, .{});
    router.get("/_scheduler/jobs", hSchedulerJobs, .{});
    router.get("/_scheduler/docs", hSchedulerDocs, .{});
    router.get("/_utils", hUtils, .{});
    router.get("/_utils/", hUtils, .{});
    router.get("/_cluster_setup", hClusterSetupGet, .{});
    router.post("/_cluster_setup", hClusterSetupPost, .{});
    router.get("/_node/:node/_config", hNodeConfig, .{});
    router.put("/_node/:node/_config/:section/:key", hNodeConfigPut, .{});
    router.get("/_all_dbs", hAllDbs, .{});
    router.get("/_session", hSession, .{});
    router.post("/_session", hSessionPost, .{});
    router.delete("/_session", hSessionDelete, .{});
    router.post("/_replicate", hReplicate, .{});
    router.post("/_create_user", hUserCreate, .{});
    router.get("/_active_tasks", hActiveTasks, .{});
    router.get("/_membership", hMembership, .{});
    router.put("/:db", hDbPut, .{});
    router.get("/:db", hDbGet, .{});
    router.delete("/:db", hDbDelete, .{});
    router.post("/:db/_bulk_docs", hBulkDocs, .{});
    router.post("/:db/_bulk_get", hBulkGet, .{});
    router.get("/:db/_bulk_get", hBulkGetNotAllowed, .{});
    router.post("/:db/_revs_diff", hRevsDiff, .{});
    router.post("/:db/_vector_search", hVectorSearch, .{});
    router.post("/:db/_find", hFind, .{});
    router.post("/:db/_explain", hExplain, .{});
    router.post("/:db/_index", hIndexCreate, .{});
    router.get("/:db/_index", hIndexList, .{});
    router.delete("/:db/_index/:ddoc/:type/:name", hIndexDelete, .{});
    router.post("/:db/_ensure_full_commit", hEnsureCommit, .{});
    router.post("/:db/_compact", hCompact, .{});
    router.post("/:db/_view_cleanup", hViewCleanup, .{});
    router.post("/:db/_purge", hPurge, .{});
    router.get("/:db/_changes", hChanges, .{});
    // CouchDB's replicator asks for a filtered changes feed with POST and the
    // ids in the body.
    router.post("/:db/_changes", hChanges, .{});
    router.get("/:db/_all_docs", hAllDocs, .{});
    router.get("/:db/_local_docs", hLocalDocs, .{});
    router.get("/:db/_design_docs", hDesignDocs, .{});
    router.post("/:db/_missing_revs", hMissingRevs, .{});
    router.head("/:db", hDbHead, .{});
    router.get("/:db/_design/:ddoc/_info", hDesignInfo, .{});
    router.get("/:db/_partition/:p/*", hNotPartitioned, .{});
    router.post("/:db/_all_docs", hAllDocsKeys, .{});
    router.get("/:db/_security", hSecurityGet, .{});
    router.put("/:db/_security", hSecurityPut, .{});
    router.get("/:db/_revs_limit", hRevsLimitGet, .{});
    router.put("/:db/_revs_limit", hRevsLimitPut, .{});
    router.get("/:db/_local/:id", hLocalGet, .{});
    router.put("/:db/_local/:id", hLocalPut, .{});
    router.delete("/:db/_local/:id", hLocalDelete, .{});
    router.get("/:db/_design/:ddoc", hDesignGet, .{});
    router.put("/:db/_design/:ddoc", hDesignPut, .{});
    router.get("/:db/_design/:ddoc/_view/:view", hView, .{});
    router.post("/:db/_design/:ddoc/_view/:view", hView, .{});
    router.get("/:db/:doc/:att", hAttGet, .{});
    router.put("/:db/:doc/:att", hAttPut, .{});
    router.delete("/:db/:doc/:att", hAttDelete, .{});
    router.get("/:db/:doc", hDocGet, .{});
    router.put("/:db/:doc", hDocPut, .{});
    router.delete("/:db/:doc", hDocDelete, .{});

    // Bind before announcing: printing first made the log report a listener
    // that never existed when the port was taken, and always claimed
    // 127.0.0.1 even for an explicit 0.0.0.0 bind.
    server.listen() catch |e| {
        if (e == error.AddressInUse) {
            std.debug.print(
                "serve: port {d} is already in use (is another zouch running?); pick another port: zouch serve <data-dir> <port>\n",
                .{port},
            );
            std.process.exit(1);
        }
        std.debug.print("serve: cannot listen on port {d}: {s}\n", .{ port, @errorName(e) });
        std.process.exit(1);
    };
    std.debug.print("zouch listening on http://{s}:{d}\n", .{ if (bind_all) "0.0.0.0" else "127.0.0.1", port });
}

fn hRoot(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    // CouchDB also reports a `uuid` (stable per installation) and the `git_sha`
    // it was built from; clients that fingerprint a node read them.
    var uuid_buf: [32]u8 = undefined;
    const uuid = app.serverUuidHex(&uuid_buf);
    res.body = try std.fmt.allocPrint(
        res.arena,
        "{{\"couchdb\":\"Welcome\",\"version\":\"{s}\",\"git_sha\":\"{s}\",\"uuid\":\"{s}\",\"vendor\":{{\"name\":\"Zouch\"}},\"features\":[]}}",
        .{ version.string, version.git_sha, uuid },
    );
}

fn hUp(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    // Liveness only, by design: this endpoint must stay cheap and must not
    // touch the data directory. It reports the build so an operator or a
    // monitoring check can tell two binaries apart. Per-database failures are
    // reported as `database_locked` / `corrupt_database` by the handlers.
    // CouchDB answers exactly {status, seeds}; the build travels on `GET /`.
    res.body = "{\"status\":\"ok\",\"seeds\":{}}";
}

/// CouchDB mints identifiers here: `{"uuids":[...]}`, `count` of them.
fn hUuids(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var count: usize = 1;
    if (q(req, "count")) |text| {
        count = std.fmt.parseInt(usize, text, 10) catch
            return err(res, 400, "bad_request", "count must be a positive integer");
    }
    if (count == 0) count = 1;
    if (count > 1000) return err(res, 400, "bad_request", "count must be a positive integer less than 1000");

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"uuids\":[");
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try l.append(res.arena, ',');
        var bytes: [16]u8 = undefined;
        app.io.random(&bytes);
        try l.append(res.arena, '"');
        for (bytes) |b| {
            try l.append(res.arena, hex[b >> 4]);
            try l.append(res.arena, hex[b & 0x0f]);
        }
        try l.append(res.arena, '"');
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// `name=admin&password=x` as a browser posts a login form. CouchDB accepts the
/// form encoding as well as JSON, and Fauxton's login sends this one.
fn formValue(alloc: std.mem.Allocator, body: []const u8, key: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const raw = pair[eq + 1 ..];
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '+') {
                try out.append(alloc, ' ');
                i += 1;
            } else if (raw[i] == '%' and i + 2 < raw.len) {
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                    try out.append(alloc, raw[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                    try out.append(alloc, raw[i]);
                    i += 1;
                    continue;
                };
                try out.append(alloc, hi * 16 + lo);
                i += 3;
            } else {
                try out.append(alloc, raw[i]);
                i += 1;
            }
        }
        return try out.toOwnedSlice(alloc);
    }
    return null;
}

fn hSessionPost(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const ctype = req.headers.get("content-type") orelse "";
    var name_s: []const u8 = "";
    var pass_s: []const u8 = "";
    if (std.mem.indexOf(u8, ctype, "application/x-www-form-urlencoded") != null) {
        name_s = (try formValue(res.arena, body, "name")) orelse
            return err(res, 400, "bad_request", "missing name");
        pass_s = (try formValue(res.arena, body, "password")) orelse
            return err(res, 400, "bad_request", "missing password");
    } else {
        const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
        if (root != .object) return err(res, 400, "bad_request", "body must be an object");
        const name_v = root.object.get("name") orelse return err(res, 400, "bad_request", "missing name");
        const pass_v = root.object.get("password") orelse return err(res, 400, "bad_request", "missing password");
        if (name_v != .string or pass_v != .string) return err(res, 400, "bad_request", "name and password must be strings");
        name_s = name_v.string;
        pass_s = pass_v.string;
    }

    var roles: []const u8 = "_admin";
    const token = (try app.createSession(name_s, pass_s, res.arena, &roles)) orelse
        return err(res, 401, "unauthorized", "Name or password is incorrect.");
    const cookie = try std.fmt.allocPrint(res.arena, "AuthSession={s}; Version=1; Path=/; HttpOnly; SameSite=Lax", .{token});
    res.headers.add("set-cookie", cookie);
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"ok\":true,\"name\":");
    try jsonw.writeString(&l, res.arena, name_s);
    try l.appendSlice(res.arena, ",\"roles\":[");
    var rit = std.mem.splitScalar(u8, roles, ',');
    var first = true;
    while (rit.next()) |role| {
        if (role.len == 0) continue;
        if (!first) try l.append(res.arena, ',');
        try jsonw.writeString(&l, res.arena, role);
        first = false;
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hSession(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var header: ?[]const u8 = null;
    var cookie_scratch: [1024]u8 = undefined;
    var cookie_roles: []const u8 = "";
    var cookie_scope: []const u8 = "";
    var cookie_user: ?[]const u8 = null;
    if (req.header("cookie")) |cookies| {
        var cit = std.mem.splitScalar(u8, cookies, ';');
        while (cit.next()) |part| {
            const c = std.mem.trim(u8, part, " ");
            if (!std.mem.startsWith(u8, c, "AuthSession=")) continue;
            cookie_user = app.sessionUser(c["AuthSession=".len..], &cookie_scratch, &cookie_roles, &cookie_scope);
            if (cookie_user != null) break;
        }
    }
    if (cookie_user == null) header = req.header("authorization");

    var user_buf: [512]u8 = undefined;
    var name: ?[]const u8 = null;
    var roles: []const u8 = "";
    if (cookie_user) |cu| {
        name = cu;
        roles = if (cookie_scope.len == 0) cookie_roles else "";
        header = null;
    }
    if (header) |hv| {
        {
            app.auth_mutex.lockUncancelable(app.io);
            defer app.auth_mutex.unlock(app.io);
            if (app.auth_header) |expected| {
                if (headerEql(hv, expected)) {
                    name = basicUser(hv, &user_buf) orelse null;
                    if (name != null) roles = "_admin";
                }
            }
        }
        if (name == null) {
            var pbuf: [512]u8 = undefined;
            if (basicCredentials(hv, &user_buf, &pbuf)) |creds| {
                if (try app.acquireDb("_users")) |udb| {
                    defer app.releaseDb(udb);
                    if (udb.docs.count() > 0) {
                        if (verifyUserDoc(res.arena, udb, creds)) |ua| {
                            name = ua.user;
                            roles = ua.roles;
                        }
                    }
                }
            }
        }
    }

    // Admin party, as CouchDB has it: with no credential configured there is
    // nobody to log in as, so the anonymous caller is the admin. Without this a
    // fresh server and Fauxton deadlock on a login that cannot succeed.
    const has_configured_auth = blk: {
        app.auth_mutex.lockUncancelable(app.io);
        defer app.auth_mutex.unlock(app.io);
        break :blk app.auth_header != null or app.auth_db.count() > 0;
    };
    if (name == null and !has_configured_auth) {
        const users_present = try app.hasUsersPresent();
        if (!users_present) roles = "_admin";
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"ok\":true,\"userCtx\":{\"name\":");
    if (name) |n| try jsonw.writeString(&l, res.arena, n) else try l.appendSlice(res.arena, "null");
    try l.appendSlice(res.arena, ",\"roles\":[");
    var rit = std.mem.splitScalar(u8, roles, ',');
    var first = true;
    while (rit.next()) |role| {
        if (role.len == 0) continue;
        if (!first) try l.append(res.arena, ',');
        try jsonw.writeString(&l, res.arena, role);
        first = false;
    }
    try l.appendSlice(res.arena, "]},\"info\":{\"authentication_db\":\"_users\",\"authentication_handlers\":[\"cookie\",\"default\"]");
    if (name != null) {
        try l.appendSlice(res.arena, ",\"authenticated\":");
        try jsonw.writeString(&l, res.arena, if (cookie_user != null) "cookie" else "default");
    }
    try l.appendSlice(res.arena, "}}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// CouchDB answers a logout with `{"ok":true}` and an expired cookie. There is
/// no session to delete on the server: the cookie is the whole session, so
/// clearing it is what logs the client out.
fn hSessionDelete(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.headers.add("set-cookie", "AuthSession=; Version=1; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT");
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn hActiveTasks(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.append(res.arena, '[');
    app.active_tasks_mutex.lockUncancelable(app.io);
    defer app.active_tasks_mutex.unlock(app.io);
    for (app.active_tasks.items, 0..) |t, i| {
        if (i != 0) try l.append(res.arena, ',');
        try l.appendSlice(res.arena, "{\"pid\":\"<1.");
        try appendInt(&l, res.arena, t.pid);
        try l.appendSlice(res.arena, ">\",\"type\":");
        try jsonw.writeString(&l, res.arena, t.task_type);
        try l.appendSlice(res.arena, ",\"database\":");
        try jsonw.writeString(&l, res.arena, t.database);
        if (t.design_document) |dd| {
            try l.appendSlice(res.arena, ",\"design_document\":");
            try jsonw.writeString(&l, res.arena, dd);
        }
        if (t.source) |s| {
            try l.appendSlice(res.arena, ",\"source\":");
            try jsonw.writeString(&l, res.arena, s);
        }
        if (t.target) |tgt| {
            try l.appendSlice(res.arena, ",\"target\":");
            try jsonw.writeString(&l, res.arena, tgt);
        }
        if (t.doc_id) |did| {
            try l.appendSlice(res.arena, ",\"doc_id\":");
            try jsonw.writeString(&l, res.arena, did);
        }
        try l.appendSlice(res.arena, ",\"started_on\":");
        try appendInt(&l, res.arena, t.started_on);
        try l.appendSlice(res.arena, ",\"updated_on\":");
        try appendInt(&l, res.arena, t.updated_on);
        try l.appendSlice(res.arena, ",\"progress\":");
        try appendInt(&l, res.arena, t.progress);
        try l.appendSlice(res.arena, ",\"changes_done\":");
        try appendInt(&l, res.arena, t.changes_done);
        try l.appendSlice(res.arena, ",\"total_changes\":");
        try appendInt(&l, res.arena, t.total_changes);
        try l.append(res.arena, '}');
    }
    try l.append(res.arena, ']');
    res.content_type = .JSON;
    res.body = l.items;
}

fn hMembership(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = "{\"all_nodes\":[\"zouch@localhost\"],\"cluster_nodes\":[\"zouch@localhost\"]}";
}

fn hAllDbs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const auth = try requestAuth(app, req, res);
    if (auth.users_present and !auth.admin) return err(res, 403, "forbidden", "Only _admin users may list databases");
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.append(res.arena, '[');
    var first = true;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    defer listed.deinit(res.arena);

    if (std.Io.Dir.cwd().openDir(app.io, app.root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, "blobs")) continue;
            if (!validName(entry.name)) continue;
            if (listed.contains(entry.name)) continue;
            try listed.put(res.arena, try res.arena.dupe(u8, entry.name), {});
            if (!first) try l.append(res.arena, ',');
            first = false;
            try jsonw.writeString(&l, res.arena, entry.name);
        }
    } else |_| {}

    // Include open handles whose directory has not reached a listing yet
    // (for example during a create/delete race).
    var hit = app.dbs.keyIterator();
    while (hit.next()) |k| {
        if (listed.contains(k.*)) continue;
        if (!first) try l.append(res.arena, ',');
        first = false;
        try jsonw.writeString(&l, res.arena, k.*);
    }
    try l.append(res.arena, ']');
    res.content_type = .JSON;
    res.body = l.items;
}

fn hSecurityGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    res.content_type = .JSON;
    res.body = db.readSecurity(res.arena) catch return err(res, 500, "internal_error", "security read failed");
}

fn validSecuritySection(val: std.json.Value) bool {
    if (val != .object) return false;
    for ([_][]const u8{ "names", "roles" }) |k| {
        if (val.object.get(k)) |arr| {
            if (arr != .array) return false;
            for (arr.array.items) |item| {
                if (item != .string) return false;
            }
        }
    }
    return true;
}

fn hSecurityPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch
        return err(res, 400, "bad_request", "invalid JSON");
    if (root.value != .object) return err(res, 400, "bad_request", "security object required");
    if (root.value.object.get("admins")) |av| {
        if (!validSecuritySection(av)) return err(res, 400, "bad_request", "invalid admins security object");
    }
    if (root.value.object.get("members")) |mv| {
        if (!validSecuritySection(mv)) return err(res, 400, "bad_request", "invalid members security object");
    }
    const auth = try requestAuth(app, req, res);
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (!auth.admin and !db.securityAdmin(auth.user, auth.roles)) {
        return err(res, 403, "forbidden", "Only database admins may change security");
    }
    db.writeSecurity(body) catch |e| switch (e) {
        error.Corrupt => return err(res, 400, "bad_request", "invalid security object"),
        else => return e,
    };
    res.status = 200;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn requireReplicatorAdmin(app: *App, req: *httpz.Request, res: *httpz.Response, name: []const u8) !bool {
    if (!std.mem.eql(u8, name, "_replicator")) return true;
    const auth = try requestAuth(app, req, res);
    if (auth.users_present and !auth.admin) {
        try err(res, 403, "forbidden", "Only _admin users may write _replicator");
        return false;
    }
    return true;
}

fn hDbPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    if (!try requireReplicatorAdmin(app, req, res, name)) return;
    if (!validName(name)) return err(res, 400, "illegal_database_name", "invalid name");
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    if (app.dbs.get(name)) |existing| {
        if (existing.closing) return err(res, 409, "conflict", "database is being deleted; retry");
        return err(res, 412, "file_exists", "The database could not be created, the file already exists.");
    }
    if (app.dbExists(name)) {
        return err(res, 412, "file_exists", "The database could not be created, the file already exists.");
    }
    _ = app.createDb(name) catch |e| switch (e) {
        error.InvalidName => return err(res, 400, "illegal_database_name", "invalid name"),
        error.DatabaseInUse => return err(res, 409, "conflict", "database is being deleted; retry"),
        else => return e,
    };
    res.status = 201;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn hDbGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const docs_count = db.live_doc_count;
    const del_count = db.deleted_doc_count;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"db_name\":");
    try jsonw.writeString(&l, res.arena, name);
    try l.appendSlice(res.arena, ",\"doc_count\":");
    try appendInt(&l, res.arena, docs_count);
    try l.appendSlice(res.arena, ",\"doc_del_count\":");
    try appendInt(&l, res.arena, del_count);
    try l.appendSlice(res.arena, ",\"update_seq\":");
    try appendInt(&l, res.arena, db.seq);
    // `sizes` as CouchDB reports it: bytes on disk, the uncompressed document
    // JSON, and the live data. The file figure is the write-ahead log plus the
    // segments it was compacted into and the local-document log; iterating the
    // directory would seek a handle this store keeps for reading. One copy of
    // each body is kept, so `external` and `active` are the same sum.
    var file_bytes: u64 = db.wal_size;
    for (db.segments.items) |seg| {
        const st = db.dir.statFile(app.io, seg.name, .{}) catch continue;
        file_bytes += st.size;
    }
    for ([_][]const u8{ "locals.log", "manifest" }) |extra| {
        const st = db.dir.statFile(app.io, extra, .{}) catch continue;
        file_bytes += st.size;
    }
    const body_bytes = db.live_body_bytes;
    try l.appendSlice(res.arena, ",\"sizes\":{\"file\":");
    try appendInt(&l, res.arena, file_bytes);
    try l.appendSlice(res.arena, ",\"external\":");
    try appendInt(&l, res.arena, body_bytes);
    try l.appendSlice(res.arena, ",\"active\":");
    try appendInt(&l, res.arena, body_bytes);
    try l.appendSlice(res.arena, "},\"purge_seq\":");
    try appendInt(&l, res.arena, db.purge_seq);
    try l.appendSlice(res.arena, ",\"instance_start_time\":\"0\",\"compact_running\":false,\"disk_format_version\":8,\"props\":{\"partitioned\":false},\"cluster\":{\"q\":1,\"n\":1,\"w\":1,\"r\":1}}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// `HEAD /{db}` answers like `GET` without a body; clients use it to test
/// existence without paying for the counts.
fn hDbHead(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    _ = (try app.getDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    res.content_type = .JSON;
    res.body = "";
}

fn hDbDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const auth = try requestAuth(app, req, res);
    if (auth.users_present and !auth.admin) {
        // The security maps belong to the database lock, not `app.mutex`.
        const sdb = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
        defer app.releaseDb(sdb);
        if (!sdb.securityAdmin(auth.user, auth.roles)) return err(res, 403, "forbidden", "Only database admins may delete databases");
    }

    const deleted = app.deleteDb(name) catch |e| switch (e) {
        error.DatabaseInUse => return err(res, 409, "conflict", "a replication is using this database; retry when it finishes"),
        else => return e,
    };
    if (!deleted) return err(res, 404, "not_found", "Database does not exist.");
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn parseLocalRev(s: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, s, "0-")) return null;
    return std.fmt.parseInt(u32, s[2..], 10) catch null;
}

fn writeLocal(
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    id: []const u8,
    rev: u32,
    body: []const u8,
) !void {
    const full_id = try std.fmt.allocPrint(alloc, "_local/{s}", .{id});
    defer alloc.free(full_id);
    var rbuf: [32]u8 = undefined;
    const revstr = std.fmt.bufPrint(&rbuf, "0-{d}", .{rev}) catch "0-0";
    try list.append(alloc, '{');
    try jsonw.fieldString(list, alloc, "_id", full_id);
    try list.append(alloc, ',');
    try jsonw.fieldString(list, alloc, "_rev", revstr);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch null;
    if (parsed) |p| {
        switch (p.value) {
            .object => |obj| {
                const keys = obj.keys();
                const vals = obj.values();
                for (keys, vals) |k, v| {
                    if (metaKey(k)) continue;
                    try list.append(alloc, ',');
                    try jsonw.writeString(list, alloc, k);
                    try list.append(alloc, ':');
                    try jsonw.writeValue(list, alloc, v);
                }
            },
            else => {},
        }
    }
    try list.append(alloc, '}');
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// PouchDB encodes a checkpoint id containing `%3D` once in GET paths and twice in PUT
/// paths. CouchDB treats both as the same local id; canonicalise repeated escapes.
fn canonicalLocalId(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var cur = try alloc.dupe(u8, raw);
    while (true) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var changed = false;
        var i: usize = 0;
        while (i < cur.len) {
            if (cur[i] == '%' and i + 2 < cur.len) {
                if (hexVal(cur[i + 1])) |hi| {
                    if (hexVal(cur[i + 2])) |lo| {
                        try out.append(alloc, hi << 4 | lo);
                        i += 3;
                        changed = true;
                        continue;
                    }
                }
            }
            try out.append(alloc, cur[i]);
            i += 1;
        }
        alloc.free(cur);
        cur = try out.toOwnedSlice(alloc);
        if (!changed) return cur;
    }
}

fn hLocalGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const raw_id = req.params.get("id") orelse return err(res, 400, "bad_request", "missing id");
    const id = try canonicalLocalId(res.arena, raw_id);
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const local = db.getLocal(id) orelse return err(res, 404, "not_found", "missing");
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try writeLocal(&l, res.arena, id, local.rev, local.body);
    res.content_type = .JSON;
    res.body = l.items;
}

fn hLocalPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const raw_id = req.params.get("id") orelse return err(res, 400, "bad_request", "missing id");
    const id = try canonicalLocalId(res.arena, raw_id);
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    var parent: ?u32 = null;
    if (root.object.get("_rev")) |rv| {
        if (rv == .string) parent = parseLocalRev(rv.string);
    }
    const rev = db.putLocalDoc(id, body, parent) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        error.InvalidRev => return err(res, 400, "bad_request", "Invalid rev format"),
        else => return e,
    };
    var l: std.ArrayListUnmanaged(u8) = .empty;
    const full_id = try std.fmt.allocPrint(res.arena, "_local/{s}", .{id});
    var rbuf: [32]u8 = undefined;
    const revstr = std.fmt.bufPrint(&rbuf, "0-{d}", .{rev}) catch "0-0";
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, full_id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, revstr);
    try l.append(res.arena, '}');
    res.status = 201;
    res.content_type = .JSON;
    res.body = l.items;
}

fn hLocalDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const raw_id = req.params.get("id") orelse return err(res, 400, "bad_request", "missing id");
    const id = try canonicalLocalId(res.arena, raw_id);
    const rs = q(req, "rev") orelse return err(res, 409, "conflict", "Document update conflict.");
    const parent = parseLocalRev(rs) orelse return err(res, 400, "bad_request", "invalid rev");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const next = db.deleteLocalDoc(id, parent) catch |e| switch (e) {
        error.NotFound => return err(res, 404, "not_found", "missing"),
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };
    var l: std.ArrayListUnmanaged(u8) = .empty;
    const full_id = try std.fmt.allocPrint(res.arena, "_local/{s}", .{id});
    var rbuf: [32]u8 = undefined;
    const revstr = std.fmt.bufPrint(&rbuf, "0-{d}", .{next}) catch "0-0";
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, full_id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, revstr);
    try l.append(res.arena, '}');
    res.content_type = .JSON;
    res.body = l.items;
}

fn hDesignGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ddoc = req.params.get("ddoc") orelse return err(res, 400, "bad_request", "missing ddoc");
    const id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc});
    return docGetById(app, req, res, name, id);
}

fn hDesignPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ddoc = req.params.get("ddoc") orelse return err(res, 400, "bad_request", "missing ddoc");
    const auth = try requestAuth(app, req, res);
    const id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc});
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    var root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (!isDbAdminFor(db, auth)) return err(res, 403, "forbidden", "You are not a db or server admin.");
    const new_edits = if (q(req, "new_edits")) |v| !std.mem.eql(u8, v, "false") else true;

    if (!new_edits) {
        const rv = root.object.get("_rev") orelse return err(res, 400, "bad_request", "missing rev");
        if (rv != .string) return err(res, 400, "bad_request", "bad rev");
        const rev = Rev.parse(rv.string) catch return err(res, 400, "bad_request", "bad rev");
        var ancestry_buf: std.ArrayListUnmanaged(Rev) = .empty;
        defer ancestry_buf.deinit(res.arena);
        if (root.object.get("_revisions")) |revs_val| {
            if (revs_val == .object) {
                const start_v = revs_val.object.get("start");
                const ids_v = revs_val.object.get("ids");
                if (start_v != null and ids_v != null and start_v.? == .integer and ids_v.? == .array) {
                    const start: u32 = std.math.cast(u32, start_v.?.integer) orelse return err(res, 400, "bad_request", "invalid revision start");
                    for (ids_v.?.array.items, 0..) |idv, i| {
                        if (idv != .string) continue;
                        const g = start -| @as(u32, @intCast(i));
                        const ar = revFromParts(g, idv.string) catch continue;
                        try ancestry_buf.append(res.arena, ar);
                    }
                }
            }
        }
        if (ancestry_buf.items.len == 0) try ancestry_buf.append(res.arena, rev);
        const result = db.putImported(id, rev, ancestry_buf.items, body, false) catch |e| return e;
        if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
        var rb: [64]u8 = undefined;
        return okIdRev(res, id, result.rev.write(&rb));
    }

    var parent: ?Rev = null;
    if (root.object.get("_rev")) |rv| {
        if (rv == .string) parent = Rev.parse(rv.string) catch return err(res, 400, "bad_request", "invalid rev");
    }
    var store_body = body;
    if (root.object.get("_attachments") != null) {
        var parent_leaf: ?*const Leaf = null;
        if (parent) |p| {
            if (db.get(id)) |d| {
                if (d.findLeaf(p)) |idx| parent_leaf = &d.leaves.items[idx];
            }
        }
        store_body = prepareAttachments(res, &root, parent_leaf, app.max_body_bytes) catch |e| switch (e) {
            error.MissingStub => return err(res, 412, "missing_stub", "A pre-existing attachment stub wasn't found"),
            else => return e,
        };
        store_body = try externalizeBody(db, res.arena, store_body);
    }
    const result = db.putLocal(id, store_body, parent, false) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };
    if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
    var rb: [64]u8 = undefined;
    try okIdRev(res, id, result.rev.write(&rb));
}

const ViewRow = struct { id: []const u8, key: std.json.Value, value: std.json.Value };

const ViewCache = struct {
    arena: std.heap.ArenaAllocator,
    seq: u64,
    ddoc_rev: []const u8,
    rows: []const ViewRow,
    refcount: std.atomic.Value(u32) = .init(1),
};

fn releaseViewCache(alloc: std.mem.Allocator, vc: *ViewCache) void {
    if (vc.refcount.fetchSub(1, .acq_rel) == 1) {
        vc.arena.deinit();
        alloc.destroy(vc);
    }
}

fn cloneJsonValue(alloc: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |a| blk: {
            var arr = std.json.Array.init(alloc);
            try arr.ensureTotalCapacity(a.items.len);
            for (a.items) |item| {
                arr.appendAssumeCapacity(try cloneJsonValue(alloc, item));
            }
            break :blk .{ .array = arr };
        },
        .object => |o| blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.ensureTotalCapacity(alloc, o.count());
            var it = o.iterator();
            while (it.next()) |e| {
                const k = try alloc.dupe(u8, e.key_ptr.*);
                const val = try cloneJsonValue(alloc, e.value_ptr.*);
                obj.putAssumeCapacity(k, val);
            }
            break :blk .{ .object = obj };
        },
    };
}

fn buildViewCache(
    alloc: std.mem.Allocator,
    seq: u64,
    ddoc_rev: []const u8,
    rows: []const ViewRow,
) !*ViewCache {
    const vc = try alloc.create(ViewCache);
    errdefer alloc.destroy(vc);
    vc.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .seq = seq,
        .ddoc_rev = &.{},
        .rows = &.{},
    };
    errdefer vc.arena.deinit();
    const va = vc.arena.allocator();
    vc.ddoc_rev = try va.dupe(u8, ddoc_rev);
    const cloned = try va.alloc(ViewRow, rows.len);
    for (rows, 0..) |row, i| {
        cloned[i] = .{
            .id = try va.dupe(u8, row.id),
            .key = try cloneJsonValue(va, row.key),
            .value = try cloneJsonValue(va, row.value),
        };
    }
    vc.rows = cloned;
    return vc;
}

fn keyRank(v: std.json.Value) u8 {
    return switch (v) {
        .null => 0,
        .bool => 1,
        .integer, .float => 2,
        .string => 3,
        .array => 4,
        .object => 5,
        .number_string => 6,
    };
}

fn keyNameLess(ctx: ?*const collate.Collator, a: []const u8, b: []const u8) bool {
    if (ctx) |c| return c.cmp(a, b) < 0;
    return std.mem.lessThan(u8, a, b);
}

fn cmpViewKey(a: std.json.Value, b: std.json.Value, coll: ?*const collate.Collator, alloc: std.mem.Allocator) i32 {
    const ra = keyRank(a);
    const rb = keyRank(b);
    if (ra != rb) return if (ra < rb) -1 else 1;
    return switch (a) {
        .string => |sa| if (coll) |c| c.cmp(sa, b.string) else switch (std.mem.order(u8, sa, b.string)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        },
        .integer => |ia| switch (b) {
            .integer => |ib| if (ia < ib) -1 else if (ia > ib) 1 else 0,
            .float => |fb| if (@as(f64, @floatFromInt(ia)) < fb) -1 else if (@as(f64, @floatFromInt(ia)) > fb) 1 else 0,
            else => 0,
        },
        .float => |fa| switch (b) {
            .integer => |ib| if (fa < @as(f64, @floatFromInt(ib))) -1 else if (fa > @as(f64, @floatFromInt(ib))) 1 else 0,
            .float => |fb| if (fa < fb) -1 else if (fa > fb) 1 else 0,
            else => 0,
        },
        .bool => |ba| if (ba == b.bool) 0 else if (!ba) -1 else 1,
        .null => 0,
        .array => |aa| blk: {
            const ab = b.array;
            const n = @min(aa.items.len, ab.items.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const c = cmpViewKey(aa.items[i], ab.items[i], coll, alloc);
                if (c != 0) break :blk c;
            }
            break :blk if (aa.items.len < ab.items.len) -1 else if (aa.items.len > ab.items.len) 1 else 0;
        },
        .object => |oa| blk: {
            const ob = b.object;
            const ka = oa.keys();
            const kb = ob.keys();
            const keys_a = alloc.dupe([]const u8, ka) catch return 0;
            defer alloc.free(keys_a);
            const keys_b = alloc.dupe([]const u8, kb) catch return 0;
            defer alloc.free(keys_b);
            std.mem.sort([]const u8, keys_a, coll, keyNameLess);
            std.mem.sort([]const u8, keys_b, coll, keyNameLess);
            const n = @min(keys_a.len, keys_b.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var kc = cmpViewKey(.{ .string = keys_a[i] }, .{ .string = keys_b[i] }, coll, alloc);
                if (kc == 0) {
                    const va = oa.get(keys_a[i]) orelse break :blk 0;
                    const vb = ob.get(keys_b[i]) orelse break :blk 0;
                    kc = cmpViewKey(va, vb, coll, alloc);
                }
                if (kc != 0) break :blk kc;
            }
            break :blk if (keys_a.len < keys_b.len) -1 else if (keys_a.len > keys_b.len) 1 else 0;
        },
        else => 0,
    };
}

fn matchViewKey(v: std.json.Value, filter: std.json.Value, coll: ?*const collate.Collator, alloc: std.mem.Allocator) bool {
    return cmpViewKey(v, filter, coll, alloc) == 0;
}

fn evalReduceChunk(
    eng: *qjs.Engine,
    alloc: std.mem.Allocator,
    src: []const u8,
    keys_json: []const u8,
    vals_json: []const u8,
    rereduce: bool,
) !std.json.Value {
    const code = try std.fmt.allocPrint(alloc, "JSON.stringify(({s})({s},{s},{s}))", .{
        src,
        keys_json,
        vals_json,
        if (rereduce) "true" else "false",
    });
    const out = eng.eval(alloc, code) catch return error.ReduceFailed;
    defer alloc.free(out);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.ReduceFailed;
    return parsed.value;
}

fn evalReduce(
    eng: *qjs.Engine,
    alloc: std.mem.Allocator,
    src: []const u8,
    rows: []const ViewRow,
    rereduce: bool,
) !std.json.Value {
    if (!rereduce and rows.len > 256) {
        var partials: std.ArrayListUnmanaged(std.json.Value) = .empty;
        var offset: usize = 0;
        while (offset < rows.len) {
            const end = @min(offset + 256, rows.len);
            const partial = try evalReduce(eng, alloc, src, rows[offset..end], false);
            try partials.append(alloc, partial);
            offset = end;
        }
        var pvals: std.ArrayListUnmanaged(u8) = .empty;
        try pvals.append(alloc, '[');
        for (partials.items, 0..) |pv, i| {
            if (i != 0) try pvals.append(alloc, ',');
            try jsonw.writeValue(&pvals, alloc, pv);
        }
        try pvals.append(alloc, ']');
        return evalReduceChunk(eng, alloc, src, "null", pvals.items, true);
    }
    var keys: std.ArrayListUnmanaged(u8) = .empty;
    var vals: std.ArrayListUnmanaged(u8) = .empty;
    try keys.append(alloc, '[');
    try vals.append(alloc, '[');
    for (rows, 0..) |row, i| {
        if (i != 0) {
            try keys.append(alloc, ',');
            try vals.append(alloc, ',');
        }
        try jsonw.writeValue(&keys, alloc, row.key);
        try jsonw.writeValue(&vals, alloc, row.value);
    }
    try keys.append(alloc, ']');
    try vals.append(alloc, ']');
    return evalReduceChunk(eng, alloc, src, if (rereduce) "null" else keys.items, vals.items, rereduce);
}

fn viewIndexName(alloc: std.mem.Allocator, id: []const u8, view: []const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(id);
    h.update("\x00");
    h.update(view);
    return std.fmt.allocPrint(alloc, "{x}.idx", .{h.final()});
}

fn loadViewIndex(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    db_seq: u64,
    ddoc_rev: []const u8,
    rows: *std.ArrayListUnmanaged(ViewRow),
    last_seq: *u64,
) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return false;
    if (parsed.value != .object) return false;
    const seq_v = parsed.value.object.get("db_seq") orelse return false;
    if (seq_v != .integer or seq_v.integer < 0) return false;
    const cached_seq: u64 = @intCast(seq_v.integer);
    if (cached_seq > db_seq) return false;
    const rev_v = parsed.value.object.get("ddoc_rev") orelse return false;
    if (rev_v != .string or !std.mem.eql(u8, rev_v.string, ddoc_rev)) return false;
    const rows_v = parsed.value.object.get("rows") orelse return false;
    if (rows_v != .array) return false;
    for (rows_v.array.items) |item| {
        if (item != .object) continue;
        const idv = item.object.get("id") orelse continue;
        const keyv = item.object.get("key") orelse continue;
        const valv = item.object.get("value") orelse continue;
        if (idv != .string) continue;
        rows.append(alloc, .{ .id = idv.string, .key = keyv, .value = valv }) catch {
            rows.clearRetainingCapacity();
            return false;
        };
    }
    last_seq.* = cached_seq;
    return true;
}

fn serializeViewIndex(
    alloc: std.mem.Allocator,
    db_seq: u64,
    ddoc_rev: []const u8,
    rows: []const ViewRow,
) ![]u8 {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(alloc, "{\"db_seq\":");
    try appendInt(&l, alloc, db_seq);
    try l.appendSlice(alloc, ",\"ddoc_rev\":");
    try jsonw.writeString(&l, alloc, ddoc_rev);
    try l.appendSlice(alloc, ",\"rows\":[");
    for (rows, 0..) |row, i| {
        if (i != 0) try l.append(alloc, ',');
        try l.appendSlice(alloc, "{\"id\":");
        try jsonw.writeString(&l, alloc, row.id);
        try l.appendSlice(alloc, ",\"key\":");
        try jsonw.writeValue(&l, alloc, row.key);
        try l.appendSlice(alloc, ",\"value\":");
        try jsonw.writeValue(&l, alloc, row.value);
        try l.append(alloc, '}');
    }
    try l.appendSlice(alloc, "]}");
    return l.items;
}

fn mapDocBody(
    eng: *qjs.Engine,
    alloc: std.mem.Allocator,
    map_src: []const u8,
    doc_id: []const u8,
    doc_body: []const u8,
    rows: *std.ArrayListUnmanaged(ViewRow),
) !void {
    const code = try std.fmt.allocPrint(alloc, "var __rows=[];function emit(k,v){{__rows.push([k,v]);}};({s})({s});JSON.stringify(__rows);", .{ map_src, doc_body });
    const out = eng.eval(alloc, code) catch return error.MapFailed;
    defer alloc.free(out);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.MapFailed;
    if (parsed.value != .array) return error.MapFailed;
    for (parsed.value.array.items) |item| {
        if (item != .array or item.array.items.len < 2) continue;
        try rows.append(alloc, .{ .id = doc_id, .key = item.array.items[0], .value = item.array.items[1] });
    }
}

fn mapDoc(
    eng: *qjs.Engine,
    alloc: std.mem.Allocator,
    map_src: []const u8,
    doc: *const Doc,
    rows: *std.ArrayListUnmanaged(ViewRow),
) !void {
    return mapDocBody(eng, alloc, map_src, doc.*.id, doc.*.winnerLeaf().body, rows);
}

fn bodyOrQueryBool(req: *httpz.Request, obj: ?std.json.ObjectMap, key: []const u8, default: bool) bool {
    if (q(req, key)) |v| return std.mem.eql(u8, v, "true");
    if (obj) |o| {
        if (o.get(key)) |v| {
            if (v == .bool) return v.bool;
        }
    }
    return default;
}

fn bodyOrQueryUsize(req: *httpz.Request, obj: ?std.json.ObjectMap, key: []const u8, default: usize) usize {
    if (q(req, key)) |v| return std.fmt.parseInt(usize, v, 10) catch default;
    if (obj) |o| {
        if (o.get(key)) |v| {
            if (v == .integer and v.integer >= 0) return std.math.cast(usize, v.integer) orelse default;
        }
    }
    return default;
}

fn bodyOrQueryJsonValue(req: *httpz.Request, alloc: std.mem.Allocator, obj: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (q(req, key)) |v| return queryJsonValue(alloc, v);
    if (obj) |o| return o.get(key);
    return null;
}

fn hView(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ddoc = req.params.get("ddoc") orelse return err(res, 400, "bad_request", "missing ddoc");
    const view = req.params.get("view") orelse return err(res, 400, "bad_request", "missing view");
    const id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc});

    var body_obj: ?std.json.ObjectMap = null;
    if (req.method == .POST) {
        if (fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else null) |b| {
            if (b.len > 0) {
                const parsed = parseBody(res, b) catch return err(res, 400, "bad_request", "invalid JSON");
                if (parsed != .object) return err(res, 400, "bad_request", "JSON object required");
                body_obj = parsed.object;
            }
        }
    }
    const include_docs = bodyOrQueryBool(req, body_obj, "include_docs", false);
    const descending = bodyOrQueryBool(req, body_obj, "descending", false);
    const limit: usize = bodyOrQueryUsize(req, body_obj, "limit", 0);
    const skip: usize = bodyOrQueryUsize(req, body_obj, "skip", 0);
    const group = bodyOrQueryBool(req, body_obj, "group", false);
    const reduce_opt = bodyOrQueryBool(req, body_obj, "reduce", true);
    const rereduce_opt = bodyOrQueryBool(req, body_obj, "rereduce", false);
    const inclusive_end = bodyOrQueryBool(req, body_obj, "inclusive_end", true);
    var keys_filter: ?std.json.Value = if (body_obj) |o| o.get("keys") else null;
    if (keys_filter == null) {
        if (q(req, "keys")) |kv| {
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, kv, .{}) catch
                return err(res, 400, "bad_request", "invalid keys");
            keys_filter = parsed.value;
        }
    }
    const key_filter = bodyOrQueryJsonValue(req, res.arena, body_obj, "key");
    const startkey = bodyOrQueryJsonValue(req, res.arena, body_obj, "startkey");
    const endkey = bodyOrQueryJsonValue(req, res.arena, body_obj, "endkey");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const ddoc_doc = db.get(id) orelse return err(res, 404, "not_found", "missing");
    const dparsed = std.json.parseFromSlice(std.json.Value, res.arena, ddoc_doc.winnerLeaf().body, .{}) catch
        return err(res, 400, "bad_request", "invalid design doc");
    if (dparsed.value != .object) return err(res, 400, "bad_request", "invalid design doc");
    const views = dparsed.value.object.get("views") orelse return err(res, 404, "not_found", "missing views");
    if (views != .object) return err(res, 404, "not_found", "missing views");
    const vv = views.object.get(view) orelse return err(res, 404, "not_found", "missing_named_view");
    if (vv != .object) return err(res, 404, "not_found", "missing_named_view");
    const map_src = vv.object.get("map") orelse return err(res, 400, "bad_request", "missing map");
    if (map_src != .string) return err(res, 400, "bad_request", "map must be a string");
    const reduce_src: ?[]const u8 = if (vv.object.get("reduce")) |rv| (if (rv == .string) rv.string else null) else null;

    var ddoc_rev_buf: [64]u8 = undefined;
    const ddoc_rev = try res.arena.dupe(u8, ddoc_doc.winnerLeaf().rev.write(&ddoc_rev_buf));
    const snap_seq = db.seq;
    const cache_key = try std.fmt.allocPrint(res.arena, "{s}\x00{s}\x00{s}", .{ name, id, view });

    var cached_vc: ?*ViewCache = null;
    {
        app.view_cache_mutex.lockUncancelable(app.io);
        defer app.view_cache_mutex.unlock(app.io);
        if (app.view_cache.get(cache_key)) |vc| {
            if (vc.seq == snap_seq and std.mem.eql(u8, vc.ddoc_rev, ddoc_rev)) {
                _ = vc.refcount.fetchAdd(1, .acq_rel);
                cached_vc = vc;
            }
        }
    }
    defer if (cached_vc) |vc| releaseViewCache(app.alloc, vc);

    var coll_holder = collate.Collator.init();
    defer if (coll_holder) |*c| c.deinit();
    const coll: ?*const collate.Collator = if (coll_holder) |*c| c else null;

    var eng_opt: ?qjs.Engine = null;
    defer if (eng_opt) |*e| e.deinit();

    var rows: std.ArrayListUnmanaged(ViewRow) = .empty;
    defer rows.deinit(res.arena);

    const sorted_rows: []const ViewRow = if (cached_vc) |vc| vc.rows else blk: {
        const idx_name = try viewIndexName(res.arena, id, view);
        var loaded = false;
        var last_seq: u64 = 0;
        if (try db.readViewIndex(res.arena, idx_name)) |bytes| {
            loaded = loadViewIndex(res.arena, bytes, snap_seq, ddoc_rev, &rows, &last_seq);
        }

        const SnapDoc = struct { id: []const u8, body: []const u8, deleted: bool };
        var snap_docs: std.ArrayListUnmanaged(SnapDoc) = .empty;
        defer snap_docs.deinit(res.arena);
        const need_build = !loaded or last_seq < snap_seq;
        if (!loaded) {
            var it = db.docs.valueIterator();
            while (it.next()) |d| {
                if (d.*.winnerLeaf().deleted) continue;
                if (std.mem.startsWith(u8, d.*.id, "_design/")) continue;
                const js_body = try buildJsDoc(db, res.arena, d.*.id, d.*.winnerLeaf().rev, d.*.winnerLeaf().body, false);
                try snap_docs.append(res.arena, .{
                    .id = try res.arena.dupe(u8, d.*.id),
                    .body = js_body,
                    .deleted = false,
                });
            }
        } else if (last_seq < snap_seq) {
            var it = db.docs.valueIterator();
            while (it.next()) |d| {
                if (d.*.seq <= last_seq) continue;
                const del = d.*.winnerLeaf().deleted;
                const js_body = if (del) "" else try buildJsDoc(db, res.arena, d.*.id, d.*.winnerLeaf().rev, d.*.winnerLeaf().body, false);
                try snap_docs.append(res.arena, .{
                    .id = try res.arena.dupe(u8, d.*.id),
                    .body = js_body,
                    .deleted = del,
                });
            }
        }

        // Release db.mutex during CPU-heavy QuickJS map and sorting so
        // concurrent reads/writes on this DB are not blocked.
        var mutex_held = false;
        db.unlock();
        // `defer`, not `errdefer`: a failed map is reported with a normal
        // `return err(...)`, and the caller's `defer releaseDb` unlocks again.
        defer if (!mutex_held) db.lock();

        const task_pid = if (need_build) app.beginTask("indexer", name, id, null, null, null, snap_docs.items.len) else 0;
        defer app.endTask(task_pid);

        if (need_build) {
            eng_opt = qjs.Engine.init() catch return err(res, 500, "internal_error", "cannot start JavaScript engine");
        }

        if (!loaded) {
            for (snap_docs.items, 0..) |sd, si| {
                mapDocBody(&eng_opt.?, res.arena, map_src.string, sd.id, sd.body, &rows) catch |e| switch (e) {
                    error.MapFailed => return err(res, 500, "compilation_error", "map function failed"),
                    else => return e,
                };
                if ((si & 63) == 63) app.updateTask(task_pid, si + 1, snap_docs.items.len);
            }
            last_seq = snap_seq;
        } else if (last_seq < snap_seq) {
            for (snap_docs.items, 0..) |sd, si| {
                var w: usize = 0;
                for (rows.items) |row| {
                    if (!std.mem.eql(u8, row.id, sd.id)) {
                        rows.items[w] = row;
                        w += 1;
                    }
                }
                rows.shrinkRetainingCapacity(w);
                if (!sd.deleted and !std.mem.startsWith(u8, sd.id, "_design/")) {
                    mapDocBody(&eng_opt.?, res.arena, map_src.string, sd.id, sd.body, &rows) catch |e| switch (e) {
                        error.MapFailed => return err(res, 500, "compilation_error", "map function failed"),
                        else => return e,
                    };
                }
                if ((si & 63) == 63) app.updateTask(task_pid, si + 1, snap_docs.items.len);
            }
            last_seq = snap_seq;
        }

        const SortCtx = struct { coll: ?*const collate.Collator, alloc: std.mem.Allocator };
        std.mem.sort(ViewRow, rows.items, SortCtx{ .coll = coll, .alloc = res.arena }, struct {
            fn less(ctx: SortCtx, a: ViewRow, b: ViewRow) bool {
                const c = cmpViewKey(a.key, b.key, ctx.coll, ctx.alloc);
                if (c != 0) return c < 0;
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.less);

        const serialized_idx = if (need_build) serializeViewIndex(res.arena, last_seq, ddoc_rev, rows.items) catch null else null;

        if (buildViewCache(app.alloc, snap_seq, ddoc_rev, rows.items) catch null) |new_vc| {
            app.view_cache_mutex.lockUncancelable(app.io);
            defer app.view_cache_mutex.unlock(app.io);
            const gop = app.view_cache.getOrPut(app.alloc, cache_key) catch null;
            if (gop) |entry| {
                if (entry.found_existing) {
                    releaseViewCache(app.alloc, entry.value_ptr.*);
                    entry.value_ptr.* = new_vc;
                } else {
                    const owned_key = app.alloc.dupe(u8, cache_key) catch null;
                    if (owned_key) |k| {
                        entry.key_ptr.* = k;
                        entry.value_ptr.* = new_vc;
                    } else {
                        _ = app.view_cache.remove(cache_key);
                        releaseViewCache(app.alloc, new_vc);
                    }
                }
            } else {
                releaseViewCache(app.alloc, new_vc);
            }
        }

        db.lock();
        mutex_held = true;
        if (serialized_idx) |b| {
            if (db.seq == snap_seq) {
                db.writeViewIndex(idx_name, b) catch {};
            }
        }
        break :blk rows.items;
    };

    var filtered: std.ArrayListUnmanaged(ViewRow) = .empty;
    defer filtered.deinit(res.arena);
    const no_filter = key_filter == null and startkey == null and endkey == null and keys_filter == null and !descending;
    if (!no_filter) {
        const lo_bound = if (descending) endkey else startkey;
        const hi_bound = if (descending) startkey else endkey;
        for (sorted_rows) |row| {
            if (key_filter) |kf| {
                if (!matchViewKey(row.key, kf, coll, res.arena)) continue;
            } else {
                if (lo_bound) |lo| {
                    const c = cmpViewKey(row.key, lo, coll, res.arena);
                    if (if (descending and !inclusive_end) c <= 0 else c < 0) continue;
                }
                if (hi_bound) |hi| {
                    const c = cmpViewKey(row.key, hi, coll, res.arena);
                    if (if (!descending and !inclusive_end) c >= 0 else c > 0) continue;
                }
            }
            if (keys_filter) |kfs| {
                if (kfs != .array) return err(res, 400, "bad_request", "keys must be an array");
                var any = false;
                for (kfs.array.items) |k| {
                    if (matchViewKey(row.key, k, coll, res.arena)) {
                        any = true;
                        break;
                    }
                }
                if (!any) continue;
            }
            try filtered.append(res.arena, row);
        }
        if (descending) std.mem.reverse(ViewRow, filtered.items);
    }
    const view_rows: []const ViewRow = if (no_filter) sorted_rows else filtered.items;

    var l: std.ArrayListUnmanaged(u8) = .empty;

    if (reduce_opt and reduce_src != null) {
        const is_count = std.mem.eql(u8, reduce_src.?, "_count");
        const is_sum = std.mem.eql(u8, reduce_src.?, "_sum");
        const is_stats = std.mem.eql(u8, reduce_src.?, "_stats");
        const ReducedRow = struct { key: std.json.Value, json_val: []const u8 };
        var reduced: std.ArrayListUnmanaged(ReducedRow) = .empty;
        defer reduced.deinit(res.arena);

        const computeBuiltin = struct {
            fn run(
                alloc: std.mem.Allocator,
                slice: []const ViewRow,
                count_only: bool,
                sum_only: bool,
                stats_only: bool,
                rereduce: bool,
            ) ![]const u8 {
                if (count_only) {
                    var c: usize = 0;
                    if (rereduce) {
                        for (slice) |r| {
                            if (r.value == .integer and r.value.integer >= 0) c += @intCast(r.value.integer);
                        }
                    } else {
                        c = slice.len;
                    }
                    return std.fmt.allocPrint(alloc, "{d}", .{c});
                }
                if (sum_only) {
                    var s: f64 = 0;
                    for (slice) |r| if (jsonNumber(r.value)) |n| {
                        s += n;
                    };
                    return std.fmt.allocPrint(alloc, "{d}", .{s});
                }
                if (stats_only) {
                    var sum: f64 = 0;
                    var count: u64 = 0;
                    var min_v: ?f64 = null;
                    var max_v: ?f64 = null;
                    var sumsqr: f64 = 0;
                    for (slice) |r| {
                        if (rereduce and r.value == .object) {
                            const o = r.value.object;
                            const sc = if (o.get("count")) |v| (if (v == .integer and v.integer >= 0) @as(u64, @intCast(v.integer)) else 0) else 0;
                            if (sc == 0) continue;
                            count += sc;
                            if (o.get("sum")) |v| if (jsonNumber(v)) |n| {
                                sum += n;
                            };
                            if (o.get("sumsqr")) |v| if (jsonNumber(v)) |n| {
                                sumsqr += n;
                            };
                            if (o.get("min")) |v| if (jsonNumber(v)) |n| {
                                min_v = if (min_v) |m| @min(m, n) else n;
                            };
                            if (o.get("max")) |v| if (jsonNumber(v)) |n| {
                                max_v = if (max_v) |m| @max(m, n) else n;
                            };
                        } else if (jsonNumber(r.value)) |n| {
                            sum += n;
                            count += 1;
                            min_v = if (min_v) |m| @min(m, n) else n;
                            max_v = if (max_v) |m| @max(m, n) else n;
                            sumsqr += n * n;
                        }
                    }
                    return std.fmt.allocPrint(alloc, "{{\"sum\":{d},\"count\":{d},\"min\":{d},\"max\":{d},\"sumsqr\":{d}}}", .{
                        sum,
                        count,
                        min_v orelse 0,
                        max_v orelse 0,
                        sumsqr,
                    });
                }
                unreachable;
            }
        }.run;

        if (group) {
            var i: usize = 0;
            while (i < view_rows.len) {
                const group_start = i;
                const group_key = view_rows[i].key;
                while (i < view_rows.len and cmpViewKey(view_rows[i].key, group_key, coll, res.arena) == 0) : (i += 1) {}
                const slice = view_rows[group_start..i];
                const jv = if (is_count or is_sum or is_stats)
                    try computeBuiltin(res.arena, slice, is_count, is_sum, is_stats, rereduce_opt)
                else blk: {
                    if (eng_opt == null) {
                        eng_opt = qjs.Engine.init() catch return err(res, 500, "internal_error", "cannot start JavaScript engine");
                    }
                    const val = evalReduce(&eng_opt.?, res.arena, reduce_src.?, slice, rereduce_opt) catch
                        return err(res, 500, "reduce_error", "reduce failed");
                    var vb: std.ArrayListUnmanaged(u8) = .empty;
                    try jsonw.writeValue(&vb, res.arena, val);
                    break :blk vb.items;
                };
                try reduced.append(res.arena, .{ .key = group_key, .json_val = jv });
            }
        } else if (view_rows.len > 0) {
            const jv = if (is_count or is_sum or is_stats)
                try computeBuiltin(res.arena, view_rows, is_count, is_sum, is_stats, rereduce_opt)
            else blk: {
                if (eng_opt == null) {
                    eng_opt = qjs.Engine.init() catch return err(res, 500, "internal_error", "cannot start JavaScript engine");
                }
                const val = evalReduce(&eng_opt.?, res.arena, reduce_src.?, view_rows, rereduce_opt) catch
                    return err(res, 500, "reduce_error", "reduce failed");
                var vb: std.ArrayListUnmanaged(u8) = .empty;
                try jsonw.writeValue(&vb, res.arena, val);
                break :blk vb.items;
            };
            try reduced.append(res.arena, .{ .key = .null, .json_val = jv });
        }

        const r_total = reduced.items.len;
        const r_start = @min(skip, r_total);
        var r_end = r_total;
        if (limit > 0 and r_end - r_start > limit) r_end = r_start + limit;

        try l.appendSlice(res.arena, "{\"rows\":[");
        var ri = r_start;
        while (ri < r_end) : (ri += 1) {
            if (ri != r_start) try l.append(res.arena, ',');
            try l.appendSlice(res.arena, "{\"key\":");
            try jsonw.writeValue(&l, res.arena, reduced.items[ri].key);
            try l.appendSlice(res.arena, ",\"value\":");
            try l.appendSlice(res.arena, reduced.items[ri].json_val);
            try l.append(res.arena, '}');
        }
    } else {
        const total = sorted_rows.len;
        const start = @min(skip, view_rows.len);
        var end = view_rows.len;
        if (limit > 0 and end - start > limit) end = start + limit;

        try l.appendSlice(res.arena, "{\"total_rows\":");
        try appendInt(&l, res.arena, total);
        try l.appendSlice(res.arena, ",\"offset\":");
        try appendInt(&l, res.arena, start);
        try l.appendSlice(res.arena, ",\"rows\":[");

        var i = start;
        while (i < end) : (i += 1) {
            if (i != start) try l.append(res.arena, ',');
            const row = view_rows[i];
            try l.appendSlice(res.arena, "{\"id\":");
            try jsonw.writeString(&l, res.arena, row.id);
            try l.appendSlice(res.arena, ",\"key\":");
            try jsonw.writeValue(&l, res.arena, row.key);
            try l.appendSlice(res.arena, ",\"value\":");
            try jsonw.writeValue(&l, res.arena, row.value);
            if (include_docs) {
                if (db.get(row.id)) |d| {
                    try l.appendSlice(res.arena, ",\"doc\":");
                    try writeDoc(db, &l, res.arena, d, d.winner, false, false, false);
                }
            }
            try l.append(res.arena, '}');
        }
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn queryJsonValue(alloc: std.mem.Allocator, s: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return null;
    return parsed.value;
}

/// Start offset of a `bytes=` range, or null when it is not one we can judge
/// (a suffix range, a multi-range, junk).
fn rangeStart(header: []const u8) ?u64 {
    const h = std.mem.trim(u8, header, " \t");
    if (!std.mem.startsWith(u8, h, "bytes=")) return null;
    const spec = h["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const first = spec[0..dash];
    if (first.len == 0) return null;
    return std.fmt.parseInt(u64, first, 10) catch null;
}

fn hAttGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    const att = try percentDecode(res.arena, req.params.get("att") orelse return err(res, 400, "bad_request", "missing attachment"));
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    // Held until the blob goes out: a plain attachment is streamed with the
    // database lock released but the handle still pinned.
    var locked = true;
    defer if (locked) app.releaseDb(db) else app.unpinDb(db);
    const doc = db.get(id) orelse return err(res, 404, "not_found", "missing");
    var li: usize = doc.winner;
    if (q(req, "rev")) |rs| {
        const r = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");
        li = doc.findLeaf(r) orelse return err(res, 404, "not_found", "missing");
    }
    const leaf = doc.leaves.items[li];
    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, leaf.body, .{}) catch
        return err(res, 404, "not_found", "missing");
    if (parsed.value != .object) return err(res, 404, "not_found", "missing");
    const atts = parsed.value.object.get("_attachments") orelse return err(res, 404, "not_found", "missing");
    if (atts != .object) return err(res, 404, "not_found", "missing");
    const entry = atts.object.get(att) orelse return err(res, 404, "not_found", "missing");
    if (entry != .object) return err(res, 404, "not_found", "missing");
    const ct_raw = if (entry.object.get("content_type")) |cv|
        (if (cv == .string) cv.string else "application/octet-stream")
    else
        "application/octet-stream";
    const ct = if (headerSafe(ct_raw)) ct_raw else "application/octet-stream";

    // A plain blob above this goes out straight from the file: reading it into
    // memory costs its own size again and `readBlob` caps a body at 64MB.
    const stream_from = 256 * 1024;
    const declared: u64 = if (entry.object.get("length")) |lv|
        (if (lv == .integer and lv.integer >= 0) @intCast(lv.integer) else 0)
    else
        0;
    const gzip_stored = if (entry.object.get("encoding")) |ev|
        (ev == .string and std.mem.eql(u8, ev.string, "gzip"))
    else
        false;
    // CouchDB ignores Range on an attachment and serves the whole body; the one
    // thing it refuses is a range that starts at or past the end (measured).
    if (req.header("range")) |rh| {
        if (rangeStart(rh)) |start| {
            if (declared > 0 and start >= declared) {
                return err(res, 416, "requested_range_not_satisfiable", "Requested range not satisfiable");
            }
        }
    }
    const blob_hex: ?[]const u8 = if (entry.object.get("blob")) |bv|
        (if (bv == .string) try res.arena.dupe(u8, bv.string) else null)
    else
        null;
    if (blob_hex) |hex| {
        if (!gzip_stored and entry.object.get("data") == null and declared >= stream_from) {
            if (db.openBlob(hex)) |file| {
                defer file.close(app.io);
                // The document's bytes are not needed any more, and holding the
                // database lock across a whole file would stall every request.
                db.unlock();
                locked = false;
                res.headers.add("content-type", ct);
                res.headers.add("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{declared}));
                sendBlob(app, res, file, declared) catch {};
                return;
            } else |_| {}
        }
    }

    const raw = (try attachmentRaw(db, res.arena, entry)) orelse
        return err(res, 404, "not_found", "missing");
    res.headers.add("content-type", ct);
    var body = raw;
    if (entry.object.get("encoding")) |ev| {
        if (ev == .string) {
            // CouchDB decodes compressed attachment storage unless the client asks for gzip.
            if (std.mem.eql(u8, ev.string, "gzip") and !acceptsGzip(req)) {
                body = gzipDecompress(res.arena, raw, app.max_body_bytes) catch |e| switch (e) {
                    error.TooLarge => return err(res, 413, "request_entity_too_large", "attachment too large"),
                    else => return err(res, 500, "internal_error", "invalid gzip attachment"),
                };
            } else if (headerSafe(ev.string)) {
                res.headers.add("content-encoding", ev.string);
            }
        }
    }
    res.body = body;
}

/// Write an already-opened blob to the connection in fixed-size pieces. The
/// header goes out here because a streamed body cannot go through `res.body`,
/// and the connection leaves httpz's hands afterwards.
fn setSocketTimeout(fd: std.posix.socket_t, opt: u32, secs: i64) void {
    if (@import("builtin").os.tag == .windows) return;
    const tv: std.posix.timeval = .{ .sec = secs, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, opt, std.mem.asBytes(&tv)) catch {};
}

fn sendBlob(app: *App, res: *httpz.Response, file: std.Io.File, len: u64) !void {
    const conn = res.conn;
    const stream = conn.stream;
    // A write this size must not fail halfway through on a non-blocking socket.
    try conn.blockingMode();
    setSocketTimeout(stream.socket.handle, std.posix.SO.SNDTIMEO, 30);
    try res.writeHeader();
    try res.disown();
    defer stream.close(app.io);
    // Stack safety note (§5.2 #15): ~100 KiB stack buffers; safe on 16 MiB HTTP
    // workers, never call from the 1 MiB feed scheduler thread.
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [32 * 1024]u8 = undefined;
    var reader = file.reader(app.io, &read_buf);
    var writer = stream.writer(app.io, &write_buf);
    var limit_buf: [4096]u8 = undefined;
    var limited = reader.interface.limited(.limited(@intCast(len)), &limit_buf);
    _ = limited.interface.streamRemaining(&writer.interface) catch return;
    writer.interface.flush() catch return;
}

fn acceptsGzip(req: *httpz.Request) bool {
    const value = req.header("accept-encoding") orelse return false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(token, "gzip") or std.ascii.eqlIgnoreCase(token, "*")) return true;
    }
    return false;
}

fn gzipDecodedReaderLen(reader: *std.Io.Reader, max_bytes: usize) !usize {
    var win_buf: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(reader, .gzip, &win_buf);
    var d_buf: [4096]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&d_buf);
    var l_buf: [4096]u8 = undefined;
    var limited = decompress.reader.limited(.limited(max_bytes), &l_buf);
    _ = limited.interface.streamRemaining(&discarding.writer) catch return error.BadGzip;
    if (discarding.fullCount() == max_bytes) {
        if (decompress.reader.peekByte()) |_| return error.TooLarge else |e| switch (e) {
            error.EndOfStream => {},
            error.ReadFailed => return error.BadGzip,
        }
    }
    return @intCast(discarding.fullCount());
}

fn gzipDecompress(alloc: std.mem.Allocator, data: []const u8, max_bytes: usize) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var decompress: flate.Decompress = .init(&in, .gzip, &.{});
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var l_buf: [4096]u8 = undefined;
    var limited = decompress.reader.limited(.limited(max_bytes), &l_buf);
    _ = try limited.interface.streamRemaining(&aw.writer);
    if (aw.writer.end == max_bytes) {
        if (decompress.reader.peekByte()) |_| return error.TooLarge else |e| switch (e) {
            error.EndOfStream => {},
            error.ReadFailed => return error.BadGzip,
        }
    }
    return aw.toOwnedSlice();
}

fn hAttPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    const att = try percentDecode(res.arena, req.params.get("att") orelse return err(res, 400, "bad_request", "missing attachment"));
    const rs = q(req, "rev") orelse return err(res, 409, "conflict", "Document update conflict.");
    const rev = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");
    const ct = req.header("content-type") orelse "application/octet-stream";
    const ce_raw = req.header("content-encoding");
    const is_gzip = if (ce_raw) |ce| std.ascii.eqlIgnoreCase(std.mem.trim(u8, ce, " \t"), "gzip") else false;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const existing = db.get(id) orelse return err(res, 404, "not_found", "missing");
    _ = existing.findLeaf(rev) orelse return err(res, 409, "conflict", "Document update conflict.");
    var body_reader = req.reader(30_000) catch return err(res, 400, "bad_request", "cannot read attachment body");
    const upload = db.writeBlobStream(&body_reader.interface, app.max_body_bytes) catch |e| switch (e) {
        error.TooLarge => return err(res, 413, "request_entity_too_large", "attachment too large"),
        else => return e,
    };

    const current_db = db;
    const doc = current_db.get(id) orelse return err(res, 404, "not_found", "missing");
    const pi = doc.findLeaf(rev) orelse return err(res, 409, "conflict", "Document update conflict.");

    const parent = std.json.parseFromSlice(std.json.Value, res.arena, doc.leaves.items[pi].body, .{}) catch
        std.json.parseFromSlice(std.json.Value, res.arena, "{}", .{}) catch unreachable;
    var root_val = parent.value;
    if (root_val != .object) root_val = (try std.json.parseFromSlice(std.json.Value, res.arena, "{}", .{})).value;

    var atts: std.json.ObjectMap = .empty;
    if (root_val.object.get("_attachments")) |old| {
        if (old == .object) {
            for (old.object.keys(), old.object.values()) |k, v| try atts.put(res.arena, k, v);
        }
    }
    var digest_buf: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&digest_buf, &upload.digest);
    const hex = try res.arena.dupe(u8, &upload.hex);
    const digest = try res.arena.dupe(u8, &digest_buf);
    var one: std.json.ObjectMap = .empty;
    try one.put(res.arena, "content_type", .{ .string = ct });
    try one.put(res.arena, "revpos", .{ .integer = @as(i64, rev.gen) + 1 });
    if (is_gzip) {
        const bf = try current_db.openBlob(&upload.hex);
        defer bf.close(app.io);
        var b_buf: [8192]u8 = undefined;
        var br = bf.reader(app.io, &b_buf);
        const decoded_len = gzipDecodedReaderLen(&br.interface, app.max_body_bytes) catch |e| switch (e) {
            error.TooLarge => return err(res, 413, "request_entity_too_large", "attachment too large"),
            error.BadGzip => return err(res, 400, "bad_request", "invalid gzip attachment"),
        };
        try one.put(res.arena, "encoding", .{ .string = "gzip" });
        try one.put(res.arena, "encoded_length", .{ .integer = @intCast(upload.len) });
        try one.put(res.arena, "length", .{ .integer = @intCast(decoded_len) });
    } else {
        try one.put(res.arena, "length", .{ .integer = @intCast(upload.len) });
    }
    try one.put(res.arena, "digest", .{ .string = try std.fmt.allocPrint(res.arena, "md5-{s}", .{digest}) });
    try one.put(res.arena, "blob", .{ .string = hex });
    try one.put(res.arena, "stub", .{ .bool = true });
    try atts.put(res.arena, att, .{ .object = one });
    try root_val.object.put(res.arena, "_attachments", .{ .object = atts });

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, res.arena, root_val);
    if (try validateDoc(current_db, res.arena, id, null, out.items, false)) |rej| return sendValidateRejection(res, rej);
    const result = current_db.putLocal(id, out.items, rev, false) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };
    var rb: [64]u8 = undefined;
    try okIdRev(res, id, result.rev.write(&rb));
}

fn hAttDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    const att = try percentDecode(res.arena, req.params.get("att") orelse return err(res, 400, "bad_request", "missing attachment"));
    const rs = q(req, "rev") orelse return err(res, 409, "conflict", "Document update conflict.");
    const rev = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const doc = db.get(id) orelse return err(res, 404, "not_found", "missing");
    const pi = doc.findLeaf(rev) orelse return err(res, 409, "conflict", "Document update conflict.");
    const parent = std.json.parseFromSlice(std.json.Value, res.arena, doc.leaves.items[pi].body, .{}) catch
        return err(res, 404, "not_found", "missing");
    var root_val = parent.value;
    if (root_val != .object) return err(res, 404, "not_found", "missing");
    if (root_val.object.getPtr("_attachments")) |attp| {
        if (attp.* == .object) _ = attp.object.swapRemove(att);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, res.arena, root_val);
    if (try validateDoc(db, res.arena, id, null, out.items, false)) |rej| return sendValidateRejection(res, rej);
    const result = db.putLocal(id, out.items, rev, false) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };
    res.status = 200;
    res.content_type = .JSON;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    var rb: [64]u8 = undefined;
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, result.rev.write(&rb));
    try l.append(res.arena, '}');
    res.body = l.items;
}

fn hDocGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    return docGetById(app, req, res, name, id);
}

fn etagMatches(if_none_match: ?[]const u8, etag: []const u8) bool {
    const hdr = if_none_match orelse return false;
    var it = std.mem.splitScalar(u8, hdr, ',');
    while (it.next()) |raw| {
        var part = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, part, "W/")) part = part[2..];
        if (std.mem.eql(u8, part, "*") or std.mem.eql(u8, part, etag)) return true;
    }
    return false;
}

fn docGetById(app: *App, req: *httpz.Request, res: *httpz.Response, name: []const u8, id: []const u8) !void {
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const doc = db.get(id) orelse return err(res, 404, "not_found", "missing");

    const revs = if (q(req, "revs")) |v| std.mem.eql(u8, v, "true") else false;
    const conflicts = if (q(req, "conflicts")) |v| std.mem.eql(u8, v, "true") else false;

    if (q(req, "open_revs")) |orv| {
        const inline_atts = if (q(req, "attachments")) |v| std.mem.eql(u8, v, "true") else false;
        if (std.mem.eql(u8, orv, "all")) {
            var l: std.ArrayListUnmanaged(u8) = .empty;
            try l.append(res.arena, '[');
            for (doc.leaves.items, 0..) |_, i| {
                if (i != 0) try l.append(res.arena, ',');
                try l.appendSlice(res.arena, "{\"ok\":");
                try writeDoc(db, &l, res.arena, doc, i, revs, conflicts, inline_atts);
                try l.append(res.arena, '}');
            }
            try l.append(res.arena, ']');
            res.content_type = .JSON;
            res.body = l.items;
            return;
        }
        if (orv.len > 0 and orv[0] == '[') {
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, orv, .{}) catch
                return err(res, 400, "bad_request", "invalid open_revs");
            const accept = req.header("accept") orelse "";
            const multipart = std.mem.indexOf(u8, accept, "multipart/mixed") != null;
            var boundary_rnd: [8]u8 = undefined;
            app.io.random(&boundary_rnd);
            const boundary = try std.fmt.allocPrint(res.arena, "zouchboundary-{s}", .{std.fmt.bytesToHex(boundary_rnd, .lower)});
            var l: std.ArrayListUnmanaged(u8) = .empty;
            if (!multipart) try l.append(res.arena, '[');
            var part: usize = 0;
            for (parsed.value.array.items) |rv| {
                if (rv != .string) continue;
                const r = Rev.parse(rv.string) catch continue;
                var idx: usize = undefined;
                if (doc.findLeaf(r)) |found| {
                    idx = found;
                } else if (q(req, "latest") != null and std.mem.eql(u8, q(req, "latest").?, "true") and doc.findDescendantOf(r) != null) {
                    idx = doc.findDescendantOf(r).?;
                } else {
                    if (multipart) {
                        try l.appendSlice(res.arena, "--");
                        try l.appendSlice(res.arena, boundary);
                        try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n");
                        try l.appendSlice(res.arena, "{\"missing\":");
                        try jsonw.writeString(&l, res.arena, rv.string);
                        try l.appendSlice(res.arena, "}\r\n");
                        part += 1;
                    } else {
                        if (part != 0) try l.append(res.arena, ',');
                        part += 1;
                        try l.appendSlice(res.arena, "{\"missing\":");
                        try jsonw.writeString(&l, res.arena, rv.string);
                        try l.append(res.arena, '}');
                    }
                    continue;
                }
                if (multipart) {
                    try l.appendSlice(res.arena, "--");
                    try l.appendSlice(res.arena, boundary);
                    try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n");
                    try writeDoc(db, &l, res.arena, doc, idx, revs, conflicts, true);
                    try l.appendSlice(res.arena, "\r\n");
                    part += 1;
                } else {
                    if (part != 0) try l.append(res.arena, ',');
                    part += 1;
                    try l.appendSlice(res.arena, "{\"ok\":");
                    try writeDoc(db, &l, res.arena, doc, idx, revs, conflicts, inline_atts);
                    try l.append(res.arena, '}');
                }
            }
            if (multipart) {
                try l.appendSlice(res.arena, "--");
                try l.appendSlice(res.arena, boundary);
                try l.appendSlice(res.arena, "--\r\n");
                const ct = try std.fmt.allocPrint(res.arena, "multipart/mixed; boundary={s}", .{boundary});
                res.headers.add("content-type", ct);
                res.body = l.items;
                return;
            }
            try l.append(res.arena, ']');
            res.content_type = .JSON;
            res.body = l.items;
            return;
        }
    }

    const inline_atts = if (q(req, "attachments")) |v| std.mem.eql(u8, v, "true") else false;
    var leaf_idx: usize = doc.winner;
    if (q(req, "rev")) |rs| {
        const r = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");
        if (doc.findLeaf(r)) |idx| {
            leaf_idx = idx;
        } else if (doc.bodyFor(r)) |stored| {
            var rb: [64]u8 = undefined;
            const etag = try std.fmt.allocPrint(res.arena, "\"{s}\"", .{r.write(&rb)});
            res.headers.add("etag", etag);
            res.headers.add("cache-control", "must-revalidate");
            if (etagMatches(req.header("if-none-match"), etag)) {
                res.status = 304;
                res.body = "";
                return;
            }
            // A revision that stopped being a leaf. CouchDB keeps serving its
            // cleaned body until compaction, and so does this store.
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try writeRetainedDoc(db, res.arena, &out, doc, r, stored.body, stored.deleted, revs, inline_atts);
            res.content_type = .JSON;
            res.body = out.items;
            return;
        } else return err(res, 404, "not_found", "missing");
    } else if (doc.winnerLeaf().deleted) {
        return err(res, 404, "not_found", "deleted");
    }

    var etag_rb: [64]u8 = undefined;
    const etag = try std.fmt.allocPrint(res.arena, "\"{s}\"", .{doc.leaves.items[leaf_idx].rev.write(&etag_rb)});
    res.headers.add("etag", etag);
    res.headers.add("cache-control", "must-revalidate");
    if (etagMatches(req.header("if-none-match"), etag)) {
        res.status = 304;
        res.body = "";
        return;
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try writeDoc(db, &l, res.arena, doc, leaf_idx, revs, conflicts, inline_atts);
    if (q(req, "revs_info")) |v| {
        if (std.mem.eql(u8, v, "true")) {
            // writeDoc has just emitted one complete object, so the array goes in
            // before its closing brace. Only leaves are stored, so the leaf is
            // `available` and its ancestors are `missing` - which is what CouchDB
            // says about revisions it has no body for.
            l.items.len -= 1;
            try l.appendSlice(res.arena, ",\"_revs_info\":[");
            var rb: [64]u8 = undefined;
            try l.appendSlice(res.arena, "{\"rev\":");
            try jsonw.writeString(&l, res.arena, doc.leaves.items[leaf_idx].rev.write(&rb));
            try l.appendSlice(res.arena, ",\"status\":\"available\"}");
            // `ancestry[0]` is the leaf's own revision, as `_revisions` shows, so
            // the ancestors start after it.
            const ancestors = if (doc.leaves.items[leaf_idx].ancestry.len > 1)
                doc.leaves.items[leaf_idx].ancestry[1..]
            else
                &[_]Rev{};
            for (ancestors) |anc| {
                try l.appendSlice(res.arena, ",{\"rev\":");
                var ab: [64]u8 = undefined;
                try jsonw.writeString(&l, res.arena, anc.write(&ab));
                // Available when the body is still held - a leaf, or an older
                // revision not yet dropped by compaction.
                const status: []const u8 = if (doc.bodyFor(anc) != null) "available" else "missing";
                try l.appendSlice(res.arena, ",\"status\":");
                try jsonw.writeString(&l, res.arena, status);
                try l.append(res.arena, '}');
            }
            try l.appendSlice(res.arena, "]}");
        }
    }
    res.content_type = .JSON;
    res.body = l.items;
}

fn prepareAttachments(
    res: *httpz.Response,
    root: *std.json.Value,
    parent: ?*const Leaf,
    max_bytes: usize,
) ![]u8 {
    const atts_ptr = root.object.getPtr("_attachments") orelse return error.MissingStub;
    if (atts_ptr.* != .object) return error.MissingStub;

    var parent_atts: ?std.json.Value = null;
    if (parent) |pl| {
        const pv = std.json.parseFromSlice(std.json.Value, res.arena, pl.body, .{}) catch null;
        if (pv) |p| {
            if (p.value == .object) parent_atts = p.value.object.get("_attachments");
        }
    }

    var out: std.json.ObjectMap = .empty;
    for (atts_ptr.object.keys(), atts_ptr.object.values()) |name, av| {
        if (av != .object) return error.MissingStub;
        var one: std.json.ObjectMap = .empty;
        const data_v = av.object.get("data");
        const stub = if (av.object.get("stub")) |sv| (sv == .bool and sv.bool) else false;
        if (stub or data_v == null) {
            if (parent_atts == null or parent_atts.? != .object) return error.MissingStub;
            const pa = parent_atts.?.object.get(name) orelse return error.MissingStub;
            if (pa != .object) return error.MissingStub;
            var parent_data = false;
            if (pa.object.get("data")) |pd| {
                if (pd == .string) {
                    try one.put(res.arena, "data", pd);
                    parent_data = true;
                }
            }
            if (!parent_data) {
                if (pa.object.get("blob")) |pb| {
                    if (pb != .string) return error.MissingStub;
                    try one.put(res.arena, "blob", pb);
                    for ([_][]const u8{ "length", "digest", "encoding", "encoded_length" }) |key| {
                        if (pa.object.get(key)) |mv| try one.put(res.arena, key, mv);
                    }
                } else return error.MissingStub;
            }
            const pc: std.json.Value = pa.object.get("content_type") orelse .{ .string = "application/octet-stream" };
            try one.put(res.arena, "content_type", pc);
            try one.put(res.arena, "revpos", .{ .integer = parent.?.rev.gen });
        } else {
            try one.put(res.arena, "data", data_v.?);
            const ct: std.json.Value = av.object.get("content_type") orelse .{ .string = "application/octet-stream" };
            try one.put(res.arena, "content_type", ct);
            const gen: i64 = if (parent) |pl| @as(i64, pl.rev.gen) + 1 else 1;
            try one.put(res.arena, "revpos", .{ .integer = gen });
            if (av.object.get("encoding")) |ev| {
                if (ev == .string) {
                    try one.put(res.arena, "encoding", ev);
                    if (data_v.? == .string) {
                        const raw_len = std.base64.standard.Decoder.calcSizeForSlice(data_v.?.string) catch 0;
                        const raw = try res.arena.alloc(u8, raw_len);
                        if (std.base64.standard.Decoder.decode(raw, data_v.?.string)) |_| {
                            try one.put(res.arena, "encoded_length", .{ .integer = @intCast(raw.len) });
                            if (av.object.get("length")) |lv| {
                                if (lv == .integer and lv.integer >= 0) {
                                    try one.put(res.arena, "length", lv);
                                }
                            } else if (std.mem.eql(u8, ev.string, "gzip")) {
                                var r_in: std.Io.Reader = .fixed(raw);
                                const decoded_len = try gzipDecodedReaderLen(&r_in, max_bytes);
                                try one.put(res.arena, "length", .{ .integer = @intCast(decoded_len) });
                            }
                        } else |_| {}
                    }
                }
            }
        }
        try out.put(res.arena, name, .{ .object = one });
    }
    try root.object.put(res.arena, "_attachments", .{ .object = out });
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&l, res.arena, root.*);
    return l.items;
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

const MimePart = struct {
    headers: []const u8,
    data: []const u8,
};

fn multipartBoundary(content_type: []const u8) ?[]const u8 {
    const bpos = std.mem.indexOf(u8, content_type, "boundary=") orelse return null;
    var boundary = std.mem.trim(u8, content_type[bpos + 9 ..], " \t\r\n");
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| boundary = boundary[0..semi];
    boundary = std.mem.trim(u8, boundary, " \t\r\n");
    if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
        boundary = boundary[1 .. boundary.len - 1];
    }
    return if (boundary.len == 0) null else boundary;
}

/// Split a MIME multipart body into its parts. This is intentionally a small
/// parser: Zouch only accepts multipart bodies from CouchDB-family clients,
/// but it must preserve attachment bytes and nested multipart documents.
fn collectMultipartParts(
    alloc: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
    out: *std.ArrayListUnmanaged(MimePart),
) !void {
    const boundary = multipartBoundary(content_type) orelse return error.BadMultipart;
    const delim = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    defer alloc.free(delim);

    var pos: usize = 0;
    var found = false;
    while (std.mem.indexOfPos(u8, body, pos, delim)) |d| {
        var start = d + delim.len;
        if (start + 2 <= body.len and std.mem.eql(u8, body[start .. start + 2], "--")) break;
        if (start + 2 <= body.len and std.mem.eql(u8, body[start .. start + 2], "\r\n")) {
            start += 2;
        } else if (start < body.len and body[start] == '\n') {
            start += 1;
        } else {
            pos = start;
            continue;
        }
        const next = std.mem.indexOfPos(u8, body, start, delim) orelse break;
        var end = next;
        if (end >= 2 and std.mem.eql(u8, body[end - 2 .. end], "\r\n")) end -= 2;
        const part = body[start..end];
        const hdr_end = std.mem.indexOf(u8, part, "\r\n\r\n") orelse {
            pos = next;
            continue;
        };
        try out.append(alloc, .{ .headers = part[0..hdr_end], .data = part[hdr_end + 4 ..] });
        found = true;
        pos = next;
    }
    if (!found) return error.BadMultipart;
}

fn multipartFilename(headers: []const u8) ?[]const u8 {
    const cd = headerValue(headers, "content-disposition") orelse return null;
    const fi = std.mem.indexOf(u8, cd, "filename=") orelse return null;
    var rest = std.mem.trim(u8, cd[fi + 9 ..], " \t");
    if (rest.len > 0 and rest[0] == '"') {
        rest = rest[1..];
        const quote = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        return rest[0..quote];
    }
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    return std.mem.trim(u8, rest[0..semi], " \t");
}

fn multipartDocumentJson(alloc: std.mem.Allocator, part: MimePart) ![]const u8 {
    const ctype = headerValue(part.headers, "content-type") orelse "application/json";
    if (!std.mem.startsWith(u8, ctype, "multipart/")) return part.data;

    var inner: std.ArrayListUnmanaged(MimePart) = .empty;
    defer inner.deinit(alloc);
    try collectMultipartParts(alloc, ctype, part.data, &inner);
    const json_part = inner.items[0];
    var root = (std.json.parseFromSlice(std.json.Value, alloc, json_part.data, .{}) catch return error.BadMultipart).value;
    if (root != .object) return error.BadMultipart;

    // Start from the JSON part's attachment map. A multipart update may carry
    // stubs for attachments that were not re-sent; replacing the whole map
    // would silently drop those blobs on the next GC.
    var atts: std.json.ObjectMap = if (root.object.get("_attachments")) |orig|
        (if (orig == .object) orig.object else .empty)
    else
        .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    for (inner.items[1..]) |ap| {
        const name = multipartFilename(ap.headers) orelse continue;
        try seen.put(alloc, name, {});
        const enc_len = std.base64.standard.Encoder.calcSize(ap.data.len);
        const b64 = try alloc.alloc(u8, enc_len);
        _ = std.base64.standard.Encoder.encode(b64, ap.data);
        var one: std.json.ObjectMap = .empty;
        const pct = headerValue(ap.headers, "content-type") orelse "application/octet-stream";
        try one.put(alloc, "content_type", .{ .string = pct });
        try one.put(alloc, "data", .{ .string = b64 });
        if (headerValue(ap.headers, "content-encoding")) |enc| {
            try one.put(alloc, "encoding", .{ .string = enc });
        }
        if (root.object.get("_attachments")) |orig| {
            if (orig == .object) {
                if (orig.object.get(name)) |oe| {
                    if (oe == .object) {
                        for ([_][]const u8{ "length", "digest", "revpos" }) |key| {
                            if (one.get(key) == null) {
                                if (oe.object.get(key)) |v| try one.put(alloc, key, v);
                            }
                        }
                    }
                }
            }
        }
        try atts.put(alloc, name, .{ .object = one });
    }
    // A follows:true entry with no corresponding MIME part is malformed;
    // leaving it in the stored body would make an attachment disappear on the
    // next read. Drop only those dangling entries; preserved stubs stay.
    var remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer remove.deinit(alloc);
    for (atts.keys(), atts.values()) |name, av| {
        if (seen.contains(name)) continue;
        if (av != .object) continue;
        if (av.object.get("follows")) |fv| {
            if (fv == .bool and fv.bool) try remove.append(alloc, name);
        }
    }
    for (remove.items) |name| _ = atts.swapRemove(name);
    try root.object.put(alloc, "_attachments", .{ .object = atts });
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, alloc, root);
    return out.items;
}

fn parseMultipartRelated(
    alloc: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    const bpos = std.mem.indexOf(u8, content_type, "boundary=") orelse return error.BadMultipart;
    var boundary = std.mem.trim(u8, content_type[bpos + 9 ..], " \t\r\n");
    if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
        boundary = boundary[1 .. boundary.len - 1];
    }
    if (boundary.len == 0) return error.BadMultipart;

    const delim = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    defer alloc.free(delim);

    var json_part: ?[]const u8 = null;
    var atts: std.json.ObjectMap = .empty;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, delim)) |d| {
        var start = d + delim.len;
        if (start + 2 <= body.len and std.mem.eql(u8, body[start .. start + 2], "--")) break;
        if (start + 2 <= body.len and std.mem.eql(u8, body[start .. start + 2], "\r\n")) start += 2;
        const next = std.mem.indexOfPos(u8, body, start, delim) orelse break;
        var end = next;
        if (end >= 2 and std.mem.eql(u8, body[end - 2 .. end], "\r\n")) end -= 2;
        const part = body[start..end];
        const hdr_end = std.mem.indexOf(u8, part, "\r\n\r\n") orelse {
            pos = next;
            continue;
        };
        const headers = part[0..hdr_end];
        const data = part[hdr_end + 4 ..];

        if (json_part == null) {
            json_part = data;
        } else {
            const cd = headerValue(headers, "content-disposition") orelse "";
            var filename: ?[]const u8 = null;
            if (std.mem.indexOf(u8, cd, "filename=\"")) |fi| {
                const rest = cd[fi + 10 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |quote| filename = rest[0..quote];
            } else if (std.mem.indexOf(u8, cd, "filename=")) |fi| {
                const rest = cd[fi + 9 ..];
                const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                filename = std.mem.trim(u8, rest[0..semi], " \t");
            }
            if (filename) |name| {
                const enc_len = std.base64.standard.Encoder.calcSize(data.len);
                const b64 = try alloc.alloc(u8, enc_len);
                _ = std.base64.standard.Encoder.encode(b64, data);
                var one: std.json.ObjectMap = .empty;
                const pct = headerValue(headers, "content-type") orelse "application/octet-stream";
                try one.put(alloc, "content_type", .{ .string = pct });
                try one.put(alloc, "data", .{ .string = b64 });
                if (headerValue(headers, "content-encoding")) |enc| {
                    try one.put(alloc, "encoding", .{ .string = enc });
                }
                try atts.put(alloc, name, .{ .object = one });
            }
        }
        pos = next;
    }

    const jp = json_part orelse return error.BadMultipart;
    var root = (try std.json.parseFromSlice(std.json.Value, alloc, jp, .{})).value;
    if (root != .object) return error.BadMultipart;
    // Keep the source's original length and digest metadata. CouchDB sends the
    // attachment bytes gzip-encoded on the wire, but the JSON part still carries
    // the decoded length; replacing the map wholesale would turn length into the
    // encoded byte count.
    if (root.object.get("_attachments")) |orig| {
        if (orig == .object) {
            for (atts.keys(), atts.values()) |name, av| {
                if (av != .object) continue;
                const oe = orig.object.get(name) orelse continue;
                if (oe != .object) continue;
                const one = atts.getPtr(name) orelse continue;
                const keys = [_][]const u8{ "length", "digest", "revpos" };
                for (keys) |key| {
                    if (one.object.get(key) == null) {
                        if (oe.object.get(key)) |v| try one.object.put(alloc, key, v);
                    }
                }
            }
        }
    }
    try root.object.put(alloc, "_attachments", .{ .object = atts });
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, alloc, root);
    return out.items;
}

fn isDbAdminFor(db: *const Db, auth: RequestAuth) bool {
    if (!db.securityRestricted() or !auth.users_present) return true;
    return auth.admin or db.securityAdmin(auth.user, auth.roles);
}

fn buildQueryJson(alloc: std.mem.Allocator, req: *httpz.Request) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    const qs = req.query() catch {
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    };
    for (0..qs.len) |i| {
        if (i != 0) try out.append(alloc, ',');
        try jsonw.writeString(&out, alloc, qs.keys[i]);
        try out.append(alloc, ':');
        try jsonw.writeString(&out, alloc, qs.values[i]);
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

fn appendCleanAttStub(
    db: *Db,
    clean: *std.json.ObjectMap,
    aa: std.mem.Allocator,
    att_name: []const u8,
    av: std.json.Value,
    default_revpos: u32,
) !void {
    if (av != .object) return;
    var stub: std.json.ObjectMap = .empty;
    const ct = if (av.object.get("content_type")) |cv| (if (cv == .string) cv.string else "application/octet-stream") else "application/octet-stream";
    try stub.put(aa, "content_type", .{ .string = ct });
    const revpos: u32 = if (av.object.get("revpos")) |rv|
        (if (rv == .integer and rv.integer > 0) (std.math.cast(u32, rv.integer) orelse default_revpos) else default_revpos)
    else
        default_revpos;
    try stub.put(aa, "revpos", .{ .integer = revpos });

    if (av.object.get("digest")) |dv| {
        if (dv == .string) try stub.put(aa, "digest", dv);
    }
    if (av.object.get("length")) |lv| {
        if (lv == .integer) try stub.put(aa, "length", lv);
    }
    if (stub.get("digest") == null or stub.get("length") == null) {
        if (try attachmentRaw(db, aa, av)) |raw| {
            if (stub.get("digest") == null) {
                var digest: [16]u8 = undefined;
                std.crypto.hash.Md5.hash(raw, &digest, .{});
                var dbuf: [24]u8 = undefined;
                _ = std.base64.standard.Encoder.encode(&dbuf, &digest);
                try stub.put(aa, "digest", .{ .string = try std.fmt.allocPrint(aa, "md5-{s}", .{dbuf}) });
            }
            if (stub.get("length") == null) {
                try stub.put(aa, "length", .{ .integer = @intCast(raw.len) });
            }
        }
    }
    if (av.object.get("encoding")) |ev| {
        if (ev == .string) {
            try stub.put(aa, "encoding", ev);
            if (av.object.get("encoded_length")) |elv| {
                if (elv == .integer) try stub.put(aa, "encoded_length", elv);
            }
        }
    }
    try stub.put(aa, "stub", .{ .bool = true });
    try clean.put(aa, att_name, .{ .object = stub });
}

/// Build the clean document JSON object exposed to JS (map, filter, validate_doc_update):
/// includes `_id`, `_rev`, `_deleted` (if true), user fields, and clean `_attachments` stubs.
fn buildJsDoc(
    db: *Db,
    alloc: std.mem.Allocator,
    doc_id: []const u8,
    rev: ?Rev,
    body: []const u8,
    deleted: bool,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var root: std.json.Value = if (std.json.parseFromSlice(std.json.Value, aa, body, .{})) |p|
        (if (p.value == .object) p.value else .{ .object = .empty })
    else |_|
        .{ .object = .empty };

    try root.object.put(aa, "_id", .{ .string = doc_id });
    if (rev) |r| {
        var rbuf: [64]u8 = undefined;
        try root.object.put(aa, "_rev", .{ .string = try aa.dupe(u8, r.write(&rbuf)) });
    }
    if (deleted) {
        try root.object.put(aa, "_deleted", .{ .bool = true });
    }
    if (root.object.get("_attachments")) |atts| {
        if (atts == .object) {
            var clean: std.json.ObjectMap = .empty;
            const gen: u32 = if (rev) |r| r.gen else 1;
            for (atts.object.keys(), atts.object.values()) |att_name, av| {
                try appendCleanAttStub(db, &clean, aa, att_name, av, gen);
            }
            if (clean.count() > 0) {
                try root.object.put(aa, "_attachments", .{ .object = clean });
            } else {
                _ = root.object.orderedRemove("_attachments");
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try jsonw.writeValue(&out, alloc, root);
    return out.toOwnedSlice(alloc);
}

const ValidateRejection = struct {
    status: u16,
    code: []const u8,
    reason: []const u8,
};

fn sendValidateRejection(res: *httpz.Response, rej: ValidateRejection) !void {
    return err(res, rej.status, rej.code, rej.reason);
}

/// Evaluate every design document's validate_doc_update.
/// Returns a rejection descriptor (401/403), or null when the write is allowed.
fn validateDoc(
    db: *Db,
    alloc: std.mem.Allocator,
    id: []const u8,
    new_rev: ?Rev,
    new_body: []const u8,
    new_deleted: bool,
) !?ValidateRejection {
    if (std.mem.startsWith(u8, id, "_design/")) return null;

    var found = false;
    var code: std.ArrayListUnmanaged(u8) = .empty;
    defer code.deinit(alloc);

    var it = db.designs.keyIterator();
    while (it.next()) |did_ptr| {
        const did = did_ptr.*;
        const ddoc = db.get(did) orelse continue;
        const leaf = ddoc.leaves.items[ddoc.winner];
        if (leaf.deleted) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, leaf.body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const fn_v = parsed.value.object.get("validate_doc_update") orelse continue;
        if (fn_v != .string) continue;
        if (!found) {
            try code.appendSlice(alloc, "(function(){var fns=[");
            found = true;
        } else {
            try code.append(alloc, ',');
        }
        try code.appendSlice(alloc, fn_v.string);
    }
    if (!found) return null;

    const nd_json = try buildJsDoc(db, alloc, id, new_rev, new_body, new_deleted);
    defer alloc.free(nd_json);
    const od_json: ?[]u8 = if (db.get(id)) |old_doc| blk: {
        const old_leaf = old_doc.winnerLeaf();
        break :blk try buildJsDoc(db, alloc, id, old_leaf.rev, old_leaf.body, old_leaf.deleted);
    } else null;
    defer if (od_json) |o| alloc.free(o);
    const sec_json = db.readSecurity(alloc) catch try alloc.dupe(u8, "{}");
    defer alloc.free(sec_json);

    try code.appendSlice(alloc, "];var nd=");
    try code.appendSlice(alloc, nd_json);
    try code.appendSlice(alloc, ";var od=");
    if (od_json) |ob| try code.appendSlice(alloc, ob) else try code.appendSlice(alloc, "null");
    try code.appendSlice(alloc, ";var uc={name:");
    if (validate_user.len > 0) {
        try jsonw.writeString(&code, alloc, validate_user);
    } else {
        try code.appendSlice(alloc, "null");
    }
    try code.appendSlice(alloc, ",roles:[");
    var role_it = std.mem.splitScalar(u8, validate_roles, ',');
    var first_role = true;
    if (validate_admin and !hasCsvRole(validate_roles, "_admin")) {
        try jsonw.writeString(&code, alloc, "_admin");
        first_role = false;
    }
    while (role_it.next()) |role| {
        if (role.len == 0) continue;
        if (!first_role) try code.append(alloc, ',');
        first_role = false;
        try jsonw.writeString(&code, alloc, role);
    }
    try code.appendSlice(alloc, "]};var sec=");
    try code.appendSlice(alloc, sec_json);
    try code.appendSlice(alloc, ";for(var i=0;i<fns.length;i++){try{fns[i](nd,od,uc,sec);}catch(e){if(e&&e.unauthorized!==undefined)return JSON.stringify({ok:false,unauth:true,reason:String(e.unauthorized)});return JSON.stringify({ok:false,reason:String(e.forbidden||e.message||e)});}}return JSON.stringify({ok:true});})()");

    var eng = qjs.Engine.init() catch return .{ .status = 403, .code = "forbidden", .reason = "validation engine unavailable" };
    defer eng.deinit();
    const out = eng.eval(alloc, code.items) catch return .{ .status = 403, .code = "forbidden", .reason = "validation function failed" };
    defer alloc.free(out);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return .{ .status = 403, .code = "forbidden", .reason = "validation function returned invalid output" };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .status = 403, .code = "forbidden", .reason = "validation function returned invalid output" };
    const ok_v = parsed.value.object.get("ok") orelse return .{ .status = 403, .code = "forbidden", .reason = "validation function returned invalid output" };
    if (ok_v == .bool and ok_v.bool) return null;
    const is_unauth = if (parsed.value.object.get("unauth")) |uv| (uv == .bool and uv.bool) else false;
    const reason_v = parsed.value.object.get("reason");
    const reason_copy = if (reason_v != null and reason_v.? == .string)
        try alloc.dupe(u8, reason_v.?.string)
    else if (is_unauth)
        "unauthorized"
    else
        "forbidden";
    return .{
        .status = if (is_unauth) 401 else 403,
        .code = if (is_unauth) "unauthorized" else "forbidden",
        .reason = reason_copy,
    };
}

const ParsedSource = struct { url: []const u8, user: ?[]const u8, password: ?[]const u8 };

fn parseSourceUrl(raw: []const u8) ParsedSource {
    const scheme = std.mem.indexOf(u8, raw, "://") orelse return .{ .url = raw, .user = null, .password = null };
    const rest = raw[scheme + 3 ..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return .{ .url = raw, .user = null, .password = null };
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (at >= slash) return .{ .url = raw, .user = null, .password = null };
    const userinfo = rest[0..at];
    const colon = std.mem.indexOfScalar(u8, userinfo, ':') orelse return .{ .url = raw, .user = null, .password = null };
    return .{ .url = raw, .user = userinfo[0..colon], .password = userinfo[colon + 1 ..] };
}

/// Every database has its own mutex (`Db.mutex`), taken by every thread that
/// touches that database's state. A replication passes this pair down so it can
/// drop the lock while it waits on the network and take it back for each
/// touch of the database it writes (or, for a push, reads): otherwise one pull
/// of a large database freezes every other request on it for the whole copy.
/// The context is the `*Db`. The database is pinned by the caller for the
/// length of the transfer, so the handle cannot be freed while the lock is
/// released. Lock order: `feed_mutex`, then `app.mutex` or `db.mutex`;
/// `app.mutex` is never held while waiting for a `db.mutex`, and a thread
/// holds at most one `db.mutex` at a time.
const ReplLock = struct {
    fn lockFn(ctx: ?*anyopaque) void {
        const db: *Db = @ptrCast(@alignCast(ctx.?));
        db.lock();
    }

    fn unlockFn(ctx: ?*anyopaque) void {
        const db: *Db = @ptrCast(@alignCast(ctx.?));
        db.unlock();
    }
};

/// A sequence is a number when the source counts sequentially, and an opaque
/// string for sources like CouchDB that encode cluster state in it. Emit what
/// the source gave, in the shape it would accept back.
fn appendSeqValue(l: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, seq: ?[]const u8) !void {
    const text = seq orelse {
        try l.appendSlice(alloc, "0");
        return;
    };
    if (std.fmt.parseInt(u64, text, 10)) |_| {
        try l.appendSlice(alloc, text);
    } else |_| {
        try jsonw.writeString(l, alloc, text);
    }
}

/// The fields CouchDB puts in a `_replicate` answer: a session, the sequence it
/// got to, and one history entry with the counters for this run.
fn appendReplicationHistory(
    l: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    session_id: []const u8,
    docs_read: usize,
    docs_written: usize,
    doc_write_failures: usize,
    missing_checked: usize,
    missing_found: usize,
    start_seq: ?[]const u8,
    end_seq: ?[]const u8,
) !void {
    try l.appendSlice(alloc, ",\"replication_id_version\":3,\"history\":[{\"session_id\":");
    try jsonw.writeString(l, alloc, session_id);
    try l.appendSlice(alloc, ",\"docs_read\":");
    try appendInt(l, alloc, docs_read);
    try l.appendSlice(alloc, ",\"docs_written\":");
    try appendInt(l, alloc, docs_written);
    try l.appendSlice(alloc, ",\"doc_write_failures\":");
    try appendInt(l, alloc, doc_write_failures);
    try l.appendSlice(alloc, ",\"missing_checked\":");
    try appendInt(l, alloc, missing_checked);
    try l.appendSlice(alloc, ",\"missing_found\":");
    try appendInt(l, alloc, missing_found);
    try l.appendSlice(alloc, ",\"start_last_seq\":");
    try appendSeqValue(l, alloc, start_seq);
    try l.appendSlice(alloc, ",\"end_last_seq\":");
    try appendSeqValue(l, alloc, end_seq);
    try l.appendSlice(alloc, "}]");
}

fn replGuard(db: *Db) replicator.Guard {
    return .{ .lock = ReplLock.lockFn, .unlock = ReplLock.unlockFn, .ctx = db };
}

const EndpointSpec = struct {
    raw_url: []const u8,
    clean_url: []const u8,
    is_url: bool,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

fn parseEndpoint(alloc: std.mem.Allocator, val: std.json.Value) !EndpointSpec {
    const raw_url = switch (val) {
        .string => |s| s,
        .object => |obj| blk: {
            const uv = obj.get("url") orelse return error.InvalidEndpoint;
            if (uv != .string) return error.InvalidEndpoint;
            break :blk uv.string;
        },
        else => return error.InvalidEndpoint,
    };
    const is_url = std.mem.startsWith(u8, raw_url, "http://") or std.mem.startsWith(u8, raw_url, "https://");
    var user: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var clean_url = raw_url;
    if (is_url) {
        const parsed = parseSourceUrl(raw_url);
        user = parsed.user;
        password = parsed.password;
        if (parsed.user != null) {
            const scheme = std.mem.indexOf(u8, raw_url, "://").?;
            const rest = raw_url[scheme + 3 ..];
            const at = std.mem.indexOfScalar(u8, rest, '@').?;
            clean_url = try std.fmt.allocPrint(alloc, "{s}://{s}", .{ raw_url[0..scheme], rest[at + 1 ..] });
        }
    }
    if (val == .object) {
        if (val.object.get("headers")) |hv| {
            if (hv == .object) {
                var hit = hv.object.iterator();
                while (hit.next()) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization") and entry.value_ptr.* == .string) {
                        var ubuf: [512]u8 = undefined;
                        var pbuf: [512]u8 = undefined;
                        if (basicCredentials(entry.value_ptr.*.string, &ubuf, &pbuf)) |creds| {
                            user = try alloc.dupe(u8, creds.user);
                            password = try alloc.dupe(u8, creds.password);
                        }
                        break;
                    }
                }
            }
        }
    }
    return .{
        .raw_url = raw_url,
        .clean_url = clean_url,
        .is_url = is_url,
        .user = user,
        .password = password,
    };
}

fn hReplicate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const auth = try requestAuth(app, req, res);
    if (auth.users_present and !auth.admin) return err(res, 403, "forbidden", "Only _admin users may replicate");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const source_v = root.object.get("source") orelse return err(res, 400, "bad_request", "missing source");
    const target_v = root.object.get("target") orelse return err(res, 400, "bad_request", "missing target");
    const source_ep = parseEndpoint(res.arena, source_v) catch
        return err(res, 400, "bad_request", "source must be a string or endpoint object");
    const target_ep = parseEndpoint(res.arena, target_v) catch
        return err(res, 400, "bad_request", "target must be a string or endpoint object");

    const target_is_url = target_ep.is_url;
    const source_is_url = source_ep.is_url;
    if (!target_is_url and !source_is_url and std.mem.eql(u8, source_ep.raw_url, target_ep.raw_url)) {
        return err(res, 400, "bad_request", "source and target are the same database");
    }
    // `continuous` asks for a job that keeps polling. CouchDB answers 202 and
    // supervises it; here it becomes a document in _replicator, which the
    // scheduler already runs on a tick.
    var continuous_requested = false;
    if (root.object.get("continuous")) |c| {
        if (c == .bool) continuous_requested = c.bool;
    }
    var cancel_requested = false;
    if (root.object.get("cancel")) |c| {
        if (c == .bool) cancel_requested = c.bool;
    }
    // CouchDB's `doc_ids` narrows a replication to the documents listed. It is
    // honoured on every path; `selector` and `since_seq` are refused instead of
    // being ignored, because ignoring them copies the whole database.
    var doc_ids_map: replicator.IdFilter = .empty;
    var doc_ids_ptr: ?*const replicator.IdFilter = null;
    if (root.object.get("doc_ids")) |dv| {
        if (dv != .array) return err(res, 400, "bad_request", "doc_ids must be an array of strings");
        for (dv.array.items) |item| {
            if (item != .string) return err(res, 400, "bad_request", "doc_ids must be an array of strings");
            const key = try res.arena.dupe(u8, item.string);
            try doc_ids_map.put(res.arena, key, {});
        }
        doc_ids_ptr = &doc_ids_map;
    }
    const use_checkpoints: bool = if (root.object.get("use_checkpoints")) |v| (if (v == .bool) v.bool else true) else true;
    const page_size: usize = if (root.object.get("worker_batch_size")) |v|
        (if (v == .integer and v.integer > 0) @intCast(v.integer) else 500)
    else
        500;
    var selector_json: ?[]const u8 = null;
    if (root.object.get("selector")) |sel| {
        if (sel != .object) return err(res, 400, "bad_request", "selector must be an object");
        if (doc_ids_ptr != null) return err(res, 400, "bad_request", "doc_ids and selector are mutually exclusive");
        if (findUnknownOperator(sel)) |bad| {
            const reason = try std.fmt.allocPrint(res.arena, "unknown operator '{s}' in selector", .{bad});
            return err(res, 400, "invalid_operator", reason);
        }
        var sel_buf: std.ArrayListUnmanaged(u8) = .empty;
        try jsonw.writeValue(&sel_buf, res.arena, sel);
        selector_json = sel_buf.items;
        if (!source_is_url) {
            // A local source is matched here, then copied through the doc_ids
            // path, which every branch already honours.
            const sdb = (try app.acquireDb(source_ep.raw_url)) orelse
                return err(res, 404, "not_found", "Database does not exist.");
            defer app.releaseDb(sdb);
            var sit = sdb.docs.valueIterator();
            while (sit.next()) |d| {
                var doc_parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.*.winnerLeaf().body, .{}) catch continue;
                if (doc_parsed.value != .object) continue;
                try doc_parsed.value.object.put(res.arena, "_id", .{ .string = d.*.id });
                if (matchSelector(doc_parsed.value, sel)) {
                    try doc_ids_map.put(res.arena, try res.arena.dupe(u8, d.*.id), {});
                }
            }
            doc_ids_ptr = &doc_ids_map;
        }
    }
    var since_seq: ?[]const u8 = null;
    if (root.object.get("since_seq")) |sv| {
        since_seq = switch (sv) {
            .string => sv.string,
            .integer => try std.fmt.allocPrint(res.arena, "{d}", .{sv.integer}),
            else => return err(res, 400, "bad_request", "since_seq must be a string or a number"),
        };
    }
    var filter_value: ?[]const u8 = null;
    if (root.object.get("filter")) |fv| {
        if (fv != .string) return err(res, 400, "bad_request", "filter must be a string");
        filter_value = fv.string;
    }
    // A design-document filter on a local source is evaluated here, then copied
    // through the doc_ids path; a remote source evaluates it in its own feed.
    if (filter_value) |spec| {
        if (!source_is_url) {
            if (doc_ids_ptr != null) return err(res, 400, "bad_request", "doc_ids and filter are mutually exclusive");
            const sdb = (try app.acquireDb(source_ep.raw_url)) orelse
                return err(res, 404, "not_found", "Database does not exist.");
            defer app.releaseDb(sdb);
            var qp_json: ?[]const u8 = null;
            if (root.object.get("query_params")) |qv| {
                var qb: std.ArrayListUnmanaged(u8) = .empty;
                try jsonw.writeValue(&qb, res.arena, qv);
                qp_json = qb.items;
            }
            const ids = buildFilterIds(sdb, res.arena, spec, 0, qp_json) catch |e| switch (e) {
                error.FilterNotFound => return err(res, 404, "not_found", "missing filter"),
                error.FilterError => return err(res, 500, "filter_error", "filter function failed"),
                else => return e,
            };
            doc_ids_map = ids;
            doc_ids_ptr = &doc_ids_map;
        }
    }
    if (cancel_requested) {
        // CouchDB cancels by repeating the request with `cancel: true`; the job
        // id is derived the same way, so it names the same job.
        var cancel_hash = std.hash.Wyhash.init(0);
        cancel_hash.update(source_ep.raw_url);
        cancel_hash.update("\x00");
        cancel_hash.update(target_ep.raw_url);
        const cancel_id = try std.fmt.allocPrint(res.arena, "repl-{x}", .{cancel_hash.final()});
        const rdb = (try app.acquireDb("_replicator")) orelse
            return err(res, 500, "internal_error", "_replicator is missing");
        const doc = rdb.docs.get(cancel_id);
        // A cancelled job leaves a tombstone behind, and cancelling twice should
        // not report success for a job that is already gone.
        if (doc == null or doc.?.winnerLeaf().deleted) {
            app.releaseDb(rdb);
            return err(res, 404, "not_found", "no continuous replication for that source and target");
        }
        const parent: Rev = doc.?.winnerLeaf().rev;
        const stored = rdb.putLocal(cancel_id, "{}", parent, true);
        app.releaseDb(rdb);
        _ = stored catch |e| return err(res, 500, "internal_error", @errorName(e));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(res.arena, "{\"ok\":true,\"_local_id\":");
        try jsonw.writeString(&out, res.arena, cancel_id);
        try out.append(res.arena, '}');
        res.content_type = .JSON;
        res.body = out.items;
        return;
    }
    if (continuous_requested) {
        if (target_is_url and root.object.get("filter") != null) {
            return err(res, 400, "not_implemented", "filter is only supported when the source is a remote database");
        }
        // The id comes from source and target so a repeated request updates the
        // same job instead of piling up copies, which is what CouchDB gets from
        // its replication id.
        var job_hash = std.hash.Wyhash.init(0);
        job_hash.update(source_ep.raw_url);
        job_hash.update("\x00");
        job_hash.update(target_ep.raw_url);
        const job_id = try std.fmt.allocPrint(res.arena, "repl-{x}", .{job_hash.final()});
        var job_body: std.ArrayListUnmanaged(u8) = .empty;
        try job_body.appendSlice(res.arena, "{\"source\":");
        try jsonw.writeValue(&job_body, res.arena, source_v);
        try job_body.appendSlice(res.arena, ",\"target\":");
        try jsonw.writeValue(&job_body, res.arena, target_v);
        try job_body.appendSlice(res.arena, ",\"continuous\":true");
        if (root.object.get("filter")) |fv| {
            if (fv == .string) {
                try job_body.appendSlice(res.arena, ",\"filter\":");
                try jsonw.writeString(&job_body, res.arena, fv.string);
            }
        }
        if (root.object.get("doc_ids")) |dv| {
            try job_body.appendSlice(res.arena, ",\"doc_ids\":");
            try jsonw.writeValue(&job_body, res.arena, dv);
        }
        if (selector_json) |sel| {
            try job_body.appendSlice(res.arena, ",\"selector\":");
            try job_body.appendSlice(res.arena, sel);
        }
        if (root.object.get("worker_batch_size")) |v| {
            try job_body.appendSlice(res.arena, ",\"worker_batch_size\":");
            try jsonw.writeValue(&job_body, res.arena, v);
        }
        if (root.object.get("use_checkpoints")) |v| {
            try job_body.appendSlice(res.arena, ",\"use_checkpoints\":");
            try jsonw.writeValue(&job_body, res.arena, v);
        }
        if (root.object.get("since_seq")) |v| {
            try job_body.appendSlice(res.arena, ",\"since_seq\":");
            try jsonw.writeValue(&job_body, res.arena, v);
        }
        if (root.object.get("create_target")) |v| {
            try job_body.appendSlice(res.arena, ",\"create_target\":");
            try jsonw.writeValue(&job_body, res.arena, v);
        }
        if (root.object.get("query_params")) |v| {
            try job_body.appendSlice(res.arena, ",\"query_params\":");
            try jsonw.writeValue(&job_body, res.arena, v);
        }
        try job_body.append(res.arena, '}');
        const rdb = (try app.acquireDb("_replicator")) orelse
            return err(res, 500, "internal_error", "_replicator is missing");
        const parent: ?Rev = if (rdb.docs.get(job_id)) |d| d.winnerLeaf().rev else null;
        const stored = rdb.putLocal(job_id, job_body.items, parent, false);
        app.releaseDb(rdb);
        _ = stored catch |e| return err(res, 500, "internal_error", @errorName(e));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(res.arena, "{\"ok\":true,\"_local_id\":");
        try jsonw.writeString(&out, res.arena, job_id);
        try out.append(res.arena, '}');
        res.status = 202;
        res.content_type = .JSON;
        res.body = out.items;
        return;
    }
    // CouchDB's replicator sets `create_target` when it is told to make the
    // destination. Honour it for a local target instead of failing later with a
    // bare 404; a remote target is the other server's business.
    if (root.object.get("create_target")) |ct| {
        if (ct == .bool and ct.bool) {
            if (target_is_url) return err(res, 400, "bad_request", "create_target is only supported when the target is on this server");
            const created = blk: {
                app.mutex.lockUncancelable(app.io);
                defer app.mutex.unlock(app.io);
                break :blk app.createDb(target_ep.raw_url);
            };
            _ = created catch |e| switch (e) {
                error.InvalidName => return err(res, 400, "illegal_database_name", "target is not a valid database name"),
                else => return e,
            };
        }
    }
    var sid_bytes: [16]u8 = undefined;
    app.io.random(&sid_bytes);
    const session_id = std.fmt.bytesToHex(sid_bytes, .lower);
    var l: std.ArrayListUnmanaged(u8) = .empty;
    if (target_is_url) {
        // Same shape as the pull: the scan and the attachment reads hold the
        // lock, the two requests to the target do not.
        const db = app.pinDb(source_ep.raw_url) catch |e| switch (e) {
            error.DatabaseNotFound => return err(res, 404, "not_found", "Database does not exist."),
            error.DatabaseInUse => return err(res, 409, "conflict", "a replication is already using this database"),
            else => return e,
        };
        defer app.unpinReplication(db);
        var diag: replicator.Diag = .{ .alloc = app.alloc };
        defer diag.deinit();
        const result = replicator.pushIntoWithOptions(app.alloc, app.io, db, .{
            .target = target_ep.clean_url,
            .username = target_ep.user,
            .password = target_ep.password,
            .diag = &diag,
            .guard = replGuard(db),
            .doc_ids = doc_ids_ptr,
            .use_checkpoints = use_checkpoints,
            .worker_batch_size = page_size,
            .since = since_seq,
            .source_name = source_ep.raw_url,
        }) catch |e|
            return replicationError(res, e, &diag);
        try l.appendSlice(res.arena, "{\"ok\":true,\"session_id\":");
        try jsonw.writeString(&l, res.arena, &session_id);
        try l.appendSlice(res.arena, ",\"source_last_seq\":");
        try appendSeqValue(&l, res.arena, result.end_seq);
        try l.appendSlice(res.arena, ",\"documents\":");
        try appendInt(&l, res.arena, result.pushed);
        try l.appendSlice(res.arena, ",\"checked\":");
        try appendInt(&l, res.arena, result.checked);
        try l.appendSlice(res.arena, ",\"doc_write_failures\":");
        try appendInt(&l, res.arena, result.failed);
        try appendReplicationHistory(&l, res.arena, &session_id, result.pushed + result.failed, result.pushed, result.failed, result.checked, result.pushed + result.failed, null, result.end_seq);
        try l.append(res.arena, '}');
        if (result.end_seq) |seq| app.alloc.free(seq);
    } else {
        // Pin the target, then run the transfer with the mutex released: the
        // replicator takes it back for every database touch. The pin keeps a
        // concurrent DELETE from freeing the handle while the lock is down.
        const db = app.pinDb(target_ep.raw_url) catch |e| switch (e) {
            error.DatabaseNotFound => return err(res, 404, "not_found", "Database does not exist."),
            error.DatabaseInUse => return err(res, 409, "conflict", "a replication is already using this database"),
            else => return e,
        };
        defer app.unpinReplication(db);
        const filter: ?[]const u8 = if (root.object.get("filter")) |fv| blk: {
            if (fv != .string) return err(res, 400, "bad_request", "filter must be a string");
            break :blk fv.string;
        } else null;
        var diag: replicator.Diag = .{ .alloc = app.alloc };
        defer diag.deinit();
        // CouchDB accepts two database names and copies between them without a
        // network hop; the same guard keeps this server answerable while it runs.
        const result = if (source_is_url)
            replicator.pullInto(app.alloc, app.io, db, .{
                .page_size = page_size,
                .use_checkpoints = use_checkpoints,
                .source = source_ep.clean_url,
                .target_path = "",
                .checkpoint_target = try std.fmt.allocPrint(res.arena, "{s}:{s}", .{ target_ep.raw_url, &db.uuid }),
                .max_attachment_bytes = app.max_body_bytes,
                .username = source_ep.user,
                .password = source_ep.password,
                .filter = filter,
                .since = since_seq,
                .selector = selector_json,
                .doc_ids = doc_ids_ptr,
                .diag = &diag,
                .lock = ReplLock.lockFn,
                .unlock = ReplLock.unlockFn,
                .lock_ctx = db,
            }) catch |e| return replicationError(res, e, &diag)
        else blk: {
            const src = app.pinDb(source_ep.raw_url) catch |e| switch (e) {
                error.DatabaseNotFound => return err(res, 404, "not_found", "Database does not exist."),
                error.DatabaseInUse => return err(res, 409, "conflict", "a replication is already using this database"),
                else => return e,
            };
            defer app.unpinReplication(src);
            break :blk replicator.pullLocal(app.alloc, src, db, .{
                .page_size = page_size,
                .use_checkpoints = use_checkpoints,
                .source_name = source_ep.raw_url,
                .doc_ids = doc_ids_ptr,
                .diag = &diag,
                .lock = ReplLock.lockFn,
                .unlock = ReplLock.unlockFn,
                .lock_ctx = db,
                .source_guard = replGuard(src),
            }) catch |e| return replicationError(res, e, &diag);
        };
        if (std.mem.eql(u8, target_ep.raw_url, "_users")) app.invalidateUsersCache();
        try l.appendSlice(res.arena, "{\"ok\":true,\"session_id\":");
        try jsonw.writeString(&l, res.arena, &session_id);
        try l.appendSlice(res.arena, ",\"source_last_seq\":");
        try appendSeqValue(&l, res.arena, result.end_seq);
        try l.appendSlice(res.arena, ",\"documents\":");
        try appendInt(&l, res.arena, result.documents);
        try l.appendSlice(res.arena, ",\"changes_seen\":");
        try appendInt(&l, res.arena, result.changes_seen);
        try l.appendSlice(res.arena, ",\"doc_write_failures\":");
        try appendInt(&l, res.arena, result.doc_write_failures);
        try appendReplicationHistory(&l, res.arena, &session_id, result.documents, result.documents, result.doc_write_failures, result.changes_seen, result.documents, result.start_seq, result.end_seq);
        try l.append(res.arena, '}');
        if (result.start_seq) |seq| app.alloc.free(seq);
        if (result.end_seq) |seq| app.alloc.free(seq);
    }
    res.content_type = .JSON;
    res.body = l.items;
}

const RequestAuth = struct {
    authenticated: bool = false,
    admin: bool = false,
    user: []const u8 = "",
    roles: []const u8 = "",
    users_present: bool = false,
};

fn requestAuth(app: *App, req: *httpz.Request, res: *httpz.Response) !RequestAuth {
    const header: ?[]const u8 = req.header("authorization");
    const db_name = req.params.get("db");
    var cookie_scratch: [1024]u8 = undefined;
    var cookie_roles: []const u8 = "";
    var cookie_scope: []const u8 = "";
    var cookie_user: ?[]const u8 = null;
    if (req.header("cookie")) |cookies| {
        var it = std.mem.splitScalar(u8, cookies, ';');
        while (it.next()) |part| {
            const c = std.mem.trim(u8, part, " ");
            if (!std.mem.startsWith(u8, c, "AuthSession=")) continue;
            cookie_user = app.sessionUser(c["AuthSession=".len..], &cookie_scratch, &cookie_roles, &cookie_scope);
            if (cookie_user != null) break;
        }
    }
    if (cookie_user) |cu| {
        // A session cookie was minted only after a password check, and it
        // carries the roles inside its signature.
        var users_present = false;
        if (try app.acquireDb("_users")) |udb| {
            defer app.releaseDb(udb);
            users_present = udb.docs.count() > 0;
        }
        const in_scope = cookie_scope.len == 0 or (db_name != null and App.scopeContains(cookie_scope, db_name.?));
        const roles = if (in_scope) try res.arena.dupe(u8, cookie_roles) else "";
        const user = try res.arena.dupe(u8, cu);
        return .{
            .authenticated = true,
            .admin = in_scope and hasCsvRole(roles, "_admin"),
            .user = user,
            .roles = roles,
            .users_present = users_present,
        };
    }

    var user_buf: [512]u8 = undefined;
    var pass_buf: [512]u8 = undefined;
    const expected_global: ?[]const u8 = blk: {
        app.auth_mutex.lockUncancelable(app.io);
        defer app.auth_mutex.unlock(app.io);
        break :blk if (app.auth_header) |h| try res.arena.dupe(u8, h) else null;
    };
    if (expected_global) |expected| {
        if (header) |h| {
            if (headerEql(h, expected)) {
                const user = try res.arena.dupe(u8, basicUser(h, &user_buf) orelse "");
                const roles = app.rolesFor(user);
                return .{
                    .authenticated = true,
                    .admin = true,
                    .user = user,
                    .roles = roles,
                };
            }
        }
        return .{};
    }

    var has_auth_db = false;
    {
        app.auth_mutex.lockUncancelable(app.io);
        defer app.auth_mutex.unlock(app.io);
        has_auth_db = app.auth_db.count() > 0;
        if (db_name) |n| {
            if (app.auth_db.get(n)) |expected_db| {
                if (header) |h| {
                    if (headerEql(h, expected_db)) {
                        const user = try res.arena.dupe(u8, basicUser(h, &user_buf) orelse "");
                        const roles = app.rolesFor(user);
                        return .{
                            .authenticated = true,
                            .admin = true,
                            .user = user,
                            .roles = roles,
                            .users_present = true,
                        };
                    }
                }
                return .{ .users_present = true };
            }
        }
    }

    if (!try app.hasUsersPresent()) return .{
        .authenticated = !has_auth_db,
        .admin = !has_auth_db,
        .users_present = has_auth_db,
    };

    const udb = (try app.acquireDb("_users")) orelse return .{
        .authenticated = !has_auth_db,
        .admin = !has_auth_db,
        .users_present = has_auth_db,
    };
    defer app.releaseDb(udb);
    if (udb.docs.count() == 0) return .{
        .authenticated = !has_auth_db,
        .admin = !has_auth_db,
        .users_present = has_auth_db,
    };
    if (header) |h| {
        if (basicCredentials(h, &user_buf, &pass_buf)) |creds| {
            if (verifyUserDoc(res.arena, udb, creds)) |ua| {
                return .{
                    .authenticated = true,
                    .admin = hasCsvRole(ua.roles, "_admin"),
                    .user = ua.user,
                    .roles = ua.roles,
                    .users_present = true,
                };
            }
        }
    }
    return .{ .users_present = true };
}

fn hUserCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const name_v = root.object.get("name") orelse return err(res, 400, "bad_request", "missing name");
    const pass_v = root.object.get("password") orelse return err(res, 400, "bad_request", "missing password");
    if (name_v != .string or pass_v != .string or name_v.string.len == 0 or pass_v.string.len == 0)
        return err(res, 400, "bad_request", "name and password must be non-empty strings");
    if (std.mem.indexOfScalar(u8, name_v.string, ':') != null)
        return err(res, 400, "bad_request", "username must not contain ':'");
    const id = try std.fmt.allocPrint(res.arena, "org.couchdb.user:{s}", .{name_v.string});
    const auth = try requestAuth(app, req, res);
    if (auth.users_present and !auth.admin) return err(res, 403, "forbidden", "Only _admin users may create users");

    var roles: std.json.Array = std.json.Array.init(res.arena);
    if (root.object.get("roles")) |rv| {
        if (rv != .array) return err(res, 400, "bad_request", "roles must be an array");
        for (rv.array.items) |item| {
            if (item != .string) return err(res, 400, "bad_request", "roles must be strings");
            if (std.mem.indexOfScalar(u8, item.string, ',') != null)
                return err(res, 400, "bad_request", "role names must not contain ','");
            try roles.append(item);
        }
    }

    var doc: std.json.ObjectMap = .empty;
    try doc.put(res.arena, "_id", .{ .string = id });
    try doc.put(res.arena, "name", name_v);
    try doc.put(res.arena, "type", .{ .string = "user" });
    try doc.put(res.arena, "roles", .{ .array = roles });
    try doc.put(res.arena, "password", pass_v);
    var doc_val: std.json.Value = .{ .object = doc };
    try hashUserPassword(app, res, &doc_val, id);

    const db = (try app.acquireDb("_users")) orelse blk: {
        app.mutex.lockUncancelable(app.io);
        const created = app.createDb("_users") catch {
            app.mutex.unlock(app.io);
            return err(res, 500, "internal_server_error", "cannot create _users");
        };
        created.pins += 1;
        app.mutex.unlock(app.io);
        created.lock();
        break :blk created;
    };
    defer app.releaseDb(db);
    if (db.get(id)) |existing| {
        if (!existing.winnerLeaf().deleted) return err(res, 409, "conflict", "User already exists.");
    }

    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&encoded, res.arena, doc_val);
    const result = db.putLocal(id, encoded.items, null, false) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "User already exists."),
        else => return e,
    };
    db.syncWal() catch |e| {
        db.failed = true;
        return e;
    };
    app.invalidateUsersCache();
    var revbuf: [64]u8 = undefined;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, result.rev.write(&revbuf));
    try l.append(res.arena, '}');
    res.status = 201;
    res.content_type = .JSON;
    res.body = l.items;
}

fn hDocPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    if (!try requireReplicatorAdmin(app, req, res, name)) return;
    const auth = try requestAuth(app, req, res);
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    if (!validDocId(id)) return err(res, 400, "bad_request", "Only reserved document ids may start with underscore.");
    const raw_body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const ctype = req.header("content-type") orelse "";
    const multipart = std.mem.startsWith(u8, ctype, "multipart/related");
    const body = if (multipart)
        (parseMultipartRelated(res.arena, ctype, raw_body) catch return err(res, 400, "bad_request", "bad multipart"))
    else
        raw_body;
    var root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    if (std.mem.eql(u8, name, "_users")) {
        validateUserDoc(root, id) catch return err(res, 400, "bad_request", "invalid user document");
    }
    if (std.mem.eql(u8, name, "_replicator")) {
        // CouchDB refuses a replication document whose endpoints are local
        // databases: only /_replicate (transient) takes those. 3.5.3 answers
        // 403 forbidden with `local_endpoints_not_supported`, or
        // `endpoint has an invalid url` when an endpoint object names one.
        for ([_][]const u8{ "source", "target" }) |key| {
            const ep = root.object.get(key) orelse continue;
            if (ep == .string) {
                if (std.mem.indexOf(u8, ep.string, "://") == null)
                    return err(res, 403, "forbidden", "local_endpoints_not_supported");
            } else if (ep == .object) {
                const url = ep.object.get("url") orelse
                    return err(res, 403, "forbidden", "endpoint has an invalid url");
                if (url != .string or std.mem.indexOf(u8, url.string, "://") == null)
                    return err(res, 403, "forbidden", "endpoint has an invalid url");
            }
        }
    }
    const new_edits = if (q(req, "new_edits")) |v| !std.mem.eql(u8, v, "false") else true;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (std.mem.startsWith(u8, id, "_design/") and !isDbAdminFor(db, auth)) {
        return err(res, 403, "forbidden", "You are not a db or server admin.");
    }

    if (!new_edits) {
        const rv = root.object.get("_rev") orelse return err(res, 400, "bad_request", "missing rev");
        if (rv != .string) return err(res, 400, "bad_request", "bad rev");
        const rev = Rev.parse(rv.string) catch return err(res, 400, "bad_request", "bad rev");
        var ancestry_buf: std.ArrayListUnmanaged(Rev) = .empty;
        defer ancestry_buf.deinit(res.arena);
        if (root.object.get("_revisions")) |revs_val| {
            if (revs_val == .object) {
                const start_v = revs_val.object.get("start");
                const ids_v = revs_val.object.get("ids");
                if (start_v != null and ids_v != null and start_v.? == .integer and ids_v.? == .array) {
                    const start: u32 = std.math.cast(u32, start_v.?.integer) orelse return err(res, 400, "bad_request", "invalid revision start");
                    for (ids_v.?.array.items, 0..) |idv, i| {
                        if (idv != .string) continue;
                        const g = start -| @as(u32, @intCast(i));
                        const ar = revFromParts(g, idv.string) catch continue;
                        try ancestry_buf.append(res.arena, ar);
                    }
                }
            }
        }
        if (ancestry_buf.items.len == 0) try ancestry_buf.append(res.arena, rev);
        const deleted = if (root.object.get("_deleted")) |dv| (dv == .bool and dv.bool) else false;
        const store_body = try externalizeBody(db, res.arena, body);
        if (try validateDoc(db, res.arena, id, rev, store_body, deleted)) |rej| return sendValidateRejection(res, rej);
        const result = db.putImported(id, rev, ancestry_buf.items, store_body, deleted) catch |e| return e;
        if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
        var rb: [64]u8 = undefined;
        return okIdRev(res, id, result.rev.write(&rb));
    }

    var parent: ?Rev = null;
    if (root.object.get("_rev")) |rv| {
        if (rv == .string) parent = Rev.parse(rv.string) catch return err(res, 400, "bad_request", "invalid rev");
    }
    // CouchDB takes the revision being updated from three places: `_rev` in the
    // body, `?rev=` on the URL, or an `If-Match` header. Clients use all three,
    // and answering 409 for the latter two breaks every one of them.
    if (parent == null) {
        if (q(req, "rev")) |rs| {
            parent = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");
        }
    }
    if (parent == null) {
        if (req.header("if-match")) |im| {
            const wanted = std.mem.trim(u8, im, " \t\"");
            if (!std.mem.eql(u8, wanted, "*")) {
                parent = Rev.parse(wanted) catch return err(res, 400, "bad_request", "invalid rev");
            }
        }
    }
    const deleted = if (root.object.get("_deleted")) |dv| (dv == .bool and dv.bool) else false;

    var store_body = body;
    if (std.mem.eql(u8, name, "_users") and root.object.get("password") != null) {
        hashUserPassword(app, res, &root, id) catch |e| switch (e) {
            error.InvalidUserId, error.InvalidPassword => return err(res, 400, "bad_request", "invalid user document"),
            error.MissingPassword => return err(res, 400, "bad_request", "missing password"),
            else => return e,
        };
        var encoded: std.ArrayListUnmanaged(u8) = .empty;
        try jsonw.writeValue(&encoded, res.arena, root);
        store_body = encoded.items;
    }
    if (root.object.get("_attachments") != null) {
        var parent_leaf: ?*const Leaf = null;
        if (parent) |p| {
            if (db.get(id)) |d| {
                if (d.findLeaf(p)) |idx| parent_leaf = &d.leaves.items[idx];
            }
        }
        store_body = prepareAttachments(res, &root, parent_leaf, app.max_body_bytes) catch |e| switch (e) {
            error.MissingStub => return err(res, 412, "missing_stub", "A pre-existing attachment stub wasn't found"),
            else => return e,
        };
        store_body = try externalizeBody(db, res.arena, store_body);
    }

    if (try validateDoc(db, res.arena, id, parent, store_body, deleted)) |rej| return sendValidateRejection(res, rej);
    const result = db.putLocal(id, store_body, parent, deleted) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        error.InvalidRev => return err(res, 400, "bad_request", "invalid rev"),
        else => return e,
    };
    if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
    var rb: [64]u8 = undefined;
    try okIdRev(res, id, result.rev.write(&rb));
}

fn hDocDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    if (!try requireReplicatorAdmin(app, req, res, name)) return;
    const auth = try requestAuth(app, req, res);
    const id = try percentDecode(res.arena, req.params.get("doc") orelse return err(res, 400, "bad_request", "missing doc"));
    // CouchDB accepts the revision to delete as `?rev=` or an `If-Match`
    // header, the same pair a PUT takes.
    const rs = q(req, "rev") orelse if (req.header("if-match")) |im| std.mem.trim(u8, im, " \t\"") else return err(res, 409, "conflict", "Document update conflict.");
    const rev = Rev.parse(rs) catch return err(res, 400, "bad_request", "invalid rev");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (std.mem.startsWith(u8, id, "_design/") and !isDbAdminFor(db, auth)) {
        return err(res, 403, "forbidden", "You are not a db or server admin.");
    }
    if (try validateDoc(db, res.arena, id, rev, "{\"_deleted\":true}", true)) |rej| return sendValidateRejection(res, rej);
    const result = db.putLocal(id, "{\"_deleted\":true}", rev, true) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };
    if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
    var rb: [64]u8 = undefined;
    res.status = 200;
    res.content_type = .JSON;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"ok\":true,\"id\":");
    try jsonw.writeString(&l, res.arena, id);
    try l.appendSlice(res.arena, ",\"rev\":");
    try jsonw.writeString(&l, res.arena, result.rev.write(&rb));
    try l.append(res.arena, '}');
    res.body = l.items;
}

fn revFromParts(gen: u32, hash: []const u8) !Rev {
    if (hash.len != 32) return error.InvalidRev;
    var out: [32]u8 = undefined;
    for (hash, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return error.InvalidRev;
        out[i] = std.ascii.toLower(c);
    }
    return .{ .gen = gen, .hash = out };
}

fn hBulkDocs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    if (!try requireReplicatorAdmin(app, req, res, name)) return;
    const auth = try requestAuth(app, req, res);
    if (req.header("content-type")) |ct_hdr| {
        if (!std.mem.startsWith(u8, ct_hdr, "application/json") and !std.mem.startsWith(u8, ct_hdr, "multipart/")) {
            return err(res, 415, "bad_content_type", "Content-Type must be application/json");
        }
    }
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const ctype = req.header("content-type") orelse "application/json";

    var docs: []std.json.Value = &.{};
    var new_edits = true;
    if (std.mem.startsWith(u8, ctype, "multipart/")) {
        var parts: std.ArrayListUnmanaged(MimePart) = .empty;
        defer parts.deinit(res.arena);
        collectMultipartParts(res.arena, ctype, body, &parts) catch
            return err(res, 400, "bad_request", "bad multipart");
        var parsed_docs: std.ArrayListUnmanaged(std.json.Value) = .empty;
        for (parts.items) |part| {
            const json = multipartDocumentJson(res.arena, part) catch
                return err(res, 400, "bad_request", "bad multipart document");
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, json, .{}) catch
                return err(res, 400, "bad_request", "invalid JSON");
            if (parsed.value != .object) return err(res, 400, "bad_request", "JSON object required");
            try parsed_docs.append(res.arena, parsed.value);
        }
        docs = parsed_docs.items;
        if (q(req, "new_edits")) |v| new_edits = !std.mem.eql(u8, v, "false");
    } else {
        const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
        if (root != .object) return err(res, 400, "bad_request", "JSON object required");
        const docs_val = root.object.get("docs") orelse return err(res, 400, "bad_request", "missing docs");
        if (docs_val != .array) return err(res, 400, "bad_request", "docs must be an array");
        docs = docs_val.array.items;
        new_edits = if (root.object.get("new_edits")) |v| (v == .bool and v.bool) else true;
    }

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(res.arena, '[');
    var first = true;
    for (docs) |item| {
        if (item != .object) {
            if (!first) try out.append(res.arena, ',');
            first = false;
            try out.appendSlice(res.arena, "{\"error\":\"bad_request\",\"reason\":\"document must be an object\"}");
            continue;
        }
        const obj = item.object;
        var generated_id: [32]u8 = undefined;
        const id = if (obj.get("_id")) |idv| blk: {
            if (idv != .string) {
                if (!first) try out.append(res.arena, ',');
                first = false;
                try out.appendSlice(res.arena, "{\"error\":\"bad_request\",\"reason\":\"document id must be a string\"}");
                continue;
            }
            break :blk idv.string;
        } else blk: {
            var rnd: [16]u8 = undefined;
            app.io.random(&rnd);
            const hex = std.fmt.bytesToHex(rnd, .lower);
            @memcpy(&generated_id, &hex);
            break :blk &generated_id;
        };

        if (!validDocId(id)) {
            if (!first) try out.append(res.arena, ',');
            first = false;
            try out.appendSlice(res.arena, "{\"id\":");
            try jsonw.writeString(&out, res.arena, id);
            try out.appendSlice(res.arena, ",\"error\":\"bad_request\",\"reason\":\"Only reserved document ids may start with underscore.\"}");
            continue;
        }
        if (std.mem.startsWith(u8, id, "_design/") and !isDbAdminFor(db, auth)) {
            if (!first) try out.append(res.arena, ',');
            first = false;
            try out.appendSlice(res.arena, "{\"id\":");
            try jsonw.writeString(&out, res.arena, id);
            try out.appendSlice(res.arena, ",\"error\":\"forbidden\",\"reason\":\"You are not a db or server admin.\"}");
            continue;
        }

        var doc_val = item;
        if (std.mem.eql(u8, name, "_users")) {
            validateUserDoc(doc_val, id) catch {
                if (!first) try out.append(res.arena, ',');
                first = false;
                try out.appendSlice(res.arena, "{\"id\":");
                try jsonw.writeString(&out, res.arena, id);
                try out.appendSlice(res.arena, ",\"error\":\"bad_request\",\"reason\":\"invalid user document\"}");
                continue;
            };
            if (doc_val.object.get("password") != null) {
                hashUserPassword(app, res, &doc_val, id) catch {
                    if (!first) try out.append(res.arena, ',');
                    first = false;
                    try out.appendSlice(res.arena, "{\"id\":");
                    try jsonw.writeString(&out, res.arena, id);
                    try out.appendSlice(res.arena, ",\"error\":\"bad_request\",\"reason\":\"invalid user document\"}");
                    continue;
                };
            }
        }

        var revbuf: [64]u8 = undefined;
        var result: ?@import("../store/db.zig").PutResult = null;
        var fail: ?[]const u8 = null;
        var fail_reason: ?[]const u8 = null;

        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        try jsonw.writeValue(&body_buf, res.arena, doc_val);
        var doc_body: []const u8 = body_buf.items;
        if (obj.get("_attachments") != null) {
            if (new_edits) {
                var parent_leaf: ?*const Leaf = null;
                if (obj.get("_rev")) |rv| {
                    if (rv == .string) {
                        const p = Rev.parse(rv.string) catch null;
                        if (p) |pr| {
                            if (db.get(id)) |d| {
                                if (d.findLeaf(pr)) |idx| parent_leaf = &d.leaves.items[idx];
                            }
                        }
                    }
                }
                if (prepareAttachments(res, &doc_val, parent_leaf, app.max_body_bytes)) |prepared| {
                    doc_body = prepared;
                } else |e| switch (e) {
                    error.MissingStub => {
                        fail = "missing_stub";
                        fail_reason = "A pre-existing attachment stub wasn't found";
                    },
                    error.TooLarge => {
                        fail = "too_large";
                        fail_reason = "Attachment exceeds ZOUCH_MAX_BODY_MB";
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        fail = "bad_request";
                        fail_reason = @errorName(e);
                    },
                }
            }
            if (fail == null) {
                if (externalizeBody(db, res.arena, doc_body)) |ext_body| {
                    doc_body = ext_body;
                } else |e| switch (e) {
                    error.OutOfMemory, error.Io => return e,
                    else => {
                        fail = "bad_request";
                        fail_reason = @errorName(e);
                    },
                }
            }
        }

        if (fail == null) {
            if (new_edits) {
                var parent: ?Rev = null;
                if (doc_val.object.get("_rev")) |rv| {
                    if (rv == .string) parent = Rev.parse(rv.string) catch null;
                }
                const deleted = if (doc_val.object.get("_deleted")) |dv| (dv == .bool and dv.bool) else false;
                if (try validateDoc(db, res.arena, id, parent, doc_body, deleted)) |rej| {
                    fail = rej.code;
                    fail_reason = rej.reason;
                } else {
                    result = db.putLocalBatch(id, doc_body, parent, deleted) catch |e| blk: {
                        switch (e) {
                            error.Conflict => fail = "conflict",
                            error.InvalidRev => {
                                fail = "bad_rev";
                                fail_reason = "Invalid _rev";
                            },
                            error.TooLarge => {
                                fail = "too_large";
                                fail_reason = "Document exceeds limit";
                            },
                            error.MemoryLimitExceeded => {
                                fail = "insufficient_storage";
                                fail_reason = "Database memory limit exceeded";
                            },
                            error.FileTooLarge => {
                                fail = "insufficient_storage";
                                fail_reason = "Database file exceeds maximum supported size";
                            },
                            else => return e,
                        }
                        break :blk null;
                    };
                }
            } else {
                const rv = doc_val.object.get("_rev");
                if (rv == null) {
                    fail = "missing_rev";
                    fail_reason = "Missing _rev";
                } else if (rv.? != .string) {
                    fail = "bad_rev";
                    fail_reason = "Invalid _rev";
                } else if (Rev.parse(rv.?.string) catch null) |rev| {
                    var ancestry_buf: std.ArrayListUnmanaged(Rev) = .empty;
                    defer ancestry_buf.deinit(res.arena);
                    var bad_start = false;
                    if (doc_val.object.get("_revisions")) |revs_val| {
                        if (revs_val == .object) {
                            const start_v = revs_val.object.get("start");
                            const ids_v = revs_val.object.get("ids");
                            if (start_v != null and ids_v != null and start_v.? == .integer and ids_v.? == .array) {
                                if (std.math.cast(u32, start_v.?.integer)) |start| {
                                    for (ids_v.?.array.items, 0..) |idv2, i| {
                                        if (idv2 != .string) continue;
                                        const g = start -| @as(u32, @intCast(i));
                                        const ar = revFromParts(g, idv2.string) catch continue;
                                        try ancestry_buf.append(res.arena, ar);
                                    }
                                } else {
                                    bad_start = true;
                                }
                            }
                        }
                    }
                    if (bad_start) {
                        fail = "bad_request";
                        fail_reason = "invalid revision start";
                    } else {
                        if (ancestry_buf.items.len == 0) try ancestry_buf.append(res.arena, rev);
                        const deleted = if (obj.get("_deleted")) |dv| (dv == .bool and dv.bool) else false;
                        if (try validateDoc(db, res.arena, id, rev, doc_body, deleted)) |rej| {
                            fail = rej.code;
                            fail_reason = rej.reason;
                        } else {
                            result = db.putImportedBatch(id, rev, ancestry_buf.items, doc_body, deleted) catch |e| blk: {
                                switch (e) {
                                    error.Conflict => fail = "conflict",
                                    error.InvalidRev => {
                                        fail = "bad_rev";
                                        fail_reason = "Invalid _rev";
                                    },
                                    error.TooLarge => {
                                        fail = "too_large";
                                        fail_reason = "Document exceeds limit";
                                    },
                                    error.MemoryLimitExceeded => {
                                        fail = "insufficient_storage";
                                        fail_reason = "Database memory limit exceeded";
                                    },
                                    error.FileTooLarge => {
                                        fail = "insufficient_storage";
                                        fail_reason = "Database file exceeds maximum supported size";
                                    },
                                    else => return e,
                                }
                                break :blk null;
                            };
                        }
                    }
                } else {
                    fail = "bad_rev";
                    fail_reason = "Invalid _rev";
                }
            }
        }

        if (fail) |f| {
            if (!first) try out.append(res.arena, ',');
            first = false;
            try out.appendSlice(res.arena, "{\"id\":");
            try jsonw.writeString(&out, res.arena, id);
            try out.appendSlice(res.arena, ",\"error\":");
            try jsonw.writeString(&out, res.arena, f);
            try out.appendSlice(res.arena, ",\"reason\":");
            try jsonw.writeString(&out, res.arena, fail_reason orelse "Document update conflict.");
            try out.append(res.arena, '}');
        } else if (new_edits) {
            if (result) |r| {
                if (!first) try out.append(res.arena, ',');
                first = false;
                try out.appendSlice(res.arena, "{\"ok\":true,\"id\":");
                try jsonw.writeString(&out, res.arena, id);
                try out.appendSlice(res.arena, ",\"rev\":");
                try jsonw.writeString(&out, res.arena, r.rev.write(&revbuf));
                try out.append(res.arena, '}');
            }
        }
    }
    db.syncWal() catch |e| {
        db.failed = true;
        return e;
    };
    if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
    try out.append(res.arena, ']');
    res.status = 201;
    res.content_type = .JSON;
    res.body = out.items;
}

fn headerSafe(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn appendQuotedFilename(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, name: []const u8) !void {
    for (name) |c| {
        switch (c) {
            '"', '\\' => {
                try list.append(alloc, '\\');
                try list.append(alloc, c);
            },
            '\r', '\n' => {},
            else => try list.append(alloc, c),
        }
    }
}

fn leafHasAttachmentPayload(db: *Db, alloc: std.mem.Allocator, leaf: Leaf) bool {
    if (std.mem.indexOf(u8, leaf.body, "_attachments") == null) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, leaf.body, .{}) catch return false;
    if (parsed.value != .object) return false;
    const atts = parsed.value.object.get("_attachments") orelse return false;
    if (atts != .object) return false;
    for (atts.object.values()) |one| {
        if (one != .object) continue;
        if (one.object.get("data")) |dv| {
            if (dv == .string) return true;
        }
        if (one.object.get("blob")) |bv| {
            if (bv == .string) {
                if (db.openBlob(bv.string)) |f| {
                    f.close(db.io);
                    return true;
                } else |_| {}
            }
        }
    }
    return false;
}

fn appendMultipartAttachments(
    db: *Db,
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    atts: std.json.Value,
    boundary: []const u8,
) !void {
    if (atts != .object) return;
    const keys = atts.object.keys();
    const vals = atts.object.values();
    for (keys, vals) |name, one| {
        if (one != .object) continue;
        const raw = (try attachmentRaw(db, alloc, one)) orelse continue;
        const ct = if (one.object.get("content_type")) |cv|
            (if (cv == .string and headerSafe(cv.string)) cv.string else "application/octet-stream")
        else
            "application/octet-stream";
        try list.appendSlice(alloc, "--");
        try list.appendSlice(alloc, boundary);
        try list.appendSlice(alloc, "\r\nContent-Type: ");
        try list.appendSlice(alloc, ct);
        if (one.object.get("encoding")) |ev| {
            if (ev == .string and headerSafe(ev.string)) {
                try list.appendSlice(alloc, "\r\nContent-Encoding: ");
                try list.appendSlice(alloc, ev.string);
            }
        }
        try list.appendSlice(alloc, "\r\nContent-Disposition: attachment; filename=\"");
        try appendQuotedFilename(list, alloc, name);
        try list.appendSlice(alloc, "\"\r\n\r\n");
        try list.appendSlice(alloc, raw);
        try list.appendSlice(alloc, "\r\n");
    }
}

fn bulkGetMultipart(
    app: *App,
    res: *httpz.Response,
    name: []const u8,
    docs: []std.json.Value,
    with_revs: bool,
    latest: bool,
) !void {
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var outer_rnd: [8]u8 = undefined;
    var inner_rnd: [8]u8 = undefined;
    app.io.random(&outer_rnd);
    app.io.random(&inner_rnd);
    const outer = try std.fmt.allocPrint(res.arena, "zouchbulk-{s}", .{std.fmt.bytesToHex(outer_rnd, .lower)});
    const inner = try std.fmt.allocPrint(res.arena, "zouchdoc-{s}", .{std.fmt.bytesToHex(inner_rnd, .lower)});
    var l: std.ArrayListUnmanaged(u8) = .empty;
    for (docs) |item| {
        if (item != .object) continue;
        const idv = item.object.get("id") orelse continue;
        if (idv != .string or !headerSafe(idv.string)) continue;
        const id = idv.string;
        try l.appendSlice(res.arena, "--");
        try l.appendSlice(res.arena, outer);
        try l.appendSlice(res.arena, "\r\nX-Doc-Id: ");
        try l.appendSlice(res.arena, id);

        const doc = db.get(id);
        if (doc == null) {
            try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n{\"error\":{\"id\":");
            try jsonw.writeString(&l, res.arena, id);
            try l.appendSlice(res.arena, ",\"error\":\"not_found\",\"reason\":\"missing\"}}\r\n");
            continue;
        }

        var leaf_idx: usize = doc.?.winner;
        var missing_rev = false;
        if (item.object.get("rev")) |rv| {
            if (rv == .string) {
                const r = Rev.parse(rv.string) catch return err(res, 400, "bad_request", "invalid rev");
                if (doc.?.findLeaf(r)) |idx| {
                    leaf_idx = idx;
                } else if (latest) {
                    leaf_idx = doc.?.winner;
                } else {
                    missing_rev = true;
                }
            }
        }
        if (missing_rev) {
            try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n{\"error\":{\"id\":");
            try jsonw.writeString(&l, res.arena, id);
            try l.appendSlice(res.arena, ",\"rev\":");
            try jsonw.writeString(&l, res.arena, item.object.get("rev").?.string);
            try l.appendSlice(res.arena, ",\"error\":\"not_found\",\"reason\":\"missing\"}}\r\n");
            continue;
        }
        const leaf = doc.?.leaves.items[leaf_idx];
        var rb: [64]u8 = undefined;
        try l.appendSlice(res.arena, "\r\nX-Rev-Id: ");
        try l.appendSlice(res.arena, leaf.rev.write(&rb));

        if (leafHasAttachmentPayload(db, res.arena, leaf)) {
            try l.appendSlice(res.arena, "\r\nContent-Type: multipart/related; boundary=");
            try l.appendSlice(res.arena, inner);
            try l.appendSlice(res.arena, "\r\n\r\n--");
            try l.appendSlice(res.arena, inner);
            try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n");
            try writeDocMode(db, &l, res.arena, doc.?, leaf_idx, with_revs, false, .follows);
            try l.appendSlice(res.arena, "\r\n");
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, leaf.body, .{}) catch null;
            if (parsed) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("_attachments")) |atts| {
                        try appendMultipartAttachments(db, &l, res.arena, atts, inner);
                    }
                }
            }
            try l.appendSlice(res.arena, "--");
            try l.appendSlice(res.arena, inner);
            try l.appendSlice(res.arena, "--\r\n");
        } else {
            try l.appendSlice(res.arena, "\r\nContent-Type: application/json\r\n\r\n");
            try writeDocMode(db, &l, res.arena, doc.?, leaf_idx, with_revs, false, .stub);
            try l.appendSlice(res.arena, "\r\n");
        }
    }
    try l.appendSlice(res.arena, "--");
    try l.appendSlice(res.arena, outer);
    try l.appendSlice(res.arena, "--\r\n");
    const ct = try std.fmt.allocPrint(res.arena, "multipart/mixed; boundary={s}", .{outer});
    res.headers.add("content-type", ct);
    res.body = l.items;
}

fn hBulkGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const docs_val = root.object.get("docs") orelse return err(res, 400, "bad_request", "missing docs");
    if (docs_val != .array) return err(res, 400, "bad_request", "docs must be an array");
    // CouchDB reads `revs` from the query string (`?_bulk_get?revs=true`);
    // a body flag is accepted as well since it costs nothing.
    const with_revs = if (q(req, "revs")) |v|
        std.mem.eql(u8, v, "true")
    else if (root.object.get("revs")) |v|
        (v == .bool and v.bool)
    else
        false;
    const with_atts = if (q(req, "attachments")) |v| std.mem.eql(u8, v, "true") else false;
    const latest = if (q(req, "latest")) |v| std.mem.eql(u8, v, "true") else false;
    const accept = req.header("accept") orelse "";
    if (with_atts and (std.mem.indexOf(u8, accept, "multipart/related") != null or
        std.mem.indexOf(u8, accept, "multipart/mixed") != null))
    {
        return bulkGetMultipart(app, res, name, docs_val.array.items, with_revs, latest);
    }

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"results\":[");
    var first = true;
    for (docs_val.array.items) |item| {
        if (item != .object) continue;
        const idv = item.object.get("id") orelse continue;
        if (idv != .string) continue;
        if (!first) try l.append(res.arena, ',');
        first = false;
        const id = idv.string;
        try l.appendSlice(res.arena, "{\"id\":");
        try jsonw.writeString(&l, res.arena, id);
        try l.appendSlice(res.arena, ",\"docs\":[");
        const doc = db.get(id);
        if (doc == null) {
            try l.appendSlice(res.arena, "{\"error\":{\"id\":");
            try jsonw.writeString(&l, res.arena, id);
            try l.appendSlice(res.arena, ",\"rev\":");
            if (item.object.get("rev")) |rv| {
                if (rv == .string) try jsonw.writeString(&l, res.arena, rv.string) else try l.appendSlice(res.arena, "\"undefined\"");
            } else {
                try l.appendSlice(res.arena, "\"undefined\"");
            }
            try l.appendSlice(res.arena, ",\"error\":\"not_found\",\"reason\":\"missing\"}}");
        } else {
            var leaf_idx: usize = doc.?.winner;
            var missing_rev = false;
            // A body kept for a superseded revision, when the request names one.
            var retained_hit: ?*const tree.Retained = null;
            if (item.object.get("rev")) |rv| {
                if (rv == .string) {
                    const r = Rev.parse(rv.string) catch
                        return err(res, 400, "bad_request", "invalid rev");
                    if (doc.?.findLeaf(r)) |idx| {
                        leaf_idx = idx;
                    } else if (latest and doc.?.findDescendantOf(r) != null) {
                        // An old revision of this document: CouchDB answers
                        // with the leaf it led to. A revision we have never
                        // seen is not_found even with latest (measured).
                        leaf_idx = doc.?.findDescendantOf(r).?;
                    } else if (doc.?.retainedFor(r)) |ret| {
                        // Not a leaf, but the body is still held: CouchDB hands
                        // back the old revision until compaction drops it.
                        retained_hit = ret;
                    } else {
                        missing_rev = true;
                    }
                }
            }
            if (missing_rev) {
                try l.appendSlice(res.arena, "{\"error\":{\"id\":");
                try jsonw.writeString(&l, res.arena, id);
                try l.appendSlice(res.arena, ",\"rev\":");
                try jsonw.writeString(&l, res.arena, item.object.get("rev").?.string);
                try l.appendSlice(res.arena, ",\"error\":\"not_found\",\"reason\":\"missing\"}}");
            } else if (retained_hit) |ret| {
                try l.appendSlice(res.arena, "{\"ok\":");
                try writeRetainedDoc(db, res.arena, &l, doc.?, ret.rev, ret.body, ret.deleted, with_revs, with_atts);
                try l.append(res.arena, '}');
            } else {
                try l.appendSlice(res.arena, "{\"ok\":");
                try writeDoc(db, &l, res.arena, doc.?, leaf_idx, with_revs, false, with_atts);
                try l.append(res.arena, '}');
            }
        }
        try l.appendSlice(res.arena, "]}");
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// A document as it stood at a revision that is no longer a leaf: cleaned user
/// fields, `_id`, `_rev`, optional `_deleted`/`_revisions`, and normalized
/// `_attachments` (never leaking internal `blob`/`data:null`).
fn writeRetainedDoc(
    db: *Db,
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
    doc: *const tree.Doc,
    rev: Rev,
    body_raw: []const u8,
    deleted: bool,
    with_revs: bool,
    inline_atts: bool,
) !void {
    var revbuf: [64]u8 = undefined;
    try list.append(alloc, '{');
    try jsonw.fieldString(list, alloc, "_id", doc.id);
    try list.append(alloc, ',');
    try jsonw.fieldString(list, alloc, "_rev", rev.write(&revbuf));
    if (deleted) {
        try list.appendSlice(alloc, ",\"_deleted\":true");
    }
    if (with_revs) {
        try list.appendSlice(alloc, ",\"_revisions\":{\"start\":");
        try appendInt(list, alloc, rev.gen);
        try list.appendSlice(alloc, ",\"ids\":[");
        var first = true;
        const fallback_anc = [_]Rev{rev};
        const anc_slice = doc.ancestryFor(rev) orelse &fallback_anc;
        for (anc_slice) |anc| {
            if (!first) try list.append(alloc, ',');
            first = false;
            try jsonw.writeString(list, alloc, anc.hash[0..]);
        }
        try list.appendSlice(alloc, "]}");
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body_raw, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| {
        if (p.value == .object) {
            for (p.value.object.keys(), p.value.object.values()) |k, v| {
                if (metaKey(k)) continue;
                try list.append(alloc, ',');
                try jsonw.writeString(list, alloc, k);
                try list.append(alloc, ':');
                try jsonw.writeValue(list, alloc, v);
            }
            const att_mode: AttachmentOutput = if (inline_atts) .inline_data else .stub;
            try writeAttachments(db, list, alloc, p.value.object.get("_attachments") orelse .null, rev.gen, att_mode);
        }
    }
    try list.append(alloc, '}');
}

fn hChanges(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const filter_spec = if (q(req, "filter")) |f| (if (f.len == 0) null else f) else null;
    if (q(req, "feed")) |feed| {
        if (std.mem.eql(u8, feed, "longpoll")) return hChangesLongpoll(app, req, res);
        if (std.mem.eql(u8, feed, "continuous")) return hChangesContinuous(app, req, res);
    }
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const since_arg = q(req, "since");
    const limit: usize = if (q(req, "limit")) |v| (std.fmt.parseInt(usize, v, 10) catch 0) else 0;
    const include_docs = if (q(req, "include_docs")) |v| std.mem.eql(u8, v, "true") else false;
    const style_all = if (q(req, "style")) |v| std.mem.eql(u8, v, "all_docs") else false;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const since: u64 = if (since_arg) |v|
        (if (std.mem.eql(u8, v, "now")) db.seq else (std.fmt.parseInt(u64, v, 10) catch 0))
    else
        0;
    var filter_ids: ?std.StringHashMapUnmanaged(void) = null;
    if (filter_spec) |spec| {
        if (std.mem.eql(u8, spec, "_doc_ids")) {
            // CouchDB sends the selection in the body of a POST; without one
            // there is nothing to select, and answering with every document
            // would silently copy the whole database.
            const body = fullBody(req, res.arena, app.max_body_bytes) catch |e|
                if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "filter=_doc_ids needs a JSON body with doc_ids");
            if (body.len == 0) return err(res, 400, "bad_request", "filter=_doc_ids needs a JSON body with doc_ids");
            var parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch
                return err(res, 400, "bad_request", "filter=_doc_ids body is not JSON");
            var ids: std.StringHashMapUnmanaged(void) = .empty;
            if (parsed.value == .object) {
                if (parsed.value.object.get("doc_ids")) |dv| {
                    if (dv != .array) return err(res, 400, "bad_request", "doc_ids must be an array of strings");
                    for (dv.array.items) |item| {
                        if (item != .string) return err(res, 400, "bad_request", "doc_ids must be an array of strings");
                        try ids.put(res.arena, item.string, {});
                    }
                }
            }
            filter_ids = ids;
        } else if (std.mem.eql(u8, spec, "_selector")) {
            // CouchDB sends the selector in the body of a POST. Match it here
            // with the same matcher `_find` uses.
            const body = fullBody(req, res.arena, app.max_body_bytes) catch |e|
                if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "filter=_selector needs a JSON body with a selector");
            if (body.len == 0) return err(res, 400, "bad_request", "filter=_selector needs a JSON body with a selector");
            var parsed_body = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch
                return err(res, 400, "bad_request", "filter=_selector body is not JSON");
            if (parsed_body.value != .object) return err(res, 400, "bad_request", "missing selector");
            const sel = parsed_body.value.object.get("selector") orelse
                return err(res, 400, "bad_request", "missing selector");
            if (findUnknownOperator(sel)) |bad| {
                const reason = try std.fmt.allocPrint(res.arena, "unknown operator '{s}' in selector", .{bad});
                return err(res, 400, "invalid_operator", reason);
            }
            var selected: std.StringHashMapUnmanaged(void) = .empty;
            var dit = db.docs.valueIterator();
            while (dit.next()) |d| {
                if (d.*.seq <= since) continue;
                var doc_parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.*.winnerLeaf().body, .{}) catch continue;
                if (doc_parsed.value != .object) continue;
                try doc_parsed.value.object.put(res.arena, "_id", .{ .string = d.*.id });
                if (matchSelector(doc_parsed.value, sel)) try selected.put(res.arena, d.*.id, {});
            }
            filter_ids = selected;
        } else filter_ids = buildFilterIds(db, res.arena, spec, since, try buildQueryJson(res.arena, req)) catch |e| switch (e) {
            error.FilterNotFound => return err(res, 404, "not_found", "missing filter"),
            error.FilterError => return err(res, 500, "filter_error", "filter function failed"),
            else => return e,
        };
    }
    const eventsource = if (q(req, "feed")) |f| std.mem.eql(u8, f, "eventsource") else false;
    return writeChanges(db, res, since, limit, include_docs, style_all, filter_ids, eventsource);
}

fn findFilterSource(db: *Db, alloc: std.mem.Allocator, spec: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.FilterNotFound;
    const ddoc = spec[0..slash];
    const fname = spec[slash + 1 ..];
    if (ddoc.len == 0 or fname.len == 0) return error.FilterNotFound;
    const ddoc_id = try std.fmt.allocPrint(alloc, "_design/{s}", .{ddoc});
    defer alloc.free(ddoc_id);
    const design = db.get(ddoc_id) orelse return error.FilterNotFound;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, design.winnerLeaf().body, .{}) catch return error.FilterNotFound;
    // `fv` is duplicated before `parsed` is freed so the scheduler can hold
    // only what it needs.
    defer parsed.deinit();
    if (parsed.value != .object) return error.FilterNotFound;
    const filters = parsed.value.object.get("filters") orelse return error.FilterNotFound;
    if (filters != .object) return error.FilterNotFound;
    const fv = filters.object.get(fname) orelse return error.FilterNotFound;
    if (fv != .string) return error.FilterNotFound;
    return try alloc.dupe(u8, fv.string);
}

fn validateFilterExists(db: *Db, alloc: std.mem.Allocator, spec: []const u8) !void {
    const src = try findFilterSource(db, alloc, spec);
    alloc.free(src);
}

fn buildFilterIds(db: *Db, alloc: std.mem.Allocator, spec: []const u8, since: u64, req_query_json: ?[]const u8) !std.StringHashMapUnmanaged(void) {
    const raw_src = try findFilterSource(db, alloc, spec);
    defer alloc.free(raw_src);

    var code: std.ArrayListUnmanaged(u8) = .empty;
    defer code.deinit(alloc);
    const trimmed = std.mem.trim(u8, raw_src, " \t\r\n");
    const fn_src = if (std.mem.startsWith(u8, trimmed, "function") or std.mem.indexOf(u8, raw_src, "=>") != null)
        try std.fmt.allocPrint(alloc, "({s})", .{raw_src})
    else
        try std.fmt.allocPrint(alloc, "(function(doc,req){{ {s} }})", .{raw_src});
    defer alloc.free(fn_src);
    try code.appendSlice(alloc, "JSON.stringify((function(){const f=");
    try code.appendSlice(alloc, fn_src);
    try code.appendSlice(alloc, ";const req={query:");
    try code.appendSlice(alloc, req_query_json orelse "{}");
    try code.appendSlice(alloc, "};const out=[];const docs=[");
    var first = true;
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.seq <= since) continue;
        if (!first) try code.append(alloc, ',');
        first = false;
        const js_doc = try buildJsDoc(db, alloc, d.*.id, d.*.winnerLeaf().rev, d.*.winnerLeaf().body, d.*.winnerLeaf().deleted);
        defer alloc.free(js_doc);
        try code.appendSlice(alloc, js_doc);
    }
    try code.appendSlice(alloc, "];for(const d of docs){if(f(d,req))out.push(d._id);}return out;})())");

    var eng = qjs.Engine.init() catch return error.FilterError;
    defer eng.deinit();
    const out = eng.eval(alloc, code.items) catch return error.FilterError;
    defer alloc.free(out);
    const result = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.FilterError;
    defer result.deinit();
    if (result.value != .array) return error.FilterError;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    errdefer freeFilterIds(alloc, &ids);
    for (result.value.array.items) |item| {
        if (item != .string) continue;
        const key = try alloc.dupe(u8, item.string);
        ids.put(alloc, key, {}) catch |e| {
            alloc.free(key);
            return e;
        };
    }
    return ids;
}

const ContinuousCtx = struct {
    app: *App,
    db: *Db,
    io: Io,
    // Every allocation that belongs to this context, including the context
    // itself, must be released with the allocator that made it: closeFeedsFor
    // runs on a request thread and used to free page_allocator memory with the
    // App's allocator.
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    last: u64,
    include_docs: bool,
    style_all: bool,
    timeout_ms: usize,
    filter_spec: ?[]u8,
    filter_query_json: ?[]u8 = null,
    elapsed: usize = 0,
    in_flight: bool = false,
    closing: bool = false,
};

fn hChangesContinuous(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const since_arg = q(req, "since");
    const filter_spec = if (q(req, "filter")) |f| (if (f.len == 0) null else f) else null;
    const include_docs = if (q(req, "include_docs")) |v| std.mem.eql(u8, v, "true") else false;
    const style_all = if (q(req, "style")) |v| std.mem.eql(u8, v, "all_docs") else false;
    var timeout_ms: usize = if (q(req, "timeout")) |v| (std.fmt.parseInt(usize, v, 10) catch 60000) else 60000;
    if (timeout_ms == 0 or timeout_ms > 60000) timeout_ms = 60000;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    var db_held = true;
    defer if (db_held) app.releaseDb(db);
    if (filter_spec) |spec| {
        validateFilterExists(db, res.arena, spec) catch |e| {
            return switch (e) {
                error.FilterNotFound => err(res, 404, "not_found", "missing filter"),
                else => e,
            };
        };
    }
    const last: u64 = if (since_arg) |v|
        (if (std.mem.eql(u8, v, "now")) db.seq else (std.fmt.parseInt(u64, v, 10) catch 0))
    else
        0;
    app.releaseDb(db);
    db_held = false;

    const active = app.feed_threads.fetchAdd(1, .monotonic);
    if (active >= app.max_feeds) {
        _ = app.feed_threads.fetchSub(1, .monotonic);
        return err(res, 503, "service_unavailable", "too many active feeds");
    }
    var feed_owned = true;
    errdefer {
        if (feed_owned) _ = app.feed_threads.fetchSub(1, .monotonic);
    }

    const alloc = std.heap.page_allocator;
    const filter_copy: ?[]u8 = if (filter_spec) |f| try alloc.dupe(u8, f) else null;
    errdefer if (filter_copy) |f| alloc.free(f);
    const query_copy: ?[]u8 = if (filter_spec != null) try buildQueryJson(alloc, req) else null;
    errdefer if (query_copy) |fq| alloc.free(fq);
    const ctx = try alloc.create(ContinuousCtx);
    errdefer alloc.destroy(ctx);
    const stream = try startJsonChunked(res);
    setSocketTimeout(stream.socket.handle, std.posix.SO.SNDTIMEO, 1);
    ctx.* = .{
        .app = app,
        .db = db,
        .io = app.io,
        .alloc = alloc,
        .stream = stream,
        .last = last,
        .include_docs = include_docs,
        .style_all = style_all,
        .timeout_ms = timeout_ms,
        .filter_spec = filter_copy,
        .filter_query_json = query_copy,
    };
    app.feed_mutex.lockUncancelable(app.io);
    // The database may have been deleted while this request was preparing its
    // stream. Registering now would hand the scheduler a pointer to a freed
    // Db, so re-check that the handle we captured is still the live one.
    app.mutex.lockUncancelable(app.io);
    const still_live = app.dbs.get(name) == db;
    app.mutex.unlock(app.io);
    if (!still_live) {
        app.feed_mutex.unlock(app.io);
        stream.close(app.io);
        return err(res, 409, "conflict", "Database was deleted");
    }
    app.continuous.append(app.alloc, ctx) catch {
        app.feed_mutex.unlock(app.io);
        stream.close(app.io);
        return error.NoSpaceLeft;
    };
    app.feed_mutex.unlock(app.io);
    feed_owned = false;
}

fn sleepMs(io: Io, ms: u64) void {
    std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

const LongpollCtx = struct {
    app: *App,
    db: *Db,
    io: Io,
    alloc: std.mem.Allocator,
    stream: std.Io.net.Stream,
    baseline: u64,
    limit: usize,
    include_docs: bool,
    style_all: bool,
    timeout_ms: usize,
    filter_spec: ?[]u8,
    filter_query_json: ?[]u8 = null,
    elapsed: usize = 0,
    in_flight: bool = false,
    closing: bool = false,
};

fn startJsonChunked(res: *httpz.Response) !std.Io.net.Stream {
    res.content_type = .JSON;
    res.chunked = true;
    res.keepalive = false;
    const conn = res.conn;
    const stream = conn.stream;
    try conn.blockingMode();
    try res.writeHeader();
    try conn.writeAll("\r\n");
    try res.disown();
    return stream;
}

fn writeChunkPart(stream: std.Io.net.Stream, io: Io, body: []const u8) bool {
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{x}\r\n", .{body.len}) catch return false;
    var w = stream.writer(io, &.{});
    w.interface.writeAll(header) catch return false;
    w.interface.writeAll(body) catch return false;
    w.interface.writeAll("\r\n") catch return false;
    return true;
}

fn finishChunks(stream: std.Io.net.Stream, io: Io) void {
    var w = stream.writer(io, &.{});
    w.interface.writeAll("0\r\n\r\n") catch {};
}

fn writeChunk(stream: std.Io.net.Stream, io: Io, body: []const u8) void {
    if (!writeChunkPart(stream, io, body)) return;
    finishChunks(stream, io);
}

fn markReplicationState(
    alloc: std.mem.Allocator,
    rdb: *Db,
    doc: *const Doc,
    root: *std.json.Value,
    state: []const u8,
    reason: ?[]const u8,
    failures: u32,
) void {
    if (root.* != .object) return;
    root.object.put(alloc, "_replication_failures", .{ .integer = failures }) catch return;
    root.object.put(alloc, "_replication_state", .{ .string = state }) catch return;
    if (reason) |r| {
        root.object.put(alloc, "_replication_state_reason", .{ .string = r }) catch return;
    } else {
        root.object.put(alloc, "_replication_state_reason", .{ .string = "" }) catch return;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    jsonw.writeValue(&out, alloc, root.*) catch return;
    _ = rdb.putLocal(doc.id, out.items, doc.winnerLeaf().rev, false) catch {};
}

fn retryTicks(failures: u32) u64 {
    const shift: u6 = @intCast(@min(failures, 6));
    const seconds: u64 = @as(u64, 1) << shift;
    return @min(seconds, 30) * 2; // scheduler ticks are two seconds; cap at 60s
}

/// Builds the set of ids a replication should copy from `doc_ids` and/or a
/// `selector`. `db` is only needed for a selector against a local source, since
/// that has to be matched here; a remote source evaluates it in its own feed.
fn buildSelection(
    arena: std.mem.Allocator,
    db: ?*Db,
    doc_ids_v: ?std.json.Value,
    selector_v: ?std.json.Value,
) !replicator.IdFilter {
    var set: replicator.IdFilter = .empty;
    if (doc_ids_v) |dv| {
        if (dv != .array) return error.InvalidSelection;
        for (dv.array.items) |item| {
            if (item != .string) return error.InvalidSelection;
            try set.put(arena, try arena.dupe(u8, item.string), {});
        }
    }
    if (selector_v) |sel| {
        if (sel != .object) return error.InvalidSelection;
        if (findUnknownOperator(sel) != null) return error.InvalidSelection;
        const source_db = db orelse return error.InvalidSelection;
        source_db.lock();
        defer source_db.unlock();
        var it = source_db.docs.valueIterator();
        while (it.next()) |d| {
            var parsed_doc = std.json.parseFromSlice(std.json.Value, arena, d.*.winnerLeaf().body, .{}) catch continue;
            if (parsed_doc.value != .object) continue;
            try parsed_doc.value.object.put(arena, "_id", .{ .string = d.*.id });
            if (matchSelector(parsed_doc.value, sel)) {
                try set.put(arena, try arena.dupe(u8, d.*.id), {});
            }
        }
    }
    return set;
}

fn runReplicationJob(
    app: *App,
    root: *std.json.Value,
    diag: ?*replicator.Diag,
    stats: *ReplStats,
    stats_alloc: std.mem.Allocator,
) !void {
    if (root.* != .object) return error.InvalidReplicationDoc;
    const source_v = root.object.get("source") orelse return error.MissingSource;
    const target_v = root.object.get("target") orelse return error.MissingTarget;
    // A job may narrow what it copies; the selection lives with the job run.
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source_ep = parseEndpoint(arena, source_v) catch return error.InvalidReplicationDoc;
    const target_ep = parseEndpoint(arena, target_v) catch return error.InvalidReplicationDoc;
    const doc_ids_v = root.object.get("doc_ids");
    const selector_v = root.object.get("selector");
    const has_selection = doc_ids_v != null or selector_v != null;
    // `use_checkpoints: false` means a repeat starts from the beginning: no
    // `_local` revision is read or written. `worker_batch_size` is how many
    // documents a page carries.
    const use_checkpoints: bool = if (root.object.get("use_checkpoints")) |v| (if (v == .bool) v.bool else true) else true;
    const page_size: usize = if (root.object.get("worker_batch_size")) |v|
        (if (v == .integer and v.integer > 0) @intCast(v.integer) else 500)
    else
        500;
    var since_seq: ?[]const u8 = null;
    if (root.object.get("since_seq")) |sv| {
        since_seq = switch (sv) {
            .string => sv.string,
            .integer => try std.fmt.allocPrint(arena, "{d}", .{sv.integer}),
            else => return error.InvalidReplicationDoc,
        };
    }

    const target_is_url = target_ep.is_url;
    if (target_is_url) {
        if (source_ep.is_url) {
            // Remote to remote, the only shape CouchDB accepts in a replication
            // document. The changes come into a staging database here and are
            // pushed on to the target; the staging copy is dropped afterwards.
            const stage_name = try std.fmt.allocPrint(arena, "repl_stage_{x}", .{
                std.hash.Wyhash.hash(0, source_ep.raw_url) ^ std.hash.Wyhash.hash(1, target_ep.raw_url),
            });
            const stage = blk: {
                app.mutex.lockUncancelable(app.io);
                defer app.mutex.unlock(app.io);
                break :blk app.createDb(stage_name) catch |e| switch (e) {
                    error.InvalidName => return error.InvalidReplicationDoc,
                    else => return e,
                };
            };
            defer _ = app.deleteDb(stage_name) catch {};

            var remote_selection = replicator.IdFilter{};
            if (has_selection) {
                remote_selection = buildSelection(arena, null, doc_ids_v, selector_v) catch |e| {
                    if (diag) |d| d.set("invalid selection: {s}", .{@errorName(e)});
                    return error.InvalidReplicationDoc;
                };
            }
            var remote_selector: ?[]const u8 = null;
            if (selector_v) |sel| {
                if (sel != .object) return error.InvalidReplicationDoc;
                var sel_buf: std.ArrayListUnmanaged(u8) = .empty;
                try jsonw.writeValue(&sel_buf, arena, sel);
                remote_selector = sel_buf.items;
            }
            const remote_filter: ?[]const u8 = if (root.object.get("filter")) |fv|
                (if (fv == .string) fv.string else null)
            else
                null;
            // The checkpoint lives on the target, as CouchDB keeps it, so a
            // restart resumes instead of reading the whole source again. The
            // staging copy is dropped with the job and cannot hold it.
            const remote_cp_id = try replicator.checkpointDocIdFor(app.alloc, .{
                .source = source_ep.clean_url,
                .target = target_ep.clean_url,
                .filter = remote_filter,
                .doc_ids = if (doc_ids_v != null) &remote_selection else null,
                .selector = remote_selector,
                .since_seq = since_seq,
            });
            defer app.alloc.free(remote_cp_id);
            const remote_auth: ?[]const u8 = if (target_ep.user) |u|
                try replicator.basicAuthHeader(app.alloc, u, target_ep.password orelse "")
            else
                null;
            defer if (remote_auth) |a| app.alloc.free(a);
            const remote_cp: ?replicator.RemoteCheckpoint = if (use_checkpoints and since_seq == null)
                replicator.readRemoteCheckpoint(app.alloc, app.io, target_ep.clean_url, remote_auth, remote_cp_id)
            else
                null;
            defer if (remote_cp) |c| c.deinit(app.alloc);

            const remote_pull = try replicator.pullInto(app.alloc, app.io, stage, .{
                .source = source_ep.clean_url,
                .since = since_seq orelse if (remote_cp) |c| c.since else null,
                .page_size = page_size,
                // The staging DB is dropped with the job, and its seq numbers
                // restart each run. A checkpoint taken in that domain would
                // skip later documents on resume, so the inner stages run
                // without checkpoints and the target checkpoint above owns
                // resume (in source-seq terms) for the whole job.
                .use_checkpoints = false,
                .target_path = "",
                .max_attachment_bytes = app.max_body_bytes,
                .username = source_ep.user,
                .password = source_ep.password,
                .filter = remote_filter,
                .selector = remote_selector,
                .doc_ids = if (doc_ids_v != null) &remote_selection else null,
                .diag = diag,
                .lock = ReplLock.lockFn,
                .unlock = ReplLock.unlockFn,
                .lock_ctx = stage,
            });
            defer if (remote_pull.end_seq) |e| app.alloc.free(e);
            defer if (remote_pull.start_seq) |e| app.alloc.free(e);
            const pushed = try replicator.pushIntoWithOptions(app.alloc, app.io, stage, .{
                .target = target_ep.clean_url,
                .username = target_ep.user,
                .password = target_ep.password,
                .diag = diag,
                .guard = replGuard(stage),
                .doc_ids = if (has_selection) &remote_selection else null,
                .use_checkpoints = false,
                .worker_batch_size = page_size,
                // Stage seqs restart each run, so the source since_seq (in
                // source-seq terms) cannot gate the push. Push the whole stage.
                .since = null,
                .source_name = source_ep.raw_url,
            });
            defer if (pushed.end_seq) |e| app.alloc.free(e);
            stats.* = .{
                .revisions_checked = remote_pull.changes_seen,
                .bulk_get_attempts = remote_pull.bulk_get_attempts,
                .bulk_get_docs = remote_pull.bulk_get_docs,
                .docs_read = remote_pull.documents,
                .docs_written = pushed.pushed,
                .doc_write_failures = pushed.failed,
                .checkpointed_source_seq = if (remote_pull.end_seq) |e| try stats_alloc.dupe(u8, e) else null,
            };
            if (use_checkpoints) {
                if (remote_pull.end_seq) |seq| {
                    replicator.writeRemoteCheckpoint(app.alloc, app.io, target_ep.clean_url, remote_auth, remote_cp_id, seq, if (remote_cp) |c| c.rev else null) catch |e| {
                        if (diag) |d| d.set("checkpoint not saved on the target: {s}", .{@errorName(e)});
                    };
                }
            }
            return;
        }
        const source_db = app.pinDb(source_ep.raw_url) catch |e| switch (e) {
            error.DatabaseInUse => return error.DatabaseInUse,
            else => return error.SourceDatabaseNotFound,
        };
        defer app.unpinReplication(source_db);
        var selection = replicator.IdFilter{};
        if (has_selection) {
            selection = buildSelection(arena, source_db, doc_ids_v, selector_v) catch |e| {
                if (diag) |d| d.set("invalid selection: {s}", .{@errorName(e)});
                return error.InvalidReplicationDoc;
            };
        }
        const pushed = try replicator.pushIntoWithOptions(app.alloc, app.io, source_db, .{
            .target = target_ep.clean_url,
            .username = target_ep.user,
            .password = target_ep.password,
            .diag = diag,
            .guard = replGuard(source_db),
            .doc_ids = if (has_selection) &selection else null,
            .use_checkpoints = use_checkpoints,
            .worker_batch_size = page_size,
            .since = since_seq,
            .source_name = source_ep.raw_url,
        });
        defer if (pushed.end_seq) |e| app.alloc.free(e);
        stats.* = .{
            .revisions_checked = pushed.checked,
            .docs_read = pushed.pushed,
            .docs_written = pushed.pushed,
            .doc_write_failures = pushed.failed,
            .checkpointed_source_seq = if (pushed.end_seq) |e| try stats_alloc.dupe(u8, e) else null,
        };
    } else {
        if (root.object.get("create_target")) |ct| {
            if (ct == .bool and ct.bool) {
                app.mutex.lockUncancelable(app.io);
                const created = app.createDb(target_ep.raw_url);
                app.mutex.unlock(app.io);
                _ = created catch |e| switch (e) {
                    error.InvalidName => return error.InvalidReplicationDoc,
                    else => return e,
                };
            }
        }
        const target = app.pinDb(target_ep.raw_url) catch |e| switch (e) {
            error.DatabaseInUse => return error.DatabaseInUse,
            else => return error.TargetDatabaseNotFound,
        };
        defer app.unpinReplication(target);
        // Two database names mean a local copy, which CouchDB's `_replicator`
        // accepts too; there is no URL to parse in that case.
        if (!source_ep.is_url) {
            if (std.mem.eql(u8, source_ep.raw_url, target_ep.raw_url)) return error.InvalidReplicationDoc;
            const src = app.pinDb(source_ep.raw_url) catch |e| switch (e) {
                error.DatabaseInUse => return error.DatabaseInUse,
                else => return error.SourceDatabaseNotFound,
            };
            defer app.unpinReplication(src);
            var selection = replicator.IdFilter{};
            if (has_selection) {
                selection = buildSelection(arena, src, doc_ids_v, selector_v) catch |e| {
                    if (diag) |d| d.set("invalid selection: {s}", .{@errorName(e)});
                    return error.InvalidReplicationDoc;
                };
            }
            const pulled = try replicator.pullLocal(app.alloc, src, target, .{
                .source_name = source_ep.raw_url,
                .use_checkpoints = use_checkpoints,
                .page_size = page_size,
                .doc_ids = if (has_selection) &selection else null,
                .diag = diag,
                .lock = ReplLock.lockFn,
                .unlock = ReplLock.unlockFn,
                .lock_ctx = target,
                .source_guard = replGuard(src),
            });
            if (std.mem.eql(u8, target_ep.raw_url, "_users")) app.invalidateUsersCache();
            stats.* = .{
                .revisions_checked = pulled.changes_seen,
                .bulk_get_attempts = pulled.bulk_get_attempts,
                .bulk_get_docs = pulled.bulk_get_docs,
                .docs_read = pulled.documents,
                .docs_written = pulled.documents,
                .doc_write_failures = pulled.doc_write_failures,
                .checkpointed_source_seq = if (pulled.end_seq) |e| try stats_alloc.dupe(u8, e) else null,
            };
            return;
        }
        const filter: ?[]const u8 = if (root.object.get("filter")) |fv| blk: {
            if (fv == .string) break :blk fv.string;
            break :blk null;
        } else null;
        var selection = replicator.IdFilter{};
        if (doc_ids_v != null) {
            selection = buildSelection(arena, null, doc_ids_v, null) catch return error.InvalidReplicationDoc;
        }
        var selector_text: ?[]const u8 = null;
        if (selector_v) |sel| {
            if (sel != .object) return error.InvalidReplicationDoc;
            var sel_buf: std.ArrayListUnmanaged(u8) = .empty;
            try jsonw.writeValue(&sel_buf, arena, sel);
            selector_text = sel_buf.items;
        }
        const pulled = try replicator.pullInto(app.alloc, app.io, target, .{
            .source = source_ep.clean_url,
            .target_path = "",
            .checkpoint_target = try std.fmt.allocPrint(arena, "{s}:{s}", .{ target_ep.raw_url, &target.uuid }),
            .max_attachment_bytes = app.max_body_bytes,
            .username = source_ep.user,
            .password = source_ep.password,
            .filter = filter,
            .since = since_seq,
            .selector = selector_text,
            .page_size = page_size,
            .use_checkpoints = use_checkpoints,
            .doc_ids = if (doc_ids_v != null) &selection else null,
            .diag = diag,
            .lock = ReplLock.lockFn,
            .unlock = ReplLock.unlockFn,
            .lock_ctx = target,
        });
        if (std.mem.eql(u8, target_ep.raw_url, "_users")) app.invalidateUsersCache();
        stats.* = .{
            .revisions_checked = pulled.changes_seen,
            .bulk_get_attempts = pulled.bulk_get_attempts,
            .bulk_get_docs = pulled.bulk_get_docs,
            .docs_read = pulled.documents,
            .docs_written = pulled.documents,
            .doc_write_failures = pulled.doc_write_failures,
            .checkpointed_source_seq = if (pulled.end_seq) |e| try stats_alloc.dupe(u8, e) else null,
        };
    }
}

fn compactionScheduler(app: *App) void {
    var tick: u64 = 0;
    while (true) {
        sleepMs(app.io, 1000);
        if (app.auto_compact_secs == 0) continue;
        tick +%= 1;
        if (tick % app.auto_compact_secs != 0) continue;
        app.mutex.lockUncancelable(app.io);
        var names: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (names.items) |n| app.alloc.free(n);
            names.deinit(app.alloc);
        }
        var it = app.dbs.iterator();
        while (it.next()) |entry| {
            const db = entry.value_ptr.*;
            if (db.seq == 0) continue;
            if ((app.auto_compact_seq.get(entry.key_ptr.*) orelse 0) == db.seq) continue;
            const copy = app.alloc.dupe(u8, entry.key_ptr.*) catch continue;
            names.append(app.alloc, copy) catch {
                app.alloc.free(copy);
                continue;
            };
        }
        app.mutex.unlock(app.io);

        for (names.items) |db_name| {
            const db = (app.acquireDb(db_name) catch continue) orelse continue;
            const task_pid = app.beginTask("database_compaction", db_name, null, null, null, null, db.seq);
            defer app.endTask(task_pid);
            const seq = db.seq;
            const ok = if (db.compactSegments()) |_| true else |_| false;
            app.releaseDb(db);
            if (ok) {
                app.updateTask(task_pid, seq, seq);
                app.mutex.lockUncancelable(app.io);
                app.recordAutoCompact(db_name, seq, tick);
                app.mutex.unlock(app.io);
            }
        }
    }
}

const ReplJob = struct {
    id: []u8,
    rev: Rev,
    body: []u8,
    is_continuous: bool,
    state_is_error: bool,
};

/// Runs `_replicator` documents. Each job runs with the app mutex released: a
/// pull or push can take minutes and holding the lock for it froze every other
/// request. The due jobs are copied out under the lock first, because the
/// document iterator cannot survive an unlock, and their state is written back
/// under it afterwards.
/// The counters CouchDB publishes in `_scheduler/docs` under `info`.
const ReplStats = struct {
    revisions_checked: usize = 0,
    bulk_get_attempts: usize = 0,
    bulk_get_docs: usize = 0,
    missing_revisions_found: usize = 0,
    docs_read: usize = 0,
    docs_written: usize = 0,
    doc_write_failures: usize = 0,
    checkpointed_source_seq: ?[]const u8 = null,
};

const RunningJob = struct {
    /// The `_replicator` document id.
    id: ?[]const u8,
    /// CouchDB's replication id: a hash of the endpoints, plus `+continuous`
    /// because a document-driven job repeats.
    repl_id: ?[]const u8,
    source: ?[]const u8,
    target: ?[]const u8,
    started: u64,
};

/// CouchDB reports times as ISO 8601 in UTC with no fractional part.
fn isoTimestamp(alloc: std.mem.Allocator, epoch: u64) ![]const u8 {
    const days: i64 = @intCast(epoch / 86400);
    const secs: u64 = epoch % 86400;
    // days -> civil date, Howard Hinnant's civil_from_days.
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(year)), @as(u64, @intCast(m)), @as(u64, @intCast(d)),
        secs / 3600,              (secs % 3600) / 60,    secs % 60,
    });
}

/// CouchDB's replication id for a document-driven job: an opaque hash of the
/// endpoints and options, suffixed `+continuous`.
fn replicationId(alloc: std.mem.Allocator, source: []const u8, target: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.Md5.init(.{});
    hasher.update(source);
    hasher.update("\n");
    hasher.update(target);
    var digest: [16]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.allocPrint(alloc, "{x}", .{digest}) catch return error.OutOfMemory;
    defer alloc.free(hex);
    return std.fmt.allocPrint(alloc, "{s}+continuous", .{hex});
}

const max_concurrent_repl_jobs: usize = 4;

fn freeRunningJob(alloc: std.mem.Allocator, r: RunningJob) void {
    if (r.id) |id| alloc.free(@constCast(id));
    if (r.repl_id) |id| alloc.free(@constCast(id));
    if (r.source) |src| alloc.free(@constCast(src));
    if (r.target) |tgt| alloc.free(@constCast(tgt));
}

fn isJobRunningLocked(app: *const App, id: []const u8) bool {
    for (app.repl_running.items) |r| {
        if (r.id) |rid| {
            if (std.mem.eql(u8, rid, id)) return true;
        }
    }
    return false;
}

fn registerRunningJobLocked(app: *App, job: ReplJob) bool {
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    var started_root = std.json.parseFromSlice(std.json.Value, arena.allocator(), job.body, .{}) catch null;
    const started_source = if (started_root) |*sr| (if (sr.value == .object) sr.value.object.get("source") else null) else null;
    const started_target = if (started_root) |*sr| (if (sr.value == .object) sr.value.object.get("target") else null) else null;
    const id_copy = app.alloc.dupe(u8, job.id) catch return false;
    errdefer app.alloc.free(id_copy);
    const repl_id = blk: {
        const sv = started_source orelse break :blk null;
        const tv = started_target orelse break :blk null;
        if (sv != .string or tv != .string) break :blk null;
        break :blk replicationId(app.alloc, sv.string, tv.string) catch null;
    };
    errdefer if (repl_id) |rid| app.alloc.free(@constCast(rid));
    const src_red = if (started_source) |sv| redactEndpoint(app.alloc, sv) catch null else null;
    errdefer if (src_red) |sr| app.alloc.free(@constCast(sr));
    const tgt_red = if (started_target) |tv| redactEndpoint(app.alloc, tv) catch null else null;
    errdefer if (tgt_red) |tr| app.alloc.free(@constCast(tr));
    app.repl_running.append(app.alloc, .{
        .id = id_copy,
        .repl_id = repl_id,
        .source = src_red,
        .target = tgt_red,
        .started = @intCast(@divTrunc(Io.Timestamp.now(app.io, .real).nanoseconds, std.time.ns_per_s)),
    }) catch return false;
    return true;
}

fn removeRunningJob(app: *App, id: []const u8) void {
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    for (app.repl_running.items, 0..) |r, idx| {
        if (r.id) |rid| {
            if (std.mem.eql(u8, rid, id)) {
                freeRunningJob(app.alloc, r);
                _ = app.repl_running.orderedRemove(idx);
                return;
            }
        }
    }
}

fn replicatorScheduler(app: *App) void {
    var tick: u64 = 0;
    var jobs: std.ArrayListUnmanaged(ReplJob) = .empty;
    defer jobs.deinit(app.alloc);
    while (true) {
        sleepMs(app.io, 2000);
        tick +%= 1;
        jobs.clearRetainingCapacity();

        if (app.acquireDb("_replicator") catch null) |rdb| {
            defer app.releaseDb(rdb);
            // db.mutex, then app.mutex: the same order `acquireDb` callers use
            // when they look up another database while holding their own.
            app.mutex.lockUncancelable(app.io);
            defer app.mutex.unlock(app.io);
            const slots = max_concurrent_repl_jobs -| app.repl_running.items.len;
            if (slots > 0) collectDueJobs(app, rdb, &jobs, tick, slots);
            // Register all picked jobs before releasing app.mutex so the next
            // tick cannot start a second worker for the same document.
            var w: usize = 0;
            for (jobs.items) |job| {
                if (registerRunningJobLocked(app, job)) {
                    jobs.items[w] = job;
                    w += 1;
                } else {
                    app.alloc.free(job.id);
                    app.alloc.free(job.body);
                }
            }
            jobs.shrinkRetainingCapacity(w);
        }

        for (jobs.items) |job| {
            const t = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, runJobThread, .{ app, job, tick }) catch {
                removeRunningJob(app, job.id);
                app.alloc.free(job.id);
                app.alloc.free(job.body);
                continue;
            };
            t.detach();
        }
    }
}

fn collectDueJobs(app: *App, rdb: *Db, jobs: *std.ArrayListUnmanaged(ReplJob), tick: u64, max_jobs: usize) void {
    var it = rdb.docs.valueIterator();
    while (it.next()) |entry| {
        if (jobs.items.len >= max_jobs) break;
        const doc = entry.*;
        const leaf = doc.winnerLeaf();
        if (leaf.deleted) continue;
        if (app.repl_done.get(doc.id)) |done_rev| {
            if (done_rev.eql(leaf.rev)) continue;
        }
        if (isJobRunningLocked(app, doc.id)) continue;
        const body = leaf.body;
        var parsed = std.json.parseFromSlice(std.json.Value, app.alloc, body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        var state_is_error = false;
        if (parsed.value.object.get("_replication_state")) |sv| {
            if (sv == .string) {
                if (std.mem.eql(u8, sv.string, "completed")) continue;
                state_is_error = std.mem.eql(u8, sv.string, "error");
            }
        }
        var persisted_failures: u32 = 0;
        if (parsed.value.object.get("_replication_failures")) |fv| {
            if (fv == .integer and fv.integer > 0) {
                persisted_failures = @intCast(@min(fv.integer, 1_000_000));
            }
        }
        if (persisted_failures > 0 and app.repl_retry.get(doc.id) == null) {
            const key = app.alloc.dupe(u8, doc.id) catch continue;
            app.repl_retry.put(app.alloc, key, .{
                .failures = persisted_failures,
                .next_tick = tick + retryTicks(persisted_failures),
            }) catch app.alloc.free(key);
        }
        if (app.repl_retry.get(doc.id)) |retry| {
            if (tick < retry.next_tick) continue;
        }
        var is_continuous = false;
        if (parsed.value.object.get("continuous")) |cv| {
            if (cv == .bool) is_continuous = cv.bool;
        }
        const id_copy = app.alloc.dupe(u8, doc.id) catch continue;
        const body_copy = app.alloc.dupe(u8, body) catch {
            app.alloc.free(id_copy);
            continue;
        };
        jobs.append(app.alloc, .{
            .id = id_copy,
            .rev = leaf.rev,
            .body = body_copy,
            .is_continuous = is_continuous,
            .state_is_error = state_is_error,
        }) catch {
            app.alloc.free(id_copy);
            app.alloc.free(body_copy);
        };
    }
}

fn runJobThread(app: *App, job: ReplJob, tick: u64) void {
    defer {
        removeRunningJob(app, job.id);
        app.alloc.free(job.id);
        app.alloc.free(job.body);
    }
    runJob(app, job, tick);
}

fn runJob(app: *App, job: ReplJob, tick: u64) void {
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    var started_root = std.json.parseFromSlice(std.json.Value, arena.allocator(), job.body, .{}) catch null;
    defer if (started_root) |*r| r.deinit();
    const task_src = if (started_root) |sr| (if (sr.value == .object) (if (sr.value.object.get("source")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const task_tgt = if (started_root) |sr| (if (sr.value == .object) (if (sr.value.object.get("target")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const repl_task_pid = app.beginTask("replication", "_replicator", null, task_src, task_tgt, job.id, 0);
    defer app.endTask(repl_task_pid);
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), job.body, .{}) catch return;
    if (parsed.value != .object) return;
    var diag: replicator.Diag = .{ .alloc = arena.allocator() };

    var stats: ReplStats = .{};
    if (runReplicationJob(app, &parsed.value, &diag, &stats, arena.allocator())) |_| {
        if (!job.is_continuous) {
            recordReplicationStats(arena.allocator(), &parsed.value, stats);
            markJobState(app, arena.allocator(), job, &parsed.value, "completed", null, 0);
        } else if (job.state_is_error) {
            markJobState(app, arena.allocator(), job, &parsed.value, "triggered", null, 0);
        }
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        if (app.repl_retry.fetchRemove(job.id)) |old| app.alloc.free(old.key);
        if (!job.is_continuous) {
            const key = app.alloc.dupe(u8, job.id) catch return;
            if (app.repl_done.fetchRemove(job.id)) |old| app.alloc.free(old.key);
            app.repl_done.put(app.alloc, key, job.rev) catch app.alloc.free(key);
        }
    } else |e| {
        const failures: u32 = blk: {
            app.mutex.lockUncancelable(app.io);
            defer app.mutex.unlock(app.io);
            const f: u32 = if (app.repl_retry.get(job.id)) |retry| retry.failures + 1 else 1;
            if (app.repl_retry.fetchRemove(job.id)) |old| app.alloc.free(old.key);
            const key = app.alloc.dupe(u8, job.id) catch break :blk f;
            app.repl_retry.put(app.alloc, key, .{
                .failures = f,
                .next_tick = tick + retryTicks(f),
            }) catch app.alloc.free(key);
            break :blk f;
        };
        markJobState(app, arena.allocator(), job, &parsed.value, "error", diag.message orelse @errorName(e), failures);
    }
}

/// Record the counters CouchDB publishes in `_scheduler/docs` under `info`, so a
/// finished job reports what it did instead of an empty object.
fn recordReplicationStats(alloc: std.mem.Allocator, root: *std.json.Value, stats: ReplStats) void {
    if (root.* != .object) return;
    var obj: std.json.ObjectMap = .empty;
    obj.put(alloc, "revisions_checked", .{ .integer = @intCast(stats.revisions_checked) }) catch return;
    // Every document read was one the target did not have, which is CouchDB's
    // meaning for this counter.
    obj.put(alloc, "missing_revisions_found", .{ .integer = @intCast(stats.docs_read) }) catch return;
    obj.put(alloc, "docs_read", .{ .integer = @intCast(stats.docs_read) }) catch return;
    obj.put(alloc, "docs_written", .{ .integer = @intCast(stats.docs_written) }) catch return;
    obj.put(alloc, "changes_pending", .null) catch return;
    obj.put(alloc, "doc_write_failures", .{ .integer = @intCast(stats.doc_write_failures) }) catch return;
    obj.put(alloc, "bulk_get_attempts", .{ .integer = @intCast(stats.bulk_get_attempts) }) catch return;
    obj.put(alloc, "bulk_get_docs", .{ .integer = @intCast(stats.bulk_get_docs) }) catch return;
    if (stats.checkpointed_source_seq) |seq| {
        obj.put(alloc, "checkpointed_source_seq", .{ .string = seq }) catch return;
    } else {
        obj.put(alloc, "checkpointed_source_seq", .null) catch return;
    }
    root.object.put(alloc, "_replication_stats", .{ .object = obj }) catch return;
}

/// Persist a job's state. Takes `_replicator`'s lock itself: it reads and
/// rewrites the `_replicator` document. The caller must not hold `app.mutex`.
fn markJobState(app: *App, alloc: std.mem.Allocator, job: ReplJob, root: *std.json.Value, state: []const u8, reason: ?[]const u8, failures: u32) void {
    const rdb = (app.acquireDb("_replicator") catch null) orelse return;
    defer app.releaseDb(rdb);
    const doc = rdb.docs.get(job.id) orelse return;
    const leaf = doc.winnerLeaf();
    if (leaf.deleted or !leaf.rev.eql(job.rev)) return;
    markReplicationState(alloc, rdb, doc, root, state, reason, failures);
}

fn freeFilterIds(alloc: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void)) void {
    var it = ids.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    ids.deinit(alloc);
}

fn longpollScheduler(app: *App) void {
    const WorkItem = struct {
        is_longpoll: bool,
        lp: ?*LongpollCtx = null,
        cont: ?*ContinuousCtx = null,
        bytes: ?[]u8 = null,
        finish: bool = false,
        send_heartbeat: bool = false,
    };
    const max_feed_pending: usize = 4 * 1024 * 1024;
    var tick_arena = std.heap.ArenaAllocator.init(app.alloc);
    defer tick_arena.deinit();

    while (true) {
        sleepMs(app.io, 50);
        _ = tick_arena.reset(.retain_capacity);
        const alloc = tick_arena.allocator();
        var work: std.ArrayListUnmanaged(WorkItem) = .empty;

        // Phase 1: snapshot pending payloads under feed_mutex + per-Db mutex.
        app.feed_mutex.lockUncancelable(app.io);
        for (app.longpolls.items) |ctx| {
            if (ctx.in_flight or ctx.closing) continue;
            ctx.elapsed += 50;
            var body: ?[]u8 = null;
            var finished = false;

            ctx.db.lock();
            if (ctx.db.seq > ctx.baseline) {
                var filter_ids: ?std.StringHashMapUnmanaged(void) = null;
                var filter_failed = false;
                if (ctx.filter_spec) |spec| {
                    filter_ids = buildFilterIds(ctx.db, alloc, spec, ctx.baseline, ctx.filter_query_json) catch null;
                    filter_failed = filter_ids == null;
                }
                if (!filter_failed) {
                    if (filter_ids == null or filter_ids.?.count() > 0) {
                        body = renderChanges(alloc, ctx.db, ctx.baseline, ctx.limit, ctx.include_docs, ctx.style_all, filter_ids) catch null;
                    }
                    if (filter_ids) |*ids| freeFilterIds(alloc, ids);
                    finished = body != null;
                } else {
                    finished = true;
                }
            }
            if (!finished and ctx.elapsed >= ctx.timeout_ms) {
                var filter_ids: ?std.StringHashMapUnmanaged(void) = null;
                var filter_failed = false;
                if (ctx.filter_spec) |spec| {
                    filter_ids = buildFilterIds(ctx.db, alloc, spec, ctx.baseline, ctx.filter_query_json) catch null;
                    filter_failed = filter_ids == null;
                }
                if (!filter_failed) {
                    body = renderChanges(alloc, ctx.db, ctx.baseline, ctx.limit, ctx.include_docs, ctx.style_all, filter_ids) catch null;
                    if (filter_ids) |*ids| freeFilterIds(alloc, ids);
                }
                finished = true;
            }
            ctx.db.unlock();

            if (finished) {
                ctx.in_flight = true;
                work.append(alloc, .{
                    .is_longpoll = true,
                    .lp = ctx,
                    .bytes = body,
                    .finish = true,
                }) catch {
                    ctx.in_flight = false;
                };
            }
        }

        for (app.continuous.items) |ctx| {
            if (ctx.in_flight or ctx.closing) continue;
            ctx.elapsed += 50;
            var line: std.ArrayListUnmanaged(u8) = .empty;
            var finished = false;

            ctx.db.lock();
            if (ctx.db.seq > ctx.last) {
                var filter_ids: ?std.StringHashMapUnmanaged(void) = null;
                var filter_failed = false;
                if (ctx.filter_spec) |spec| {
                    filter_ids = buildFilterIds(ctx.db, alloc, spec, ctx.last, ctx.filter_query_json) catch null;
                    filter_failed = filter_ids == null;
                }
                if (filter_failed) {
                    finished = true;
                } else {
                    var arr: std.ArrayListUnmanaged(*Doc) = .empty;
                    defer arr.deinit(alloc);
                    var build_ok = true;
                    var it = ctx.db.docs.valueIterator();
                    while (it.next()) |d| {
                        if (d.*.seq <= ctx.last) continue;
                        if (filter_ids) |ids| {
                            if (!ids.contains(d.*.id)) continue;
                        }
                        arr.append(alloc, d.*) catch {
                            build_ok = false;
                            break;
                        };
                    }
                    if (build_ok) {
                        sortBySeq(arr.items);
                        for (arr.items) |d| {
                            appendChangeObject(ctx.db, &line, alloc, d, ctx.include_docs, ctx.style_all) catch {
                                build_ok = false;
                                break;
                            };
                            line.append(alloc, '\n') catch {
                                build_ok = false;
                                break;
                            };
                            if (line.items.len > max_feed_pending) {
                                finished = true;
                                break;
                            }
                        }
                    }
                    if (filter_ids) |*ids| freeFilterIds(alloc, ids);
                    if (build_ok) {
                        ctx.last = ctx.db.seq;
                    } else {
                        line.clearRetainingCapacity();
                    }
                }
            }
            ctx.db.unlock();

            if (ctx.elapsed >= ctx.timeout_ms) finished = true;
            const send_hb = line.items.len == 0 and !finished and ctx.elapsed % 1000 == 0;
            if (line.items.len > 0 or send_hb or finished) {
                ctx.in_flight = true;
                work.append(alloc, .{
                    .is_longpoll = false,
                    .cont = ctx,
                    .bytes = if (line.items.len > 0) line.items else null,
                    .finish = finished,
                    .send_heartbeat = send_hb,
                }) catch {
                    ctx.in_flight = false;
                };
            }
        }
        app.feed_mutex.unlock(app.io);

        if (work.items.len == 0) continue;

        // Phase 2: write to sockets with feed_mutex released so a stalled
        // consumer cannot block feed registration or other feeds/workers.
        for (work.items) |*item| {
            if (item.is_longpoll) {
                const ctx = item.lp.?;
                if (!ctx.closing) {
                    if (item.bytes) |b| writeChunk(ctx.stream, ctx.io, b);
                }
            } else {
                const ctx = item.cont.?;
                var write_ok = !ctx.closing;
                if (write_ok) {
                    if (item.bytes) |b| {
                        if (!writeChunkPart(ctx.stream, ctx.io, b)) write_ok = false;
                    } else if (item.send_heartbeat) {
                        if (!writeChunkPart(ctx.stream, ctx.io, "\n")) write_ok = false;
                    }
                    if (write_ok and item.finish) finishChunks(ctx.stream, ctx.io);
                }
                if (!write_ok) item.finish = true;
            }
        }

        // Phase 3: retire completed, failed, or closing contexts under feed_mutex.
        app.feed_mutex.lockUncancelable(app.io);
        for (work.items) |item| {
            if (item.is_longpoll) {
                const ctx = item.lp.?;
                ctx.in_flight = false;
                if (std.mem.indexOfScalar(*LongpollCtx, app.longpolls.items, ctx)) |idx| {
                    _ = app.longpolls.orderedRemove(idx);
                }
                ctx.stream.close(ctx.io);
                if (ctx.filter_spec) |f| ctx.alloc.free(f);
                if (ctx.filter_query_json) |fq| ctx.alloc.free(fq);
                ctx.alloc.destroy(ctx);
                _ = app.feed_threads.fetchSub(1, .monotonic);
            } else {
                const ctx = item.cont.?;
                ctx.in_flight = false;
                if (item.finish or ctx.closing) {
                    if (std.mem.indexOfScalar(*ContinuousCtx, app.continuous.items, ctx)) |idx| {
                        _ = app.continuous.orderedRemove(idx);
                    }
                    ctx.stream.close(ctx.io);
                    if (ctx.filter_spec) |f| ctx.alloc.free(f);
                    if (ctx.filter_query_json) |fq| ctx.alloc.free(fq);
                    ctx.alloc.destroy(ctx);
                    _ = app.feed_threads.fetchSub(1, .monotonic);
                }
            }
        }
        app.feed_mutex.unlock(app.io);
    }
}

fn hChangesLongpoll(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const since_arg = q(req, "since");
    const filter_spec = if (q(req, "filter")) |f| (if (f.len == 0) null else f) else null;
    const limit: usize = if (q(req, "limit")) |v| (std.fmt.parseInt(usize, v, 10) catch 0) else 0;
    const include_docs = if (q(req, "include_docs")) |v| std.mem.eql(u8, v, "true") else false;
    const style_all = if (q(req, "style")) |v| std.mem.eql(u8, v, "all_docs") else false;
    var timeout_ms: usize = if (q(req, "timeout")) |v| (std.fmt.parseInt(usize, v, 10) catch 25000) else 25000;
    if (timeout_ms == 0 or timeout_ms > 60000) timeout_ms = 60000;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    var db_held = true;
    defer if (db_held) app.releaseDb(db);
    if (filter_spec) |spec| {
        validateFilterExists(db, res.arena, spec) catch |e| {
            return switch (e) {
                error.FilterNotFound => err(res, 404, "not_found", "missing filter"),
                else => e,
            };
        };
    }
    const baseline: u64 = if (since_arg) |v|
        (if (std.mem.eql(u8, v, "now")) db.seq else (std.fmt.parseInt(u64, v, 10) catch 0))
    else
        0;
    app.releaseDb(db);
    db_held = false;

    const active = app.feed_threads.fetchAdd(1, .monotonic);
    if (active >= app.max_feeds) {
        _ = app.feed_threads.fetchSub(1, .monotonic);
        return err(res, 503, "service_unavailable", "too many active feeds");
    }
    var feed_owned = true;
    errdefer {
        if (feed_owned) _ = app.feed_threads.fetchSub(1, .monotonic);
    }

    const alloc = std.heap.page_allocator;
    const filter_copy: ?[]u8 = if (filter_spec) |f| try alloc.dupe(u8, f) else null;
    errdefer if (filter_copy) |f| alloc.free(f);
    const query_copy: ?[]u8 = if (filter_spec != null) try buildQueryJson(alloc, req) else null;
    errdefer if (query_copy) |fq| alloc.free(fq);
    const ctx = try alloc.create(LongpollCtx);
    errdefer alloc.destroy(ctx);
    const stream = try startJsonChunked(res);
    setSocketTimeout(stream.socket.handle, std.posix.SO.SNDTIMEO, 1);
    ctx.* = .{
        .app = app,
        .db = db,
        .io = app.io,
        .alloc = alloc,
        .stream = stream,
        .baseline = baseline,
        .limit = limit,
        .include_docs = include_docs,
        .style_all = style_all,
        .timeout_ms = timeout_ms,
        .filter_spec = filter_copy,
        .filter_query_json = query_copy,
    };
    app.feed_mutex.lockUncancelable(app.io);
    // See hChangesContinuous: refuse to publish a context whose database was
    // deleted while the response was being set up.
    app.mutex.lockUncancelable(app.io);
    const still_live = app.dbs.get(name) == db;
    app.mutex.unlock(app.io);
    if (!still_live) {
        app.feed_mutex.unlock(app.io);
        stream.close(app.io);
        return err(res, 409, "conflict", "Database was deleted");
    }
    app.longpolls.append(app.alloc, ctx) catch {
        app.feed_mutex.unlock(app.io);
        stream.close(app.io);
        return error.NoSpaceLeft;
    };
    app.feed_mutex.unlock(app.io);
    feed_owned = false;
}

fn appendChangeObject(
    db: *Db,
    l: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    d: *Doc,
    include_docs: bool,
    style_all: bool,
) !void {
    try l.appendSlice(alloc, "{\"seq\":");
    try appendInt(l, alloc, d.seq);
    try l.appendSlice(alloc, ",\"id\":");
    try jsonw.writeString(l, alloc, d.id);
    try l.appendSlice(alloc, ",\"changes\":[");
    if (style_all) {
        for (d.leaves.items, 0..) |leaf, j| {
            if (j != 0) try l.append(alloc, ',');
            var rb: [64]u8 = undefined;
            try l.appendSlice(alloc, "{\"rev\":");
            try jsonw.writeString(l, alloc, leaf.rev.write(&rb));
            try l.append(alloc, '}');
        }
    } else {
        var rb: [64]u8 = undefined;
        try l.appendSlice(alloc, "{\"rev\":");
        try jsonw.writeString(l, alloc, d.winnerLeaf().rev.write(&rb));
        try l.append(alloc, '}');
    }
    try l.append(alloc, ']');
    if (d.winnerLeaf().deleted) try l.appendSlice(alloc, ",\"deleted\":true");
    if (include_docs) {
        try l.appendSlice(alloc, ",\"doc\":");
        try writeDoc(db, l, alloc, d, d.winner, true, false, false);
    }
    try l.append(alloc, '}');
}

fn renderChanges(alloc: std.mem.Allocator, db: *Db, since: u64, limit: usize, include_docs: bool, style_all: bool, filter_ids: ?std.StringHashMapUnmanaged(void)) ![]u8 {
    var arr: std.ArrayListUnmanaged(*Doc) = .empty;
    defer arr.deinit(alloc);
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.seq > since) {
            if (filter_ids) |ids| {
                if (!ids.contains(d.*.id)) continue;
            }
            try arr.append(alloc, d.*);
        }
    }
    sortBySeq(arr.items);
    var truncated = false;
    if (limit > 0 and arr.items.len > limit) {
        arr.shrinkRetainingCapacity(limit);
        truncated = true;
    }

    var last_seq: u64 = db.seq;
    // A filtered page that hit the limit must resume at the last emitted
    // matching change, not at the end of the feed.
    if (arr.items.len > 0 and (filter_ids == null or truncated)) last_seq = arr.items[arr.items.len - 1].seq;
    var pending: usize = 0;
    if (filter_ids == null) {
        var pit = db.docs.valueIterator();
        while (pit.next()) |d| {
            if (d.*.seq > last_seq) pending += 1;
        }
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(alloc, "{\"results\":[");
    for (arr.items, 0..) |d, i| {
        if (i != 0) try l.append(alloc, ',');
        try appendChangeObject(db, &l, alloc, d, include_docs, style_all);
    }
    try l.appendSlice(alloc, "],\"last_seq\":");
    try appendInt(&l, alloc, last_seq);
    try l.appendSlice(alloc, ",\"pending\":");
    try appendInt(&l, alloc, pending);
    try l.append(alloc, '}');
    return l.toOwnedSlice(alloc);
}

fn writeChanges(
    db: *Db,
    res: *httpz.Response,
    since: u64,
    limit: usize,
    include_docs: bool,
    style_all: bool,
    filter_ids: ?std.StringHashMapUnmanaged(void),
    eventsource: bool,
) !void {
    const body = try renderChanges(res.arena, db, since, limit, include_docs, style_all, filter_ids);
    if (eventsource) {
        // `feed=eventsource` is `text/event-stream`: one `data:` frame per change,
        // rather than the JSON body the other feeds return.
        res.content_type = .EVENTS;
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch {
            res.body = "";
            return;
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        if (parsed.value == .object) {
            if (parsed.value.object.get("results")) |rows| {
                if (rows == .array) {
                    for (rows.array.items) |row| {
                        try out.appendSlice(res.arena, "data: ");
                        try jsonw.writeValue(&out, res.arena, row);
                        try out.appendSlice(res.arena, "\n\n");
                    }
                }
            }
        }
        res.body = out.items;
        return;
    }
    res.content_type = .JSON;
    res.body = body;
}

fn queryJsonString(alloc: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return null;
    if (parsed.value != .string) return null;
    return parsed.value.string;
}

fn allDocsOptString(req: *httpz.Request, alloc: std.mem.Allocator, obj: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (q(req, key)) |v| return queryJsonString(alloc, v);
    if (obj) |o| {
        if (o.get(key)) |v| {
            if (v == .string) return v.string;
        }
    }
    return null;
}

fn hAllDocs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    var body_obj: ?std.json.ObjectMap = null;
    if (req.method == .POST) {
        const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
        if (body.len > 0) {
            const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
            if (root != .object) return err(res, 400, "bad_request", "JSON object required");
            body_obj = root.object;
        }
    }
    const include_docs = bodyOrQueryBool(req, body_obj, "include_docs", false);
    const limit: usize = bodyOrQueryUsize(req, body_obj, "limit", 0);
    const skip: usize = bodyOrQueryUsize(req, body_obj, "skip", 0);
    const descending = bodyOrQueryBool(req, body_obj, "descending", false);
    const inclusive_end = bodyOrQueryBool(req, body_obj, "inclusive_end", true);
    const key = allDocsOptString(req, res.arena, body_obj, "key");
    const startkey = allDocsOptString(req, res.arena, body_obj, "startkey");
    const endkey = allDocsOptString(req, res.arena, body_obj, "endkey");

    var keys_val: ?std.json.Value = null;
    if (body_obj) |o| {
        if (o.get("keys")) |kv| keys_val = kv;
    }
    if (keys_val == null) {
        if (q(req, "keys")) |kv| {
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, kv, .{}) catch
                return err(res, 400, "bad_request", "invalid keys");
            keys_val = parsed.value;
        }
    }
    if (keys_val) |kv| {
        if (kv != .array) return err(res, 400, "bad_request", "keys must be an array");
        for (kv.array.items) |item| {
            if (item != .string) return err(res, 400, "bad_request", "keys must be strings");
        }
        const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
        defer app.releaseDb(db);

        const total_keys = kv.array.items.len;
        const start = @min(skip, total_keys);
        var end = total_keys;
        if (limit > 0 and end - start > limit) end = start + limit;

        var l: std.ArrayListUnmanaged(u8) = .empty;
        try l.appendSlice(res.arena, "{\"total_rows\":");
        try appendInt(&l, res.arena, db.count());
        try l.appendSlice(res.arena, ",\"offset\":null,\"rows\":[");
        var i = start;
        var out_i: usize = 0;
        while (i < end) : (i += 1) {
            const kitem = kv.array.items[if (descending) (total_keys - 1 - i) else i];
            const k = kitem.string;
            if (out_i != 0) try l.append(res.arena, ',');
            out_i += 1;
            const doc = db.get(k);
            if (doc == null) {
                try l.appendSlice(res.arena, "{\"key\":");
                try jsonw.writeString(&l, res.arena, k);
                try l.appendSlice(res.arena, ",\"error\":\"not_found\"}");
                continue;
            }
            var rb: [64]u8 = undefined;
            try l.appendSlice(res.arena, "{\"id\":");
            try jsonw.writeString(&l, res.arena, doc.?.id);
            try l.appendSlice(res.arena, ",\"key\":");
            try jsonw.writeString(&l, res.arena, k);
            try l.appendSlice(res.arena, ",\"value\":{\"rev\":");
            try jsonw.writeString(&l, res.arena, doc.?.winnerLeaf().rev.write(&rb));
            if (doc.?.winnerLeaf().deleted) {
                try l.appendSlice(res.arena, ",\"deleted\":true},\"doc\":null");
            } else {
                try l.append(res.arena, '}');
                if (include_docs) {
                    try l.appendSlice(res.arena, ",\"doc\":");
                    try writeDoc(db, &l, res.arena, doc.?, doc.?.winner, true, false, false);
                }
            }
            try l.append(res.arena, '}');
        }
        try l.appendSlice(res.arena, "]}");
        res.content_type = .JSON;
        res.body = l.items;
        return;
    }

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var arr: std.ArrayListUnmanaged(*Doc) = .empty;
    defer arr.deinit(res.arena);
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (!d.*.winnerLeaf().deleted) try arr.append(res.arena, d.*);
    }
    sortById(arr.items);

    var filtered: std.ArrayListUnmanaged(*Doc) = .empty;
    defer filtered.deinit(res.arena);
    for (arr.items) |d| {
        if (key) |k| {
            if (!std.mem.eql(u8, d.id, k)) continue;
        } else if (!descending) {
            if (startkey) |sk| if (std.mem.lessThan(u8, d.id, sk)) continue;
            if (endkey) |ek| {
                if (inclusive_end) {
                    if (std.mem.lessThan(u8, ek, d.id)) continue;
                } else if (!std.mem.lessThan(u8, d.id, ek)) continue;
            }
        } else {
            if (startkey) |sk| if (std.mem.lessThan(u8, sk, d.id)) continue;
            if (endkey) |ek| {
                if (inclusive_end) {
                    if (std.mem.lessThan(u8, d.id, ek)) continue;
                } else if (!std.mem.lessThan(u8, ek, d.id)) continue;
            }
        }
        try filtered.append(res.arena, d);
    }
    if (descending) std.mem.reverse(*Doc, filtered.items);

    const total = arr.items.len;
    const start = @min(skip, filtered.items.len);
    var end = filtered.items.len;
    if (limit > 0 and end - start > limit) end = start + limit;

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"total_rows\":");
    try appendInt(&l, res.arena, total);
    try l.appendSlice(res.arena, ",\"offset\":");
    try appendInt(&l, res.arena, start);
    try l.appendSlice(res.arena, ",\"rows\":[");
    var i = start;
    while (i < end) : (i += 1) {
        if (i != start) try l.append(res.arena, ',');
        const d = filtered.items[i];
        var rb: [64]u8 = undefined;
        try l.appendSlice(res.arena, "{\"id\":");
        try jsonw.writeString(&l, res.arena, d.id);
        try l.appendSlice(res.arena, ",\"key\":");
        try jsonw.writeString(&l, res.arena, d.id);
        try l.appendSlice(res.arena, ",\"value\":{\"rev\":");
        try jsonw.writeString(&l, res.arena, d.winnerLeaf().rev.write(&rb));
        try l.append(res.arena, '}');
        if (include_docs) {
            try l.appendSlice(res.arena, ",\"doc\":");
            try writeDoc(db, &l, res.arena, d, d.winner, true, false, false);
        }
        try l.append(res.arena, '}');
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hRevsLimitGet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try appendInt(&l, res.arena, db.getRevsLimit());
    res.content_type = .JSON;
    res.body = l.items;
}

fn hRevsLimitPut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .integer or root.integer <= 0 or root.integer > 1_000_000) {
        return err(res, 400, "bad_request", "invalid revs limit");
    }
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    db.setRevsLimit(@intCast(root.integer)) catch |e| return e;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn hAllDocsKeys(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    return hAllDocs(app, req, res);
}

const VecHit = struct { doc: *Doc, score: f32 };
const SortHit = struct { doc: *Doc, key: ?std.json.Value, keys: []const ?std.json.Value = &.{} };
const SortSpec = struct { field: []const u8, desc: bool };

const VECTOR_MAGIC = "ZVEC0002";
const VecEntry = struct { id: []const u8, norm: f32, q: []const i8 };
const Quantized = struct { q: []i8, norm: f32 };

fn quantize(alloc: std.mem.Allocator, vec: []const f32) !Quantized {
    var max_abs: f32 = 0;
    for (vec) |v| max_abs = @max(max_abs, @abs(v));
    const scale: f32 = if (max_abs == 0) 1 else max_abs / 127.0;
    const qi = try alloc.alloc(i8, vec.len);
    var sumsq: f32 = 0;
    for (vec, 0..) |v, i| {
        const scaled = @round(v / scale);
        const clamped: f32 = @max(-127, @min(127, scaled));
        qi[i] = @intFromFloat(clamped);
        const qf: f32 = @floatFromInt(qi[i]);
        sumsq += qf * qf;
    }
    return .{ .q = qi, .norm = @sqrt(sumsq) };
}

fn quantizedCosine(query: Quantized, entry: VecEntry) ?f32 {
    if (query.q.len != entry.q.len) return null;
    if (query.norm == 0 or entry.norm == 0) return null;
    var dot: i32 = 0;
    for (query.q, entry.q) |a, b| dot += @as(i32, a) * @as(i32, b);
    return @as(f32, @floatFromInt(dot)) / (query.norm * entry.norm);
}

fn embeddingFromBody(alloc: std.mem.Allocator, body: []const u8, dim: usize) !?[]f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const ev = parsed.value.object.get("embedding_b64") orelse return null;
    if (ev != .string) return null;
    const n = std.base64.standard.Decoder.calcSizeForSlice(ev.string) catch return null;
    if (n != dim * 4) return null;
    const raw = try alloc.alloc(u8, n);
    defer alloc.free(raw);
    std.base64.standard.Decoder.decode(raw, ev.string) catch return null;
    const out = try alloc.alloc(f32, dim);
    for (out, 0..) |*v, i| {
        const bits = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        v.* = @bitCast(bits);
    }
    return out;
}

fn cosine(query: []const f32, vec: []const f32) ?f32 {
    if (query.len != vec.len) return null;
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (query, vec) |qv, dv| {
        dot += qv * dv;
        na += qv * qv;
        nb += dv * dv;
    }
    if (na == 0 or nb == 0) return null;
    return dot / (@sqrt(na) * @sqrt(nb));
}

/// Release entries produced by `loadVectorIndex`. The caller owns the slice,
/// every id and every quantised vector.
fn freeVectorEntries(alloc: std.mem.Allocator, entries: []VecEntry) void {
    for (entries) |e| {
        alloc.free(e.id);
        alloc.free(e.q);
    }
    alloc.free(entries);
}

fn freeVectorEntriesPartial(alloc: std.mem.Allocator, entries: []VecEntry, filled: usize) void {
    for (entries[0..filled]) |e| {
        alloc.free(e.id);
        alloc.free(e.q);
    }
    alloc.free(entries);
}

fn loadVectorIndex(db: *Db, alloc: std.mem.Allocator, dim: usize) !?[]VecEntry {
    const bytes = (try db.readVectorIndex()) orelse return null;
    // readVectorIndex() allocates on Db.alloc; the entries keep their own
    // copies of the ids so the file buffer can be released here.
    defer db.alloc.free(bytes);
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], VECTOR_MAGIC)) return null;
    const seq = std.mem.readInt(u64, bytes[8..16], .little);
    if (seq != db.seq) return null;
    const stored_dim = std.mem.readInt(u32, bytes[16..20], .little);
    if (stored_dim != dim) return null;
    const count = std.mem.readInt(u32, bytes[20..24], .little);
    const entries = try alloc.alloc(VecEntry, count);
    var filled: usize = 0;
    errdefer freeVectorEntriesPartial(alloc, entries, filled);
    var pos: usize = 24;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > bytes.len) {
            freeVectorEntriesPartial(alloc, entries, filled);
            return null;
        }
        const id_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (pos + id_len + 4 + dim > bytes.len) {
            freeVectorEntriesPartial(alloc, entries, filled);
            return null;
        }
        const id = try alloc.dupe(u8, bytes[pos .. pos + id_len]);
        errdefer alloc.free(id);
        pos += id_len;
        const norm_bits = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const norm: f32 = @bitCast(norm_bits);
        pos += 4;
        const qi = try alloc.alloc(i8, dim);
        errdefer alloc.free(qi);
        for (qi, 0..) |*v, j| v.* = @bitCast(bytes[pos + j]);
        pos += dim;
        entries[i] = .{ .id = id, .norm = norm, .q = qi };
        filled = i + 1;
    }
    return entries;
}

fn buildVectorIndex(db: *Db, alloc: std.mem.Allocator, dim: usize) !void {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    try b.appendSlice(alloc, VECTOR_MAGIC);
    try appendU64(&b, alloc, db.seq);
    try appendU32(&b, alloc, @intCast(dim));
    try appendU32(&b, alloc, 0);
    var count: u32 = 0;
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        const vec = (try embeddingFromBody(alloc, d.*.winnerLeaf().body, dim)) orelse continue;
        defer alloc.free(vec);
        const qz = try quantize(alloc, vec);
        defer alloc.free(qz.q);
        try appendU32(&b, alloc, @intCast(d.*.id.len));
        try b.appendSlice(alloc, d.*.id);
        try appendU32(&b, alloc, @bitCast(qz.norm));
        for (qz.q) |x| try b.append(alloc, @bitCast(x));
        count += 1;
    }
    std.mem.writeInt(u32, b.items[20..24], count, .little);
    try db.writeVectorIndex(b.items);
}

fn persistHnsw(app: *App, db: *Db, cache: *VectorCache) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.alloc);
    out.appendSlice(app.alloc, HNSW_FILE_MAGIC) catch return;
    appendU64(&out, app.alloc, cache.seq) catch return;
    appendU32(&out, app.alloc, @intCast(cache.ids.items.len)) catch return;
    for (cache.ids.items) |id| {
        appendU32(&out, app.alloc, @intCast(id.len)) catch return;
        out.appendSlice(app.alloc, id) catch return;
    }
    const graph = cache.index.serialize(app.alloc) catch return;
    defer app.alloc.free(graph);
    out.appendSlice(app.alloc, graph) catch return;
    db.writeHnswIndex(out.items) catch {};
}

fn checkVectorBudget(app: *App, vector_count: usize, dim: usize) !void {
    if (vector_count == 0 or app.vector_index_mb == 0) return;
    const budget = std.math.mul(usize, app.vector_index_mb, 1024 * 1024) catch std.math.maxInt(usize);
    const per_vec = dim * @sizeOf(f32) + 128;
    const est = std.math.mul(usize, vector_count, per_vec) catch return error.VectorIndexLimitExceeded;
    if (est > budget) return error.VectorIndexLimitExceeded;
}

fn appendNewHnswDocs(app: *App, db: *Db, cache: *VectorCache, dim: usize) !bool {
    if (cache.revs.items.len != cache.ids.items.len) return false;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(app.alloc);
    for (cache.ids.items) |id| try seen.put(app.alloc, id, {});
    for (cache.ids.items, cache.revs.items) |id, rev| {
        const d = db.get(id) orelse return false;
        const leaf = d.winnerLeaf();
        if (leaf.deleted or !leaf.rev.eql(rev)) return false;
    }
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        if (seen.contains(d.*.id)) continue;
        const vec = (try embeddingFromBody(app.alloc, d.*.winnerLeaf().body, dim)) orelse continue;
        defer app.alloc.free(vec);
        try checkVectorBudget(app, cache.ids.items.len + 1, dim);
        const id: u32 = @intCast(cache.ids.items.len);
        try cache.index.insert(id, vec);
        // `seen` above borrows the ids, so the cache holds its own copy.
        const owned_id = try app.alloc.dupe(u8, d.*.id);
        cache.ids.append(app.alloc, owned_id) catch |e| {
            app.alloc.free(owned_id);
            return e;
        };
        try cache.revs.append(app.alloc, d.*.winnerLeaf().rev);
    }
    return true;
}

fn hnswFor(app: *App, db: *Db, dim: usize, name: []const u8) !*VectorCache {
    const cache_key = try std.fmt.allocPrint(app.alloc, "{s}\x00{d}", .{ name, dim });
    errdefer app.alloc.free(cache_key);
    const existing: ?*VectorCache = blk: {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        break :blk app.vector_cache.get(cache_key);
    };
    if (existing) |cached| {
        if (cached.seq == db.seq and cached.dim == dim) {
            app.alloc.free(cache_key);
            return cached;
        }
        if (cached.seq < db.seq and cached.dim == dim and cached.revs.items.len == cached.ids.items.len) {
            if (try appendNewHnswDocs(app, db, cached, dim)) {
                cached.seq = db.seq;
                persistHnsw(app, db, cached);
                app.alloc.free(cache_key);
                return cached;
            }
        }
        app.mutex.lockUncancelable(app.io);
        const removed = app.vector_cache.fetchRemove(cache_key);
        app.mutex.unlock(app.io);
        if (removed) |old| {
            destroyVectorCache(app.alloc, old.value);
            app.alloc.free(old.key);
        }
    }

    if (try db.readHnswIndex()) |bytes| {
        defer db.alloc.free(bytes);
        if (loadHnswFile(app.alloc, bytes, dim)) |loaded| {
            var published = false;
            errdefer if (!published) destroyVectorCache(app.alloc, loaded);
            if (loaded.seq == db.seq) {
                var revs_ok = true;
                for (loaded.ids.items) |id| {
                    const d = db.get(id) orelse {
                        revs_ok = false;
                        break;
                    };
                    if (d.winnerLeaf().deleted) {
                        revs_ok = false;
                        break;
                    }
                    try loaded.revs.append(app.alloc, d.winnerLeaf().rev);
                }
                if (revs_ok) {
                    try checkVectorBudget(app, loaded.ids.items.len, dim);
                    app.mutex.lockUncancelable(app.io);
                    defer app.mutex.unlock(app.io);
                    if (app.vector_cache.fetchRemove(cache_key)) |old| {
                        destroyVectorCache(app.alloc, old.value);
                        app.alloc.free(old.key);
                    }
                    try app.vector_cache.put(app.alloc, cache_key, loaded);
                    published = true;
                    return loaded;
                }
            }
            destroyVectorCache(app.alloc, loaded);
            published = true;
        } else |e| {
            if (e == error.DimensionMismatch or e == error.InvalidVector) return e;
        }
    }

    const SnapVec = struct { id: []u8, rev: Rev, vec: []f32 };
    var snap_vecs: std.ArrayListUnmanaged(SnapVec) = .empty;
    defer {
        for (snap_vecs.items) |sv| {
            app.alloc.free(sv.id);
            app.alloc.free(sv.vec);
        }
        snap_vecs.deinit(app.alloc);
    }
    const snap_seq = db.seq;
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        const vec = (try embeddingFromBody(app.alloc, d.*.winnerLeaf().body, dim)) orelse continue;
        errdefer app.alloc.free(vec);
        const owned_id = try app.alloc.dupe(u8, d.*.id);
        errdefer app.alloc.free(owned_id);
        try snap_vecs.append(app.alloc, .{ .id = owned_id, .rev = d.*.winnerLeaf().rev, .vec = vec });
    }
    try checkVectorBudget(app, snap_vecs.items.len, dim);

    const cache = try app.alloc.create(VectorCache);
    cache.* = .{ .seq = snap_seq, .dim = dim, .index = Hnsw.init(app.alloc, dim) };
    errdefer destroyVectorCache(app.alloc, cache);

    // Release db.mutex while building the HNSW graph so concurrent DB reads/writes
    // are not blocked. db remains pinned by acquireDb.
    var mutex_held = false;
    db.unlock();
    defer if (!mutex_held) db.lock();

    const task_pid = app.beginTask("indexer", name, "_design/vector", null, null, null, snap_vecs.items.len);
    defer app.endTask(task_pid);

    for (snap_vecs.items, 0..) |sv, si| {
        const id: u32 = @intCast(cache.ids.items.len);
        cache.index.insert(id, sv.vec) catch |e| switch (e) {
            error.DimensionMismatch, error.InvalidVector => return e,
            else => continue,
        };
        const owned_id = try app.alloc.dupe(u8, sv.id);
        cache.ids.append(app.alloc, owned_id) catch |e| {
            app.alloc.free(owned_id);
            return e;
        };
        try cache.revs.append(app.alloc, sv.rev);
        if ((si & 63) == 63) app.updateTask(task_pid, si + 1, snap_vecs.items.len);
    }

    db.lock();
    mutex_held = true;

    if (db.seq == snap_seq) {
        persistHnsw(app, db, cache);
    }

    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    if (app.vector_cache.fetchRemove(cache_key)) |old| {
        destroyVectorCache(app.alloc, old.value);
        app.alloc.free(old.key);
    }
    try app.vector_cache.put(app.alloc, cache_key, cache);
    return cache;
}

fn vectorEntries(db: *Db, alloc: std.mem.Allocator, dim: usize) !?[]VecEntry {
    if (try loadVectorIndex(db, alloc, dim)) |entries| return entries;
    try buildVectorIndex(db, alloc, dim);
    return try loadVectorIndex(db, alloc, dim);
}

fn cosineFromBody(alloc: std.mem.Allocator, body: []const u8, query: []const f32) !?f32 {
    const vec = (try embeddingFromBody(alloc, body, query.len)) orelse return null;
    return cosine(query, vec);
}

fn hVectorSearch(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const started = Io.Timestamp.now(app.io, .awake);
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const k: usize = if (root.object.get("k")) |kv|
        (if (kv == .integer and kv.integer > 0) @intCast(@min(kv.integer, 1000)) else 10)
    else
        10;
    const include_docs = if (root.object.get("include_docs")) |iv| (iv == .bool and iv.bool) else false;
    const engine = if (root.object.get("engine")) |ev|
        (if (ev == .string) ev.string else return err(res, 400, "bad_request", "engine must be a string"))
    else
        "flat";
    if (!std.mem.eql(u8, engine, "flat") and !std.mem.eql(u8, engine, "hnsw")) {
        return err(res, 400, "bad_request", "engine must be 'flat' or 'hnsw'");
    }
    const ef: usize = if (root.object.get("ef")) |ev|
        (if (ev == .integer and ev.integer > 0) @intCast(@min(ev.integer, 4096)) else @max(k * 4, 64))
    else
        @max(k * 4, 64);

    var filter_sel: ?std.json.Value = null;
    if (root.object.get("filter")) |fv| {
        if (fv != .object) return err(res, 400, "bad_request", "filter must be a JSON object");
        if (findUnknownOperator(fv)) |bad| {
            const reason = try std.fmt.allocPrint(res.arena, "Invalid operator: {s}", .{bad});
            return err(res, 400, "invalid_operator", reason);
        }
        filter_sel = fv;
    }

    var query: []f32 = undefined;
    if (root.object.get("vector")) |qv| {
        if (qv != .array) return err(res, 400, "bad_request", "vector must be an array");
        query = try res.arena.alloc(f32, qv.array.items.len);
        for (qv.array.items, 0..) |item, i| {
            query[i] = switch (item) {
                .float => |f| @floatCast(f),
                .integer => |v| @floatFromInt(v),
                else => return err(res, 400, "bad_request", "vector values must be numbers"),
            };
            if (!std.math.isFinite(query[i])) return err(res, 400, "bad_request", "vector values must be finite numbers");
        }
    } else if (root.object.get("vector_b64")) |bv| {
        if (bv != .string) return err(res, 400, "bad_request", "vector_b64 must be a string");
        const n = std.base64.standard.Decoder.calcSizeForSlice(bv.string) catch
            return err(res, 400, "bad_request", "invalid base64 in vector_b64");
        if (n == 0 or n % 4 != 0) return err(res, 400, "bad_request", "vector_b64 byte length must be a non-zero multiple of 4");
        const raw = try res.arena.alloc(u8, n);
        std.base64.standard.Decoder.decode(raw, bv.string) catch
            return err(res, 400, "bad_request", "invalid base64 in vector_b64");
        query = try res.arena.alloc(f32, n / 4);
        for (query, 0..) |*v, i| {
            const bits = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
            v.* = @bitCast(bits);
            if (!std.math.isFinite(v.*)) return err(res, 400, "bad_request", "vector values must be finite numbers");
        }
    } else {
        return err(res, 400, "bad_request", "missing vector or vector_b64");
    }
    if (query.len == 0) return err(res, 400, "bad_request", "empty vector");
    var qnorm: f32 = 0;
    for (query) |v| qnorm += v * v;
    if (qnorm == 0 or !std.math.isFinite(qnorm)) return err(res, 400, "bad_request", "invalid zero or non-finite vector");
    const qvec = try quantize(res.arena, query);

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var hits: std.ArrayListUnmanaged(VecHit) = .empty;
    defer hits.deinit(res.arena);
    var used_index = false;
    var indexed_seq: u64 = db.seq;
    const search_k = if (filter_sel != null) @max(k * 8, 64) else k;
    if (std.mem.eql(u8, engine, "hnsw")) {
        const cache = hnswFor(app, db, query.len, name) catch |e| switch (e) {
            error.DimensionMismatch => return err(res, 400, "dimension_mismatch", "vector dimension mismatch"),
            error.InvalidVector => return err(res, 400, "bad_request", "invalid vector"),
            error.VectorIndexLimitExceeded => return err(res, 507, "insufficient_storage", "Vector index memory budget (ZOUCH_VECTOR_INDEX_MB) exceeded"),
            else => null,
        };
        if (cache) |c| {
            const approx = c.index.search(query, search_k, @max(search_k, ef)) catch |e| switch (e) {
                error.DimensionMismatch => return err(res, 400, "dimension_mismatch", "vector dimension mismatch"),
                error.InvalidVector => return err(res, 400, "bad_request", "invalid vector"),
                else => null,
            };
            if (approx) |ah| {
                defer app.alloc.free(ah);
                used_index = true;
                indexed_seq = c.seq;
                for (ah) |h| {
                    if (h.id >= c.ids.items.len) continue;
                    const d = db.get(c.ids.items[h.id]) orelse continue;
                    if (d.winnerLeaf().deleted) continue;
                    if (filter_sel) |fsel| {
                        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
                        if (!matchSelector(parsed.value, fsel)) continue;
                    }
                    try hits.append(res.arena, .{ .doc = d, .score = h.score });
                }
            }
        }
    }
    if (!used_index) {
        if (vectorEntries(db, res.arena, query.len) catch null) |entries| {
            used_index = true;
            for (entries) |entry| {
                const d = db.get(entry.id) orelse continue;
                if (d.winnerLeaf().deleted) continue;
                if (filter_sel) |fsel| {
                    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
                    if (!matchSelector(parsed.value, fsel)) continue;
                }
                const score = quantizedCosine(qvec, entry) orelse continue;
                try hits.append(res.arena, .{ .doc = d, .score = score });
            }
        }
    }
    if (!used_index) {
        var it = db.docs.valueIterator();
        while (it.next()) |d| {
            if (d.*.winnerLeaf().deleted) continue;
            if (filter_sel) |fsel| {
                const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.*.winnerLeaf().body, .{}) catch continue;
                if (!matchSelector(parsed.value, fsel)) continue;
            }
            if (try cosineFromBody(res.arena, d.*.winnerLeaf().body, query)) |score| {
                try hits.append(res.arena, .{ .doc = d.*, .score = score });
            }
        }
    }
    const sortHits = struct {
        fn less(_: void, a: VecHit, b: VecHit) bool {
            return a.score > b.score;
        }
    }.less;
    std.mem.sort(VecHit, hits.items, {}, sortHits);
    if (used_index and hits.items.len > 0) {
        const rescore_n = @min(hits.items.len, @max(k * 4, 32));
        for (hits.items[0..rescore_n]) |*hit| {
            if (try cosineFromBody(res.arena, hit.doc.winnerLeaf().body, query)) |exact| {
                hit.score = exact;
            }
        }
        std.mem.sort(VecHit, hits.items, {}, sortHits);
    }
    if (hits.items.len > k) hits.shrinkRetainingCapacity(k);

    const elapsed = started.durationTo(Io.Timestamp.now(app.io, .awake)).nanoseconds;
    const took_ms: i96 = @divTrunc(if (elapsed < 0) 0 else elapsed, 1_000_000);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"hits\":[");
    for (hits.items, 0..) |hit, i| {
        if (i != 0) try l.append(res.arena, ',');
        try l.appendSlice(res.arena, "{\"id\":");
        try jsonw.writeString(&l, res.arena, hit.doc.id);
        try l.appendSlice(res.arena, ",\"score\":");
        var nb: [32]u8 = undefined;
        try l.appendSlice(res.arena, std.fmt.bufPrint(&nb, "{d:.6}", .{hit.score}) catch "0");
        if (include_docs) {
            try l.appendSlice(res.arena, ",\"doc\":");
            try writeDoc(db, &l, res.arena, hit.doc, hit.doc.winner, false, false, false);
        }
        try l.append(res.arena, '}');
    }
    try l.appendSlice(res.arena, "],\"took_ms\":");
    try appendInt(&l, res.arena, took_ms);
    try l.appendSlice(res.arena, ",\"indexed_seq\":");
    try appendInt(&l, res.arena, indexed_seq);
    try l.append(res.arena, '}');
    res.content_type = .JSON;
    res.body = l.items;
}

fn jsonNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        // Integers outside i64 and literals such as 1e999 arrive as text.
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// CouchDB orders types null < boolean < number < string < array < object, and
/// compares across them. That is what makes `{"n": {"$gt": null}}` mean "the
/// field is present and not null" rather than "incomparable, so no match".
fn typeRank(v: std.json.Value) u8 {
    return switch (v) {
        .null => 0,
        .bool => 1,
        .integer, .float, .number_string => 2,
        .string => 3,
        .array => 4,
        .object => 5,
    };
}

/// Order two integer literals of any size by sign, digit count, then digits.
/// Null when either is not a plain integer (fraction or exponent), so the
/// caller falls back to `f64`.
fn bigIntCmp(a: []const u8, b: []const u8) ?i32 {
    const na = a.len > 0 and a[0] == '-';
    const nb = b.len > 0 and b[0] == '-';
    const da = std.mem.trimStart(u8, if (na) a[1..] else a, "0");
    const db_ = std.mem.trimStart(u8, if (nb) b[1..] else b, "0");
    for (da) |c| if (c < '0' or c > '9') return null;
    for (db_) |c| if (c < '0' or c > '9') return null;
    const zero_a = da.len == 0;
    const zero_b = db_.len == 0;
    if (zero_a and zero_b) return 0;
    const sa: i32 = if (zero_a) 0 else if (na) -1 else 1;
    const sb: i32 = if (zero_b) 0 else if (nb) -1 else 1;
    if (sa != sb) return if (sa < sb) -1 else 1;
    var mag: i32 = if (da.len != db_.len)
        (if (da.len < db_.len) -1 else 1)
    else switch (std.mem.order(u8, da, db_)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    if (sa < 0) mag = -mag;
    return mag;
}

fn valueCmp(a: std.json.Value, b: std.json.Value) ?i32 {
    const ra = typeRank(a);
    const rb = typeRank(b);
    if (ra != rb) return if (ra < rb) -1 else 1;
    switch (ra) {
        0 => return 0,
        1 => return if (a.bool == b.bool) 0 else if (!a.bool) -1 else 1,
        2 => {
            if (a == .number_string and b == .number_string) {
                if (bigIntCmp(a.number_string, b.number_string)) |c| return c;
            }
            const na = jsonNumber(a) orelse 0;
            const nb = jsonNumber(b) orelse 0;
            if (na < nb) return -1;
            if (na > nb) return 1;
            return 0;
        },
        3 => return switch (std.mem.order(u8, a.string, b.string)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        },
        4 => {
            const min_len = @min(a.array.items.len, b.array.items.len);
            for (0..min_len) |i| {
                const c = valueCmp(a.array.items[i], b.array.items[i]) orelse return null;
                if (c != 0) return c;
            }
            if (a.array.items.len < b.array.items.len) return -1;
            if (a.array.items.len > b.array.items.len) return 1;
            return 0;
        },
        5 => {
            const nextMinKey = struct {
                fn next(obj: std.json.ObjectMap, after: ?[]const u8) ?[]const u8 {
                    var best: ?[]const u8 = null;
                    for (obj.keys()) |k| {
                        if (after) |prev| {
                            if (std.mem.order(u8, k, prev) != .gt) continue;
                        }
                        if (best == null or std.mem.order(u8, k, best.?) == .lt) best = k;
                    }
                    return best;
                }
            }.next;
            var prev: ?[]const u8 = null;
            while (true) {
                const ka = nextMinKey(a.object, prev);
                const kb = nextMinKey(b.object, prev);
                if (ka == null and kb == null) return 0;
                if (ka == null) return -1;
                if (kb == null) return 1;
                switch (std.mem.order(u8, ka.?, kb.?)) {
                    .lt => return -1,
                    .gt => return 1,
                    .eq => {},
                }
                const c = valueCmp(a.object.get(ka.?).?, b.object.get(kb.?).?) orelse return null;
                if (c != 0) return c;
                prev = ka.?;
            }
        },
        else => return null,
    }
}

fn valueAtPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    if (root != .object) return null;
    var cur = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

/// Every selector operator the matcher below implements. `_find` rejects
/// anything else: an unrecognised `$name` used to be ignored, so a typo
/// returned HTTP 200 with zero rows and looked like missing data.
const known_operators = [_][]const u8{
    "$all",    "$allMatch", "$and",  "$beginsWith", "$elemMatch",   "$eq",
    "$exists", "$gt",       "$gte",  "$in",         "$keyMapMatch", "$lt",
    "$lte",    "$mod",      "$ne",   "$nin",        "$nor",         "$not",
    "$or",     "$regex",    "$size", "$text",       "$type",
};

fn isKnownOperator(op: []const u8) bool {
    for (known_operators) |known| {
        if (std.mem.eql(u8, known, op)) return true;
    }
    return false;
}

/// Return the first operator key the matcher cannot evaluate, or null.
/// `$text` subtrees are skipped: `$search`, `$default` and `$case_sensitive`
/// are options of that operator, not operators themselves.
fn findUnknownOperator(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.len > 0 and key[0] == '$') {
                    if (!isKnownOperator(key)) return key;
                    if (std.mem.eql(u8, key, "$text")) continue;
                }
                if (findUnknownOperator(entry.value_ptr.*)) |bad| return bad;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findUnknownOperator(item)) |bad| return bad;
            }
            return null;
        },
        else => return null,
    }
}

fn rangeMatch(field: ?std.json.Value, ov: std.json.Value, op: enum { gt, gte, lt, lte }) bool {
    const f = field orelse return false;
    if (ov != .null and typeRank(f) != typeRank(ov)) return false;
    const c = valueCmp(f, ov) orelse return false;
    return switch (op) {
        .gt => c > 0,
        .gte => c >= 0,
        .lt => c < 0,
        .lte => c <= 0,
    };
}

fn matchCondition(field: ?std.json.Value, cond: std.json.Value) bool {
    if (cond == .object) {
        var has_op = false;
        for (cond.object.keys()) |k| {
            if (k.len > 0 and k[0] == '$') has_op = true;
        }
        if (has_op) {
            for (cond.object.keys(), cond.object.values()) |op, ov| {
                if (std.mem.eql(u8, op, "$exists")) {
                    const want = ov == .bool and ov.bool;
                    if (want != (field != null)) return false;
                } else if (std.mem.eql(u8, op, "$eq")) {
                    if (field == null or valueCmp(field.?, ov) != 0) return false;
                } else if (std.mem.eql(u8, op, "$ne")) {
                    // A field that is not there is neither equal nor unequal:
                    // CouchDB excludes it from both, so `$ne: null` on a
                    // missing field does not match (measured).
                    if (field == null) return false;
                    if (valueCmp(field.?, ov) == 0) return false;
                } else if (std.mem.eql(u8, op, "$gt")) {
                    if (!rangeMatch(field, ov, .gt)) return false;
                } else if (std.mem.eql(u8, op, "$gte")) {
                    if (!rangeMatch(field, ov, .gte)) return false;
                } else if (std.mem.eql(u8, op, "$lt")) {
                    if (!rangeMatch(field, ov, .lt)) return false;
                } else if (std.mem.eql(u8, op, "$lte")) {
                    if (!rangeMatch(field, ov, .lte)) return false;
                } else if (std.mem.eql(u8, op, "$beginsWith")) {
                    if (field == null or field.? != .string or ov != .string) return false;
                    if (!std.mem.startsWith(u8, field.?.string, ov.string)) return false;
                } else if (std.mem.eql(u8, op, "$size")) {
                    if (field == null or field.? != .array or ov != .integer) return false;
                    if (field.?.array.items.len != (std.math.cast(usize, ov.integer) orelse return false)) return false;
                } else if (std.mem.eql(u8, op, "$type")) {
                    if (field == null or ov != .string) return false;
                    const actual = switch (field.?) {
                        .null => "null",
                        .bool => "boolean",
                        .integer, .float, .number_string => "number",
                        .string => "string",
                        .array => "array",
                        .object => "object",
                    };
                    if (!std.mem.eql(u8, actual, ov.string)) return false;
                } else if (std.mem.eql(u8, op, "$not")) {
                    if (matchCondition(field, ov)) return false;
                } else if (std.mem.eql(u8, op, "$regex")) {
                    if (field == null or field.? != .string or ov != .string) return false;
                    if (zouch_regex_match(ov.string.ptr, ov.string.len, field.?.string.ptr, field.?.string.len) != 1) return false;
                } else if (std.mem.eql(u8, op, "$allMatch")) {
                    if (field == null or field.? != .array) return false;
                    for (field.?.array.items) |item| {
                        if (!(matchCondition(item, ov) or matchSelector(item, ov))) return false;
                    }
                } else if (std.mem.eql(u8, op, "$keyMapMatch")) {
                    if (field == null or field.? != .object) return false;
                    var found = false;
                    for (field.?.object.values()) |item| {
                        if (matchCondition(item, ov) or matchSelector(item, ov)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                } else if (std.mem.eql(u8, op, "$all")) {
                    if (field == null or field.? != .array or ov != .array) return false;
                    for (ov.array.items) |want| {
                        var found = false;
                        for (field.?.array.items) |item| {
                            if (valueCmp(item, want) == 0) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) return false;
                    }
                } else if (std.mem.eql(u8, op, "$elemMatch")) {
                    if (field == null or field.? != .array) return false;
                    var found = false;
                    for (field.?.array.items) |item| {
                        if (matchCondition(item, ov) or matchSelector(item, ov)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                } else if (std.mem.eql(u8, op, "$mod")) {
                    if (field == null or field.? != .integer or ov != .array or ov.array.items.len != 2) return false;
                    if (ov.array.items[0] != .integer or ov.array.items[1] != .integer) return false;
                    const divisor = ov.array.items[0].integer;
                    const remainder = ov.array.items[1].integer;
                    if (divisor == 0) return false;
                    if (@mod(field.?.integer, divisor) != remainder) return false;
                } else if (std.mem.eql(u8, op, "$in") or std.mem.eql(u8, op, "$nin")) {
                    if (ov != .array) return false;
                    var found = false;
                    for (ov.array.items) |item| {
                        if (field != null and valueCmp(field.?, item) == 0) {
                            found = true;
                            break;
                        }
                    }
                    if (std.mem.eql(u8, op, "$nin")) found = !found;
                    if (!found) return false;
                } else {
                    return false;
                }
            }
            return true;
        }
    }
    const f = field orelse return false;
    return valueCmp(f, cond) == 0;
}

fn textValueContains(v: std.json.Value, needle: []const u8) bool {
    return switch (v) {
        .string => std.ascii.findIgnoreCase(v.string, needle) != null,
        .array => blk: {
            for (v.array.items) |item| if (textValueContains(item, needle)) break :blk true;
            break :blk false;
        },
        .object => blk: {
            for (v.object.values()) |item| if (textValueContains(item, needle)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn textMatches(root: std.json.Value, query: []const u8) bool {
    var toks = std.mem.splitScalar(u8, query, ' ');
    while (toks.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        if (token.len == 0) continue;
        if (std.mem.indexOfScalar(u8, token, ':')) |colon| {
            if (colon > 0 and colon + 1 < token.len) {
                const field = token[0..colon];
                const term = token[colon + 1 ..];
                const value = valueAtPath(root, field) orelse return false;
                if (!textValueContains(value, term)) return false;
                continue;
            }
        }
        if (!textValueContains(root, token)) return false;
    }
    return true;
}

fn matchSelector(root: std.json.Value, sel: std.json.Value) bool {
    if (sel != .object) return false;
    for (sel.object.keys(), sel.object.values()) |k, v| {
        if (std.mem.eql(u8, k, "$and")) {
            if (v != .array) return false;
            for (v.array.items) |item| if (!matchSelector(root, item)) return false;
        } else if (std.mem.eql(u8, k, "$or")) {
            if (v != .array) return false;
            var any = false;
            for (v.array.items) |item| if (matchSelector(root, item)) {
                any = true;
                break;
            };
            if (!any) return false;
        } else if (std.mem.eql(u8, k, "$nor")) {
            if (v != .array) return false;
            for (v.array.items) |item| if (matchSelector(root, item)) return false;
        } else if (std.mem.eql(u8, k, "$not")) {
            if (matchSelector(root, v)) return false;
        } else if (std.mem.eql(u8, k, "$text")) {
            const q_str: ?[]const u8 = switch (v) {
                .string => |s| s,
                .object => |obj| if (obj.get("$search")) |sv| (if (sv == .string) sv.string else null) else null,
                else => null,
            };
            if (q_str == null or !textMatches(root, q_str.?)) return false;
        } else {
            if (!matchCondition(valueAtPath(root, k), v)) return false;
        }
    }
    return true;
}

fn mangoIndexName(alloc: std.mem.Allocator, field: []const u8) ![]u8 {
    return mangoIndexNameFor(alloc, &.{field});
}

fn mangoIndexNameFor(alloc: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    return mangoIndexNameWithFilter(alloc, fields, null);
}

fn mangoIndexNameWithFilter(alloc: std.mem.Allocator, fields: []const []const u8, partial_filter: ?std.json.Value) ![]u8 {
    var h = std.hash.Wyhash.init(0);
    for (fields, 0..) |field, i| {
        if (i > 0) h.update("\x1f");
        h.update(field);
    }
    if (partial_filter) |pfs| {
        var pfs_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer pfs_buf.deinit(alloc);
        try jsonw.writeValue(&pfs_buf, alloc, pfs);
        h.update("\x1e");
        h.update(pfs_buf.items);
    }
    return std.fmt.allocPrint(alloc, "{x}.idx", .{h.final()});
}

fn selectorImpliesEntry(sel: std.json.Value, key: []const u8, val: std.json.Value) bool {
    if (sel != .object) return false;
    if (sel.object.get(key)) |sv| {
        if (sv == .object) {
            if (sv.object.get("$eq")) |eqv| {
                if (valueCmp(eqv, val) == 0) return true;
            }
        } else if (val != .object) {
            if (valueCmp(sv, val) == 0) return true;
        } else if (val.object.get("$eq")) |eqv| {
            if (valueCmp(sv, eqv) == 0) return true;
        }
        if (valueCmp(sv, val) == 0) return true;
    }
    if (sel.object.get("$and")) |av| {
        if (av == .array) {
            for (av.array.items) |sub| {
                if (selectorImpliesEntry(sub, key, val)) return true;
            }
        }
    }
    return false;
}

fn selectorImplies(sel: std.json.Value, pfs: std.json.Value) bool {
    if (pfs != .object) return true;
    const keys = pfs.object.keys();
    const vals = pfs.object.values();
    for (keys, vals) |k, v| {
        if (std.mem.eql(u8, k, "$and") and v == .array) {
            for (v.array.items) |sub| {
                if (!selectorImplies(sel, sub)) return false;
            }
            continue;
        }
        if (!selectorImpliesEntry(sel, k, v)) return false;
    }
    return true;
}

const PartialIndexMatch = struct {
    ddoc_id: []const u8,
    name: []const u8,
    pfs: std.json.Value,
};

fn findPartialIndexFor(db: *Db, arena: std.mem.Allocator, field: []const u8, sel: std.json.Value) ?PartialIndexMatch {
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        if (!std.mem.startsWith(u8, d.*.id, "_design/")) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, d.*.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const zi = parsed.value.object.get("zouch_indexes") orelse continue;
        if (zi != .object) continue;
        var zit = zi.object.iterator();
        while (zit.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const pfs = entry.value_ptr.*.object.get("partial_filter_selector") orelse continue;
            const fields = entry.value_ptr.*.object.get("fields") orelse continue;
            if (fields != .array or fields.array.items.len == 0) continue;
            const fname = indexFieldName(fields.array.items[0]) orelse continue;
            if (!std.mem.eql(u8, fname, field)) continue;
            if (selectorImplies(sel, pfs)) {
                return .{ .ddoc_id = d.*.id, .name = entry.key_ptr.*, .pfs = pfs };
            }
        }
    }
    return null;
}

const IdxRow = struct { id: []const u8, key: std.json.Value };

fn idxRowLess(_: void, a: IdxRow, b: IdxRow) bool {
    if (valueCmp(a.key, b.key)) |c| {
        if (c != 0) return c < 0;
    }
    return std.mem.lessThan(u8, a.id, b.id);
}

const MultiRow = struct { id: []const u8, keys: []std.json.Value };

fn multiKeyCmp(a: []const std.json.Value, b: []const std.json.Value) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = valueCmp(a[i], b[i]) orelse return .lt;
        if (c != 0) return if (c < 0) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

fn buildMangoIndexFields(db: *Db, alloc: std.mem.Allocator, fields: []const []const u8) !void {
    return buildMangoIndexFieldsOpt(null, db, null, alloc, fields, null);
}

fn buildMangoIndexFieldsWithFilter(db: *Db, alloc: std.mem.Allocator, fields: []const []const u8, partial_filter: ?std.json.Value) !void {
    return buildMangoIndexFieldsOpt(null, db, null, alloc, fields, partial_filter);
}

fn buildMangoIndexFieldsOpt(app: ?*App, db: *Db, db_name: ?[]const u8, alloc: std.mem.Allocator, fields: []const []const u8, partial_filter: ?std.json.Value) !void {
    var rows: std.ArrayListUnmanaged(MultiRow) = .empty;
    defer rows.deinit(alloc);
    // Parsed bodies live until the rows are serialised, so they share one arena
    // that is freed here rather than leaking when the caller passes a general
    // allocator.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const SnapDoc = struct { id: []const u8, body: []const u8 };
    var snap_docs: std.ArrayListUnmanaged(SnapDoc) = .empty;
    defer snap_docs.deinit(sa);
    const snap_seq = db.seq;
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        try snap_docs.append(sa, .{
            .id = try sa.dupe(u8, d.*.id),
            .body = try sa.dupe(u8, d.*.winnerLeaf().body),
        });
    }

    var mutex_held = true;
    if (app != null) {
        mutex_held = false;
        db.unlock();
    }
    defer if (!mutex_held) {
        if (app != null) db.lock();
    };
    const task_pid = if (app) |a| a.beginTask("indexer", db_name orelse "", "_design/zouch", null, null, null, snap_docs.items.len) else 0;
    defer if (app) |a| a.endTask(task_pid);

    for (snap_docs.items, 0..) |sd, si| {
        const parsed = std.json.parseFromSlice(std.json.Value, sa, sd.body, .{}) catch continue;
        if (partial_filter) |pfs| {
            if (!matchSelector(parsed.value, pfs)) continue;
        }
        var keys = try sa.alloc(std.json.Value, fields.len);
        var complete = true;
        for (fields, 0..) |field, i| {
            keys[i] = valueAtPath(parsed.value, field) orelse {
                complete = false;
                break;
            };
        }
        if (!complete) continue;
        try rows.append(alloc, .{ .id = sd.id, .keys = keys });
        if ((si & 63) == 63) {
            if (app) |a| a.updateTask(task_pid, si + 1, snap_docs.items.len);
        }
    }
    std.mem.sort(MultiRow, rows.items, {}, struct {
        fn less(_: void, a: MultiRow, b: MultiRow) bool {
            return multiKeyCmp(a.keys, b.keys) == .lt;
        }
    }.less);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(alloc);
    try l.appendSlice(alloc, "{\"version\":3,\"db_seq\":");
    try appendInt(&l, alloc, snap_seq);
    try l.appendSlice(alloc, ",\"fields\":[");
    for (fields, 0..) |field, i| {
        if (i != 0) try l.append(alloc, ',');
        try jsonw.writeString(&l, alloc, field);
    }
    try l.appendSlice(alloc, "],\"rows\":[");
    for (rows.items, 0..) |row, i| {
        if (i != 0) try l.append(alloc, ',');
        try l.appendSlice(alloc, "{\"id\":");
        try jsonw.writeString(&l, alloc, row.id);
        try l.appendSlice(alloc, ",\"key\":[");
        for (row.keys, 0..) |key, j| {
            if (j != 0) try l.append(alloc, ',');
            try jsonw.writeValue(&l, alloc, key);
        }
        try l.appendSlice(alloc, "]}");
    }
    try l.appendSlice(alloc, "]}");
    const name = try mangoIndexNameWithFilter(alloc, fields, partial_filter);
    defer alloc.free(name);

    if (app != null) {
        db.lock();
        mutex_held = true;
    }
    if (db.seq == snap_seq) {
        try db.writeMangoIndex(name, l.items);
    }
}

fn loadMangoIndexFields(db: *Db, alloc: std.mem.Allocator, fields: []const []const u8) ?std.json.Value {
    return loadMangoIndexFieldsOpt(null, db, null, alloc, fields, null);
}

fn loadMangoIndexFieldsWithFilter(db: *Db, alloc: std.mem.Allocator, fields: []const []const u8, partial_filter: ?std.json.Value) ?std.json.Value {
    return loadMangoIndexFieldsOpt(null, db, null, alloc, fields, partial_filter);
}

fn loadMangoIndexFieldsOpt(app: ?*App, db: *Db, db_name: ?[]const u8, alloc: std.mem.Allocator, fields: []const []const u8, partial_filter: ?std.json.Value) ?std.json.Value {
    const name = mangoIndexNameWithFilter(alloc, fields, partial_filter) catch return null;
    const first = db.readMangoIndex(alloc, name) catch return null;
    const first_bytes = first orelse return null;
    const parsed_first = std.json.parseFromSlice(std.json.Value, alloc, first_bytes, .{}) catch return null;
    if (parsed_first.value == .object) {
        const ver = parsed_first.value.object.get("version");
        if (ver != null and ver.? == .integer and ver.?.integer == 3) {
            const sv = parsed_first.value.object.get("db_seq");
            if (sv != null and sv.? == .integer and sv.?.integer == @as(i64, @intCast(db.seq))) return parsed_first.value;
        }
    }
    buildMangoIndexFieldsOpt(app, db, db_name, alloc, fields, partial_filter) catch return null;
    const rebuilt = db.readMangoIndex(alloc, name) catch return null;
    const rebuilt_bytes = rebuilt orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, rebuilt_bytes, .{}) catch return null;
    if (parsed.value != .object) return null;
    const ver = parsed.value.object.get("version") orelse return null;
    if (ver != .integer or ver.integer != 3) return null;
    const sv = parsed.value.object.get("db_seq") orelse return null;
    if (sv != .integer or sv.integer != @as(i64, @intCast(db.seq))) return null;
    return parsed.value;
}

fn buildMangoIndex(db: *Db, alloc: std.mem.Allocator, field: []const u8) !void {
    return buildMangoIndexOpt(null, db, null, alloc, field, null);
}

fn buildMangoIndexWithFilter(db: *Db, alloc: std.mem.Allocator, field: []const u8, partial_filter: ?std.json.Value) !void {
    return buildMangoIndexOpt(null, db, null, alloc, field, partial_filter);
}

fn buildMangoIndexOpt(app: ?*App, db: *Db, db_name: ?[]const u8, alloc: std.mem.Allocator, field: []const u8, partial_filter: ?std.json.Value) !void {
    var rows: std.ArrayListUnmanaged(IdxRow) = .empty;
    defer rows.deinit(alloc);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const SnapDoc = struct { id: []const u8, body: []const u8 };
    var snap_docs: std.ArrayListUnmanaged(SnapDoc) = .empty;
    defer snap_docs.deinit(sa);
    const snap_seq = db.seq;
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        try snap_docs.append(sa, .{
            .id = try sa.dupe(u8, d.*.id),
            .body = try sa.dupe(u8, d.*.winnerLeaf().body),
        });
    }

    var mutex_held = true;
    if (app != null) {
        mutex_held = false;
        db.unlock();
    }
    defer if (!mutex_held) {
        if (app != null) db.lock();
    };
    const task_pid = if (app) |a| a.beginTask("indexer", db_name orelse "", "_design/zouch", null, null, null, snap_docs.items.len) else 0;
    defer if (app) |a| a.endTask(task_pid);

    for (snap_docs.items, 0..) |sd, si| {
        const parsed = std.json.parseFromSlice(std.json.Value, sa, sd.body, .{}) catch continue;
        if (partial_filter) |pfs| {
            if (!matchSelector(parsed.value, pfs)) continue;
        }
        const key = valueAtPath(parsed.value, field) orelse continue;
        try rows.append(alloc, .{ .id = sd.id, .key = key });
        if ((si & 63) == 63) {
            if (app) |a| a.updateTask(task_pid, si + 1, snap_docs.items.len);
        }
    }
    std.mem.sort(IdxRow, rows.items, {}, idxRowLess);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(alloc);
    try l.appendSlice(alloc, "{\"version\":2,\"db_seq\":");
    try appendInt(&l, alloc, snap_seq);
    try l.appendSlice(alloc, ",\"purge_seq\":");
    try appendInt(&l, alloc, db.purge_seq);
    try l.appendSlice(alloc, ",\"field\":");
    try jsonw.writeString(&l, alloc, field);
    try l.appendSlice(alloc, ",\"rows\":[");
    for (rows.items, 0..) |row, i| {
        if (i != 0) try l.append(alloc, ',');
        try l.appendSlice(alloc, "{\"id\":");
        try jsonw.writeString(&l, alloc, row.id);
        try l.appendSlice(alloc, ",\"key\":");
        try jsonw.writeValue(&l, alloc, row.key);
        try l.append(alloc, '}');
    }
    try l.appendSlice(alloc, "]}");
    const name = try mangoIndexNameWithFilter(alloc, &.{field}, partial_filter);
    defer alloc.free(name);

    if (app != null) {
        db.lock();
        mutex_held = true;
    }
    if (db.seq == snap_seq) {
        try db.writeMangoIndex(name, l.items);
    }
}

fn loadMangoIndex(db: *Db, alloc: std.mem.Allocator, field: []const u8) ?std.json.Value {
    return loadMangoIndexOpt(null, db, null, alloc, field, null);
}

fn loadMangoIndexWithFilter(db: *Db, alloc: std.mem.Allocator, field: []const u8, partial_filter: ?std.json.Value) ?std.json.Value {
    return loadMangoIndexOpt(null, db, null, alloc, field, partial_filter);
}

fn tryIncrementalMangoIndex(
    db: *Db,
    alloc: std.mem.Allocator,
    name: []const u8,
    field: []const u8,
    partial_filter: ?std.json.Value,
    cached_val: std.json.Value,
    cached_seq: u64,
) !?std.json.Value {
    const cached_rows_v = cached_val.object.get("rows") orelse return null;
    if (cached_rows_v != .array) return null;
    const cached_purge: u64 = if (cached_val.object.get("purge_seq")) |pv|
        (if (pv == .integer and pv.integer >= 0) @intCast(pv.integer) else return null)
    else
        0;
    if (cached_purge != db.purge_seq) return null;

    var changed_count: usize = 0;
    var cnt_it = db.docs.valueIterator();
    while (cnt_it.next()) |d| {
        if (d.*.seq > cached_seq) changed_count += 1;
    }
    if (changed_count == 0 or changed_count * 2 >= db.docs.count()) return null;

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var changed: std.StringHashMapUnmanaged(void) = .empty;
    var rows: std.ArrayListUnmanaged(IdxRow) = .empty;
    defer rows.deinit(alloc);

    var doc_it = db.docs.valueIterator();
    while (doc_it.next()) |d| {
        if (d.*.seq <= cached_seq) continue;
        try changed.put(sa, d.*.id, {});
        if (d.*.winnerLeaf().deleted) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, sa, d.*.winnerLeaf().body, .{}) catch continue;
        if (partial_filter) |pfs| {
            if (!matchSelector(parsed.value, pfs)) continue;
        }
        const key = valueAtPath(parsed.value, field) orelse continue;
        try rows.append(alloc, .{ .id = d.*.id, .key = key });
    }

    for (cached_rows_v.array.items) |row| {
        if (row != .object) continue;
        const id_v = row.object.get("id") orelse continue;
        const key_v = row.object.get("key") orelse continue;
        if (id_v != .string) continue;
        if (changed.contains(id_v.string)) continue;
        try rows.append(alloc, .{ .id = id_v.string, .key = key_v });
    }

    std.mem.sort(IdxRow, rows.items, {}, idxRowLess);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(alloc);
    try l.appendSlice(alloc, "{\"version\":2,\"db_seq\":");
    try appendInt(&l, alloc, db.seq);
    try l.appendSlice(alloc, ",\"purge_seq\":");
    try appendInt(&l, alloc, db.purge_seq);
    try l.appendSlice(alloc, ",\"field\":");
    try jsonw.writeString(&l, alloc, field);
    try l.appendSlice(alloc, ",\"rows\":[");
    for (rows.items, 0..) |row, i| {
        if (i != 0) try l.append(alloc, ',');
        try l.appendSlice(alloc, "{\"id\":");
        try jsonw.writeString(&l, alloc, row.id);
        try l.appendSlice(alloc, ",\"key\":");
        try jsonw.writeValue(&l, alloc, row.key);
        try l.append(alloc, '}');
    }
    try l.appendSlice(alloc, "]}");
    try db.writeMangoIndex(name, l.items);

    const updated_bytes = (try db.readMangoIndex(alloc, name)) orelse return null;
    const parsed_updated = std.json.parseFromSlice(std.json.Value, alloc, updated_bytes, .{}) catch return null;
    if (parsed_updated.value != .object) return null;
    return parsed_updated.value;
}

fn loadMangoIndexOpt(app: ?*App, db: *Db, db_name: ?[]const u8, alloc: std.mem.Allocator, field: []const u8, partial_filter: ?std.json.Value) ?std.json.Value {
    const name = mangoIndexNameWithFilter(alloc, &.{field}, partial_filter) catch return null;
    const first = db.readMangoIndex(alloc, name) catch return null;
    const first_bytes = first orelse return null;
    const parsed_first = std.json.parseFromSlice(std.json.Value, alloc, first_bytes, .{}) catch return null;
    if (parsed_first.value == .object) {
        const ver = parsed_first.value.object.get("version");
        if (ver != null and ver.? == .integer and ver.?.integer == 2) {
            if (parsed_first.value.object.get("db_seq")) |sv| {
                if (sv == .integer and sv.integer == @as(i64, @intCast(db.seq))) return parsed_first.value;
                if (sv == .integer and sv.integer > 0 and sv.integer < @as(i64, @intCast(db.seq))) {
                    if (tryIncrementalMangoIndex(db, alloc, name, field, partial_filter, parsed_first.value, @intCast(sv.integer)) catch null) |inc| {
                        return inc;
                    }
                }
            }
        }
    }
    buildMangoIndexOpt(app, db, db_name, alloc, field, partial_filter) catch return null;
    const rebuilt = db.readMangoIndex(alloc, name) catch return null;
    const rebuilt_bytes = rebuilt orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, rebuilt_bytes, .{}) catch return null;
    if (parsed.value != .object) return null;
    const ver = parsed.value.object.get("version") orelse return null;
    if (ver != .integer or ver.integer != 2) return null;
    const sv = parsed.value.object.get("db_seq") orelse return null;
    if (sv != .integer or sv.integer != @as(i64, @intCast(db.seq))) return null;
    return parsed.value;
}

const BookmarkData = struct {
    id: []const u8,
    offset: ?usize = null,
    key: ?std.json.Value = null,
};

fn encodeBookmark(alloc: std.mem.Allocator, id: []const u8, offset: usize, key: ?std.json.Value) ![]u8 {
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "{\"id\":");
    try jsonw.writeString(&raw, alloc, id);
    try raw.appendSlice(alloc, ",\"offset\":");
    try appendInt(&raw, alloc, offset);
    if (key) |kv| {
        try raw.appendSlice(alloc, ",\"key\":");
        try jsonw.writeValue(&raw, alloc, kv);
    }
    try raw.append(alloc, '}');
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(raw.items.len));
    _ = enc.encode(out, raw.items);
    return out;
}

fn decodeBookmark(alloc: std.mem.Allocator, s: []const u8) !?BookmarkData {
    if (std.mem.eql(u8, s, "nil") or s.len == 0) return null;
    const dec = std.base64.url_safe_no_pad.Decoder;
    const out = try alloc.alloc(u8, dec.calcSizeForSlice(s) catch return error.InvalidBookmark);
    dec.decode(out, s) catch return error.InvalidBookmark;
    if (out.len > 0 and out[0] == '{') {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.InvalidBookmark;
        if (parsed.value != .object) return error.InvalidBookmark;
        const id_v = parsed.value.object.get("id") orelse return error.InvalidBookmark;
        if (id_v != .string) return error.InvalidBookmark;
        const off: ?usize = if (parsed.value.object.get("offset")) |ov|
            (if (ov == .integer and ov.integer >= 0) @intCast(ov.integer) else null)
        else
            null;
        return .{ .id = id_v.string, .offset = off, .key = parsed.value.object.get("key") };
    }
    return .{ .id = out };
}

fn insertAtPath(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, path: []const u8, val: std.json.Value) !void {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = path[0..dot];
        const tail = path[dot + 1 ..];
        const gop = try obj.getOrPut(alloc, head);
        if (!gop.found_existing or gop.value_ptr.* != .object) {
            gop.value_ptr.* = .{ .object = .empty };
        }
        try insertAtPath(alloc, &gop.value_ptr.object, tail, val);
    } else {
        try obj.put(alloc, path, val);
    }
}

fn indexFieldName(fv: std.json.Value) ?[]const u8 {
    return switch (fv) {
        .string => |s| if (s.len > 0) s else null,
        .object => |obj| blk: {
            const keys = obj.keys();
            if (keys.len != 1 or keys[0].len == 0) break :blk null;
            break :blk keys[0];
        },
        else => null,
    };
}

fn textTokenize(s: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, s, " \t\r\n.,;:!?()[]{}<>/\\|@#$%^&*+=-_\"'`~");
}

fn textAddKey(cache: *TextCache, id: []const u8, key: []u8) !void {
    if (cache.index.getPtr(key)) |list| {
        cache.alloc.free(key);
        if (list.items.len == 0 or !std.mem.eql(u8, list.items[list.items.len - 1], id))
            try list.append(cache.alloc, id);
    } else {
        try cache.keys.append(cache.alloc, key);
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.append(cache.alloc, id);
        try cache.index.put(cache.alloc, key, list);
    }
}

fn textLowerToken(alloc: std.mem.Allocator, token: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, token.len);
    for (token, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn textIndexValue(cache: *TextCache, id: []const u8, value: std.json.Value, field: ?[]const u8) !void {
    switch (value) {
        .string => {
            var it = textTokenize(value.string);
            while (it.next()) |raw| {
                const token = try textLowerToken(cache.alloc, raw);
                defer cache.alloc.free(token);
                try textAddKey(cache, id, try cache.alloc.dupe(u8, token));
                if (field) |f| {
                    const key = try std.fmt.allocPrint(cache.alloc, "{s}\x00{s}", .{ f, token });
                    try textAddKey(cache, id, key);
                }
            }
        },
        .array => for (value.array.items) |item| try textIndexValue(cache, id, item, field),
        .object => {
            const keys = value.object.keys();
            const vals = value.object.values();
            for (keys, vals) |key, val| {
                const next_field = if (field) |f| f else key;
                try textIndexValue(cache, id, val, next_field);
            }
        },
        else => {},
    }
}

const TEXT_FILE_MAGIC = "ZTXTF001";

fn persistText(app: *App, db: *Db, cache: *TextCache) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.alloc);
    out.appendSlice(app.alloc, TEXT_FILE_MAGIC) catch return;
    appendU64(&out, app.alloc, cache.seq) catch return;
    appendU32(&out, app.alloc, @intCast(cache.index.count())) catch return;
    var it = cache.index.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        appendU32(&out, app.alloc, @intCast(key.len)) catch return;
        out.appendSlice(app.alloc, key) catch return;
        appendU32(&out, app.alloc, @intCast(entry.value_ptr.items.len)) catch return;
        for (entry.value_ptr.items) |id| {
            appendU32(&out, app.alloc, @intCast(id.len)) catch return;
            out.appendSlice(app.alloc, id) catch return;
        }
    }
    db.writeTextIndex(out.items) catch {};
}

fn loadTextFile(alloc: std.mem.Allocator, bytes: []u8) !*TextCache {
    if (bytes.len < TEXT_FILE_MAGIC.len + 12 or !std.mem.eql(u8, bytes[0..TEXT_FILE_MAGIC.len], TEXT_FILE_MAGIC)) return error.CorruptIndex;
    var pos: usize = TEXT_FILE_MAGIC.len;
    const seq = std.mem.readInt(u64, bytes[pos..][0..8], .little);
    pos += 8;
    const keys_n = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;
    if (keys_n > 10_000_000) return error.CorruptIndex;
    const cache = try alloc.create(TextCache);
    cache.* = .{ .alloc = alloc, .seq = seq, .owns_ids = true };
    errdefer {
        cache.deinit();
        alloc.destroy(cache);
    }
    var i: u32 = 0;
    while (i < keys_n) : (i += 1) {
        if (pos + 4 > bytes.len) return error.CorruptIndex;
        const klen = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (klen == 0 or pos + klen > bytes.len) return error.CorruptIndex;
        const key = try alloc.dupe(u8, bytes[pos .. pos + klen]);
        pos += klen;
        try cache.keys.append(alloc, key);
        if (pos + 4 > bytes.len) return error.CorruptIndex;
        const docs_n = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var j: u32 = 0;
        while (j < docs_n) : (j += 1) {
            if (pos + 4 > bytes.len) return error.CorruptIndex;
            const dlen = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (dlen == 0 or pos + dlen > bytes.len) return error.CorruptIndex;
            const id = try alloc.dupe(u8, bytes[pos .. pos + dlen]);
            pos += dlen;
            try cache.ids.append(alloc, id);
            try list.append(alloc, id);
        }
        try cache.index.put(alloc, key, list);
    }
    return cache;
}

fn textCacheFor(app: *App, db: *Db, name: []const u8) !*TextCache {
    {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        if (app.text_cache.get(name)) |cache| {
            if (cache.seq == db.seq) return cache;
        }
        if (app.text_cache.fetchRemove(name)) |old| {
            old.value.deinit();
            app.alloc.destroy(old.value);
            app.alloc.free(old.key);
        }
    }
    if (try db.readTextIndex()) |bytes| {
        defer db.alloc.free(bytes);
        if (loadTextFile(app.alloc, bytes)) |loaded| {
            if (loaded.seq == db.seq) {
                const key = try app.alloc.dupe(u8, name);
                errdefer {
                    loaded.deinit();
                    app.alloc.destroy(loaded);
                    app.alloc.free(key);
                }
                app.mutex.lockUncancelable(app.io);
                defer app.mutex.unlock(app.io);
                if (app.text_cache.fetchRemove(name)) |old| {
                    old.value.deinit();
                    app.alloc.destroy(old.value);
                    app.alloc.free(old.key);
                }
                try app.text_cache.put(app.alloc, key, loaded);
                return loaded;
            }
            loaded.deinit();
            app.alloc.destroy(loaded);
        } else |_| {}
    }
    const cache = try app.alloc.create(TextCache);
    cache.* = .{ .alloc = app.alloc, .seq = db.seq };
    errdefer {
        cache.deinit();
        app.alloc.destroy(cache);
    }
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        var arena = std.heap.ArenaAllocator.init(app.alloc);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), d.*.winnerLeaf().body, .{}) catch continue;
        try textIndexValue(cache, d.*.id, parsed.value, null);
    }
    persistText(app, db, cache);
    const key = try app.alloc.dupe(u8, name);
    errdefer app.alloc.free(key);
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    if (app.text_cache.fetchRemove(name)) |old| {
        old.value.deinit();
        app.alloc.destroy(old.value);
        app.alloc.free(old.key);
    }
    try app.text_cache.put(app.alloc, key, cache);
    return cache;
}

fn textIntersect(result: *?std.StringHashMapUnmanaged(void), list: []const []const u8, arena: std.mem.Allocator) !bool {
    if (result.* == null) {
        var m: std.StringHashMapUnmanaged(void) = .empty;
        for (list) |id| try m.put(arena, id, {});
        result.* = m;
        return true;
    }
    var next: std.StringHashMapUnmanaged(void) = .empty;
    var kit = result.*.?.keyIterator();
    while (kit.next()) |idp| {
        var found = false;
        for (list) |id| {
            if (std.mem.eql(u8, id, idp.*)) {
                found = true;
                break;
            }
        }
        if (found) try next.put(arena, idp.*, {});
    }
    result.*.?.deinit(arena);
    result.* = next;
    return true;
}

fn textCandidates(app: *App, db: *Db, name: []const u8, query: []const u8, arena: std.mem.Allocator) !?std.StringHashMapUnmanaged(void) {
    const cache = try textCacheFor(app, db, name);
    var result: ?std.StringHashMapUnmanaged(void) = null;
    errdefer if (result) |*m| m.deinit(arena);
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var any = false;
    while (words.next()) |word| {
        var field: ?[]const u8 = null;
        var rest = word;
        if (std.mem.indexOfScalar(u8, word, ':')) |colon| {
            if (colon > 0 and colon + 1 < word.len) {
                field = word[0..colon];
                rest = word[colon + 1 ..];
            }
        }
        var terms = textTokenize(rest);
        while (terms.next()) |raw| {
            any = true;
            const term = try textLowerToken(arena, raw);
            const key = if (field) |f| try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ f, term }) else term;
            const list = cache.index.get(key) orelse {
                if (result) |*m| m.deinit(arena);
                result = .empty;
                return result;
            };
            _ = try textIntersect(&result, list.items, arena);
        }
    }
    if (!any) return null;
    return result;
}

fn hFind(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const sel = root.object.get("selector") orelse return err(res, 400, "bad_request", "missing selector");
    if (findUnknownOperator(sel)) |bad| {
        // CouchDB's wording: clients and tests match on it.
        const reason = try std.fmt.allocPrint(res.arena, "Invalid operator: {s}", .{bad});
        return err(res, 400, "invalid_operator", reason);
    }
    const limit: usize = if (root.object.get("limit")) |v|
        (if (v == .integer and v.integer > 0) (std.math.cast(usize, v.integer) orelse std.math.maxInt(usize)) else 25)
    else
        25;
    const skip: usize = if (root.object.get("skip")) |v|
        (if (v == .integer and v.integer > 0) @intCast(v.integer) else 0)
    else
        0;
    const fields = root.object.get("fields");
    const bookmark_data: ?BookmarkData = if (root.object.get("bookmark")) |bv| blk: {
        if (bv != .string) break :blk null;
        break :blk decodeBookmark(res.arena, bv.string) catch
            return err(res, 400, "bad_request", "invalid bookmark");
    } else null;

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const started = Io.Timestamp.now(app.io, .awake);
    var examined_docs: usize = 0;
    var examined_keys: usize = 0;
    const want_stats = if (root.object.get("execution_stats")) |sv| (sv == .bool and sv.bool) else false;
    var use_index_fields: ?[]const std.json.Value = null;
    var use_index_partial: ?std.json.Value = null;
    if (root.object.get("use_index")) |uiv| {
        if (uiv != .array or uiv.array.items.len != 2) return err(res, 400, "bad_request", "use_index must be [ddoc, name]");
        if (uiv.array.items[0] != .string or uiv.array.items[1] != .string) return err(res, 400, "bad_request", "use_index must be [ddoc, name]");
        const ddoc_id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{uiv.array.items[0].string});
        const ddoc = db.get(ddoc_id) orelse return err(res, 400, "bad_request", "unknown index");
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, ddoc.winnerLeaf().body, .{}) catch return err(res, 400, "bad_request", "unknown index");
        if (parsed.value != .object) return err(res, 400, "bad_request", "unknown index");
        const zi = parsed.value.object.get("zouch_indexes") orelse return err(res, 400, "bad_request", "unknown index");
        if (zi != .object) return err(res, 400, "bad_request", "unknown index");
        const entry = zi.object.get(uiv.array.items[1].string) orelse return err(res, 400, "bad_request", "unknown index");
        if (entry != .object) return err(res, 400, "bad_request", "unknown index");
        const index_fields = entry.object.get("fields") orelse return err(res, 400, "bad_request", "index has no fields");
        if (index_fields != .array) return err(res, 400, "bad_request", "index has invalid fields");
        use_index_fields = index_fields.array.items;
        use_index_partial = entry.object.get("partial_filter_selector");
    }

    var sort_specs: std.ArrayListUnmanaged(SortSpec) = .empty;
    defer sort_specs.deinit(res.arena);
    var sort_field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sort_field_names.deinit(res.arena);
    if (root.object.get("sort")) |sv| {
        if (sv == .array) {
            for (sv.array.items) |item| {
                if (item == .string) {
                    try sort_specs.append(res.arena, .{ .field = item.string, .desc = false });
                    try sort_field_names.append(res.arena, item.string);
                } else if (item == .object) {
                    const keys = item.object.keys();
                    if (keys.len > 0) {
                        var desc = false;
                        if (item.object.get(keys[0])) |dir| {
                            if (dir == .string and std.mem.eql(u8, dir.string, "desc")) desc = true;
                        }
                        try sort_specs.append(res.arena, .{ .field = keys[0], .desc = desc });
                        try sort_field_names.append(res.arena, keys[0]);
                    }
                }
            }
        }
    }
    const sort_field: ?[]const u8 = if (sort_specs.items.len > 0) sort_specs.items[0].field else null;
    const sort_desc: bool = if (sort_specs.items.len > 0) sort_specs.items[0].desc else false;

    // CouchDB refuses a sort no index can serve instead of scanning and sorting
    // (measured: even `sort:["_id"]` is refused unless the selector ranges over
    // `_id`, which lets `_all_docs` answer it).
    if (sort_specs.items.len == 1) {
        const sf = sort_specs.items[0].field;
        const has_index = loadMangoIndex(db, res.arena, sf) != null or findPartialIndexFor(db, res.arena, sf, sel) != null;
        const id_ranged = std.mem.eql(u8, sf, "_id") and selectorRangesField(sel, "_id");
        if (!has_index and !id_ranged) {
            return err(res, 400, "no_usable_index", "No index exists for this sort, try indexing by the sort fields.");
        }
    } else if (sort_specs.items.len > 1) {
        const has_multi = loadMangoIndexFields(db, res.arena, sort_field_names.items) != null;
        if (!has_multi) {
            return err(res, 400, "no_usable_index", "No index exists for this sort, try indexing by the sort fields.");
        }
    }

    var matches: std.ArrayListUnmanaged(SortHit) = .empty;
    defer matches.deinit(res.arena);
    var used_index = false;
    var pre_sorted = false;
    var candidate_map: ?std.StringHashMapUnmanaged(void) = null;
    defer if (candidate_map) |*m| m.deinit(res.arena);
    if (sel == .object) {
        if (sel.object.get("$text")) |tv| {
            const q_str: ?[]const u8 = switch (tv) {
                .string => |s| s,
                .object => |obj| if (obj.get("$search")) |sv| (if (sv == .string) sv.string else null) else null,
                else => null,
            };
            if (q_str) |qs| {
                if (try textCandidates(app, db, name, qs, res.arena)) |m| {
                    candidate_map = m;
                    used_index = true;
                }
            }
        }
    }
    if (sel == .object and use_index_fields != null and use_index_fields.?.len >= 1) {
        const uf = use_index_fields.?;
        var prefix_vals: std.ArrayListUnmanaged(std.json.Value) = .empty;
        defer prefix_vals.deinit(res.arena);
        var last_eq: ?std.json.Value = null;
        var last_lower: ?std.json.Value = null;
        var last_upper: ?std.json.Value = null;
        var last_lower_incl = false;
        var last_upper_incl = false;
        var usable = true;
        var ufields: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ufields.deinit(res.arena);
        for (uf, 0..) |fv, fi| {
            const fname = indexFieldName(fv) orelse {
                usable = false;
                break;
            };
            try ufields.append(res.arena, fname);
            const cond = sel.object.get(fname) orelse {
                usable = false;
                break;
            };
            if (fi + 1 < uf.len) {
                const eq: ?std.json.Value = if (cond == .object) cond.object.get("$eq") else cond;
                if (eq == null) {
                    usable = false;
                    break;
                }
                try prefix_vals.append(res.arena, eq.?);
            } else {
                if (cond == .object) {
                    last_eq = cond.object.get("$eq");
                    if (last_eq == null) {
                        last_lower = cond.object.get("$gt");
                        if (last_lower == null) {
                            last_lower = cond.object.get("$gte");
                            last_lower_incl = last_lower != null;
                        }
                        last_upper = cond.object.get("$lt");
                        if (last_upper == null) {
                            last_upper = cond.object.get("$lte");
                            last_upper_incl = last_upper != null;
                        }
                        if (last_lower == null and last_upper == null) usable = false;
                    }
                } else {
                    last_eq = cond;
                }
            }
        }
        if (use_index_partial) |pfs| {
            if (!selectorImplies(sel, pfs)) usable = false;
        }
        if (usable) {
            const maybe_idx = if (ufields.items.len == 1)
                loadMangoIndexOpt(app, db, name, res.arena, ufields.items[0], use_index_partial)
            else
                loadMangoIndexFieldsOpt(app, db, name, res.arena, ufields.items, use_index_partial);
            if (maybe_idx) |idx| {
                const rows_v = idx.object.get("rows") orelse null;
                var ids: std.ArrayListUnmanaged([]const u8) = .empty;
                defer ids.deinit(res.arena);
                if (rows_v) |rv| {
                    if (rv == .array) {
                        if (uf.len == 1) {
                            try collectMangoRangeIds(rv.array.items, last_eq, last_lower, last_lower_incl, last_upper, last_upper_incl, &examined_keys, res.arena, &ids);
                        } else {
                            for (rv.array.items) |row| {
                                examined_keys += 1;
                                if (row != .object) continue;
                                const id_v = row.object.get("id") orelse continue;
                                const key_v = row.object.get("key") orelse continue;
                                if (id_v != .string) continue;
                                if (key_v != .array or key_v.array.items.len != uf.len) continue;
                                var prefix_ok = true;
                                for (prefix_vals.items, 0..) |pv, pi| {
                                    if (valueCmp(key_v.array.items[pi], pv) != 0) {
                                        prefix_ok = false;
                                        break;
                                    }
                                }
                                if (!prefix_ok) continue;
                                const last_key = key_v.array.items[uf.len - 1];
                                if (last_eq) |qv| {
                                    if (valueCmp(last_key, qv) != 0) continue;
                                }
                                if (last_lower) |lv| {
                                    const c = valueCmp(last_key, lv) orelse continue;
                                    if (if (last_lower_incl) c < 0 else c <= 0) continue;
                                }
                                if (last_upper) |uv| {
                                    const c = valueCmp(last_key, uv) orelse continue;
                                    if (if (last_upper_incl) c > 0 else c >= 0) continue;
                                }
                                try ids.append(res.arena, id_v.string);
                            }
                        }
                    }
                }
                if (candidate_map == null) {
                    var m: std.StringHashMapUnmanaged(void) = .empty;
                    for (ids.items) |id| try m.put(res.arena, id, {});
                    candidate_map = m;
                } else {
                    var next: std.StringHashMapUnmanaged(void) = .empty;
                    for (ids.items) |id| if (candidate_map.?.contains(id)) try next.put(res.arena, id, {});
                    candidate_map.?.deinit(res.arena);
                    candidate_map = next;
                }
                used_index = true;
            }
        }
    }
    if (sel == .object) {
        const field_keys = sel.object.keys();
        const field_vals = sel.object.values();
        for (field_keys, field_vals) |indexed_field, cond| {
            if (indexed_field.len == 0 or indexed_field[0] == '$') continue;
            var eq: ?std.json.Value = null;
            var lower: ?std.json.Value = null;
            var upper: ?std.json.Value = null;
            var lower_inclusive = false;
            var upper_inclusive = false;
            if (cond == .object) {
                eq = cond.object.get("$eq");
                lower = cond.object.get("$gt");
                if (lower == null) {
                    lower = cond.object.get("$gte");
                    lower_inclusive = lower != null;
                }
                upper = cond.object.get("$lt");
                if (upper == null) {
                    upper = cond.object.get("$lte");
                    upper_inclusive = upper != null;
                }
            } else {
                eq = cond;
            }
            if (eq == null and lower == null and upper == null) continue;
            const pm = findPartialIndexFor(db, res.arena, indexed_field, sel);
            const idx = if (pm) |p|
                (loadMangoIndexOpt(app, db, name, res.arena, indexed_field, p.pfs) orelse continue)
            else
                (loadMangoIndexOpt(app, db, name, res.arena, indexed_field, null) orelse continue);
            const rows_v = idx.object.get("rows") orelse continue;
            if (rows_v != .array) continue;
            var ids: std.ArrayListUnmanaged([]const u8) = .empty;
            defer ids.deinit(res.arena);
            try collectMangoRangeIds(rows_v.array.items, eq, lower, lower_inclusive, upper, upper_inclusive, &examined_keys, res.arena, &ids);
            if (field_keys.len == 1 and sort_specs.items.len == 1 and std.mem.eql(u8, sort_field.?, indexed_field)) {
                for (ids.items) |id| {
                    const d = db.get(id) orelse continue;
                    examined_docs += 1;
                    if (d.winnerLeaf().deleted) continue;
                    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
                    if (!matchSelector(parsed.value, sel)) continue;
                    const key = valueAtPath(parsed.value, sort_field.?);
                    const keys = try res.arena.alloc(?std.json.Value, 1);
                    keys[0] = key;
                    try matches.append(res.arena, .{ .doc = d, .key = key, .keys = keys });
                }
                used_index = true;
                pre_sorted = true;
                break;
            }
            if (candidate_map == null) {
                var m: std.StringHashMapUnmanaged(void) = .empty;
                for (ids.items) |id| try m.put(res.arena, id, {});
                candidate_map = m;
            } else {
                var next: std.StringHashMapUnmanaged(void) = .empty;
                for (ids.items) |id| {
                    if (candidate_map.?.contains(id)) try next.put(res.arena, id, {});
                }
                candidate_map.?.deinit(res.arena);
                candidate_map = next;
            }
            used_index = true;
        }
    }
    if (candidate_map) |*m| {
        var kit = m.keyIterator();
        while (kit.next()) |idp| {
            const d = db.get(idp.*) orelse continue;
            examined_docs += 1;
            if (d.winnerLeaf().deleted) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
            if (!matchSelector(parsed.value, sel)) continue;
            const keys = try res.arena.alloc(?std.json.Value, sort_specs.items.len);
            for (sort_specs.items, 0..) |sp, si| {
                keys[si] = if (std.mem.eql(u8, sp.field, "_id")) .{ .string = d.id } else valueAtPath(parsed.value, sp.field);
            }
            const key = if (keys.len > 0) keys[0] else null;
            try matches.append(res.arena, .{ .doc = d, .key = key, .keys = keys });
        }
    }
    if (!used_index) {
        var it = db.docs.valueIterator();
        while (it.next()) |d| {
            examined_docs += 1;
            if (d.*.winnerLeaf().deleted) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.*.winnerLeaf().body, .{}) catch continue;
            if (!matchSelector(parsed.value, sel)) continue;
            const keys = try res.arena.alloc(?std.json.Value, sort_specs.items.len);
            for (sort_specs.items, 0..) |sp, si| {
                keys[si] = if (std.mem.eql(u8, sp.field, "_id")) .{ .string = d.*.id } else valueAtPath(parsed.value, sp.field);
            }
            const key = if (keys.len > 0) keys[0] else null;
            try matches.append(res.arena, .{ .doc = d.*, .key = key, .keys = keys });
        }
    }
    if (pre_sorted) {
        if (sort_desc) std.mem.reverse(SortHit, matches.items);
    } else if (sort_specs.items.len > 0) {
        std.mem.sort(SortHit, matches.items, sort_specs.items, struct {
            fn less(specs: []const SortSpec, a: SortHit, b: SortHit) bool {
                for (specs, 0..) |sp, si| {
                    const ka = a.keys[si];
                    const kb = b.keys[si];
                    if (ka == null and kb == null) continue;
                    if (ka == null) return false;
                    if (kb == null) return true;
                    const c = valueCmp(ka.?, kb.?) orelse 0;
                    if (c != 0) return if (sp.desc) c > 0 else c < 0;
                }
                return std.mem.lessThan(u8, a.doc.id, b.doc.id);
            }
        }.less);
    } else {
        std.mem.sort(SortHit, matches.items, {}, struct {
            fn less(_: void, a: SortHit, b: SortHit) bool {
                return std.mem.lessThan(u8, a.doc.id, b.doc.id);
            }
        }.less);
    }

    var bookmarked: usize = 0;
    if (bookmark_data) |bm| {
        var found_bm = false;
        for (matches.items, 0..) |hit, i| {
            if (std.mem.eql(u8, hit.doc.id, bm.id)) {
                bookmarked = i + 1;
                found_bm = true;
                break;
            }
        }
        if (!found_bm) {
            if (bm.key != null and sort_specs.items.len == 1) {
                for (matches.items, 0..) |hit, i| {
                    const hk = hit.key orelse continue;
                    const c = valueCmp(hk, bm.key.?) orelse 0;
                    const past = if (sort_desc) c < 0 or (c == 0 and std.mem.lessThan(u8, bm.id, hit.doc.id)) else c > 0 or (c == 0 and std.mem.lessThan(u8, bm.id, hit.doc.id));
                    if (past) {
                        bookmarked = i;
                        found_bm = true;
                        break;
                    }
                }
                if (!found_bm) bookmarked = matches.items.len;
            } else if (bm.offset) |off| {
                bookmarked = @min(off, matches.items.len);
            }
        }
    }
    const start = @min(bookmarked +| skip, matches.items.len);
    var end = matches.items.len;
    if (end - start > limit) end = start + limit;

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"docs\":[");
    var j = start;
    while (j < end) : (j += 1) {
        if (j != start) try l.append(res.arena, ',');
        const d = matches.items[j].doc;
        if (fields) |fv| {
            if (fv == .array) {
                const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
                var proj: std.json.ObjectMap = .empty;
                for (fv.array.items) |field| {
                    if (field != .string) continue;
                    if (std.mem.eql(u8, field.string, "_id")) {
                        try proj.put(res.arena, "_id", .{ .string = d.id });
                    } else if (std.mem.eql(u8, field.string, "_rev")) {
                        var revbuf: [64]u8 = undefined;
                        try proj.put(res.arena, "_rev", .{ .string = try res.arena.dupe(u8, d.winnerLeaf().rev.write(&revbuf)) });
                    } else if (parsed.value == .object) {
                        if (valueAtPath(parsed.value, field.string)) |val| {
                            try insertAtPath(res.arena, &proj, field.string, val);
                        }
                    }
                }
                try jsonw.writeValue(&l, res.arena, .{ .object = proj });
                continue;
            }
        }
        try writeDoc(db, &l, res.arena, d, d.winner, false, false, false);
    }
    try l.appendSlice(res.arena, "],\"bookmark\":");
    if (end > start) {
        const last_hit = matches.items[end - 1];
        const bm = try encodeBookmark(res.arena, last_hit.doc.id, end, last_hit.key);
        try jsonw.writeString(&l, res.arena, bm);
    } else {
        try l.appendSlice(res.arena, "\"nil\"");
    }
    // CouchDB says so when the query had to scan rather than use an index; this
    // store scans unless a full-text index answered it, so the warning is true
    // exactly when nothing else did.
    if (!used_index and !pre_sorted) {
        try l.appendSlice(res.arena, ",\"warning\":\"No matching index found, create an index to optimize query time.\"");
    }
    if (want_stats) {
        const elapsed = started.durationTo(Io.Timestamp.now(app.io, .awake)).nanoseconds;
        const ms: i96 = @divTrunc(if (elapsed < 0) 0 else elapsed, 1_000_000);
        try l.appendSlice(res.arena, ",\"execution_stats\":{\"total_keys_examined\":");
        try appendInt(&l, res.arena, examined_keys);
        try l.appendSlice(res.arena, ",\"total_docs_examined\":");
        try appendInt(&l, res.arena, examined_docs);
        try l.appendSlice(res.arena, ",\"total_quorum_docs_examined\":0,\"results_returned\":");
        try appendInt(&l, res.arena, end - start);
        try l.appendSlice(res.arena, ",\"execution_time_ms\":");
        try appendInt(&l, res.arena, ms);
        try l.append(res.arena, '}');
    }
    try l.append(res.arena, '}');
    res.content_type = .JSON;
    res.body = l.items;
}

/// Whether the selector constrains `field` to a value or a range, which is what
/// lets CouchDB answer a `_id` sort from `_all_docs`.
fn selectorRangesField(sel: std.json.Value, field: []const u8) bool {
    if (sel != .object) return false;
    const cond = sel.object.get(field) orelse return false;
    if (cond != .object) return true;
    for ([_][]const u8{ "$eq", "$gt", "$gte", "$lt", "$lte" }) |op| {
        if (cond.object.get(op) != null) return true;
    }
    return false;
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string, .string => |v| std.mem.eql(u8, v, switch (b) {
            .number_string, .string => |s| s,
            else => unreachable,
        }),
        .array => |arr| blk: {
            if (arr.items.len != b.array.items.len) break :blk false;
            for (arr.items, b.array.items) |ai, bi| {
                if (!jsonValuesEqual(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != b.object.count()) break :blk false;
            for (obj.keys(), obj.values()) |k, v| {
                const bv = b.object.get(k) orelse break :blk false;
                if (!jsonValuesEqual(v, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn hIndexCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const auth = try requestAuth(app, req, res);
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (!isDbAdminFor(db, auth)) return err(res, 403, "forbidden", "You are not a db or server admin.");

    const idx_v = root.object.get("index") orelse return err(res, 400, "bad_request", "missing index");
    if (idx_v != .object) return err(res, 400, "bad_request", "index must be an object");
    const fields_v = idx_v.object.get("fields") orelse return err(res, 400, "bad_request", "missing fields");
    if (fields_v != .array or fields_v.array.items.len == 0) return err(res, 400, "bad_request", "fields must be a non-empty array");
    var field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer field_names.deinit(res.arena);
    for (fields_v.array.items) |fv| {
        const fname = indexFieldName(fv) orelse
            return err(res, 400, "bad_request", "fields must be field names or {field: direction} objects");
        if (fv == .object) {
            const dir = fv.object.get(fname).?;
            if (dir != .string or (!std.mem.eql(u8, dir.string, "asc") and !std.mem.eql(u8, dir.string, "desc"))) {
                return err(res, 400, "bad_request", "sort direction must be 'asc' or 'desc'");
            }
        }
        try field_names.append(res.arena, fname);
    }
    const pfs_v: ?std.json.Value = idx_v.object.get("partial_filter_selector") orelse root.object.get("partial_filter_selector");
    if (pfs_v) |pfs| {
        if (pfs != .object) return err(res, 400, "bad_request", "partial_filter_selector must be an object");
        if (findUnknownOperator(pfs)) |bad| {
            const reason = try std.fmt.allocPrint(res.arena, "Invalid operator: {s}", .{bad});
            return err(res, 400, "invalid_operator", reason);
        }
    }
    const index_name = if (root.object.get("name")) |v| (if (v == .string) v.string else "zouch_index") else "zouch_index";
    const ddoc = if (root.object.get("ddoc")) |v| (if (v == .string) v.string else "zouch") else "zouch";
    const ddoc_id = if (std.mem.startsWith(u8, ddoc, "_design/"))
        try res.arena.dupe(u8, ddoc)
    else
        try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc});

    var doc_obj: std.json.ObjectMap = .empty;
    var parent: ?Rev = null;
    if (db.get(ddoc_id)) |existing| {
        if (!existing.winnerLeaf().deleted) {
            parent = existing.winnerLeaf().rev;
            const parsed = std.json.parseFromSlice(std.json.Value, res.arena, existing.winnerLeaf().body, .{}) catch null;
            if (parsed) |p| {
                if (p.value == .object) doc_obj = p.value.object;
            }
        }
    }
    var indexes: std.json.ObjectMap = .empty;
    if (doc_obj.get("zouch_indexes")) |zi| {
        if (zi == .object) indexes = zi.object;
    }
    if (indexes.get(index_name)) |prev_val| {
        if (prev_val == .object) {
            const prev_fields = prev_val.object.get("fields") orelse .null;
            const prev_pfs = prev_val.object.get("partial_filter_selector");
            const same_fields = jsonValuesEqual(prev_fields, fields_v);
            const same_pfs = if (prev_pfs == null and pfs_v == null)
                true
            else if (prev_pfs != null and pfs_v != null)
                jsonValuesEqual(prev_pfs.?, pfs_v.?)
            else
                false;
            if (same_fields and same_pfs) {
                var l: std.ArrayListUnmanaged(u8) = .empty;
                try l.appendSlice(res.arena, "{\"result\":\"exists\",\"id\":");
                try jsonw.writeString(&l, res.arena, ddoc_id);
                try l.appendSlice(res.arena, ",\"name\":");
                try jsonw.writeString(&l, res.arena, index_name);
                try l.append(res.arena, '}');
                res.status = 200;
                res.content_type = .JSON;
                res.body = l.items;
                return;
            }
            return err(res, 400, "invalid_index", "Cannot overwrite existing index with different definition");
        }
    }
    var entry: std.json.ObjectMap = .empty;
    try entry.put(res.arena, "name", .{ .string = index_name });
    try entry.put(res.arena, "fields", fields_v);
    try entry.put(res.arena, "type", .{ .string = "json" });
    if (pfs_v) |pfs| {
        try entry.put(res.arena, "partial_filter_selector", pfs);
    }
    try indexes.put(res.arena, index_name, .{ .object = entry });
    try doc_obj.put(res.arena, "zouch_indexes", .{ .object = indexes });

    var store: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&store, res.arena, .{ .object = doc_obj });
    _ = db.putLocal(ddoc_id, store.items, parent, false) catch |e| switch (e) {
        error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
        else => return e,
    };

    if (field_names.items.len > 1) {
        buildMangoIndexFieldsOpt(app, db, name, res.arena, field_names.items, pfs_v) catch {};
    } else {
        buildMangoIndexOpt(app, db, name, res.arena, field_names.items[0], pfs_v) catch {};
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"result\":\"created\",\"id\":");
    try jsonw.writeString(&l, res.arena, ddoc_id);
    try l.appendSlice(res.arena, ",\"name\":");
    try jsonw.writeString(&l, res.arena, index_name);
    try l.append(res.arena, '}');
    res.status = 200;
    res.content_type = .JSON;
    res.body = l.items;
}

fn hIndexList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var indexes: std.ArrayListUnmanaged(*Doc) = .empty;
    defer indexes.deinit(res.arena);
    var it = db.docs.valueIterator();
    while (it.next()) |d| {
        if (d.*.winnerLeaf().deleted) continue;
        if (!std.mem.startsWith(u8, d.*.id, "_design/")) continue;
        try indexes.append(res.arena, d.*);
    }
    sortById(indexes.items);

    var count: usize = 0;
    for (indexes.items) |d| {
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const zi = parsed.value.object.get("zouch_indexes") orelse continue;
        if (zi != .object) continue;
        count += zi.object.count();
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"total_rows\":");
    try appendInt(&l, res.arena, count);
    try l.appendSlice(res.arena, ",\"indexes\":[");
    var first = true;
    for (indexes.items) |d| {
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, d.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const zi = parsed.value.object.get("zouch_indexes") orelse continue;
        if (zi != .object) continue;
        const keys = zi.object.keys();
        const vals = zi.object.values();
        for (keys, vals) |k, v| {
            if (v != .object) continue;
            if (!first) try l.append(res.arena, ',');
            first = false;
            try l.appendSlice(res.arena, "{\"ddoc\":");
            try jsonw.writeString(&l, res.arena, d.id);
            try l.appendSlice(res.arena, ",\"name\":");
            try jsonw.writeString(&l, res.arena, k);
            try l.appendSlice(res.arena, ",\"type\":\"json\",\"def\":{\"fields\":");
            if (v.object.get("fields")) |f| {
                try jsonw.writeValue(&l, res.arena, f);
            } else {
                try l.appendSlice(res.arena, "[]");
            }
            if (v.object.get("partial_filter_selector")) |pfs| {
                try l.appendSlice(res.arena, ",\"partial_filter_selector\":");
                try jsonw.writeValue(&l, res.arena, pfs);
            }
            try l.appendSlice(res.arena, "}}");
        }
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hIndexDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ddoc_raw = req.params.get("ddoc") orelse return err(res, 400, "bad_request", "missing ddoc");
    const idx_type = req.params.get("type") orelse return err(res, 400, "bad_request", "missing type");
    const index_name = req.params.get("name") orelse return err(res, 400, "bad_request", "missing name");
    const auth = try requestAuth(app, req, res);
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (!isDbAdminFor(db, auth)) return err(res, 403, "forbidden", "You are not a db or server admin.");

    if (!std.mem.eql(u8, idx_type, "json")) {
        return err(res, 404, "not_found", "missing");
    }
    const ddoc_id = if (std.mem.startsWith(u8, ddoc_raw, "_design/"))
        ddoc_raw
    else
        try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc_raw});

    const existing = db.get(ddoc_id) orelse return err(res, 404, "not_found", "missing");
    if (existing.winnerLeaf().deleted) return err(res, 404, "not_found", "missing");

    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, existing.winnerLeaf().body, .{}) catch
        return err(res, 404, "not_found", "missing");
    if (parsed.value != .object) return err(res, 404, "not_found", "missing");

    var doc_obj = parsed.value.object;
    const zi = doc_obj.get("zouch_indexes") orelse return err(res, 404, "not_found", "missing");
    if (zi != .object) return err(res, 404, "not_found", "missing");
    var indexes = zi.object;
    const removed_entry = indexes.get(index_name) orelse return err(res, 404, "not_found", "missing");
    var idx_file_to_delete: ?[]const u8 = null;
    if (removed_entry == .object) {
        if (removed_entry.object.get("fields")) |fv| {
            if (fv == .array and fv.array.items.len > 0) {
                var field_names: std.ArrayListUnmanaged([]const u8) = .empty;
                for (fv.array.items) |item| {
                    if (indexFieldName(item)) |fname| {
                        field_names.append(res.arena, fname) catch {};
                    }
                }
                if (field_names.items.len > 0) {
                    const pfs = removed_entry.object.get("partial_filter_selector");
                    idx_file_to_delete = mangoIndexNameWithFilter(res.arena, field_names.items, pfs) catch null;
                }
            }
        }
    }
    if (!indexes.orderedRemove(index_name)) {
        return err(res, 404, "not_found", "missing");
    }

    if (indexes.count() == 0) {
        _ = doc_obj.orderedRemove("zouch_indexes");
    } else {
        try doc_obj.put(res.arena, "zouch_indexes", .{ .object = indexes });
    }

    var has_other_content = false;
    for (doc_obj.keys()) |k| {
        if (!std.mem.eql(u8, k, "_id") and !std.mem.eql(u8, k, "_rev")) {
            has_other_content = true;
            break;
        }
    }

    if (!has_other_content) {
        _ = db.putLocal(ddoc_id, "{}", existing.winnerLeaf().rev, true) catch |e| switch (e) {
            error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
            else => return e,
        };
    } else {
        var store: std.ArrayListUnmanaged(u8) = .empty;
        try jsonw.writeValue(&store, res.arena, .{ .object = doc_obj });
        _ = db.putLocal(ddoc_id, store.items, existing.winnerLeaf().rev, false) catch |e| switch (e) {
            error.Conflict => return err(res, 409, "conflict", "Document update conflict."),
            else => return e,
        };
    }
    if (idx_file_to_delete) |idx_file| db.deleteMangoIndex(idx_file);

    res.status = 200;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn mangoLowerBound(items: []const std.json.Value, target: std.json.Value, inclusive: bool) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const row = items[mid];
        const key_v = if (row == .object) (row.object.get("key") orelse .null) else .null;
        const c = valueCmp(key_v, target) orelse 0;
        const go_right = if (inclusive) c < 0 else c <= 0;
        if (go_right) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn collectMangoRangeIds(
    items: []const std.json.Value,
    eq: ?std.json.Value,
    lower: ?std.json.Value,
    lower_inclusive: bool,
    upper: ?std.json.Value,
    upper_inclusive: bool,
    examined_keys: *usize,
    alloc: std.mem.Allocator,
    ids: *std.ArrayListUnmanaged([]const u8),
) !void {
    const start_idx: usize = if (eq) |qv|
        mangoLowerBound(items, qv, true)
    else if (lower) |lv|
        mangoLowerBound(items, lv, lower_inclusive)
    else
        0;

    for (items[start_idx..]) |row| {
        examined_keys.* += 1;
        if (row != .object) continue;
        const id_v = row.object.get("id") orelse continue;
        const key_v = row.object.get("key") orelse continue;
        if (id_v != .string) continue;
        if (eq) |qv| {
            if (valueCmp(key_v, qv) != 0) break;
        }
        if (lower) |lv| {
            const c = valueCmp(key_v, lv) orelse continue;
            if (if (lower_inclusive) c < 0 else c <= 0) continue;
        }
        if (upper) |uv| {
            const c = valueCmp(key_v, uv) orelse continue;
            if (if (upper_inclusive) c > 0 else c >= 0) break;
        }
        try ids.append(alloc, id_v.string);
    }
}

fn hasMangoIndexDeclared(db: *Db, arena: std.mem.Allocator, fields: []const []const u8) bool {
    var it = db.designs.keyIterator();
    while (it.next()) |did_ptr| {
        const ddoc = db.get(did_ptr.*) orelse continue;
        if (ddoc.winnerLeaf().deleted) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, ddoc.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const zi = parsed.value.object.get("zouch_indexes") orelse continue;
        if (zi != .object) continue;
        for (zi.object.values()) |entry| {
            if (entry != .object) continue;
            if (entry.object.get("partial_filter_selector") != null) continue;
            const flds = entry.object.get("fields") orelse continue;
            if (flds != .array or flds.array.items.len != fields.len) continue;
            var match = true;
            for (flds.array.items, fields) |fv, expected| {
                const fname = indexFieldName(fv) orelse {
                    match = false;
                    break;
                };
                if (!std.mem.eql(u8, fname, expected)) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
    }
    return false;
}

const ExplainIndexLoc = struct {
    ddoc_id: []const u8,
    name: []const u8,
};

fn explainIndexLocFor(db: *Db, arena: std.mem.Allocator, field: []const u8) ?ExplainIndexLoc {
    var it = db.designs.keyIterator();
    while (it.next()) |did_ptr| {
        const ddoc = db.get(did_ptr.*) orelse continue;
        if (ddoc.winnerLeaf().deleted) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, ddoc.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const indexes = parsed.value.object.get("zouch_indexes") orelse continue;
        if (indexes != .object) continue;
        var zit = indexes.object.iterator();
        while (zit.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            if (entry.value_ptr.*.object.get("partial_filter_selector") != null) continue;
            const fields = entry.value_ptr.*.object.get("fields") orelse continue;
            if (fields != .array or fields.array.items.len != 1) continue;
            const fname = indexFieldName(fields.array.items[0]) orelse continue;
            if (std.mem.eql(u8, fname, field)) return .{ .ddoc_id = did_ptr.*, .name = entry.key_ptr.* };
        }
    }
    return null;
}

/// The name an index was created under, found by the first field it covers.
/// Indexes live in `_design/zouch` under `zouch_indexes`.
fn explainIndexNameFor(db: *Db, arena: std.mem.Allocator, field: []const u8) ?[]const u8 {
    const ddoc = db.get("_design/zouch") orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, ddoc.winnerLeaf().body, .{}) catch return null;
    if (parsed.value != .object) return null;
    const indexes = parsed.value.object.get("zouch_indexes") orelse return null;
    if (indexes != .object) return null;
    var it = indexes.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const fields = entry.value_ptr.*.object.get("fields") orelse continue;
        if (fields != .array or fields.array.items.len == 0) continue;
        const first = fields.array.items[0];
        const fname = indexFieldName(first) orelse continue;
        if (std.mem.eql(u8, fname, field)) return entry.key_ptr.*;
    }
    return null;
}

/// CouchDB lists the local documents (`_local/...`) here, which is how a
/// replication's checkpoint can be seen - or shown to be absent when
/// `use_checkpoints` is false. `total_rows` and `offset` are null, as CouchDB
/// reports them.
fn hLocalDocs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"total_rows\":null,\"offset\":null,\"rows\":[");
    var it = db.locals.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try l.append(res.arena, ',');
        first = false;
        try l.appendSlice(res.arena, "{\"id\":");
        try jsonw.writeString(&l, res.arena, entry.key_ptr.*);
        try l.appendSlice(res.arena, ",\"key\":");
        try jsonw.writeString(&l, res.arena, entry.key_ptr.*);
        try l.appendSlice(res.arena, ",\"value\":{\"rev\":");
        var rev_buf: [24]u8 = undefined;
        const rev = try std.fmt.bufPrint(&rev_buf, "0-{d}", .{entry.value_ptr.*.rev});
        try jsonw.writeString(&l, res.arena, rev);
        try l.appendSlice(res.arena, "}}");
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn explainSingleFieldJson(alloc: std.mem.Allocator, field: []const u8) ![]u8 {
    var fb: std.ArrayListUnmanaged(u8) = .empty;
    try fb.appendSlice(alloc, "[{");
    try jsonw.writeString(&fb, alloc, field);
    try fb.appendSlice(alloc, ":\"asc\"}]");
    return fb.items;
}

fn hExplain(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    var selector: ?std.json.Value = null;
    var limit: usize = 25;
    var skip: usize = 0;
    var hint_ddoc: ?[]const u8 = null;
    var hint_name: ?[]const u8 = null;
    var sort_field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sort_field_names.deinit(res.arena);
    if (fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else null) |body| {
        if (parseBody(res, body) catch null) |root| {
            if (root == .object) {
                selector = root.object.get("selector");
                if (root.object.get("limit")) |lv| {
                    if (lv == .integer and lv.integer >= 0) limit = @intCast(lv.integer);
                }
                if (root.object.get("skip")) |sv| {
                    if (sv == .integer and sv.integer >= 0) skip = @intCast(sv.integer);
                }
                if (root.object.get("use_index")) |uiv| {
                    if (uiv != .array or uiv.array.items.len != 2 or uiv.array.items[0] != .string or uiv.array.items[1] != .string)
                        return err(res, 400, "bad_request", "use_index must be [ddoc, name]");
                    hint_ddoc = uiv.array.items[0].string;
                    hint_name = uiv.array.items[1].string;
                }
                if (root.object.get("sort")) |sv| {
                    if (sv == .array) {
                        for (sv.array.items) |item| {
                            if (indexFieldName(item)) |fname| {
                                try sort_field_names.append(res.arena, fname);
                            }
                        }
                    }
                }
            }
        }
    }

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    if (sort_field_names.items.len == 1) {
        const sf = sort_field_names.items[0];
        const has_index = hasMangoIndexDeclared(db, res.arena, &.{sf}) or (selector != null and findPartialIndexFor(db, res.arena, sf, selector.?) != null);
        const id_ranged = selector != null and std.mem.eql(u8, sf, "_id") and selectorRangesField(selector.?, "_id");
        if (!has_index and !id_ranged) {
            return err(res, 400, "no_usable_index", "No index exists for this sort, try indexing by the sort fields.");
        }
    } else if (sort_field_names.items.len > 1) {
        if (!hasMangoIndexDeclared(db, res.arena, sort_field_names.items)) {
            return err(res, 400, "no_usable_index", "No index exists for this sort, try indexing by the sort fields.");
        }
    }

    var index_name: []const u8 = "_all_docs";
    var index_type: []const u8 = "special";
    var index_fields_json: []const u8 = "[{\"_id\":\"asc\"}]";
    var index_ddoc: ?[]const u8 = null;
    var index_pfs: ?std.json.Value = null;
    if (hint_name) |hn| {
        const ddoc_id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{hint_ddoc.?});
        const ddoc = db.get(ddoc_id) orelse return err(res, 400, "bad_request", "unknown index");
        const parsed_ddoc = std.json.parseFromSlice(std.json.Value, res.arena, ddoc.winnerLeaf().body, .{}) catch
            return err(res, 400, "bad_request", "unknown index");
        if (parsed_ddoc.value != .object) return err(res, 400, "bad_request", "unknown index");
        const zi = parsed_ddoc.value.object.get("zouch_indexes") orelse return err(res, 400, "bad_request", "unknown index");
        if (zi != .object) return err(res, 400, "bad_request", "unknown index");
        const entry = zi.object.get(hn) orelse return err(res, 400, "bad_request", "unknown index");
        if (entry != .object) return err(res, 400, "bad_request", "unknown index");
        const flds = entry.object.get("fields") orelse return err(res, 400, "bad_request", "index has no fields");
        if (flds != .array) return err(res, 400, "bad_request", "index has invalid fields");
        const pfs_opt = entry.object.get("partial_filter_selector");
        const pfs_ok = if (pfs_opt) |pfs| (selector != null and selectorImplies(selector.?, pfs)) else true;
        if (pfs_ok) {
            index_name = hn;
            index_type = "json";
            index_ddoc = ddoc_id;
            index_pfs = pfs_opt;
            var fb: std.ArrayListUnmanaged(u8) = .empty;
            try fb.append(res.arena, '[');
            for (flds.array.items, 0..) |f, i| {
                if (i != 0) try fb.append(res.arena, ',');
                if (f == .object) {
                    try jsonw.writeValue(&fb, res.arena, f);
                } else {
                    try fb.append(res.arena, '{');
                    try jsonw.writeString(&fb, res.arena, if (f == .string) f.string else "field");
                    try fb.appendSlice(res.arena, ":\"asc\"}");
                }
            }
            try fb.append(res.arena, ']');
            index_fields_json = fb.items;
        }
    } else if (selector) |sel| {
        if (sel == .object) {
            if (sel.object.get("$text") != null) {
                index_name = "_text";
                index_type = "text";
                index_fields_json = "[]";
            } else {
                for (sel.object.keys()) |field| {
                    if (field.len == 0 or field[0] == '$') continue;
                    if (findPartialIndexFor(db, res.arena, field, sel)) |pm| {
                        index_name = pm.name;
                        index_ddoc = pm.ddoc_id;
                        index_type = "json";
                        index_pfs = pm.pfs;
                        index_fields_json = try explainSingleFieldJson(res.arena, field);
                        break;
                    }
                    if (!hasMangoIndexDeclared(db, res.arena, &.{field})) continue;
                    // Report the index's own name, which is what CouchDB shows,
                    // not the field it was found by.
                    if (explainIndexLocFor(db, res.arena, field)) |loc| {
                        index_name = loc.name;
                        index_ddoc = loc.ddoc_id;
                    } else {
                        index_name = explainIndexNameFor(db, res.arena, field) orelse field;
                        index_ddoc = "_design/zouch";
                    }
                    index_type = "json";
                    index_fields_json = try explainSingleFieldJson(res.arena, field);
                    break;
                }
            }
        }
    }

    // CouchDB's explanation document: the index it would use, the selector it
    // read, the planner options, and hints about which fields could be indexed.
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"dbname\":");
    try jsonw.writeString(&l, res.arena, name);
    try l.appendSlice(res.arena, ",\"index\":{\"ddoc\":");
    if (index_ddoc) |dd| {
        try jsonw.writeString(&l, res.arena, dd);
    } else {
        try l.appendSlice(res.arena, "null");
    }
    try l.appendSlice(res.arena, ",\"name\":");
    try jsonw.writeString(&l, res.arena, index_name);
    try l.appendSlice(res.arena, ",\"type\":");
    try jsonw.writeString(&l, res.arena, index_type);
    try l.appendSlice(res.arena, ",\"partitioned\":false,\"def\":{\"fields\":");
    try l.appendSlice(res.arena, index_fields_json);
    if (index_pfs) |pfs| {
        try l.appendSlice(res.arena, ",\"partial_filter_selector\":");
        try jsonw.writeValue(&l, res.arena, pfs);
    }
    try l.appendSlice(res.arena, "}},\"partitioned\":false,\"selector\":");
    if (selector) |sel| {
        try jsonw.writeValue(&l, res.arena, sel);
    } else {
        try l.appendSlice(res.arena, "null");
    }
    try l.appendSlice(res.arena, ",\"opts\":{\"use_index\":[],\"bookmark\":\"nil\",\"limit\":");
    try appendInt(&l, res.arena, limit);
    try l.appendSlice(res.arena, ",\"skip\":");
    try appendInt(&l, res.arena, skip);
    try l.appendSlice(res.arena, ",\"sort\":{},\"fields\":[],\"partition\":\"\",\"r\":1," ++ "\"conflicts\":false,\"stale\":false,\"update\":true,\"stable\":false," ++ "\"execution_stats\":false,\"allow_fallback\":true},\"limit\":");
    try appendInt(&l, res.arena, limit);
    try l.appendSlice(res.arena, ",\"skip\":");
    try appendInt(&l, res.arena, skip);
    try l.appendSlice(res.arena, ",\"fields\":[],\"index_candidates\":[]");

    // Every top-level field the selector names could be indexed; operators
    // cannot. CouchDB reports both lists, so a client can tell why an index was
    // not picked.
    try l.appendSlice(res.arena, ",\"selector_hints\":[{\"type\":\"json\",\"indexable_fields\":[");
    var first_field = true;
    if (selector) |sel| {
        if (sel == .object) {
            for (sel.object.keys()) |field| {
                if (field.len == 0 or field[0] == '$') continue;
                if (!first_field) try l.append(res.arena, ',');
                try jsonw.writeString(&l, res.arena, field);
                first_field = false;
            }
        }
    }
    try l.appendSlice(res.arena, "],\"unindexable_fields\":[]}]");
    // The planner's map/reduce arguments and whether a covering index was used.
    try l.appendSlice(res.arena, ",\"covering\":false,\"mrargs\":{\"include_docs\":true,\"view_type\":\"map\"," ++ "\"reduce\":false,\"partition\":null,\"start_key\":null,\"end_key\":\"<MAX>\",\"direction\":\"fwd\"," ++ "\"stable\":false,\"update\":true,\"conflicts\":\"undefined\"}}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// `GET /{db}/_design/{ddoc}/_info`: what CouchDB reports about a view index.
/// Views are computed on demand here, so nothing is persisted and the sizes are
/// zero - but `update_seq` is the database's, and `signature` identifies the
/// design document, so a client watching for staleness still gets a truthful
/// answer: there is no stale index to wait for.
fn hDesignInfo(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ddoc = req.params.get("ddoc") orelse return err(res, 400, "bad_request", "missing ddoc");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    const id = try std.fmt.allocPrint(res.arena, "_design/{s}", .{ddoc});
    const doc = db.get(id) orelse return err(res, 404, "not_found", "missing");

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(doc.winnerLeaf().body, &digest, .{});
    var sig_buf: [std.crypto.hash.Md5.digest_length * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        sig_buf[i * 2] = hex[b >> 4];
        sig_buf[i * 2 + 1] = hex[b & 0x0f];
    }

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"name\":");
    try jsonw.writeString(&l, res.arena, ddoc);
    try l.appendSlice(res.arena, ",\"view_index\":{\"updates_pending\":{\"minimum\":0,\"preferred\":0,\"total\":0},\"waiting_commit\":false,\"waiting_clients\":0,\"updater_running\":false,\"update_seq\":");
    try appendInt(&l, res.arena, db.seq);
    try l.appendSlice(res.arena, ",\"purge_seq\":");
    try appendInt(&l, res.arena, db.purge_seq);
    try l.appendSlice(res.arena, ",\"compact_running\":false,\"sizes\":{\"file\":0,\"external\":0,\"active\":0},\"language\":\"javascript\",\"signature\":");
    try jsonw.writeString(&l, res.arena, &sig_buf);
    try l.appendSlice(res.arena, ",\"updater_status\":\"idle\"}}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// `_utils` in CouchDB is Fauxton. Shipping a whole web UI is out of scope, so
/// this answers with a small page that says so rather than a 404: a client or a
/// bookmark that reaches for it gets an answer, not an error.
/// Where a Fauxton build lives, when one is installed: `$ZOUCH_WWW`, or `www`
/// inside the data directory.
fn wwwDir(app: *App, alloc: std.mem.Allocator) ?[]const u8 {
    if (app.www_dir) |d| return d;
    const p = std.fmt.allocPrint(alloc, "{s}/www", .{app.root}) catch return null;
    std.Io.Dir.cwd().access(app.io, p, .{}) catch return null;
    return p;
}

fn assetType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    if (std.mem.eql(u8, ext, "html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, "js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, "css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, "json")) return "application/json";
    if (std.mem.eql(u8, ext, "map")) return "application/json";
    if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, "woff")) return "font/woff";
    if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
    return "application/octet-stream";
}

/// Serves a file out of the Fauxton build. False means there is no build, or no
/// such file, and the caller answers as it did before.
fn serveAsset(app: *App, res: *httpz.Response, rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    // No path escapes the build directory.
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    // A directory on disk wins, so a newer build can be tried without rebuilding;
    // otherwise the copy embedded in the binary answers.
    if (wwwDir(app, res.arena)) |dir| {
        const path = std.fmt.allocPrint(res.arena, "{s}/{s}", .{ dir, rel }) catch return false;
        if (std.Io.Dir.cwd().readFileAlloc(app.io, path, res.arena, .limited(32 * 1024 * 1024))) |bytes| {
            res.header("content-type", assetType(rel));
            res.body = bytes;
            return true;
        } else |_| {}
    }
    if (www_assets.find(rel)) |bytes| {
        res.header("content-type", assetType(rel));
        res.body = bytes;
        return true;
    }
    return false;
}

/// Fauxton asks this on load to decide whether to show its setup wizard. zouch is
/// always already set up: one node, its own data directory.
fn hClusterSetupGet(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = "{\"state\":\"single_node_enabled\"}";
}

/// The wizard's single-node action is the one that means anything here: it sets
/// the admin credential. Clustering is not something zouch does, and saying so
/// is better than pretending the request worked.
fn hClusterSetupPost(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const auth = try requestAuth(app, req, res);
    if (!auth.authenticated) return err(res, 401, "unauthorized", "Authentication required");
    if (auth.users_present and !auth.admin) return err(res, 403, "forbidden", "Only _admin users may configure cluster");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "body must be an object");
    const action_v = root.object.get("action") orelse return err(res, 400, "bad_request", "missing action");
    if (action_v != .string) return err(res, 400, "bad_request", "action must be a string");
    if (!std.mem.eql(u8, action_v.string, "enable_single_node")) {
        return err(res, 400, "not_supported", "zouch is a single node; clustering is not supported");
    }
    const user_v = root.object.get("username") orelse return err(res, 400, "bad_request", "missing username");
    const pass_v = root.object.get("password") orelse return err(res, 400, "bad_request", "missing password");
    if (user_v != .string or pass_v != .string or user_v.string.len == 0 or pass_v.string.len == 0) {
        return err(res, 400, "bad_request", "username and password must be non-empty strings");
    }
    const creds = try std.fmt.allocPrint(res.arena, "{s}:{s}", .{ user_v.string, pass_v.string });
    if (std.mem.indexOfScalar(u8, user_v.string, ':') != null) {
        return err(res, 400, "bad_request", "username must not contain ':'");
    }
    const id = try std.fmt.allocPrint(res.arena, "org.couchdb.user:{s}", .{user_v.string});
    var roles: std.json.Array = std.json.Array.init(res.arena);
    try roles.append(.{ .string = "_admin" });
    var doc: std.json.ObjectMap = .empty;
    try doc.put(res.arena, "_id", .{ .string = id });
    try doc.put(res.arena, "name", user_v);
    try doc.put(res.arena, "type", .{ .string = "user" });
    try doc.put(res.arena, "roles", .{ .array = roles });
    try doc.put(res.arena, "password", pass_v);
    var doc_val: std.json.Value = .{ .object = doc };
    try hashUserPassword(app, res, &doc_val, id);

    const udb = (try app.acquireDb("_users")) orelse blk: {
        app.mutex.lockUncancelable(app.io);
        const created = app.createDb("_users") catch {
            app.mutex.unlock(app.io);
            return err(res, 500, "internal_server_error", "cannot create _users");
        };
        created.pins += 1;
        app.mutex.unlock(app.io);
        created.lock();
        break :blk created;
    };
    defer app.releaseDb(udb);
    const parent: ?Rev = if (udb.get(id)) |existing| existing.winnerLeaf().rev else null;
    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&encoded, res.arena, doc_val);
    _ = try udb.putLocal(id, encoded.items, parent, false);
    try udb.syncWal();
    app.invalidateUsersCache();

    const has_auth_header = blk: {
        app.auth_mutex.lockUncancelable(app.io);
        defer app.auth_mutex.unlock(app.io);
        break :blk app.auth_header != null;
    };
    if (has_auth_header) {
        app.setAuth(creds) catch return err(res, 400, "bad_request", "invalid credentials");
    }
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// The settings this server actually has. There is no runtime configuration
/// file to enumerate, so this is not CouchDB's long list - it is what is true.
fn hNodeConfig(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"couchdb\":{\"database_dir\":");
    try jsonw.writeString(&l, res.arena, app.root);
    try l.appendSlice(res.arena, ",\"max_document_size\":\"4294967296\"},\"zouch\":{\"version\":");
    try jsonw.writeString(&l, res.arena, version.string);
    try l.appendSlice(res.arena, ",\"vendor\":\"Zouch\"}}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hNodeConfigPut(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    return err(res, 400, "not_supported", "zouch takes its configuration from the command line; it cannot be changed at runtime");
}

fn hUtils(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    if (serveAsset(app, res, "index.html")) return;
    res.content_type = .HTML;
    res.body = try std.fmt.allocPrint(
        res.arena,
        "<!doctype html><html><head><title>Zouch {s}</title></head>" ++
            "<body><h1>Zouch {s}</h1>" ++
            "<p>A CouchDB-compatible document store. Fauxton is not bundled.</p>" ++
            "<p>The API starts at <a href=\"/_all_dbs\">/_all_dbs</a>, " ++
            "<a href=\"/_scheduler/docs\">/_scheduler/docs</a> and " ++
            "<a href=\"/_up\">/_up</a>.</p></body></html>",
        .{ version.string, version.string },
    );
}

/// Partitions are not implemented. CouchDB says so explicitly, which is more use
/// to a client than a bare 404: the database exists, the feature does not.
fn hNotPartitioned(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    return err(res, 400, "bad_request", "database is not partitioned");
}

/// `_scheduler/jobs` lists replications running right now. Jobs run inline on the
/// scheduler thread, so this is empty unless one is in flight.
fn hSchedulerJobs(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    var l: std.ArrayListUnmanaged(u8) = .empty;
    const job_count = app.repl_running.items.len;
    try l.appendSlice(res.arena, "{\"total_rows\":");
    try appendInt(&l, res.arena, job_count);
    try l.appendSlice(res.arena, ",\"offset\":0,\"jobs\":[");
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&host_buf) catch "localhost";
    const node = try std.fmt.allocPrint(res.arena, "zouch@{s}", .{host});
    const pid_num: u64 = @intCast(std.c.getpid());
    for (app.repl_running.items, 0..) |r, idx| {
        if (idx != 0) try l.append(res.arena, ',');
        const started_iso = try isoTimestamp(res.arena, r.started);
        // The field set CouchDB sends: no `state` and no `error_count` here -
        // those belong to `_scheduler/docs`.
        try l.appendSlice(res.arena, "{\"database\":\"_replicator\",\"id\":");
        if (r.repl_id) |id| try jsonw.writeString(&l, res.arena, id) else try l.appendSlice(res.arena, "null");
        try l.appendSlice(res.arena, ",\"pid\":\"<0.");
        try appendInt(&l, res.arena, pid_num);
        try l.appendSlice(res.arena, ".0>\",\"source\":");
        if (r.source) |src| try jsonw.writeString(&l, res.arena, src) else try l.appendSlice(res.arena, "null");
        try l.appendSlice(res.arena, ",\"target\":");
        if (r.target) |tgt| try jsonw.writeString(&l, res.arena, tgt) else try l.appendSlice(res.arena, "null");
        try l.appendSlice(res.arena, ",\"user\":null,\"doc_id\":");
        if (r.id) |id| try jsonw.writeString(&l, res.arena, id) else try l.appendSlice(res.arena, "null");
        try l.appendSlice(res.arena, ",\"info\":null,\"history\":[{\"timestamp\":");
        try jsonw.writeString(&l, res.arena, started_iso);
        try l.appendSlice(res.arena, ",\"type\":\"started\"},{\"timestamp\":");
        try jsonw.writeString(&l, res.arena, started_iso);
        try l.appendSlice(res.arena, ",\"type\":\"added\"}],\"node\":");
        try jsonw.writeString(&l, res.arena, node);
        try l.appendSlice(res.arena, ",\"start_time\":");
        try jsonw.writeString(&l, res.arena, started_iso);
        try l.append(res.arena, '}');
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// A replication endpoint as CouchDB reports it in `_scheduler/docs`: the url
/// without credentials, with a trailing slash. The stored document keeps the
/// credentials it needs; this endpoint must not hand them out.
fn redactEndpoint(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var raw: ?[]const u8 = null;
    switch (value) {
        .string => |text| raw = text,
        .object => |obj| {
            if (obj.get("url")) |u| {
                if (u == .string) raw = u.string;
            }
        },
        else => {},
    }
    const text = raw orelse return "null";
    const scheme_at = std.mem.indexOf(u8, text, "://") orelse return try alloc.dupe(u8, text);
    const rest = text[scheme_at + 3 ..];
    var host_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?') {
            host_end = i;
            break;
        }
    }
    var host = rest[0..host_end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    var path = if (host_end < rest.len and rest[host_end] == '/') rest[host_end + 1 ..] else "";
    if (std.mem.indexOfScalar(u8, path, '?')) |qmark| path = path[0..qmark];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, text[0 .. scheme_at + 3]);
    try out.appendSlice(alloc, host);
    try out.append(alloc, '/');
    try out.appendSlice(alloc, path);
    if (path.len == 0 or path[path.len - 1] != '/') try out.append(alloc, '/');
    // `items` has spare capacity; the caller frees the returned slice, which
    // must be the allocation the allocator handed out.
    return try out.toOwnedSlice(alloc);
}

/// `_scheduler/docs` reports one entry per replication document, with the state
/// and the statistics the job recorded - the data CouchDB's dashboard shows.
fn hSchedulerDocs(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const rdb = (app.acquireDb("_replicator") catch null) orelse {
        res.content_type = .JSON;
        res.body = "{\"total_rows\":0,\"offset\":0,\"docs\":[]}";
        return;
    };
    defer app.releaseDb(rdb);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;
    var entries: std.ArrayListUnmanaged(u8) = .empty;
    var it = rdb.docs.valueIterator();
    while (it.next()) |entry| {
        const doc = entry.*;
        if (doc.winnerLeaf().deleted) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, res.arena, doc.winnerLeaf().body, .{}) catch continue;
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        if (count != 0) try entries.append(res.arena, ',');
        count += 1;
        try entries.appendSlice(res.arena, "{\"database\":\"_replicator\",\"doc_id\":");
        try jsonw.writeString(&entries, res.arena, doc.id);
        try entries.appendSlice(res.arena, ",\"id\":null,\"source\":");
        if (root.get("source")) |src| {
            try jsonw.writeString(&entries, res.arena, try redactEndpoint(res.arena, src));
        } else try entries.appendSlice(res.arena, "null");
        try entries.appendSlice(res.arena, ",\"target\":");
        if (root.get("target")) |tgt| {
            try jsonw.writeString(&entries, res.arena, try redactEndpoint(res.arena, tgt));
        } else try entries.appendSlice(res.arena, "null");
        try entries.appendSlice(res.arena, ",\"state\":");
        if (root.get("_replication_state")) |sv| {
            try jsonw.writeValue(&entries, res.arena, sv);
        } else {
            try entries.appendSlice(res.arena, "\"initializing\"");
        }
        try entries.appendSlice(res.arena, ",\"error_count\":0,\"info\":");
        if (root.get("_replication_stats")) |stats| {
            try jsonw.writeValue(&entries, res.arena, stats);
        } else {
            try entries.appendSlice(res.arena, "{}");
        }
        try entries.append(res.arena, '}');
    }
    try l.appendSlice(res.arena, "{\"total_rows\":");
    try appendInt(&l, res.arena, count);
    try l.appendSlice(res.arena, ",\"offset\":0,\"docs\":[");
    try l.appendSlice(res.arena, entries.items);
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hBulkGetNotAllowed(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    return err(res, 405, "method_not_allowed", "Only POST allowed");
}

fn lessThanId(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `_design_docs` is `_all_docs` narrowed to design documents, in id order.
fn hDesignDocs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ids.deinit(res.arena);
    var it = db.docs.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr.*;
        if (doc.winnerLeaf().deleted) continue;
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "_design/")) continue;
        try ids.append(res.arena, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, ids.items, {}, lessThanId);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"total_rows\":");
    try appendInt(&l, res.arena, ids.items.len);
    try l.appendSlice(res.arena, ",\"offset\":0,\"rows\":[");
    for (ids.items, 0..) |id, i| {
        if (i != 0) try l.append(res.arena, ',');
        try l.appendSlice(res.arena, "{\"id\":");
        try jsonw.writeString(&l, res.arena, id);
        try l.appendSlice(res.arena, ",\"key\":");
        try jsonw.writeString(&l, res.arena, id);
        try l.appendSlice(res.arena, ",\"value\":{\"rev\":");
        var rb: [64]u8 = undefined;
        try jsonw.writeString(&l, res.arena, db.docs.get(id).?.winnerLeaf().rev.write(&rb));
        try l.appendSlice(res.arena, "}}");
    }
    try l.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = l.items;
}

/// `_missing_revs` answers which of the given revisions this database does not
/// have - the question a replicator asks before sending anything.
fn hMissingRevs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.appendSlice(res.arena, "{\"missing_revs\":{");
    var first = true;
    for (root.object.keys(), root.object.values()) |id, rv| {
        if (rv != .array) continue;
        const doc = db.get(id);
        var missing: std.ArrayListUnmanaged(Rev) = .empty;
        defer missing.deinit(res.arena);
        for (rv.array.items) |item| {
            if (item != .string) continue;
            const rev = Rev.parse(item.string) catch continue;
            const have = if (doc) |d|
                (d.findLeaf(rev) != null or d.findDescendantOf(rev) != null or d.retainedFor(rev) != null)
            else
                false;
            if (!have) try missing.append(res.arena, rev);
        }
        if (missing.items.len == 0) continue;
        if (!first) try l.append(res.arena, ',');
        first = false;
        try jsonw.writeString(&l, res.arena, id);
        try l.appendSlice(res.arena, ":[");
        for (missing.items, 0..) |m, i| {
            if (i != 0) try l.append(res.arena, ',');
            var rb: [64]u8 = undefined;
            try jsonw.writeString(&l, res.arena, m.write(&rb));
        }
        try l.append(res.arena, ']');
    }
    try l.appendSlice(res.arena, "}}");
    res.content_type = .JSON;
    res.body = l.items;
}

fn hRevsDiff(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "JSON object required");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);

    var l: std.ArrayListUnmanaged(u8) = .empty;
    try l.append(res.arena, '{');
    const keys = root.object.keys();
    const vals = root.object.values();
    var first = true;
    for (keys, vals) |id, rv| {
        if (rv != .array) continue;
        const doc = db.get(id);
        var missing: std.ArrayListUnmanaged(Rev) = .empty;
        defer missing.deinit(res.arena);
        for (rv.array.items) |item| {
            if (item != .string) continue;
            const rev = Rev.parse(item.string) catch continue;
            const have = if (doc) |d| (d.findLeaf(rev) != null or d.findDescendantOf(rev) != null or d.retainedFor(rev) != null) else false;
            if (!have) try missing.append(res.arena, rev);
        }
        if (missing.items.len == 0) continue;
        if (!first) try l.append(res.arena, ',');
        first = false;
        try jsonw.writeString(&l, res.arena, id);
        try l.appendSlice(res.arena, ":{\"missing\":[");
        for (missing.items, 0..) |m, i| {
            if (i != 0) try l.append(res.arena, ',');
            var rb: [64]u8 = undefined;
            try jsonw.writeString(&l, res.arena, m.write(&rb));
        }
        try l.append(res.arena, ']');
        if (doc) |d| {
            var max_gen: u32 = 0;
            for (missing.items) |m| {
                if (m.gen > max_gen) max_gen = m.gen;
            }
            var anc_count: usize = 0;
            for (d.leaves.items) |leaf| {
                var candidate: ?Rev = null;
                if (leaf.rev.gen < max_gen) {
                    candidate = leaf.rev;
                } else {
                    for (leaf.ancestry) |anc| {
                        if (anc.gen < max_gen) {
                            candidate = anc;
                            break;
                        }
                    }
                }
                if (candidate) |cand| {
                    if (anc_count == 0) {
                        try l.appendSlice(res.arena, ",\"possible_ancestors\":[");
                    } else {
                        try l.append(res.arena, ',');
                    }
                    anc_count += 1;
                    var rb: [64]u8 = undefined;
                    try jsonw.writeString(&l, res.arena, cand.write(&rb));
                }
            }
            if (anc_count > 0) try l.append(res.arena, ']');
        }
        try l.append(res.arena, '}');
    }
    try l.append(res.arena, '}');
    res.content_type = .JSON;
    res.body = l.items;
}

fn hCompact(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const auth = try requestAuth(app, req, res);
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    if (!isDbAdminFor(db, auth)) return err(res, 403, "forbidden", "Only database admins may compact");
    const task_pid = app.beginTask("database_compaction", name, null, null, null, null, db.seq);
    defer app.endTask(task_pid);
    db.compactSegments() catch |e| return e;
    app.updateTask(task_pid, db.seq, db.seq);
    res.status = 202;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn hViewCleanup(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    db.clearViewIndexes();
    res.status = 202;
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn hPurge(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const auth = try requestAuth(app, req, res);
    const body = fullBody(req, res.arena, app.max_body_bytes) catch |e| if (e == error.TooLarge) return e else return err(res, 400, "bad_request", "missing body");
    const root = parseBody(res, body) catch return err(res, 400, "bad_request", "invalid JSON");
    if (root != .object) return err(res, 400, "bad_request", "body must be an object");

    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    var released = false;
    defer if (!released) app.releaseDb(db);
    if (auth.users_present and !auth.admin and !db.securityAdmin(auth.user, auth.roles)) {
        return err(res, 403, "forbidden", "Only database admins may purge");
    }

    var response: std.ArrayListUnmanaged(u8) = .empty;
    var purged_any = false;
    try response.appendSlice(res.arena, "{\"purged\":{");
    var first_id = true;
    for (root.object.keys(), root.object.values()) |id, revs_v| {
        if (revs_v != .array) return err(res, 400, "bad_request", "purge revisions must be an array");
        const doc = db.get(id) orelse continue;
        var purged_here: std.ArrayListUnmanaged([]const u8) = .empty;
        var purged_revs: std.ArrayListUnmanaged(Rev) = .empty;
        for (revs_v.array.items) |rv| {
            if (rv != .string) continue;
            const rev = Rev.parse(rv.string) catch continue;
            var matched = false;
            var i = doc.leaves.items.len;
            while (i > 0) {
                i -= 1;
                var contains_rev = doc.leaves.items[i].rev.eql(rev);
                if (!contains_rev) {
                    for (doc.leaves.items[i].ancestry) |anc| {
                        if (anc.eql(rev)) {
                            contains_rev = true;
                            break;
                        }
                    }
                }
                if (contains_rev) {
                    matched = true;
                    var leaf = doc.leaves.orderedRemove(i);
                    try purged_revs.appendSlice(res.arena, leaf.ancestry);
                    leaf.deinit(db.alloc);
                }
            }
            for (doc.retained.items) |r| {
                if (r.rev.eql(rev)) {
                    matched = true;
                    break;
                }
            }
            if (matched) {
                try purged_revs.append(res.arena, rev);
                try purged_here.append(res.arena, rv.string);
            }
        }
        if (purged_revs.items.len > 0) {
            var ri: usize = doc.retained.items.len;
            while (ri > 0) {
                ri -= 1;
                const r = doc.retained.items[ri];
                var in_purged = false;
                for (purged_revs.items) |pr| {
                    if (pr.eql(r.rev)) {
                        in_purged = true;
                        break;
                    }
                }
                if (in_purged and doc.findDescendantOf(r.rev) == null and doc.findLeaf(r.rev) == null) {
                    const rem = doc.retained.orderedRemove(ri);
                    db.alloc.free(rem.body);
                }
            }
        }
        if (purged_here.items.len > 0) {
            purged_any = true;
            if (!first_id) try response.append(res.arena, ',');
            first_id = false;
            try jsonw.writeString(&response, res.arena, id);
            try response.appendSlice(res.arena, ":[");
            for (purged_here.items, 0..) |rv, i| {
                if (i != 0) try response.append(res.arena, ',');
                try jsonw.writeString(&response, res.arena, rv);
            }
            try response.append(res.arena, ']');
        }
        if (doc.leaves.items.len == 0) {
            _ = db.designs.remove(id);
            if (db.docs.fetchRemove(id)) |kv| kv.value.deinit(db.alloc);
        } else {
            doc.recomputeWinner();
        }
    }
    if (purged_any) {
        // Purge bypasses the normal write path, so advance the sequence,
        // update memory accounting, clear persisted view/search indexes, and snapshot.
        db.seq +%= 1;
        db.recomputeApproxBytes();
        db.recomputeStats();
        db.clearViewIndexes();
        db.clearSearchIndexes();
    }
    try response.appendSlice(res.arena, "},\"purge_seq\":");
    const purge_seq = if (purged_any) try db.bumpPurgeSeq() else db.purge_seq;
    try appendInt(&response, res.arena, purge_seq);
    try response.append(res.arena, '}');
    if (purged_any) db.snapshot() catch |e| return e;
    if (purged_any) {
        app.releaseDb(db);
        released = true;
        if (std.mem.eql(u8, name, "_users")) app.invalidateUsersCache();
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        app.dropSearchCaches(name);
    }
    res.status = 201;
    res.content_type = .JSON;
    res.body = response.items;
}

fn hEnsureCommit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.params.get("db") orelse return err(res, 400, "bad_request", "missing db");
    const ct = req.header("content-type") orelse
        return err(res, 415, "bad_content_type", "Content-Type must be application/json");
    if (!std.mem.startsWith(u8, ct, "application/json")) {
        return err(res, 415, "bad_content_type", "Content-Type must be application/json");
    }
    const db = (try app.acquireDb(name)) orelse return err(res, 404, "not_found", "Database does not exist.");
    defer app.releaseDb(db);
    db.syncWal() catch |e| {
        db.failed = true;
        return e;
    };
    res.status = 201;
    res.content_type = .JSON;
    res.body = "{\"ok\":true,\"instance_start_time\":\"0\"}";
}

fn appendU32(l: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try l.appendSlice(alloc, &buf);
}

fn appendU64(l: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try l.appendSlice(alloc, &buf);
}

fn appendInt(l: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try l.appendSlice(alloc, s);
}

fn sortBySeq(items: []*Doc) void {
    std.mem.sort(*Doc, items, {}, struct {
        fn less(_: void, a: *Doc, b: *Doc) bool {
            return a.seq < b.seq;
        }
    }.less);
}

fn sortById(items: []*Doc) void {
    std.mem.sort(*Doc, items, {}, struct {
        fn less(_: void, a: *Doc, b: *Doc) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
}

test "vector cache owns its document ids across a purge" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-hnsw-ownership";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("d1");
    db.lock();
    defer db.unlock();
    const embedding_body = "{\"embedding_b64\":\"AACAPwAAAD8AAIA+AAAAPg==\"}";
    _ = try db.putLocal("doc-a", embedding_body, null, false);
    const cache = try hnswFor(app, db, 4, "d1");
    try std.testing.expectEqual(@as(usize, 1), cache.ids.items.len);
    const doc = db.get("doc-a").?;
    // hPurge frees Doc.id while the cache is still live, so the cache must not
    // borrow it.
    try std.testing.expect(@intFromPtr(cache.ids.items[0].ptr) != @intFromPtr(doc.id.ptr));

    _ = db.docs.fetchRemove("doc-a");
    const stale_id_ptr = @intFromPtr(doc.id.ptr);
    doc.deinit(db.alloc);
    db.seq +%= 1;
    _ = try db.putLocal("doc-b", embedding_body, null, false);

    // Refreshing the cache must not hash or compare the freed id.
    const refreshed = try hnswFor(app, db, 4, "d1");
    try std.testing.expectEqual(@as(usize, 1), refreshed.ids.items.len);
    try std.testing.expectEqualStrings("doc-b", refreshed.ids.items[0]);
    try std.testing.expect(@intFromPtr(refreshed.ids.items[0].ptr) != stale_id_ptr);
}

test "vector index load frees the index file buffer" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-vector-index";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("d1");
    db.lock();
    defer db.unlock();
    _ = try db.putLocal("doc-a", "{\"embedding_b64\":\"AACAPwAAAD8AAIA+AAAAPg==\"}", null, false);
    try buildVectorIndex(db, alloc, 4);
    const entries = (try loadVectorIndex(db, alloc, 4)) orelse return error.TestUnexpectedResult;
    defer freeVectorEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("doc-a", entries[0].id);
    // The entries own copies of the ids, so the testing allocator must see
    // every allocation released once the buffer and the entries are freed.
}

test "filter id scan frees its scratch" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-filter-ids";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("d1");
    db.lock();
    defer db.unlock();
    _ = try db.putLocal("_design/ddoc", "{\"filters\":{\"ok\":\"function(doc,req){ return true; }\"}}", null, false);
    _ = try db.putLocal("doc-1", "{\"a\":1}", null, false);
    var ids = try buildFilterIds(db, alloc, "ddoc/ok", 0, null);
    defer freeFilterIds(alloc, &ids);
    // The design document and doc-1 both match.
    try std.testing.expectEqual(@as(usize, 2), ids.count());
    // The design document is parsed and its id allocated per call; the feed
    // scheduler runs this every 50 ms with a general allocator.
}

test "mango index build releases everything on allocation failure" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-mango-oom";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("m1");
    db.lock();
    defer db.unlock();
    _ = try db.putLocal("d1", "{\"a\":1,\"b\":\"x\"}", null, false);
    _ = try db.putLocal("d2", "{\"a\":2,\"b\":\"y\"}", null, false);

    // Every allocation the index build makes is handed a failure in turn: each
    // run must either finish or fail cleanly, and free everything it took.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
        const fa = failing.allocator();
        buildMangoIndex(db, fa, "a") catch {};
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        var failing2 = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
        buildMangoIndexFields(db, failing2.allocator(), &.{ "a", "b" }) catch {};
        try std.testing.expectEqual(failing2.allocated_bytes, failing2.freed_bytes);
        if (!failing.has_induced_failure and !failing2.has_induced_failure) break;
    }
}

test "document serialisation releases everything on allocation failure" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-writedoc-oom";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("w1");
    db.lock();
    defer db.unlock();
    _ = try db.putLocal("d1", "{\"a\":1,\"nested\":{\"b\":[1,2,3]}}", null, false);
    const d = db.get("d1").?;

    // `_bulk_get`, `open_revs` and a document GET all serialise through writeDoc,
    // so this is the handler path that allocates per document.
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
        const fa = failing.allocator();
        var l: std.ArrayListUnmanaged(u8) = .empty;
        writeDoc(db, &l, fa, d, 0, true, true, true) catch {};
        l.deinit(fa);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "app and database handles release everything on allocation failure" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-app-oom";
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = i });
        if (App.init(failing.allocator(), io, root)) |app| {
            // The closing snapshot is best-effort and swallows its own OOM, so
            // skip it: this test is about the handles, not the snapshot.
            if (app.createDb("d1")) |db| {
                db.failed = true;
            } else |_| {}
            app.deinit();
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "role and database credentials are replaced in place" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-settings";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();

    try app.setRoles("alice:one;bob:two");
    try app.setRoles("alice:three");
    try std.testing.expectEqualStrings("three", app.rolesFor("alice"));
    try std.testing.expectEqualStrings("two", app.rolesFor("bob"));
    try std.testing.expectEqual(@as(usize, 2), app.user_roles.count());

    try app.setDbAuth("d1", "user:pass");
    try app.setDbAuth("d1", "user:other");
    try std.testing.expectEqual(@as(usize, 1), app.auth_db.count());
    try std.testing.expect(app.auth_db.get("d1") != null);

    try app.setAuth("user:pass");
    try app.setAuth("user:other");
    try std.testing.expect(app.auth_header != null);
}

const TestDispatchResult = struct {
    status: u16,
    body: []const u8,
    raw: []const u8,
    ht: httpz.testing.Testing,
};

fn dispatchTestReq(
    app: *App,
    method: httpz.Method,
    path: []const u8,
    action: httpz.Action(*App),
    db_param: ?[]const u8,
    doc_param: ?[]const u8,
    headers: []const [2][]const u8,
    queries: []const [2][]const u8,
    body_opt: ?[]const u8,
) !TestDispatchResult {
    return dispatchTestReqWithParams(app, method, path, action, db_param, doc_param, &.{}, headers, queries, body_opt);
}

fn dispatchTestReqWithParams(
    app: *App,
    method: httpz.Method,
    path: []const u8,
    action: httpz.Action(*App),
    db_param: ?[]const u8,
    doc_param: ?[]const u8,
    extra_params: []const [2][]const u8,
    headers: []const [2][]const u8,
    queries: []const [2][]const u8,
    body_opt: ?[]const u8,
) !TestDispatchResult {
    var ht = httpz.testing.init(.{});
    errdefer ht.deinit();
    ht.req.method = method;
    ht.url(path);
    if (db_param) |d| {
        ht.req.params.names[ht.req.params.len] = "db";
        ht.req.params.values[ht.req.params.len] = d;
        ht.req.params.len += 1;
    }
    if (doc_param) |doc| {
        ht.req.params.names[ht.req.params.len] = "doc";
        ht.req.params.values[ht.req.params.len] = doc;
        ht.req.params.len += 1;
    }
    for (extra_params) |p| {
        ht.req.params.names[ht.req.params.len] = p[0];
        ht.req.params.values[ht.req.params.len] = p[1];
        ht.req.params.len += 1;
    }
    for (headers) |h| ht.header(h[0], h[1]);
    for (queries) |kv| ht.query(kv[0], kv[1]);
    if (body_opt) |b| ht.body(b);
    try app.dispatch(action, ht.req, ht.res);
    const pr = try ht.parseResponse();
    return .{ .status = pr.status, .body = pr.body, .raw = pr.raw, .ht = ht };
}

fn extractAuthCookie(raw: []const u8) ?[]const u8 {
    const needle = "AuthSession=";
    const start = std.mem.indexOf(u8, raw, needle) orelse return null;
    const rest = raw[start..];
    const end = std.mem.indexOfAny(u8, rest, ";\r\n") orelse rest.len;
    return rest[0..end];
}

test "cookie auth with _users restricts admin-only actions" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-cookie-auth";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const d1 = try app.createDb("d1");
    {
        d1.lock();
        defer d1.unlock();
        try d1.writeSecurity("{\"admins\":{\"names\":[\"admin\"],\"roles\":[\"_admin\"]},\"members\":{\"names\":[\"alice\",\"admin\"]}}");
    }
    _ = try app.createDb("_replicator");

    // Create _admin user in _users (when no static auth_header is configured)
    var r_admin_create = try dispatchTestReq(
        app,
        .POST,
        "/_create_user",
        hUserCreate,
        null,
        null,
        &.{.{ "content-type", "application/json" }},
        &.{},
        "{\"name\":\"admin\",\"password\":\"secret\",\"roles\":[\"_admin\"]}",
    );
    defer r_admin_create.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), r_admin_create.status);

    // Login as admin -> AuthSession cookie
    var r_admin_login = try dispatchTestReq(app, .POST, "/_session", hSessionPost, null, null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"name\":\"admin\",\"password\":\"secret\"}");
    defer r_admin_login.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r_admin_login.status);
    const admin_cookie = extractAuthCookie(r_admin_login.raw) orelse return error.TestUnexpectedResult;

    // Create non-admin user alice via admin cookie
    var r_create = try dispatchTestReq(
        app,
        .POST,
        "/_create_user",
        hUserCreate,
        null,
        null,
        &.{ .{ "cookie", admin_cookie }, .{ "content-type", "application/json" } },
        &.{},
        "{\"name\":\"alice\",\"password\":\"pw\",\"roles\":[]}",
    );
    defer r_create.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), r_create.status);

    // Login as alice -> AuthSession cookie
    var r_login = try dispatchTestReq(
        app,
        .POST,
        "/_session",
        hSessionPost,
        null,
        null,
        &.{.{ "content-type", "application/json" }},
        &.{},
        "{\"name\":\"alice\",\"password\":\"pw\"}",
    );
    defer r_login.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r_login.status);
    const alice_cookie = extractAuthCookie(r_login.raw) orelse return error.TestUnexpectedResult;

    // Non-admin cookie denied on admin-only routes
    var r_all_dbs = try dispatchTestReq(app, .GET, "/_all_dbs", hAllDbs, null, null, &.{.{ "cookie", alice_cookie }}, &.{}, null);
    defer r_all_dbs.ht.deinit();
    try std.testing.expectEqual(@as(u16, 403), r_all_dbs.status);

    var r_user = try dispatchTestReq(app, .POST, "/_create_user", hUserCreate, null, null, &.{ .{ "cookie", alice_cookie }, .{ "content-type", "application/json" } }, &.{}, "{\"name\":\"bob\",\"password\":\"pw\"}");
    defer r_user.ht.deinit();
    try std.testing.expectEqual(@as(u16, 403), r_user.status);

    var r_del = try dispatchTestReq(app, .DELETE, "/d1", hDbDelete, "d1", null, &.{.{ "cookie", alice_cookie }}, &.{}, null);
    defer r_del.ht.deinit();
    try std.testing.expectEqual(@as(u16, 403), r_del.status);

    var r_rep = try dispatchTestReq(app, .PUT, "/_replicator/rep1", hDocPut, "_replicator", "rep1", &.{ .{ "cookie", alice_cookie }, .{ "content-type", "application/json" } }, &.{}, "{\"source\":\"a\",\"target\":\"b\"}");
    defer r_rep.ht.deinit();
    try std.testing.expectEqual(@as(u16, 403), r_rep.status);

    // Non-admin cookie allowed on normal DB doc write
    var r_doc = try dispatchTestReq(app, .PUT, "/d1/doc1", hDocPut, "d1", "doc1", &.{ .{ "cookie", alice_cookie }, .{ "content-type", "application/json" } }, &.{}, "{\"ok\":1}");
    defer r_doc.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), r_doc.status);

    // Admin cookie allowed on /_all_dbs and DELETE /{db}
    var r_admin_dbs = try dispatchTestReq(app, .GET, "/_all_dbs", hAllDbs, null, null, &.{.{ "cookie", admin_cookie }}, &.{}, null);
    defer r_admin_dbs.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r_admin_dbs.status);

    var r_admin_del = try dispatchTestReq(app, .DELETE, "/d1", hDbDelete, "d1", null, &.{.{ "cookie", admin_cookie }}, &.{}, null);
    defer r_admin_del.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r_admin_del.status);
}

test "ZOUCH_AUTH_FILE mode protects global routes and POST /_cluster_setup" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-auth-file";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    try app.setAuth("admin:secret");

    var r1 = try dispatchTestReq(app, .GET, "/_all_dbs", hAllDbs, null, null, &.{}, &.{}, null);
    defer r1.ht.deinit();
    try std.testing.expectEqual(@as(u16, 401), r1.status);

    var r2 = try dispatchTestReq(app, .POST, "/_cluster_setup", hClusterSetupPost, null, null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"action\":\"enable_single_node\",\"username\":\"u\",\"password\":\"p\"}");
    defer r2.ht.deinit();
    try std.testing.expectEqual(@as(u16, 401), r2.status);

    const admin_auth = "Basic YWRtaW46c2VjcmV0";
    var r3 = try dispatchTestReq(app, .GET, "/_all_dbs", hAllDbs, null, null, &.{.{ "authorization", admin_auth }}, &.{}, null);
    defer r3.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r3.status);

    var r4 = try dispatchTestReq(app, .POST, "/_cluster_setup", hClusterSetupPost, null, null, &.{ .{ "authorization", admin_auth }, .{ "content-type", "application/json" } }, &.{}, "{\"action\":\"enable_single_node\",\"username\":\"admin2\",\"password\":\"secret2\"}");
    defer r4.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), r4.status);
}

test "hRevsDiff ancestor revisions and hBulkDocs new_edits=false validate_doc_update" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-revs-vdu";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("d1");
    var revbuf: [64]u8 = undefined;
    const rev1 = blk: {
        db.lock();
        defer db.unlock();
        const r1 = try db.putLocal("doc1", "{\"v\":1}", null, false);
        const r1s = try alloc.dupe(u8, r1.rev.write(&revbuf));
        _ = try db.putLocal("doc1", "{\"v\":2}", r1.rev, false);
        break :blk r1s;
    };
    defer alloc.free(rev1);

    const missing_rev = "2-00000000000000000000000000000000";
    const revs_body = try std.fmt.allocPrint(alloc, "{{\"doc1\":[\"{s}\",\"{s}\"]}}", .{ rev1, missing_rev });
    defer alloc.free(revs_body);
    var rd = try dispatchTestReq(app, .POST, "/d1/_revs_diff", hRevsDiff, "d1", null, &.{.{ "content-type", "application/json" }}, &.{}, revs_body);
    defer rd.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), rd.status);
    const rd_parsed = try std.json.parseFromSlice(std.json.Value, alloc, rd.body, .{});
    defer rd_parsed.deinit();
    const doc1_diff = rd_parsed.value.object.get("doc1").?.object;
    const missing_arr = doc1_diff.get("missing").?.array;
    try std.testing.expectEqual(@as(usize, 1), missing_arr.items.len);
    try std.testing.expectEqualStrings(missing_rev, missing_arr.items[0].string);

    {
        db.lock();
        defer db.unlock();
        _ = try db.putLocal("_design/guard", "{\"validate_doc_update\":\"function(newDoc){ if(newDoc.bad) throw({forbidden:'nope'}); }\"}", null, false);
    }
    var bd = try dispatchTestReq(app, .POST, "/d1/_bulk_docs", hBulkDocs, "d1", null, &.{.{ "content-type", "application/json" }}, &.{.{ "new_edits", "false" }}, "{\"docs\":[{\"_id\":\"doc2\",\"_rev\":\"1-00000000000000000000000000000000\",\"bad\":true}],\"new_edits\":false}");
    defer bd.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), bd.status);
    try std.testing.expect(std.mem.indexOf(u8, bd.body, "\"forbidden\"") != null);
    try std.testing.expect(db.get("doc2") == null);
}

test "mango range type matching, $text search, fields projection, and execution_stats" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-mango";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("m1");
    {
        db.lock();
        defer db.unlock();
        _ = try db.putLocal("alpha", "{\"name\":\"alpha\",\"nested\":{\"x\":1,\"y\":\"z\"}}", null, false);
        _ = try db.putLocal("beta", "{\"name\":\"beta\",\"nested\":{\"x\":2}}", null, false);
        _ = try db.putLocal("odd", "{\"name\":\"odd\",\"nested\":{\"x\":\"nope\",\"z\":3}}", null, false);
    }

    // $gte: 2 must not match string "z" in alpha.nested.y
    var f1 = try dispatchTestReq(app, .POST, "/m1/_find", hFind, "m1", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"nested\":{\"$keyMapMatch\":{\"$gte\":2}}}}");
    defer f1.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), f1.status);
    try std.testing.expect(std.mem.indexOf(u8, f1.body, "\"beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f1.body, "\"odd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f1.body, "\"alpha\"") == null);

    // $text: {"$search": ...}, fields without _id, and execution_stats.results_returned
    var f2 = try dispatchTestReq(app, .POST, "/m1/_find", hFind, "m1", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"$text\":{\"$search\":\"alpha\"}},\"fields\":[\"name\"],\"execution_stats\":true}");
    defer f2.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), f2.status);
    try std.testing.expect(std.mem.indexOf(u8, f2.body, "\"name\":\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f2.body, "\"_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, f2.body, "\"results_returned\":1") != null);
}

test "views descending range, reduce skip/limit, and vector search errors + restart cache" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-views-vec";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        const app = try App.init(alloc, io, root);
        defer app.deinit();
        const db = try app.createDb("v1");
        {
            db.lock();
            defer db.unlock();
            _ = try db.putLocal("_design/v", "{\"views\":{\"by_k\":{\"map\":\"function(doc){ if(doc.k) emit(doc.k, 1); }\",\"reduce\":\"_count\"}}}", null, false);
            _ = try db.putLocal("d1", "{\"k\":\"a\",\"embedding_b64\":\"AACAPwAAAAAAAAAAAAAAAA==\"}", null, false);
            _ = try db.putLocal("d2", "{\"k\":\"b\"}", null, false);
            _ = try db.putLocal("d3", "{\"k\":\"c\"}", null, false);
        }

        var v_desc = try dispatchTestReqWithParams(app, .GET, "/v1/_design/v/_view/by_k", hView, "v1", null, &.{ .{ "ddoc", "v" }, .{ "view", "by_k" } }, &.{}, &.{ .{ "reduce", "false" }, .{ "descending", "true" }, .{ "startkey", "\"c\"" }, .{ "endkey", "\"b\"" } }, null);
        defer v_desc.ht.deinit();
        try std.testing.expectEqual(@as(u16, 200), v_desc.status);
        const pos_c = std.mem.indexOf(u8, v_desc.body, "\"key\":\"c\"") orelse return error.TestUnexpectedResult;
        const pos_b = std.mem.indexOf(u8, v_desc.body, "\"key\":\"b\"") orelse return error.TestUnexpectedResult;
        try std.testing.expect(pos_c < pos_b);
        try std.testing.expect(std.mem.indexOf(u8, v_desc.body, "\"key\":\"a\"") == null);

        var v_red = try dispatchTestReqWithParams(app, .GET, "/v1/_design/v/_view/by_k", hView, "v1", null, &.{ .{ "ddoc", "v" }, .{ "view", "by_k" } }, &.{}, &.{ .{ "reduce", "true" }, .{ "group", "true" }, .{ "skip", "1" }, .{ "limit", "1" } }, null);
        defer v_red.ht.deinit();
        try std.testing.expectEqual(@as(u16, 200), v_red.status);
        try std.testing.expect(std.mem.indexOf(u8, v_red.body, "\"key\":\"b\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, v_red.body, "\"key\":\"a\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, v_red.body, "\"key\":\"c\"") == null);

        var vs_bad_vec = try dispatchTestReq(app, .POST, "/v1/_vector_search", hVectorSearch, "v1", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"vector\":[0,0,0,0],\"engine\":\"hnsw\"}");
        defer vs_bad_vec.ht.deinit();
        try std.testing.expectEqual(@as(u16, 400), vs_bad_vec.status);

        var vs_ok = try dispatchTestReq(app, .POST, "/v1/_vector_search", hVectorSearch, "v1", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"vector\":[1,0,0,0],\"engine\":\"hnsw\"}");
        defer vs_ok.ht.deinit();
        try std.testing.expectEqual(@as(u16, 200), vs_ok.status);

        var vs_dim = try dispatchTestReq(app, .POST, "/v1/_vector_search", hVectorSearch, "v1", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"vector\":[1,0],\"engine\":\"hnsw\"}");
        defer vs_dim.ht.deinit();
        try std.testing.expectEqual(@as(u16, 400), vs_dim.status);
    }

    // Reopen App and verify post-restart cache.revs is populated from loaded vector index
    const app2 = try App.init(alloc, io, root);
    defer app2.deinit();
    const db2 = (try app2.getDb("v1")).?;
    db2.lock();
    defer db2.unlock();
    const cache = try hnswFor(app2, db2, 4, "v1");
    try std.testing.expectEqual(@as(usize, 1), cache.revs.items.len);
}

test "DELETE /_index removes named index, preserves other views, and deletes empty design doc" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-index-delete";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("idxdb");

    {
        db.lock();
        defer db.unlock();
        _ = try db.putLocal("_design/dd", "{\"views\":{\"v1\":{\"map\":\"function(d){emit(d._id,1);}\"}}}", null, false);
    }
    var c1 = try dispatchTestReq(app, .POST, "/idxdb/_index", hIndexCreate, "idxdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"index\":{\"fields\":[\"a\"]},\"ddoc\":\"dd\",\"name\":\"idx1\"}");
    defer c1.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), c1.status);

    var c2 = try dispatchTestReq(app, .POST, "/idxdb/_index", hIndexCreate, "idxdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"index\":{\"fields\":[\"b\"]},\"ddoc\":\"dd\",\"name\":\"idx2\"}");
    defer c2.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), c2.status);

    var d1 = try dispatchTestReqWithParams(app, .DELETE, "/idxdb/_index/dd/json/idx1", hIndexDelete, "idxdb", null, &.{ .{ "ddoc", "dd" }, .{ "type", "json" }, .{ "name", "idx1" } }, &.{}, &.{}, null);
    defer d1.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), d1.status);
    try std.testing.expect(std.mem.indexOf(u8, d1.body, "\"ok\":true") != null);

    // Deleting again returns 404
    var d1_again = try dispatchTestReqWithParams(app, .DELETE, "/idxdb/_index/dd/json/idx1", hIndexDelete, "idxdb", null, &.{ .{ "ddoc", "dd" }, .{ "type", "json" }, .{ "name", "idx1" } }, &.{}, &.{}, null);
    defer d1_again.ht.deinit();
    try std.testing.expectEqual(@as(u16, 404), d1_again.status);

    // Delete remaining index; views must be preserved on _design/dd
    var d2 = try dispatchTestReqWithParams(app, .DELETE, "/idxdb/_index/dd/json/idx2", hIndexDelete, "idxdb", null, &.{ .{ "ddoc", "dd" }, .{ "type", "json" }, .{ "name", "idx2" } }, &.{}, &.{}, null);
    defer d2.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), d2.status);
    const dd_doc = db.get("_design/dd") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!dd_doc.winnerLeaf().deleted);
    try std.testing.expect(std.mem.indexOf(u8, dd_doc.winnerLeaf().body, "\"views\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dd_doc.winnerLeaf().body, "zouch_indexes") == null);

    // Design doc with only an index is deleted when its last index is removed
    var c3 = try dispatchTestReq(app, .POST, "/idxdb/_index", hIndexCreate, "idxdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"index\":{\"fields\":[\"c\"]},\"ddoc\":\"only_idx\",\"name\":\"solo\"}");
    defer c3.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), c3.status);
    var d3 = try dispatchTestReqWithParams(app, .DELETE, "/idxdb/_index/only_idx/json/solo", hIndexDelete, "idxdb", null, &.{ .{ "ddoc", "only_idx" }, .{ "type", "json" }, .{ "name", "solo" } }, &.{}, &.{}, null);
    defer d3.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), d3.status);
    const only_doc = db.get("_design/only_idx") orelse return error.TestUnexpectedResult;
    try std.testing.expect(only_doc.winnerLeaf().deleted);
}

test "cmpViewKey collates JSON objects lexicographically like CouchDB" {
    const alloc = std.testing.allocator;
    const ab = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":1,\"b\":1}", .{});
    defer ab.deinit();
    const b_only = try std.json.parseFromSlice(std.json.Value, alloc, "{\"b\":1}", .{});
    defer b_only.deinit();
    const a_only = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":1}", .{});
    defer a_only.deinit();
    const b1_a2 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"b\":1,\"a\":2}", .{});
    defer b1_a2.deinit();
    const a1_b2 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":1,\"b\":2}", .{});
    defer a1_b2.deinit();
    const b2_a1 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"b\":2,\"a\":1}", .{});
    defer b2_a1.deinit();
    const empty = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer empty.deinit();

    try std.testing.expectEqual(@as(i32, -1), cmpViewKey(ab.value, b_only.value, null, alloc));
    try std.testing.expectEqual(@as(i32, 1), cmpViewKey(b_only.value, ab.value, null, alloc));
    try std.testing.expectEqual(@as(i32, -1), cmpViewKey(a_only.value, ab.value, null, alloc));
    try std.testing.expectEqual(@as(i32, 1), cmpViewKey(b1_a2.value, a1_b2.value, null, alloc));
    try std.testing.expectEqual(@as(i32, -1), cmpViewKey(empty.value, a_only.value, null, alloc));
    try std.testing.expectEqual(@as(i32, 0), cmpViewKey(b2_a1.value, a1_b2.value, null, alloc));
}

test "partial_filter_selector persists, filters index rows, and gates index selection" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-partial-index";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const app = try App.init(alloc, io, root);
    defer app.deinit();
    const db = try app.createDb("pdb");
    {
        db.lock();
        defer db.unlock();
        _ = try db.putLocal("d1", "{\"a\":1,\"status\":\"active\"}", null, false);
        _ = try db.putLocal("d2", "{\"a\":1,\"status\":\"archived\"}", null, false);
        _ = try db.putLocal("d3", "{\"a\":2,\"status\":\"active\"}", null, false);
    }

    var ci = try dispatchTestReq(app, .POST, "/pdb/_index", hIndexCreate, "pdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"index\":{\"fields\":[\"a\"],\"partial_filter_selector\":{\"status\":\"active\"}},\"ddoc\":\"pdd\",\"name\":\"p_idx\"}");
    defer ci.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), ci.status);

    var li = try dispatchTestReq(app, .GET, "/pdb/_index", hIndexList, "pdb", null, &.{}, &.{}, null);
    defer li.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), li.status);
    try std.testing.expect(std.mem.indexOf(u8, li.body, "\"partial_filter_selector\":{\"status\":\"active\"}") != null);

    // Partial index on disk only contains the 2 active docs
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const pfs_parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), "{\"status\":\"active\"}", .{});
    const idx_val = loadMangoIndexWithFilter(db, arena_state.allocator(), "a", pfs_parsed.value) orelse return error.TestUnexpectedResult;
    const rows = idx_val.object.get("rows").?.array;
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);

    // _explain selects p_idx when selector implies partial_filter_selector
    var ex_ok = try dispatchTestReq(app, .POST, "/pdb/_explain", hExplain, "pdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"a\":1,\"status\":\"active\"}}");
    defer ex_ok.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), ex_ok.status);
    try std.testing.expect(std.mem.indexOf(u8, ex_ok.body, "\"name\":\"p_idx\"") != null);

    // _explain with use_index refuses p_idx when selector does not imply partial_filter_selector
    var ex_skip = try dispatchTestReq(app, .POST, "/pdb/_explain", hExplain, "pdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"a\":1},\"use_index\":[\"pdd\",\"p_idx\"]}");
    defer ex_skip.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), ex_skip.status);
    try std.testing.expect(std.mem.indexOf(u8, ex_skip.body, "\"name\":\"_all_docs\"") != null);

    // _find without status:"active" must still return both d1 and d2
    var f_all = try dispatchTestReq(app, .POST, "/pdb/_find", hFind, "pdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"a\":1},\"use_index\":[\"pdd\",\"p_idx\"]}");
    defer f_all.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), f_all.status);
    try std.testing.expect(std.mem.indexOf(u8, f_all.body, "\"d1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f_all.body, "\"d2\"") != null);

    // _find with status:"active" returns only d1
    var f_act = try dispatchTestReq(app, .POST, "/pdb/_find", hFind, "pdb", null, &.{.{ "content-type", "application/json" }}, &.{}, "{\"selector\":{\"a\":1,\"status\":\"active\"}}");
    defer f_act.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), f_act.status);
    try std.testing.expect(std.mem.indexOf(u8, f_act.body, "\"d1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f_act.body, "\"d2\"") == null);
}

test "active_tasks reports active compaction, indexer, and replication tasks" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-active-tasks";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const app = try App.init(alloc, io, root);
    defer app.deinit();

    // Empty initially
    var empty_res = try dispatchTestReq(app, .GET, "/_active_tasks", hActiveTasks, null, null, &.{}, &.{}, null);
    defer empty_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), empty_res.status);
    try std.testing.expectEqualStrings("[]", empty_res.body);

    // Register one task of each kind
    const p_comp = app.beginTask("database_compaction", "db1", null, null, null, null, 100);
    app.updateTask(p_comp, 40, 100);
    const p_idx = app.beginTask("indexer", "db1", "_design/dd", null, null, null, 50);
    app.updateTask(p_idx, 25, 50);
    const p_rep = app.beginTask("replication", "_replicator", null, "http://src", "http://dst", "rep1", 0);

    var active_res = try dispatchTestReq(app, .GET, "/_active_tasks", hActiveTasks, null, null, &.{}, &.{}, null);
    defer active_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), active_res.status);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"type\":\"database_compaction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"progress\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"type\":\"indexer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"design_document\":\"_design/dd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"progress\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"type\":\"replication\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_res.body, "\"doc_id\":\"rep1\"") != null);

    // Ending tasks removes them
    app.endTask(p_comp);
    app.endTask(p_idx);
    app.endTask(p_rep);

    var done_res = try dispatchTestReq(app, .GET, "/_active_tasks", hActiveTasks, null, null, &.{}, &.{}, null);
    defer done_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), done_res.status);
    try std.testing.expectEqualStrings("[]", done_res.body);
}

test "admission control enforces ZOUCH_MAX_BODY_MB (413) and ZOUCH_VECTOR_INDEX_MB (507)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-admission-control";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const app = try App.init(alloc, io, root);
    defer app.deinit();

    var create_res = try dispatchTestReq(app, .PUT, "/admdb", hDbPut, "admdb", null, &.{}, &.{}, null);
    defer create_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), create_res.status);

    // 1) ZOUCH_MAX_BODY_MB: setting cap to 1 MiB rejects body > 1 MiB with 413
    app.setMaxBodyMb(1);
    const big_body = try alloc.alloc(u8, 1024 * 1024 + 16);
    defer alloc.free(big_body);
    @memset(big_body, ' ');
    var too_big = try dispatchTestReq(
        app,
        .PUT,
        "/admdb/bigdoc",
        hDocPut,
        "admdb",
        "bigdoc",
        &.{.{ "content-type", "application/json" }},
        &.{},
        big_body,
    );
    defer too_big.ht.deinit();
    try std.testing.expectEqual(@as(u16, 413), too_big.status);
    try std.testing.expect(std.mem.indexOf(u8, too_big.body, "\"too_large\"") != null);

    // 2) ZOUCH_VECTOR_INDEX_MB: 0 means unlimited (200); positive cap rejects oversized budget
    var doc_put = try dispatchTestReq(
        app,
        .PUT,
        "/admdb/v1",
        hDocPut,
        "admdb",
        "v1",
        &.{.{ "content-type", "application/json" }},
        &.{},
        "{\"embedding_b64\":\"AACAPwAAAD8AAIA+AAAAPg==\"}",
    );
    defer doc_put.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), doc_put.status);

    app.setVectorIndexMb(0);
    var vec_res = try dispatchTestReq(
        app,
        .POST,
        "/admdb/_vector_search",
        hVectorSearch,
        "admdb",
        null,
        &.{.{ "content-type", "application/json" }},
        &.{},
        "{\"vector\":[1.0,0.0,0.0,0.0],\"k\":1,\"engine\":\"hnsw\"}",
    );
    defer vec_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 200), vec_res.status);

    app.setVectorIndexMb(1);
    try std.testing.expectError(error.VectorIndexLimitExceeded, checkVectorBudget(app, 10000, 128));
}

test "concurrent reads succeed while view index build runs without holding db.mutex" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cache/zouch-test-concurrent-view";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const app = try App.init(alloc, io, root);
    defer app.deinit();

    var create_res = try dispatchTestReq(app, .PUT, "/concdb", hDbPut, "concdb", null, &.{}, &.{}, null);
    defer create_res.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), create_res.status);

    // Seed docs and a design doc with a non-trivial map function
    var put_doc = try dispatchTestReq(
        app,
        .PUT,
        "/concdb/d1",
        hDocPut,
        "concdb",
        "d1",
        &.{.{ "content-type", "application/json" }},
        &.{},
        "{\"val\":42}",
    );
    defer put_doc.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), put_doc.status);

    const ddoc_body = "{\"views\":{\"slow\":{\"map\":\"function(doc){var s=0;for(var i=0;i<50000;i++){s+=i;}emit(doc._id,s);}\"}}}";
    var put_ddoc = try dispatchTestReq(
        app,
        .PUT,
        "/concdb/_design/vdd",
        hDocPut,
        "concdb",
        "_design/vdd",
        &.{.{ "content-type", "application/json" }},
        &.{},
        ddoc_body,
    );
    defer put_ddoc.ht.deinit();
    try std.testing.expectEqual(@as(u16, 201), put_ddoc.status);

    const Worker = struct {
        app: *App,
        status: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
        fn run(self: *@This()) void {
            var res = dispatchTestReqWithParams(
                self.app,
                .GET,
                "/concdb/_design/vdd/_view/slow",
                hView,
                "concdb",
                null,
                &.{ .{ "ddoc", "vdd" }, .{ "view", "slow" } },
                &.{},
                &.{},
                null,
            ) catch {
                self.status.store(500, .release);
                return;
            };
            defer res.ht.deinit();
            self.status.store(res.status, .release);
        }
    };

    var worker = Worker{ .app = app };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Perform concurrent reads on the same DB while the view build is running.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var get_res = try dispatchTestReq(app, .GET, "/concdb/d1", hDocGet, "concdb", "d1", &.{}, &.{}, null);
        defer get_res.ht.deinit();
        try std.testing.expectEqual(@as(u16, 200), get_res.status);
    }

    thread.join();
    try std.testing.expectEqual(@as(u16, 200), worker.status.load(.acquire));
}
