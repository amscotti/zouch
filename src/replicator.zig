//! One-shot pull replication from a CouchDB-compatible source into a local
//! Zouch database. This is the shared primitive behind the `pull` CLI command
//! and, later, the `_replicator` scheduler.

const std = @import("std");
const Db = @import("store/db.zig").Db;
const Doc = @import("doc/tree.zig").Doc;
const Rev = @import("doc/rev.zig").Rev;
const jsonw = @import("http/jsonw.zig");
const flate = std.compress.flate;

/// A set of document ids to restrict a replication to, as `doc_ids` asks for.
pub const IdFilter = std.StringHashMapUnmanaged(void);

/// Upper bound for one attachment, matching what a blob read will accept.
const max_attachment = 64 * 1024 * 1024;

pub const Result = struct {
    documents: usize = 0,
    changes_seen: usize = 0,
    /// `_bulk_get` requests made and documents they returned: CouchDB reports
    /// both, and a pull that batches shows them non-zero.
    bulk_get_attempts: usize = 0,
    bulk_get_docs: usize = 0,
    doc_write_failures: usize = 0,
    /// Sequences the run started and ended at, when the source has them. The
    /// caller owns both and frees them; they are null unless the run finished.
    start_seq: ?[]u8 = null,
    end_seq: ?[]u8 = null,
};

/// Carries a human-readable explanation of a replication failure out to the
/// caller. Zig errors cannot hold payloads, and "error.SourceHttpError" alone
/// does not tell a user whether the password, the database name or the server
/// was wrong. The CLI prints `message`; the HTTP `_replicator` scheduler stores
/// it as the job's last error.
pub const Diag = struct {
    alloc: std.mem.Allocator,
    message: ?[]u8 = null,
    /// Last non-2xx status seen, so callers can add a targeted hint.
    status: u16 = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        if (self.message) |old| self.alloc.free(old);
        self.message = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    }

    pub fn clear(self: *Diag) void {
        if (self.message) |old| self.alloc.free(old);
        self.message = null;
        self.status = 0;
    }

    pub fn deinit(self: *Diag) void {
        self.clear();
    }
};

/// Written once per committed changes page. A first sync of a large database
/// is otherwise silent for minutes, which reads as a hung command.
pub const Progress = struct {
    documents: usize = 0,
    changes: usize = 0,
};

/// A pair of callbacks that take and release the lock of the database being
/// touched (the server passes that database's own `Db.mutex`). A pull that held
/// it across its network waits froze every other request on that database for
/// the duration of the copy. With this the loop holds it only while it touches
/// the database.
pub const Guard = struct {
    lock: ?*const fn (?*anyopaque) void = null,
    unlock: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    fn enter(self: Guard) void {
        if (self.lock) |f| f(self.ctx);
    }

    fn leave(self: Guard) void {
        if (self.unlock) |f| f(self.ctx);
    }
};

pub const Options = struct {
    source: []const u8,
    target_path: []const u8,
    /// Identity placed in the remote checkpoint key. When omitted, `pullInto`
    /// uses the target database's persistent UUID so a recreated or separate
    /// target database never resumes from another database's checkpoint.
    checkpoint_target: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    /// A mango selector, serialized. The source evaluates it: CouchDB accepts a
    /// selector only on a POSTed changes feed, where it is the body.
    selector: ?[]const u8 = null,
    /// Start at this source sequence instead of the stored checkpoint, which is
    /// what CouchDB's `since_seq` does.
    since: ?[]const u8 = null,
    /// When set, only these document ids are copied.
    doc_ids: ?*const IdFilter = null,
    page_size: usize = 500,
    /// `use_checkpoints: false` in a replication document means no `_local`
    /// checkpoint is read or written, so a repeat starts from the beginning.
    use_checkpoints: bool = true,
    diag: ?*Diag = null,
    /// Lock/unlock the caller's database mutex. The pull releases it while it
    /// waits on the source and takes it back for each write. Absent, the caller
    /// keeps the lock for the whole call (the CLI is single-threaded and has
    /// none to take).
    lock: ?*const fn (ctx: ?*anyopaque) void = null,
    unlock: ?*const fn (ctx: ?*anyopaque) void = null,
    lock_ctx: ?*anyopaque = null,
    /// Called after each page is committed. Keep it cheap: it runs on the
    /// replication path.
    on_progress: ?*const fn (ctx: ?*anyopaque, progress: Progress) void = null,
    progress_ctx: ?*anyopaque = null,
    /// Custom HTTP headers sent on every outbound request.
    headers: []const std.http.Header = &.{},
    /// Prefer `/_session` cookie login up front when username/password are set.
    use_session_auth: bool = false,
    max_attachment_bytes: usize = max_attachment,
};

/// A checkpoint kept on a remote target: the sequence reached, and the target's
/// `_rev` for the `_local` document so the next write can replace it.
pub const RemoteCheckpoint = struct {
    since: []u8,
    rev: ?[]u8,

    pub fn deinit(self: RemoteCheckpoint, alloc: std.mem.Allocator) void {
        alloc.free(self.since);
        if (self.rev) |r| alloc.free(r);
    }
};

pub const CheckpointKey = struct {
    source: []const u8,
    target: []const u8 = "",
    filter: ?[]const u8 = null,
    doc_ids: ?*const IdFilter = null,
    selector: ?[]const u8 = null,
    since_seq: ?[]const u8 = null,
};

/// The `_local` id a pull uses, so a remote-to-remote job can keep its
/// checkpoint on the target under the same id a pull into a local database uses.
pub fn checkpointDocId(alloc: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ![]u8 {
    return checkpointId(alloc, .{ .source = source, .filter = filter });
}

/// Full checkpoint id hashing source, target, filter, doc_ids, selector, and since_seq.
pub fn checkpointDocIdFor(alloc: std.mem.Allocator, key: CheckpointKey) ![]u8 {
    return checkpointId(alloc, key);
}

pub fn basicAuthHeader(alloc: std.mem.Allocator, user: []const u8, password: []const u8) ![]u8 {
    return basicAuth(alloc, user, password);
}

/// Reads the checkpoint a remote-to-remote job left on its target. Any failure
/// means "start from the beginning", which is always safe, so nothing is
/// reported: a missing, unreadable or foreign document is not an error.
pub fn readRemoteCheckpoint(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    auth: ?[]const u8,
    id: []const u8,
) ?RemoteCheckpoint {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const url = std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimSlash(base_url), id }) catch return null;
    defer alloc.free(url);
    const body = httpRequest(&client, alloc, .GET, url, auth, null, null) catch return null;
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const since_v = parsed.value.object.get("since") orelse return null;
    if (since_v != .string) return null;
    const since = alloc.dupe(u8, since_v.string) catch return null;
    errdefer alloc.free(since);
    var rev: ?[]u8 = null;
    if (parsed.value.object.get("_rev")) |rv| {
        if (rv == .string) rev = alloc.dupe(u8, rv.string) catch null;
    }
    return .{ .since = since, .rev = rev };
}

/// Writes the checkpoint a remote-to-remote job reached, so a restart resumes
/// instead of reading the whole source again. CouchDB keeps it on the target;
/// so does this, under the same `_local` id a local pull would use.
pub fn writeRemoteCheckpoint(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    auth: ?[]const u8,
    id: []const u8,
    since: []const u8,
    rev: ?[]const u8,
) !void {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimSlash(base_url), id });
    defer alloc.free(url);
    const body = if (rev) |r|
        try std.fmt.allocPrint(alloc, "{{\"_rev\":\"{s}\",\"since\":\"{s}\"}}", .{ r, since })
    else
        try std.fmt.allocPrint(alloc, "{{\"since\":\"{s}\"}}", .{since});
    defer alloc.free(body);
    const out = try httpRequest(&client, alloc, .PUT, url, auth, body, null);
    alloc.free(out);
}

fn trimSlash(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return url[0..end];
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

fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~')
        {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 15]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn basicAuth(alloc: std.mem.Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ user, pass });
    defer alloc.free(raw);
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try alloc.alloc(u8, "Basic ".len + encoded_len);
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(out["Basic ".len..], raw);
    return out;
}

const retry_max_attempts: usize = 4;
const retry_base_ms: u64 = 100;

fn isTransientStatus(status: u16) bool {
    return status == 429 or (status >= 500 and status < 600);
}

fn isTransientError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.BadUrl,
        error.TooLarge,
        error.AttachmentDigestMismatch,
        error.SourceHttpError,
        => false,
        else => true,
    };
}

fn setSocketTimeouts(fd: std.posix.socket_t, secs: i64) void {
    if (@import("builtin").os.tag == .windows) return;
    const tv: std.posix.timeval = .{ .sec = secs, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

const max_http_response_bytes: usize = 64 * 1024 * 1024;
const network_timeout_secs: i64 = 60;

fn sleepBackoff(io: std.Io, ms: u64) void {
    std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

const AuthSession = struct {
    alloc: std.mem.Allocator,
    base_url: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    basic_auth: ?[]u8 = null,
    cookie: ?[]u8 = null,
    extra_headers: []const std.http.Header = &.{},
    tried_session: bool = false,

    fn init(
        alloc: std.mem.Allocator,
        base_url: []const u8,
        username: ?[]const u8,
        password: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) !AuthSession {
        const basic: ?[]u8 = if (username) |u|
            try basicAuth(alloc, u, password orelse "")
        else
            null;
        return .{
            .alloc = alloc,
            .base_url = trimSlash(base_url),
            .username = username,
            .password = password,
            .basic_auth = basic,
            .extra_headers = extra_headers,
        };
    }

    fn deinit(self: *AuthSession) void {
        if (self.basic_auth) |b| self.alloc.free(b);
        if (self.cookie) |c| self.alloc.free(c);
    }

    fn serverRootUrl(url: []const u8) []const u8 {
        const trimmed = trimSlash(url);
        const scheme_end = std.mem.indexOf(u8, trimmed, "://") orelse return trimmed;
        const after_host = std.mem.indexOfScalarPos(u8, trimmed, scheme_end + 3, '/') orelse return trimmed;
        const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
        if (last_slash >= after_host) return trimmed[0..last_slash];
        return trimmed;
    }

    fn loginSession(self: *AuthSession, client: *std.http.Client) bool {
        self.tried_session = true;
        const user = self.username orelse return false;
        const pass = self.password orelse "";
        const root = serverRootUrl(self.base_url);
        const session_url = std.fmt.allocPrint(self.alloc, "{s}/_session", .{root}) catch return false;
        defer self.alloc.free(session_url);
        const uri = std.Uri.parse(session_url) catch return false;

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.alloc);
        payload.appendSlice(self.alloc, "{\"name\":") catch return false;
        jsonw.writeString(&payload, self.alloc, user) catch return false;
        payload.appendSlice(self.alloc, ",\"password\":") catch return false;
        jsonw.writeString(&payload, self.alloc, pass) catch return false;
        payload.append(self.alloc, '}') catch return false;

        var hdrs: [2]std.http.Header = .{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
        };
        var req = client.request(.POST, uri, .{
            .extra_headers = &hdrs,
        }) catch return false;
        defer req.deinit();
        if (req.connection) |conn| setSocketTimeouts(conn.stream_reader.stream.socket.handle, network_timeout_secs);
        req.sendBodyComplete(payload.items) catch return false;
        var head_buf: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&head_buf) catch return false;
        const status: u16 = @backingInt(response.head.status);
        if (status < 200 or status >= 300) return false;

        var it = response.head.iterateHeaders();
        while (it.next()) |hdr| {
            if (!std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) continue;
            if (std.mem.indexOf(u8, hdr.value, "AuthSession=")) |pos| {
                const rest = hdr.value[pos..];
                const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                if (end > "AuthSession=".len) {
                    const duped = self.alloc.dupe(u8, rest[0..end]) catch return false;
                    if (self.cookie) |old| self.alloc.free(old);
                    self.cookie = duped;
                    return true;
                }
            }
        }
        return false;
    }
};

fn httpRequest(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
    diag: ?*Diag,
) ![]u8 {
    var session = AuthSession{
        .alloc = alloc,
        .base_url = url,
        .basic_auth = if (auth) |a| try alloc.dupe(u8, a) else null,
    };
    defer session.deinit();
    return httpRequestSession(client, alloc, method, url, &session, body, null, diag);
}

fn httpRequestOnce(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    extra_headers: []const std.http.Header,
    aw: *std.Io.Writer.Allocating,
) !std.http.Status {
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    var req_opts: std.http.Client.RequestOptions = .{ .extra_headers = extra_headers };
    if (body != null) req_opts.redirect_behavior = .unhandled;
    var req = try client.request(method, uri, req_opts);
    defer req.deinit();
    if (req.connection) |conn| setSocketTimeouts(conn.stream_reader.stream.socket.handle, network_timeout_secs);

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(payload);
        try bw.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) alloc.free(decompress_buffer);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);
    var l_buf: [4096]u8 = undefined;
    var limited = reader.limited(.limited(max_http_response_bytes), &l_buf);
    _ = limited.interface.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
    if (aw.writer.end == max_http_response_bytes) {
        if (reader.peekByte()) |_| return error.TooLarge else |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        }
    }
    return response.head.status;
}

fn httpRequestSession(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    session: ?*AuthSession,
    body: ?[]const u8,
    content_type: ?[]const u8,
    diag: ?*Diag,
) ![]u8 {
    var backoff_ms: u64 = retry_base_ms;
    var attempt: usize = 0;
    while (attempt < retry_max_attempts) : (attempt += 1) {
        var hdrs: std.ArrayListUnmanaged(std.http.Header) = .empty;
        defer hdrs.deinit(alloc);
        try hdrs.append(alloc, .{ .name = "accept", .value = "application/json" });
        if (session) |s| {
            if (s.cookie) |c| {
                try hdrs.append(alloc, .{ .name = "cookie", .value = c });
            } else if (s.basic_auth) |a| {
                try hdrs.append(alloc, .{ .name = "authorization", .value = a });
            }
            for (s.extra_headers) |eh| {
                try hdrs.append(alloc, eh);
            }
        }
        if (body != null) {
            try hdrs.append(alloc, .{ .name = "content-type", .value = content_type orelse "application/json" });
        }

        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();

        const http_status = httpRequestOnce(client, alloc, method, url, body, hdrs.items, &aw) catch |e| {
            if (isTransientError(e) and attempt + 1 < retry_max_attempts) {
                aw.deinit();
                sleepBackoff(client.io, backoff_ms);
                backoff_ms *= 2;
                continue;
            }
            if (diag) |d| d.set("{s} {s}: {s}", .{ @tagName(method), url, @errorName(e) });
            return e;
        };

        const status: u16 = @backingInt(http_status);
        if (status >= 200 and status < 300) {
            return aw.toOwnedSlice();
        }
        if ((status == 401 or status == 403) and session != null) {
            const s = session.?;
            if (s.username != null and !s.tried_session) {
                if (s.loginSession(client)) {
                    aw.deinit();
                    continue;
                }
            }
        }
        if (isTransientStatus(status) and attempt + 1 < retry_max_attempts) {
            aw.deinit();
            sleepBackoff(client.io, backoff_ms);
            backoff_ms *= 2;
            continue;
        }
        if (diag) |d| {
            d.status = status;
            // One line, bounded: the body is usually CouchDB's
            // {"error":...,"reason":...}, which is exactly the useful part.
            var flat: [160]u8 = undefined;
            const text = aw.written();
            const n = @min(text.len, flat.len);
            for (flat[0..n], text[0..n]) |*dst, c|
                dst.* = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
            d.set("{s} {s} returned {d} {s}: {s}", .{
                @tagName(method),
                url,
                status,
                http_status.phrase() orelse "",
                flat[0..n],
            });
        }
        return error.SourceHttpError;
    }
    unreachable;
}

fn httpGet(client: *std.http.Client, alloc: std.mem.Allocator, url: []const u8, session: ?*AuthSession, diag: ?*Diag) ![]u8 {
    return httpRequestSession(client, alloc, .GET, url, session, null, null, diag);
}

fn httpPost(client: *std.http.Client, alloc: std.mem.Allocator, url: []const u8, session: ?*AuthSession, body: []const u8, diag: ?*Diag) ![]u8 {
    return httpRequestSession(client, alloc, .POST, url, session, body, null, diag);
}

const max_checkpoint_history: usize = 50;

const CheckpointHistoryEntry = struct {
    session_id: []u8,
    recorded_seq: []u8,
};

const CheckpointDoc = struct {
    since: []u8,
    session_id: ?[]u8 = null,
    rev: ?[]u8 = null,
    history: std.ArrayListUnmanaged(CheckpointHistoryEntry) = .empty,

    fn deinit(self: *CheckpointDoc, alloc: std.mem.Allocator) void {
        alloc.free(self.since);
        if (self.session_id) |s| alloc.free(s);
        if (self.rev) |r| alloc.free(r);
        for (self.history.items) |h| {
            alloc.free(h.session_id);
            alloc.free(h.recorded_seq);
        }
        self.history.deinit(alloc);
    }
};

fn hashOptField(h: *std.crypto.hash.Md5, val: ?[]const u8) void {
    if (val) |v| {
        h.update("\x01");
        h.update(v);
    } else {
        h.update("\x00");
    }
}

fn checkpointId(alloc: std.mem.Allocator, key: CheckpointKey) ![]u8 {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(key.source);
    h.update("\x00");
    h.update(key.target);
    h.update("\x00");
    hashOptField(&h, key.filter);
    hashOptField(&h, key.selector);
    hashOptField(&h, key.since_seq);
    if (key.doc_ids) |set| {
        h.update("\x01");
        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ids.deinit(alloc);
        var it = set.keyIterator();
        while (it.next()) |kp| try ids.append(alloc, kp.*);
        std.mem.sort([]const u8, ids.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (ids.items) |id| {
            h.update(id);
            h.update("\x00");
        }
    } else {
        h.update("\x00");
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "_local/{s}", .{hex});
}

fn legacyCheckpointId(alloc: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(source);
    h.update("\x00");
    if (filter) |f| h.update(f);
    return std.fmt.allocPrint(alloc, "_local/zouch-pull-{x}", .{h.final()});
}

fn generateSessionId(io: std.Io) [32]u8 {
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    return std.fmt.bytesToHex(rnd, .lower);
}

fn parseSeqValue(alloc: std.mem.Allocator, val: std.json.Value) ?[]u8 {
    return switch (val) {
        .string => |s| alloc.dupe(u8, s) catch null,
        .integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}) catch null,
        else => null,
    };
}

fn parseCheckpointJson(alloc: std.mem.Allocator, body: []const u8, rev_override: ?[]const u8) ?CheckpointDoc {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    var cp = CheckpointDoc{
        .since = undefined,
    };
    errdefer {
        if (cp.session_id) |s| alloc.free(s);
        if (cp.rev) |r| alloc.free(r);
        for (cp.history.items) |h| {
            alloc.free(h.session_id);
            alloc.free(h.recorded_seq);
        }
        cp.history.deinit(alloc);
    }

    if (obj.get("session_id")) |sv| {
        if (sv == .string) cp.session_id = alloc.dupe(u8, sv.string) catch return null;
    }
    if (rev_override) |r| {
        cp.rev = alloc.dupe(u8, r) catch return null;
    } else if (obj.get("_rev")) |rv| {
        if (rv == .string) cp.rev = alloc.dupe(u8, rv.string) catch return null;
    }

    if (obj.get("history")) |hv| {
        if (hv == .array) {
            for (hv.array.items) |item| {
                if (item != .object) continue;
                const h_sid_v = item.object.get("session_id") orelse continue;
                if (h_sid_v != .string) continue;
                const h_seq_v = item.object.get("recorded_seq") orelse item.object.get("source_last_seq") orelse continue;
                const h_seq = parseSeqValue(alloc, h_seq_v) orelse continue;
                const h_sid = alloc.dupe(u8, h_sid_v.string) catch {
                    alloc.free(h_seq);
                    return null;
                };
                cp.history.append(alloc, .{ .session_id = h_sid, .recorded_seq = h_seq }) catch {
                    alloc.free(h_sid);
                    alloc.free(h_seq);
                    return null;
                };
            }
        }
    }

    const since_val = obj.get("source_last_seq") orelse obj.get("since") orelse {
        if (cp.history.items.len > 0) {
            cp.since = alloc.dupe(u8, cp.history.items[0].recorded_seq) catch return null;
            return cp;
        }
        return null;
    };
    cp.since = parseSeqValue(alloc, since_val) orelse return null;
    return cp;
}

fn readLocalCheckpointDoc(alloc: std.mem.Allocator, db: *Db, id: []const u8, legacy_id: ?[]const u8) ?CheckpointDoc {
    if (db.getLocal(id)) |local| {
        if (parseCheckpointJson(alloc, local.body, null)) |cp| return cp;
    }
    if (legacy_id) |lid| {
        if (db.getLocal(lid)) |local| {
            if (parseCheckpointJson(alloc, local.body, null)) |cp| return cp;
        }
    }
    return null;
}

fn readRemoteCheckpointDoc(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    session: ?*AuthSession,
    id: []const u8,
) ?CheckpointDoc {
    const url = std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimSlash(base_url), id }) catch return null;
    defer alloc.free(url);
    const body = httpRequestSession(client, alloc, .GET, url, session, null, null, null) catch return null;
    defer alloc.free(body);
    return parseCheckpointJson(alloc, body, null);
}

fn resolveResumeSeq(alloc: std.mem.Allocator, src_cp: ?*const CheckpointDoc, dst_cp: ?*const CheckpointDoc) ![]u8 {
    if (src_cp != null and dst_cp != null) {
        const s = src_cp.?;
        const d = dst_cp.?;
        if (s.session_id != null and d.session_id != null and std.mem.eql(u8, s.session_id.?, d.session_id.?)) {
            return alloc.dupe(u8, s.since);
        }
        for (s.history.items) |sh| {
            for (d.history.items) |dh| {
                if (std.mem.eql(u8, sh.session_id, dh.session_id)) {
                    return alloc.dupe(u8, sh.recorded_seq);
                }
            }
        }
        if (s.history.items.len == 0 and d.history.items.len == 0) {
            const sn = std.fmt.parseInt(u64, s.since, 10) catch null;
            const dn = std.fmt.parseInt(u64, d.since, 10) catch null;
            if (sn != null and dn != null) {
                return std.fmt.allocPrint(alloc, "{d}", .{@min(sn.?, dn.?)});
            }
        }
        return alloc.dupe(u8, "0");
    }
    if (src_cp) |s| return alloc.dupe(u8, s.since);
    if (dst_cp) |d| return alloc.dupe(u8, d.since);
    return alloc.dupe(u8, "0");
}

fn buildCheckpointJson(
    alloc: std.mem.Allocator,
    session_id: []const u8,
    seq: []const u8,
    history: []const CheckpointHistoryEntry,
    rev: ?[]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    if (rev) |r| {
        try out.appendSlice(alloc, "\"_rev\":");
        try jsonw.writeString(&out, alloc, r);
        try out.append(alloc, ',');
    }
    try out.appendSlice(alloc, "\"session_id\":");
    try jsonw.writeString(&out, alloc, session_id);
    try out.appendSlice(alloc, ",\"source_last_seq\":");
    try jsonw.writeString(&out, alloc, seq);
    try out.appendSlice(alloc, ",\"since\":");
    try jsonw.writeString(&out, alloc, seq);
    try out.appendSlice(alloc, ",\"replication_id_version\":4,\"history\":[");
    try out.appendSlice(alloc, "{\"session_id\":");
    try jsonw.writeString(&out, alloc, session_id);
    try out.appendSlice(alloc, ",\"recorded_seq\":");
    try jsonw.writeString(&out, alloc, seq);
    try out.appendSlice(alloc, ",\"source_last_seq\":");
    try jsonw.writeString(&out, alloc, seq);
    try out.append(alloc, '}');

    const limit = @min(history.len, max_checkpoint_history - 1);
    for (history[0..limit]) |h| {
        if (std.mem.eql(u8, h.session_id, session_id)) continue;
        try out.appendSlice(alloc, ",{\"session_id\":");
        try jsonw.writeString(&out, alloc, h.session_id);
        try out.appendSlice(alloc, ",\"recorded_seq\":");
        try jsonw.writeString(&out, alloc, h.recorded_seq);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

fn saveLocalCheckpointDoc(
    alloc: std.mem.Allocator,
    db: *Db,
    id: []const u8,
    session_id: []const u8,
    seq: []const u8,
    history: []const CheckpointHistoryEntry,
) !void {
    const body = try buildCheckpointJson(alloc, session_id, seq, history, null);
    defer alloc.free(body);
    const parent: ?u32 = if (db.getLocal(id)) |l| l.rev else null;
    _ = try db.putLocalDoc(id, body, parent);
}

fn writeRemoteCheckpointDoc(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    session: ?*AuthSession,
    id: []const u8,
    session_id: []const u8,
    seq: []const u8,
    history: []const CheckpointHistoryEntry,
    rev: *?[]u8,
) !void {
    const url = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimSlash(base_url), id });
    defer alloc.free(url);
    const body = try buildCheckpointJson(alloc, session_id, seq, history, rev.*);
    defer alloc.free(body);
    const resp = try httpRequestSession(client, alloc, .PUT, url, session, body, "application/json", null);
    defer alloc.free(resp);
    if (std.json.parseFromSlice(std.json.Value, alloc, resp, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("rev")) |rv| {
                if (rv == .string) {
                    if (alloc.dupe(u8, rv.string)) |new_rev| {
                        if (rev.*) |old| alloc.free(old);
                        rev.* = new_rev;
                    } else |_| {}
                }
            }
        }
    } else |_| {}
}

fn lastSeqString(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| alloc.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
        else => error.BadSequence,
    };
}

pub fn pull(alloc: std.mem.Allocator, io: std.Io, opts: Options) !Result {
    const db = try Db.open(alloc, io, opts.target_path);
    defer db.close();
    var pull_opts = opts;
    if (pull_opts.checkpoint_target == null) {
        pull_opts.checkpoint_target = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ opts.target_path, &db.uuid });
    }
    defer if (opts.checkpoint_target == null) alloc.free(pull_opts.checkpoint_target.?);
    return pullInto(alloc, io, db, pull_opts);
}

/// "md5-" followed by the 16-byte digest in base64, which is how CouchDB
/// writes attachment digests.
fn parseMd5Digest(text: []const u8) ?[16]u8 {
    if (!std.mem.startsWith(u8, text, "md5-")) return null;
    const b64 = text[4..];
    if (b64.len != 24) return null;
    var out: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&out, b64) catch return null;
    return out;
}

/// Percent-encode a path segment the way CouchDB expects attachment names:
/// everything outside the unreserved set, including `/`, becomes an escape.
fn appendEncoded(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(alloc, c),
        else => {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 0xf]);
        },
    };
}

/// Fetch one attachment and write it straight to a blob, so a large file costs
/// a fixed buffer rather than twice its size. The digest the storage layer
/// computes names the blob, and it is the digest this pull verifies against the
/// source's, because the request asks for the payload without a transport
/// encoding.
fn httpGetAttachmentStream(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    db: *Db,
    url: []const u8,
    session: ?*AuthSession,
    max_len: usize,
    diag: ?*Diag,
) !Db.BlobUpload {
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    var backoff_ms: u64 = retry_base_ms;
    var attempt: usize = 0;
    while (attempt < retry_max_attempts) : (attempt += 1) {
        var hdrs: std.ArrayListUnmanaged(std.http.Header) = .empty;
        defer hdrs.deinit(alloc);
        try hdrs.append(alloc, .{ .name = "accept", .value = "*/*" });
        if (session) |s| {
            if (s.cookie) |c| {
                try hdrs.append(alloc, .{ .name = "cookie", .value = c });
            } else if (s.basic_auth) |a| {
                try hdrs.append(alloc, .{ .name = "authorization", .value = a });
            }
            for (s.extra_headers) |eh| {
                try hdrs.append(alloc, eh);
            }
        }
        // Ask the source not to compress. It has to be done through the client's
        // own header field: an extra_headers entry for accept-encoding is emitted
        // alongside the default one, and the source may then send the stored gzip
        // bytes, which are not the attachment.
        var req = client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = hdrs.items,
        }) catch |e| {
            if (isTransientError(e) and attempt + 1 < retry_max_attempts) {
                sleepBackoff(client.io, backoff_ms);
                backoff_ms *= 2;
                continue;
            }
            if (diag) |d| d.set("request {s}: {s}", .{ url, @errorName(e) });
            return e;
        };
        defer req.deinit();
        if (req.connection) |conn| setSocketTimeouts(conn.stream_reader.stream.socket.handle, network_timeout_secs);
        req.sendBodiless() catch |e| {
            if (isTransientError(e) and attempt + 1 < retry_max_attempts) {
                sleepBackoff(client.io, backoff_ms);
                backoff_ms *= 2;
                continue;
            }
            if (diag) |d| d.set("send {s}: {s}", .{ url, @errorName(e) });
            return e;
        };
        var head_buf: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&head_buf) catch |e| {
            if (isTransientError(e) and attempt + 1 < retry_max_attempts) {
                sleepBackoff(client.io, backoff_ms);
                backoff_ms *= 2;
                continue;
            }
            if (diag) |d| d.set("head {s}: {s}", .{ url, @errorName(e) });
            return e;
        };
        const status: u16 = @backingInt(response.head.status);
        if (status < 200 or status >= 300) {
            if ((status == 401 or status == 403) and session != null) {
                const s = session.?;
                if (s.username != null and !s.tried_session) {
                    if (s.loginSession(client)) continue;
                }
            }
            if (isTransientStatus(status) and attempt + 1 < retry_max_attempts) {
                sleepBackoff(client.io, backoff_ms);
                backoff_ms *= 2;
                continue;
            }
            if (diag) |d| {
                d.status = status;
                d.set("GET {s} returned {d} {s}", .{ url, status, response.head.status.phrase() orelse "" });
            }
            return error.SourceHttpError;
        }
        var transfer_buf: [32 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        return db.writeBlobStream(reader, max_len) catch |e| {
            if (diag) |d| d.set("blob write {s}: {s}", .{ url, @errorName(e) });
            return e;
        };
    }
    unreachable;
}

/// Turn one attachment object into a blob this database owns: verify it when
/// the digest describes the bytes we hold, then record the blob, its length and
/// a digest of the payload we actually store.
fn storeAttachment(db: *Db, alloc: std.mem.Allocator, av: *std.json.Value, raw: []const u8) !void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(raw, &digest, .{});
    // A source that stores the attachment compressed reports the digest of the
    // compressed bytes while handing over the decoded ones, so the digest only
    // describes what we hold when the source stored it plain.
    if (av.object.get("encoding") == null) {
        if (av.object.get("digest")) |dv| {
            if (dv == .string) {
                if (parseMd5Digest(dv.string)) |want| {
                    if (!std.mem.eql(u8, &want, &digest)) return error.AttachmentDigestMismatch;
                }
            }
        }
    }
    // The name has to outlive this frame: the document is serialized later,
    // and a pointer to the local hex buffer is a stack address by then.
    const hex = try alloc.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    try db.writeBlob(hex, raw);
    var digest_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&digest_b64, &digest);
    try av.object.put(alloc, "digest", .{ .string = try std.fmt.allocPrint(alloc, "md5-{s}", .{digest_b64}) });
    try av.object.put(alloc, "data", .null);
    try av.object.put(alloc, "blob", .{ .string = hex });
    try av.object.put(alloc, "stub", .{ .bool = true });
    try av.object.put(alloc, "length", .{ .integer = @intCast(raw.len) });
    _ = av.object.swapRemove("encoding");
    _ = av.object.swapRemove("encoded_length");
}

/// The bytes are already on disk, named by their digest; check that digest
/// against the source's and point the attachment at the blob.
fn recordUpload(alloc: std.mem.Allocator, av: *std.json.Value, upload: Db.BlobUpload) !void {
    if (av.object.get("encoding") == null) {
        if (av.object.get("digest")) |dv| {
            if (dv == .string) {
                if (parseMd5Digest(dv.string)) |want| {
                    if (!std.mem.eql(u8, &want, &upload.digest)) return error.AttachmentDigestMismatch;
                }
            }
        }
    }
    const hex = try alloc.dupe(u8, &upload.hex);
    var digest_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&digest_b64, &upload.digest);
    try av.object.put(alloc, "digest", .{ .string = try std.fmt.allocPrint(alloc, "md5-{s}", .{digest_b64}) });
    try av.object.put(alloc, "data", .null);
    try av.object.put(alloc, "blob", .{ .string = hex });
    try av.object.put(alloc, "stub", .{ .bool = true });
    try av.object.put(alloc, "length", .{ .integer = @intCast(upload.len) });
    _ = av.object.swapRemove("encoding");
    _ = av.object.swapRemove("encoded_length");
}

/// Store one attachment, taking the caller's lock only for the database
/// write. The bytes arrive over the network, which must not happen under the
/// lock: a pull from the same server would wait on a request that needs it.
fn storeAttachmentLocked(db: *Db, alloc: std.mem.Allocator, av: *std.json.Value, raw: []const u8, guard: Guard) !void {
    guard.enter();
    defer guard.leave();
    try storeAttachment(db, alloc, av, raw);
}

/// Replace the source's attachments with blobs this database holds. An
/// attachment the source did not inline is fetched on its own, so a document
/// full of large files costs the size of the largest one rather than the whole
/// base64-encoded payload.
fn externalizeAttachments(
    db: *Db,
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    source: []const u8,
    session: ?*AuthSession,
    enc_id: []const u8,
    rev_text: []const u8,
    body: []const u8,
    max_att_bytes: usize,
    diag: ?*Diag,
    guard: Guard,
) ![]const u8 {
    if (std.mem.indexOf(u8, body, "_attachments") == null) return body;
    var root = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return body;
    defer root.deinit();
    if (root.value != .object) return body;
    const atts = root.value.object.get("_attachments") orelse return body;
    if (atts != .object) return body;
    var it = atts.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const av = entry.value_ptr;
        if (av.* != .object) continue;
        if (av.object.get("data")) |data_v| {
            if (data_v == .string) {
                const n = std.base64.standard.Decoder.calcSizeForSlice(data_v.string) catch continue;
                const raw = try alloc.alloc(u8, n);
                defer alloc.free(raw);
                std.base64.standard.Decoder.decode(raw, data_v.string) catch continue;
                try storeAttachmentLocked(db, alloc, av, raw, guard);
                continue;
            }
        }
        var url: std.ArrayListUnmanaged(u8) = .empty;
        defer url.deinit(alloc);
        try url.appendSlice(alloc, source);
        try url.append(alloc, '/');
        try appendEncoded(&url, alloc, enc_id);
        try url.append(alloc, '/');
        try appendEncoded(&url, alloc, name);
        try url.appendSlice(alloc, "?rev=");
        try url.appendSlice(alloc, rev_text);
        const max_len: usize = max_att_bytes;
        // The response goes straight to a blob: no copy of the whole file in
        // memory, and no lock held while it arrives.
        const upload = httpGetAttachmentStream(client, alloc, db, url.items, session, max_len, diag) catch |e| {
            if (diag) |d| d.set("attachment {s} of {s}: {s}", .{ name, enc_id, @errorName(e) });
            return e;
        };
        try recordUpload(alloc, av, upload);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try jsonw.writeValue(&out, alloc, root.value);
    return out.items;
}

pub const LocalOptions = struct {
    /// Name of the source database, which keys the checkpoint on the target.
    source_name: []const u8,
    page_size: usize = 100,
    /// See `Options.use_checkpoints`.
    use_checkpoints: bool = true,
    doc_ids: ?*const IdFilter = null,
    diag: ?*Diag = null,
    /// Guards the target database (the one this call writes).
    lock: ?*const fn (?*anyopaque) void = null,
    unlock: ?*const fn (?*anyopaque) void = null,
    lock_ctx: ?*anyopaque = null,
    /// Guards the source database, which has its own lock: a page is copied
    /// out under this one and released before the target's lock is taken, so
    /// no thread ever holds both.
    source_guard: Guard = .{},
    on_progress: ?*const fn (?*anyopaque, Progress) void = null,
    progress_ctx: ?*anyopaque = null,
};

/// One document of a page, copied out of the source while its lock is held so
/// a concurrent write cannot free the memory underneath the import.
const LocalRow = struct {
    id: []u8,
    seq: u64,
    rev: Rev,
    ancestry: []Rev,
    body: []u8,
    deleted: bool,

    fn deinit(self: LocalRow, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.ancestry);
        alloc.free(self.body);
    }
};

/// Copy every blob the body references from the source database into the
/// target. Blobs are content addressed, so writing one that is already there
/// rewrites the same bytes under the same name.
fn copyAttachmentBlobs(alloc: std.mem.Allocator, source: *Db, target: *Db, body: []const u8) !void {
    if (std.mem.indexOf(u8, body, "\"_attachments\"") == null) return;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const atts = parsed.value.object.get("_attachments") orelse return;
    if (atts != .object) return;
    var it = atts.object.iterator();
    while (it.next()) |entry| {
        const av = entry.value_ptr;
        if (av.* != .object) continue;
        const blob_v = av.object.get("blob") orelse continue;
        if (blob_v != .string) continue;
        // A local copy can move the file itself; reading it here would put the
        // whole attachment in memory for no reason.
        try target.copyBlobFrom(source, blob_v.string);
    }
}

/// Replicate one database of this server into another. There is no network
/// hop, so each database operation runs under the caller's lock and none of
/// them wait; the page is copied out because Doc pointers do not survive an
/// unlock.
pub fn pullLocal(alloc: std.mem.Allocator, source: *Db, target: *Db, opts: LocalOptions) !Result {
    const guard: Guard = .{ .lock = opts.lock, .unlock = opts.unlock, .ctx = opts.lock_ctx };
    const opts_source_guard = opts.source_guard;
    const cp_key = try std.fmt.allocPrint(alloc, "local:{s}", .{opts.source_name});
    defer alloc.free(cp_key);
    const cp_id = try checkpointId(alloc, .{ .source = cp_key, .doc_ids = opts.doc_ids });
    defer alloc.free(cp_id);

    const session_id = generateSessionId(target.io);
    var result = Result{};
    var since: u64 = blk: {
        guard.enter();
        defer guard.leave();
        if (!opts.use_checkpoints) break :blk 0;
        if (readLocalCheckpointDoc(alloc, target, cp_id, null)) |*cp_val| {
            var cp = cp_val.*;
            defer cp.deinit(alloc);
            break :blk std.fmt.parseInt(u64, cp.since, 10) catch 0;
        }
        break :blk 0;
    };

    const start_text = try std.fmt.allocPrint(alloc, "{d}", .{since});
    errdefer alloc.free(start_text);

    while (true) {
        var rows: std.ArrayListUnmanaged(LocalRow) = .empty;
        defer {
            for (rows.items) |row| row.deinit(alloc);
            rows.deinit(alloc);
        }
        var docs_in_page: usize = 0;
        // The last sequence of the page *before* `doc_ids` filtering: a page
        // that holds no selected document must still advance past itself.
        var page_max = since;
        {
            opts_source_guard.enter();
            defer opts_source_guard.leave();
            var page: std.ArrayListUnmanaged(*Doc) = .empty;
            defer page.deinit(alloc);
            var it = source.docs.valueIterator();
            while (it.next()) |entry| {
                const doc = entry.*;
                if (doc.seq > since) try page.append(alloc, doc);
            }
            std.mem.sort(*Doc, page.items, {}, struct {
                fn lessThan(_: void, a: *Doc, b: *Doc) bool {
                    return a.seq < b.seq;
                }
            }.lessThan);
            if (page.items.len > opts.page_size) page.shrinkRetainingCapacity(opts.page_size);
            docs_in_page = page.items.len;
            for (page.items) |doc| {
                if (doc.seq > page_max) page_max = doc.seq;
            }
            for (page.items) |doc| {
                if (opts.doc_ids) |set| {
                    if (!set.contains(doc.id)) continue;
                }
                for (doc.leaves.items) |leaf| {
                    const id_copy = try alloc.dupe(u8, doc.id);
                    errdefer alloc.free(id_copy);
                    const body_copy = try alloc.dupe(u8, leaf.body);
                    errdefer alloc.free(body_copy);
                    const anc_copy = try alloc.dupe(Rev, leaf.ancestry);
                    errdefer alloc.free(anc_copy);
                    try rows.append(alloc, .{
                        .id = id_copy,
                        .seq = doc.seq,
                        .rev = leaf.rev,
                        .ancestry = anc_copy,
                        .body = body_copy,
                        .deleted = leaf.deleted,
                    });
                }
            }
        }
        if (docs_in_page == 0) break;

        for (rows.items) |row| {
            result.changes_seen += 1;
            guard.enter();
            defer guard.leave();
            var have = false;
            if (target.docs.get(row.id)) |known| {
                have = known.findLeaf(row.rev) != null or
                    known.findDescendantOf(row.rev) != null or
                    known.retainedFor(row.rev) != null;
            }
            if (have) continue;
            if (!row.deleted) try copyAttachmentBlobs(alloc, source, target, row.body);
            _ = try target.putImportedBatch(row.id, row.rev, row.ancestry, row.body, row.deleted);
            result.documents += 1;
        }

        {
            guard.enter();
            defer guard.leave();
            const seq_text = try std.fmt.allocPrint(alloc, "{d}", .{page_max});
            defer alloc.free(seq_text);
            if (opts.use_checkpoints) try saveLocalCheckpointDoc(alloc, target, cp_id, &session_id, seq_text, &.{});
        }
        since = page_max;
        if (opts.on_progress) |f| f(opts.progress_ctx, .{ .documents = result.documents, .changes = result.changes_seen });
        if (docs_in_page < opts.page_size) break;
    }
    result.start_seq = start_text;
    result.end_seq = try std.fmt.allocPrint(alloc, "{d}", .{since});
    return result;
}

pub fn pullInto(alloc: std.mem.Allocator, io: std.Io, db: *Db, opts: Options) !Result {
    const source = trimSlash(opts.source);
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var session = try AuthSession.init(alloc, source, opts.username, opts.password, opts.headers);
    defer session.deinit();
    if (opts.use_session_auth and session.username != null) {
        _ = session.loginSession(&client);
    }

    const cp_target: []const u8 = opts.checkpoint_target orelse if (opts.target_path.len > 0) opts.target_path else &db.uuid;
    const cp_id = try checkpointId(alloc, .{
        .source = source,
        .target = cp_target,
        .filter = opts.filter,
        .doc_ids = opts.doc_ids,
        .selector = opts.selector,
        .since_seq = opts.since,
    });
    defer alloc.free(cp_id);
    const legacy_cp_id = try legacyCheckpointId(alloc, source, opts.filter);
    defer alloc.free(legacy_cp_id);
    const session_id = generateSessionId(io);
    const guard: Guard = .{ .lock = opts.lock, .unlock = opts.unlock, .ctx = opts.lock_ctx };
    var result = Result{};

    var remote_rev: ?[]u8 = null;
    defer if (remote_rev) |r| alloc.free(r);
    var history: std.ArrayListUnmanaged(CheckpointHistoryEntry) = .empty;
    defer {
        for (history.items) |h| {
            alloc.free(h.session_id);
            alloc.free(h.recorded_seq);
        }
        history.deinit(alloc);
    }

    var since: []u8 = blk: {
        if (opts.since) |forced| break :blk try alloc.dupe(u8, forced);
        if (!opts.use_checkpoints) break :blk try alloc.dupe(u8, "0");

        var local_cp: ?CheckpointDoc = local_blk: {
            guard.enter();
            defer guard.leave();
            break :local_blk readLocalCheckpointDoc(alloc, db, cp_id, legacy_cp_id);
        };
        defer if (local_cp) |*cp| cp.deinit(alloc);

        var remote_cp: ?CheckpointDoc = readRemoteCheckpointDoc(alloc, &client, source, &session, cp_id);
        defer if (remote_cp) |*cp| cp.deinit(alloc);
        if (remote_cp) |*rcp| {
            if (rcp.rev) |r| remote_rev = try alloc.dupe(u8, r);
        }
        if (local_cp) |*lcp| {
            for (lcp.history.items) |h| {
                const h_sid = try alloc.dupe(u8, h.session_id);
                errdefer alloc.free(h_sid);
                const h_seq = try alloc.dupe(u8, h.recorded_seq);
                try history.append(alloc, .{ .session_id = h_sid, .recorded_seq = h_seq });
            }
        }
        break :blk try resolveResumeSeq(
            alloc,
            if (remote_cp) |*rcp| rcp else null,
            if (local_cp) |*lcp| lcp else null,
        );
    };
    defer alloc.free(since);
    const start_text = try alloc.dupe(u8, since);
    errdefer alloc.free(start_text);

    while (true) {
        const filter_suffix = if (opts.filter) |f| blk: {
            const encoded = try urlEncode(alloc, f);
            defer alloc.free(encoded);
            break :blk try std.fmt.allocPrint(alloc, "&filter={s}", .{encoded});
        } else try alloc.dupe(u8, "");
        defer alloc.free(filter_suffix);
        const filter_param = if (opts.selector != null) "&filter=_selector" else filter_suffix;
        const changes_url = try std.fmt.allocPrint(
            alloc,
            "{s}/_changes?since={s}&style=all_docs&limit={d}{s}",
            .{ source, since, opts.page_size, filter_param },
        );
        defer alloc.free(changes_url);
        const changes_body = if (opts.selector) |sel| blk: {
            const body = try std.fmt.allocPrint(alloc, "{{\"selector\":{s}}}", .{sel});
            defer alloc.free(body);
            break :blk try httpPost(&client, alloc, changes_url, &session, body, opts.diag);
        } else try httpGet(&client, alloc, changes_url, &session, opts.diag);
        defer alloc.free(changes_body);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, changes_body, .{}) catch return error.InvalidSourceResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSourceResponse;
        const results_v = parsed.value.object.get("results") orelse return error.InvalidSourceResponse;
        if (results_v != .array) return error.InvalidSourceResponse;
        const rows = results_v.array.items;

        var pending: std.ArrayListUnmanaged(PendingDoc) = .empty;
        defer pending.deinit(alloc);
        for (rows) |row| {
            if (row != .object) return error.InvalidSourceResponse;
            const id_v = row.object.get("id") orelse return error.InvalidSourceResponse;
            if (id_v != .string) return error.InvalidSourceResponse;
            const changes_v = row.object.get("changes") orelse return error.InvalidSourceResponse;
            if (changes_v != .array) return error.InvalidSourceResponse;
            if (opts.doc_ids) |set| {
                if (!set.contains(id_v.string)) continue;
            }
            result.changes_seen += changes_v.array.items.len;
            for (changes_v.array.items) |change| {
                if (change != .object) return error.InvalidSourceResponse;
                const rev_v = change.object.get("rev") orelse return error.InvalidSourceResponse;
                if (rev_v != .string) return error.InvalidSourceResponse;
                const rev = Rev.parse(rev_v.string) catch {
                    result.doc_write_failures += 1;
                    continue;
                };
                // Skip a revision the database already holds, which is what
                // CouchDB's `_revs_diff` pre-pass saves: without it every
                // re-run fetched and re-imported every changed document.
                var have = false;
                {
                    guard.enter();
                    defer guard.leave();
                    if (db.docs.get(id_v.string)) |known| {
                        have = known.findLeaf(rev) != null or
                            known.findDescendantOf(rev) != null or
                            known.retainedFor(rev) != null;
                    }
                }
                if (have) continue;
                try pending.append(alloc, .{ .id = id_v.string, .rev = rev, .rev_text = rev_v.string });
            }
        }
        try fetchPending(alloc, &client, source, &session, db, pending.items, opts, guard, &result);
        const last_seq_v = parsed.value.object.get("last_seq") orelse break;
        const next_since = try lastSeqString(alloc, last_seq_v);
        alloc.free(since);
        since = next_since;
        // The checkpoint is durable in locals.log; the document WAL must be
        // durable before it, or a power cut resumes past missing documents.
        {
            guard.enter();
            defer guard.leave();
            try db.syncWal();
            if (opts.use_checkpoints) try saveLocalCheckpointDoc(alloc, db, cp_id, &session_id, since, history.items);
        }
        if (opts.use_checkpoints) {
            writeRemoteCheckpointDoc(alloc, &client, source, &session, cp_id, &session_id, since, history.items, &remote_rev) catch {};
        }
        if (opts.on_progress) |report| {
            report(opts.progress_ctx, .{ .documents = result.documents, .changes = result.changes_seen });
        }
        if (rows.len < opts.page_size) break;
    }

    guard.enter();
    defer guard.leave();
    try db.syncWal();
    result.start_seq = start_text;
    result.end_seq = try alloc.dupe(u8, since);
    return result;
}

const PendingDoc = struct { id: []const u8, rev: Rev, rev_text: []const u8 };

/// Fetch the revisions the destination lacks through `_bulk_get`, a page at a
/// time, instead of one GET per revision. `_bulk_get` is also what CouchDB
/// itself uses, and its two counters are what `_scheduler/docs` reports.
fn fetchPending(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    source: []const u8,
    session: ?*AuthSession,
    db: *Db,
    pending: []const PendingDoc,
    opts: Options,
    guard: Guard,
    result: *Result,
) !void {
    var offset: usize = 0;
    var bulk_supported = true;
    while (offset < pending.len) {
        const end = @min(offset + opts.page_size, pending.len);
        const batch = pending[offset..end];
        if (!bulk_supported) {
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        }
        var req: std.ArrayListUnmanaged(u8) = .empty;
        defer req.deinit(alloc);
        try req.appendSlice(alloc, "{\"docs\":[");
        for (batch, 0..) |p, i| {
            if (i > 0) try req.append(alloc, ',');
            try req.appendSlice(alloc, "{\"id\":");
            try jsonw.writeString(&req, alloc, p.id);
            try req.appendSlice(alloc, ",\"rev\":");
            try jsonw.writeString(&req, alloc, p.rev_text);
            try req.append(alloc, '}');
        }
        try req.appendSlice(alloc, "]}");
        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/_bulk_get?revs=true&attachments=false&att_encoding_info=true",
            .{source},
        );
        defer alloc.free(url);
        // A source without `_bulk_get` (an old CouchDB, or a proxy in front of
        // one) is not a reason to fail the replication: fall back to one GET
        // per revision and stay on that path for the rest of the run.
        const body = httpPost(client, alloc, url, session, req.items, opts.diag) catch {
            bulk_supported = false;
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        };
        defer alloc.free(body);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
            bulk_supported = false;
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            bulk_supported = false;
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        }
        const results_v = parsed.value.object.get("results") orelse {
            bulk_supported = false;
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        };
        if (results_v != .array) {
            bulk_supported = false;
            try fetchIndividually(alloc, client, source, session, db, batch, opts, guard, result);
            offset = end;
            continue;
        }
        result.bulk_get_attempts += 1;
        for (results_v.array.items) |entry| {
            if (entry != .object) continue;
            const docs_v = entry.object.get("docs") orelse continue;
            if (docs_v != .array) continue;
            const entry_id = if (entry.object.get("id")) |idv|
                (if (idv == .string) idv.string else "")
            else
                "";
            for (docs_v.array.items) |item| {
                if (item != .object) continue;
                // A revision the source does not have comes back as `error`
                // instead of `ok`; the caller's diagnostics already record what
                // the changes feed promised, so it is skipped here.
                const ok = item.object.get("ok") orelse continue;
                if (ok != .object) continue;
                result.bulk_get_docs += 1;
                var text: std.ArrayListUnmanaged(u8) = .empty;
                defer text.deinit(alloc);
                try jsonw.writeValue(&text, alloc, ok);
                const id_text = if (ok.object.get("_id")) |v|
                    (if (v == .string) v.string else entry_id)
                else
                    entry_id;
                const rev_text = if (ok.object.get("_rev")) |v|
                    (if (v == .string) v.string else "")
                else
                    "";
                const rev = Rev.parse(rev_text) catch {
                    result.doc_write_failures += 1;
                    continue;
                };
                try importFetchedDoc(alloc, client, source, session, db, id_text, rev, text.items, opts.max_attachment_bytes, opts.diag, guard);
                result.documents += 1;
            }
        }
        offset = end;
    }
}

/// One GET per revision, for a source that has no `_bulk_get`.
fn fetchIndividually(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    source: []const u8,
    session: ?*AuthSession,
    db: *Db,
    batch: []const PendingDoc,
    opts: Options,
    guard: Guard,
    result: *Result,
) !void {
    for (batch) |p| {
        const enc_id = try urlEncode(alloc, p.id);
        defer alloc.free(enc_id);
        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}?rev={s}&revs=true&attachments=false&att_encoding_info=true",
            .{ source, enc_id, p.rev_text },
        );
        defer alloc.free(url);
        const body = try httpGet(client, alloc, url, session, opts.diag);
        defer alloc.free(body);
        try importFetchedDoc(alloc, client, source, session, db, p.id, p.rev, body, opts.max_attachment_bytes, opts.diag, guard);
        result.documents += 1;
    }
}

/// Store one document the source handed back: its revision ancestry, its
/// attachments (fetched and written to blobs) and the body itself.
fn importFetchedDoc(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    source: []const u8,
    session: ?*AuthSession,
    db: *Db,
    id: []const u8,
    rev: Rev,
    doc_body: []const u8,
    max_att_bytes: usize,
    diag: ?*Diag,
    guard: Guard,
) !void {
    var doc_parsed = std.json.parseFromSlice(std.json.Value, alloc, doc_body, .{}) catch return error.InvalidSourceResponse;
    defer doc_parsed.deinit();
    if (doc_parsed.value != .object) return error.InvalidSourceResponse;
    const doc = doc_parsed.value.object;
    var ancestry: std.ArrayListUnmanaged(Rev) = .empty;
    defer ancestry.deinit(alloc);
    if (doc.get("_revisions")) |revs| {
        if (revs == .object) {
            const start = revs.object.get("start");
            const ids = revs.object.get("ids");
            if (start != null and ids != null and start.? == .integer and ids.? == .array) {
                const start_gen = std.math.cast(u32, start.?.integer) orelse return error.InvalidSourceResponse;
                for (ids.?.array.items, 0..) |rid, i| {
                    if (rid != .string) continue;
                    const idx_u32 = std.math.cast(u32, i) orelse return error.InvalidSourceResponse;
                    const g = start_gen -| idx_u32;
                    const ar = revFromParts(g, rid.string) catch continue;
                    try ancestry.append(alloc, ar);
                }
            }
        }
    }
    if (ancestry.items.len == 0) try ancestry.append(alloc, rev);
    const deleted = if (doc.get("_deleted")) |d| (d == .bool and d.bool) else false;
    var body_arena = std.heap.ArenaAllocator.init(alloc);
    defer body_arena.deinit();
    var revbuf: [64]u8 = undefined;
    const rev_text = rev.write(&revbuf);
    const enc_id = try urlEncode(alloc, id);
    defer alloc.free(enc_id);
    const stored = externalizeAttachments(db, body_arena.allocator(), client, source, session, enc_id, rev_text, doc_body, max_att_bytes, diag, guard) catch |e| {
        if (diag) |d| d.set("attachment on {s} rev {s}: {s}", .{ id, rev_text, @errorName(e) });
        return e;
    };
    {
        guard.enter();
        defer guard.leave();
        _ = try db.putImportedBatch(id, rev, ancestry.items, stored, deleted);
    }
}

fn gzipDecode(alloc: std.mem.Allocator, data: []const u8, max_bytes: usize) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var win_buf: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .gzip, &win_buf);
    var l_buf: [4096]u8 = undefined;
    var limited = decompress.reader.limited(.limited(max_bytes +| 1), &l_buf);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const written = limited.interface.streamRemaining(&out.writer) catch return error.InvalidGzip;
    if (written > max_bytes) return error.TooLarge;
    return out.toOwnedSlice();
}

fn inlineAttachments(db: *Db, alloc: std.mem.Allocator, doc: *std.json.Value) !void {
    if (doc.* != .object) return;
    const atts_v = doc.object.get("_attachments") orelse return;
    if (atts_v != .object) return;
    var out: std.json.ObjectMap = .empty;
    const keys = atts_v.object.keys();
    const vals = atts_v.object.values();
    for (keys, vals) |name, entry| {
        if (entry != .object) continue;
        var raw: ?[]u8 = null;
        if (entry.object.get("data")) |data_v| {
            if (data_v == .string) {
                const n = std.base64.standard.Decoder.calcSizeForSlice(data_v.string) catch 0;
                if (n > 0) {
                    const bytes = try alloc.alloc(u8, n);
                    std.base64.standard.Decoder.decode(bytes, data_v.string) catch {
                        alloc.free(bytes);
                        continue;
                    };
                    raw = bytes;
                }
            }
        }
        if (raw == null) {
            if (entry.object.get("blob")) |blob_v| {
                if (blob_v == .string) raw = db.readBlob(alloc, blob_v.string) catch null;
            }
        }
        var bytes = raw orelse {
            try out.put(alloc, name, entry);
            continue;
        };
        if (entry.object.get("encoding")) |enc| {
            if (enc == .string and std.mem.eql(u8, enc.string, "gzip")) {
                const decoded = gzipDecode(alloc, bytes, db.max_blob_bytes) catch |e| {
                    alloc.free(bytes);
                    if (e == error.TooLarge) return e;
                    try out.put(alloc, name, entry);
                    continue;
                };
                alloc.free(bytes);
                bytes = decoded;
            }
        }
        defer alloc.free(bytes);
        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        var item: std.json.ObjectMap = .empty;
        if (entry.object.get("content_type")) |ct| try item.put(alloc, "content_type", ct);
        if (entry.object.get("revpos")) |rp| try item.put(alloc, "revpos", rp);
        try item.put(alloc, "data", .{ .string = encoded });
        try out.put(alloc, name, .{ .object = item });
    }
    try doc.object.put(alloc, "_attachments", .{ .object = out });
}

pub const PushResult = struct {
    checked: usize = 0,
    pushed: usize = 0,
    failed: usize = 0,
    /// The local update_seq after the push, which is the only sequence a push
    /// has; the caller owns it.
    end_seq: ?[]u8 = null,
};

pub const PushOptions = struct {
    target: []const u8,
    local_path: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    diag: ?*Diag = null,
    use_checkpoints: bool = true,
    worker_batch_size: usize = 1000,
    since: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    use_session_auth: bool = false,
};

pub const PushIntoOptions = struct {
    target: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    diag: ?*Diag = null,
    guard: Guard = .{},
    doc_ids: ?*const IdFilter = null,
    use_checkpoints: bool = true,
    worker_batch_size: usize = 1000,
    since: ?[]const u8 = null,
    source_name: []const u8 = "local",
    headers: []const std.http.Header = &.{},
    use_session_auth: bool = false,
};

pub fn push(alloc: std.mem.Allocator, io: std.Io, opts: PushOptions) !PushResult {
    const db = try Db.open(alloc, io, opts.local_path);
    defer db.close();
    return pushIntoWithOptions(alloc, io, db, .{
        .target = opts.target,
        .username = opts.username,
        .password = opts.password,
        .diag = opts.diag,
        .use_checkpoints = opts.use_checkpoints,
        .worker_batch_size = opts.worker_batch_size,
        .since = opts.since,
        .headers = opts.headers,
        .use_session_auth = opts.use_session_auth,
    });
}

pub fn pushInto(
    alloc: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    target_raw: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    diag: ?*Diag,
    guard: Guard,
    doc_ids: ?*const IdFilter,
) !PushResult {
    return pushIntoWithOptions(alloc, io, db, .{
        .target = target_raw,
        .username = username,
        .password = password,
        .diag = diag,
        .guard = guard,
        .doc_ids = doc_ids,
    });
}

fn hasNonEmptyAttachments(doc_val: std.json.Value) bool {
    if (doc_val != .object) return false;
    const atts = doc_val.object.get("_attachments") orelse return false;
    return atts == .object and atts.object.count() > 0;
}

const MultipartPayload = struct {
    content_type: []u8,
    body: []u8,

    fn deinit(self: *MultipartPayload, alloc: std.mem.Allocator) void {
        alloc.free(self.content_type);
        alloc.free(self.body);
    }
};

fn appendMimeHeaderSafe(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: []const u8,
    quoted: bool,
) !void {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) continue;
        if (quoted and (c == '"' or c == '\\')) {
            try out.append(alloc, '\\');
        }
        try out.append(alloc, c);
    }
}

fn buildMultipartRelatedDoc(
    db: *Db,
    alloc: std.mem.Allocator,
    json_alloc: std.mem.Allocator,
    io: std.Io,
    doc: *std.json.Value,
) !MultipartPayload {
    var rnd: [12]u8 = undefined;
    io.random(&rnd);
    const boundary = std.fmt.bytesToHex(rnd, .lower);

    const AttPart = struct {
        name: []const u8,
        content_type: []const u8,
        bytes: []u8,
    };
    var parts: std.ArrayListUnmanaged(AttPart) = .empty;
    defer {
        for (parts.items) |p| alloc.free(p.bytes);
        parts.deinit(alloc);
    }

    const atts_v = doc.object.get("_attachments").?;
    var stub_atts: std.json.ObjectMap = .empty;
    const keys = atts_v.object.keys();
    const vals = atts_v.object.values();
    for (keys, vals) |name, entry| {
        if (entry != .object) continue;
        var raw: ?[]u8 = null;
        if (entry.object.get("data")) |data_v| {
            if (data_v == .string) {
                const n = std.base64.standard.Decoder.calcSizeForSlice(data_v.string) catch 0;
                if (n > 0) {
                    const bytes = try alloc.alloc(u8, n);
                    std.base64.standard.Decoder.decode(bytes, data_v.string) catch {
                        alloc.free(bytes);
                        continue;
                    };
                    raw = bytes;
                }
            }
        }
        if (raw == null) {
            if (entry.object.get("blob")) |blob_v| {
                if (blob_v == .string) raw = db.readBlob(alloc, blob_v.string) catch null;
            }
        }
        var bytes = raw orelse {
            try stub_atts.put(json_alloc, name, entry);
            continue;
        };
        if (entry.object.get("encoding")) |enc| {
            if (enc == .string and std.mem.eql(u8, enc.string, "gzip")) {
                const decoded = gzipDecode(alloc, bytes, db.max_blob_bytes) catch |e| {
                    alloc.free(bytes);
                    if (e == error.TooLarge) return e;
                    try stub_atts.put(json_alloc, name, entry);
                    continue;
                };
                alloc.free(bytes);
                bytes = decoded;
            }
        }

        const ct: []const u8 = if (entry.object.get("content_type")) |ct_v|
            (if (ct_v == .string) ct_v.string else "application/octet-stream")
        else
            "application/octet-stream";

        var item: std.json.ObjectMap = .empty;
        try item.put(json_alloc, "content_type", .{ .string = ct });
        if (entry.object.get("revpos")) |rp| try item.put(json_alloc, "revpos", rp);
        try item.put(json_alloc, "length", .{ .integer = @intCast(bytes.len) });
        try item.put(json_alloc, "follows", .{ .bool = true });
        try stub_atts.put(json_alloc, name, .{ .object = item });
        try parts.append(alloc, .{ .name = name, .content_type = ct, .bytes = bytes });
    }
    try doc.object.put(json_alloc, "_attachments", .{ .object = stub_atts });

    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(alloc);
    try body.appendSlice(alloc, "--");
    try body.appendSlice(alloc, &boundary);
    try body.appendSlice(alloc, "\r\nContent-Type: application/json\r\n\r\n");
    try jsonw.writeValue(&body, alloc, doc.*);
    try body.appendSlice(alloc, "\r\n");

    for (parts.items) |p| {
        try body.appendSlice(alloc, "--");
        try body.appendSlice(alloc, &boundary);
        try body.appendSlice(alloc, "\r\nContent-Disposition: attachment; filename=\"");
        try appendMimeHeaderSafe(&body, alloc, p.name, true);
        try body.appendSlice(alloc, "\"\r\nContent-Type: ");
        try appendMimeHeaderSafe(&body, alloc, p.content_type, false);
        const len_line = try std.fmt.allocPrint(alloc, "\r\nContent-Length: {d}\r\n\r\n", .{p.bytes.len});
        defer alloc.free(len_line);
        try body.appendSlice(alloc, len_line);
        try body.appendSlice(alloc, p.bytes);
        try body.appendSlice(alloc, "\r\n");
    }
    try body.appendSlice(alloc, "--");
    try body.appendSlice(alloc, &boundary);
    try body.appendSlice(alloc, "--\r\n");

    const ct_header = try std.fmt.allocPrint(alloc, "multipart/related; boundary=\"{s}\"", .{boundary});
    errdefer alloc.free(ct_header);
    return .{ .content_type = ct_header, .body = try body.toOwnedSlice(alloc) };
}

fn putMultipartDoc(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    target: []const u8,
    session: ?*AuthSession,
    doc_id: []const u8,
    payload: MultipartPayload,
    diag: ?*Diag,
    result: *PushResult,
) !void {
    const enc_id = try urlEncode(alloc, doc_id);
    defer alloc.free(enc_id);
    const url = try std.fmt.allocPrint(alloc, "{s}/{s}?new_edits=false", .{ target, enc_id });
    defer alloc.free(url);
    const resp = httpRequestSession(client, alloc, .PUT, url, session, payload.body, payload.content_type, diag) catch |e| {
        if (e == error.SourceHttpError and diag != null and diag.?.status >= 400 and diag.?.status < 500) {
            result.failed += 1;
            return;
        }
        return e;
    };
    alloc.free(resp);
    result.pushed += 1;
}

pub fn pushIntoWithOptions(
    alloc: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    opts: PushIntoOptions,
) !PushResult {
    const target = trimSlash(opts.target);
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var session = try AuthSession.init(alloc, target, opts.username, opts.password, opts.headers);
    defer session.deinit();
    if (opts.use_session_auth and session.username != null) {
        _ = session.loginSession(&client);
    }

    const guard = opts.guard;
    const batch_size: usize = @max(opts.worker_batch_size, 1);
    const src_key = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ opts.source_name, &db.uuid });
    defer alloc.free(src_key);
    const cp_id = try checkpointId(alloc, .{
        .source = src_key,
        .target = target,
        .doc_ids = opts.doc_ids,
        .since_seq = opts.since,
    });
    defer alloc.free(cp_id);
    const legacy_cp_id = try legacyCheckpointId(alloc, opts.source_name, null);
    defer alloc.free(legacy_cp_id);
    const session_id = generateSessionId(io);

    var remote_rev: ?[]u8 = null;
    defer if (remote_rev) |r| alloc.free(r);
    var history: std.ArrayListUnmanaged(CheckpointHistoryEntry) = .empty;
    defer {
        for (history.items) |h| {
            alloc.free(h.session_id);
            alloc.free(h.recorded_seq);
        }
        history.deinit(alloc);
    }

    var since: u64 = blk: {
        if (opts.since) |forced| break :blk std.fmt.parseInt(u64, forced, 10) catch 0;
        if (!opts.use_checkpoints) break :blk 0;

        var local_cp: ?CheckpointDoc = local_blk: {
            guard.enter();
            defer guard.leave();
            break :local_blk readLocalCheckpointDoc(alloc, db, cp_id, legacy_cp_id);
        };
        defer if (local_cp) |*cp| cp.deinit(alloc);

        var remote_cp: ?CheckpointDoc = readRemoteCheckpointDoc(alloc, &client, target, &session, cp_id);
        defer if (remote_cp) |*cp| cp.deinit(alloc);
        if (remote_cp) |*rcp| {
            if (rcp.rev) |r| remote_rev = try alloc.dupe(u8, r);
        }
        if (local_cp) |*lcp| {
            for (lcp.history.items) |h| {
                const h_sid = try alloc.dupe(u8, h.session_id);
                errdefer alloc.free(h_sid);
                const h_seq = try alloc.dupe(u8, h.recorded_seq);
                try history.append(alloc, .{ .session_id = h_sid, .recorded_seq = h_seq });
            }
        }
        const resolved = try resolveResumeSeq(
            alloc,
            if (local_cp) |*lcp| lcp else null,
            if (remote_cp) |*rcp| rcp else null,
        );
        defer alloc.free(resolved);
        break :blk std.fmt.parseInt(u64, resolved, 10) catch 0;
    };

    var result = PushResult{};
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var docs: std.json.Array = std.json.Array.init(alloc);
    defer docs.deinit();

    while (true) {
        var diff: std.ArrayListUnmanaged(u8) = .empty;
        defer diff.deinit(alloc);
        var docs_in_page: usize = 0;
        var page_max_seq: u64 = since;
        var page_checked: usize = 0;

        {
            // Collect one seq-ordered page of docs with seq > since under the lock.
            guard.enter();
            defer guard.leave();
            var page: std.ArrayListUnmanaged(*Doc) = .empty;
            defer page.deinit(alloc);
            var it = db.docs.valueIterator();
            while (it.next()) |entry| {
                const doc = entry.*;
                if (doc.seq <= since) continue;
                if (opts.doc_ids) |set| {
                    if (!set.contains(doc.id)) continue;
                }
                try page.append(alloc, doc);
            }
            std.mem.sort(*Doc, page.items, {}, struct {
                fn lessThan(_: void, a: *Doc, b: *Doc) bool {
                    return a.seq < b.seq;
                }
            }.lessThan);
            if (page.items.len > batch_size) page.shrinkRetainingCapacity(batch_size);
            docs_in_page = page.items.len;

            if (docs_in_page > 0) {
                try diff.append(alloc, '{');
                for (page.items, 0..) |doc, doc_idx| {
                    if (doc.seq > page_max_seq) page_max_seq = doc.seq;
                    if (doc_idx > 0) try diff.append(alloc, ',');
                    try jsonw.writeString(&diff, alloc, doc.id);
                    try diff.append(alloc, ':');
                    try diff.append(alloc, '[');
                    for (doc.leaves.items, 0..) |leaf, i| {
                        if (i > 0) try diff.append(alloc, ',');
                        var revbuf: [64]u8 = undefined;
                        try jsonw.writeString(&diff, alloc, leaf.rev.write(&revbuf));
                        page_checked += 1;
                    }
                    try diff.append(alloc, ']');
                }
                try diff.append(alloc, '}');
            }
        }
        result.checked += page_checked;
        if (docs_in_page == 0) break;

        if (page_checked > 0) {
            const diff_url = try std.fmt.allocPrint(alloc, "{s}/_revs_diff", .{target});
            defer alloc.free(diff_url);
            const diff_body = try httpPost(&client, alloc, diff_url, &session, diff.items, opts.diag);
            defer alloc.free(diff_body);
            var diff_parsed = std.json.parseFromSlice(std.json.Value, alloc, diff_body, .{}) catch return error.InvalidSourceResponse;
            defer diff_parsed.deinit();
            if (diff_parsed.value != .object) return error.InvalidSourceResponse;

            var locked = false;
            {
                // Reading the local bodies and blobs again needs the lock; everything it
                // produces is copied into `arena`, so an upload can run without it.
                guard.enter();
                locked = true;
                defer if (locked) guard.leave();
                var mit = diff_parsed.value.object.iterator();
                while (mit.next()) |me| {
                    const id = me.key_ptr.*;
                    const entry = me.value_ptr.*;
                    if (entry != .object) continue;
                    const missing = entry.object.get("missing") orelse continue;
                    if (missing != .array) continue;
                    const doc = db.docs.get(id) orelse continue;
                    for (missing.array.items) |rev_v| {
                        if (rev_v != .string) continue;
                        const rev = Rev.parse(rev_v.string) catch return error.InvalidTargetResponse;
                        const idx = doc.findLeaf(rev) orelse return error.MissingLocalRevision;
                        const leaf = doc.leaves.items[idx];
                        var doc_parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), leaf.body, .{}) catch return error.InvalidLocalDocument;
                        if (doc_parsed.value != .object) return error.InvalidLocalDocument;
                        var revbuf: [64]u8 = undefined;
                        const rev_text = rev.write(&revbuf);
                        try doc_parsed.value.object.put(arena.allocator(), "_id", .{ .string = try arena.allocator().dupe(u8, id) });
                        try doc_parsed.value.object.put(arena.allocator(), "_rev", .{ .string = try arena.allocator().dupe(u8, rev_text) });
                        var ids: std.json.Array = std.json.Array.init(arena.allocator());
                        for (leaf.ancestry) |anc| {
                            var buf: [64]u8 = undefined;
                            const s = anc.write(&buf);
                            const dash = std.mem.indexOfScalar(u8, s, '-') orelse continue;
                            try ids.append(.{ .string = try arena.allocator().dupe(u8, s[dash + 1 ..]) });
                        }
                        var revisions: std.json.ObjectMap = .empty;
                        try revisions.put(arena.allocator(), "start", .{ .integer = leaf.rev.gen });
                        try revisions.put(arena.allocator(), "ids", .{ .array = ids });
                        try doc_parsed.value.object.put(arena.allocator(), "_revisions", .{ .object = revisions });

                        if (hasNonEmptyAttachments(doc_parsed.value)) {
                            if (docs.items.len > 0) {
                                guard.leave();
                                locked = false;
                                try postBulk(&client, alloc, target, &session, &docs, opts.diag, &result);
                                docs.clearRetainingCapacity();
                                guard.enter();
                                locked = true;
                            }
                            var mp = try buildMultipartRelatedDoc(db, alloc, arena.allocator(), io, &doc_parsed.value);
                            defer mp.deinit(alloc);
                            const id_copy = try alloc.dupe(u8, id);
                            defer alloc.free(id_copy);
                            guard.leave();
                            locked = false;
                            try putMultipartDoc(&client, alloc, target, &session, id_copy, mp, opts.diag, &result);
                            _ = arena.reset(.retain_capacity);
                            guard.enter();
                            locked = true;
                            continue;
                        }

                        try docs.append(doc_parsed.value);
                        if (docs.items.len >= batch_size) {
                            guard.leave();
                            locked = false;
                            try postBulk(&client, alloc, target, &session, &docs, opts.diag, &result);
                            docs.clearRetainingCapacity();
                            _ = arena.reset(.retain_capacity);
                            guard.enter();
                            locked = true;
                        }
                    }
                }
                // The last, partial batch has to be flushed before the block's defer
                // runs; flushing after it would release the lock a second time.
                if (docs.items.len > 0) {
                    guard.leave();
                    locked = false;
                    try postBulk(&client, alloc, target, &session, &docs, opts.diag, &result);
                    docs.clearRetainingCapacity();
                    _ = arena.reset(.retain_capacity);
                }
            }
        }

        since = page_max_seq;
        if (opts.use_checkpoints) {
            const seq_text = try std.fmt.allocPrint(alloc, "{d}", .{since});
            defer alloc.free(seq_text);
            {
                guard.enter();
                defer guard.leave();
                try saveLocalCheckpointDoc(alloc, db, cp_id, &session_id, seq_text, history.items);
            }
            writeRemoteCheckpointDoc(alloc, &client, target, &session, cp_id, &session_id, seq_text, history.items, &remote_rev) catch {};
        }

        if (docs_in_page < batch_size) break;
    }

    {
        guard.enter();
        defer guard.leave();
        result.end_seq = try std.fmt.allocPrint(alloc, "{d}", .{db.seq});
    }
    return result;
}

/// Upload one `_bulk_docs` batch. Split out because the caller sends the
/// database in bounded batches: building one body for a whole database held a
/// copy of every document in memory at once.
fn postBulk(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    target: []const u8,
    session: ?*AuthSession,
    docs: *std.json.Array,
    diag: ?*Diag,
    result: *PushResult,
) !void {
    var bulk: std.ArrayListUnmanaged(u8) = .empty;
    defer bulk.deinit(alloc);
    try bulk.appendSlice(alloc, "{\"docs\":");
    try jsonw.writeValue(&bulk, alloc, .{ .array = docs.* });
    try bulk.appendSlice(alloc, ",\"new_edits\":false}");
    const bulk_url = try std.fmt.allocPrint(alloc, "{s}/_bulk_docs", .{target});
    defer alloc.free(bulk_url);
    const bulk_resp = try httpPost(client, alloc, bulk_url, session, bulk.items, diag);
    defer alloc.free(bulk_resp);

    // A 2xx from _bulk_docs only means the request was accepted. CouchDB
    // reports per-document failures in the response array; treating the
    // status alone as success leaves failed revisions silently missing.
    var bulk_parsed = std.json.parseFromSlice(std.json.Value, alloc, bulk_resp, .{}) catch return error.InvalidTargetResponse;
    defer bulk_parsed.deinit();
    var batch_failed: usize = 0;
    switch (bulk_parsed.value) {
        // CouchDB returns an empty array (or per-doc results) for new_edits=false;
        // Zouch returns only failed entries. Accept any array of per-document
        // result objects, count failures, and keep advancing the checkpoint.
        .array => |arr| {
            for (arr.items) |row| {
                if (row != .object) return error.InvalidTargetResponse;
                if (row.object.get("error") != null) {
                    batch_failed += 1;
                    continue;
                }
                const ok = row.object.get("ok") orelse return error.InvalidTargetResponse;
                if (ok != .bool or !ok.bool) return error.InvalidTargetResponse;
            }
        },
        .object => |obj| {
            if (obj.get("error") == null) return error.InvalidTargetResponse;
            batch_failed = docs.items.len;
        },
        else => return error.InvalidTargetResponse,
    }
    result.failed += batch_failed;
    result.pushed += docs.items.len -| batch_failed;
}

test "replicator URL encoding" {
    const alloc = std.testing.allocator;
    const encoded = try urlEncode(alloc, "a/b c");
    defer alloc.free(encoded);
    try std.testing.expectEqualStrings("a%2Fb%20c", encoded);
}

test "checkpointDocIdFor hashes all replication parameters deterministically" {
    const alloc = std.testing.allocator;
    var ids1: IdFilter = .empty;
    defer ids1.deinit(alloc);
    try ids1.put(alloc, "b", {});
    try ids1.put(alloc, "a", {});

    var ids2: IdFilter = .empty;
    defer ids2.deinit(alloc);
    try ids2.put(alloc, "a", {});
    try ids2.put(alloc, "b", {});

    const cp1 = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp1);

    const cp2 = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids2,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp2);
    try std.testing.expectEqualStrings(cp1, cp2);

    const cp_diff_target = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/other",
        .filter = "app/by_type",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp_diff_target);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_target));

    const cp_diff_since = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "20",
    });
    defer alloc.free(cp_diff_since);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_since));

    var ids3: IdFilter = .empty;
    defer ids3.deinit(alloc);
    try ids3.put(alloc, "a", {});
    try ids3.put(alloc, "c", {});
    const cp_diff_ids = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids3,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp_diff_ids);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_ids));

    const cp_diff_selector = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"task\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp_diff_selector);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_selector));

    const cp_diff_filter = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
        .filter = "app/other",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp_diff_filter);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_filter));

    const cp_diff_source = try checkpointDocIdFor(alloc, .{
        .source = "http://src/other",
        .target = "http://dst/db",
        .filter = "app/by_type",
        .doc_ids = &ids1,
        .selector = "{\"type\":\"note\"}",
        .since_seq = "10",
    });
    defer alloc.free(cp_diff_source);
    try std.testing.expect(!std.mem.eql(u8, cp1, cp_diff_source));
}

const MockPushState = struct {
    revs_diff_calls: std.atomic.Value(usize) = .init(0),
    bulk_docs_calls: std.atomic.Value(usize) = .init(0),
    multipart_puts: std.atomic.Value(usize) = .init(0),
    session_logins: std.atomic.Value(usize) = .init(0),
    seen_custom_header: std.atomic.Value(bool) = .init(false),
    require_session_cookie: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    server: std.Io.net.Server,
    alloc: std.mem.Allocator,
    checkpoint_body: ?[]u8 = null,
    last_multipart_ct: ?[]u8 = null,
    last_multipart_body: ?[]u8 = null,
    mutex: std.Io.Mutex = .init,

    fn deinit(self: *MockPushState) void {
        if (self.checkpoint_body) |s| self.alloc.free(s);
        if (self.last_multipart_ct) |s| self.alloc.free(s);
        if (self.last_multipart_body) |s| self.alloc.free(s);
    }
};

fn mockPushServerLoop(state: *MockPushState) void {
    while (!state.stop.load(.acquire)) {
        var stream = state.server.accept(state.io) catch break;
        defer stream.close(state.io);
        if (state.stop.load(.acquire)) break;

        var read_buf: [8192]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = stream.reader(state.io, &read_buf);
        var sw = stream.writer(state.io, &write_buf);
        var http_server = std.http.Server.init(&sr.interface, &sw.interface);

        var req = http_server.receiveHead() catch break;
        const target = req.head.target;
        const method = req.head.method;

        var has_cookie = false;
        var req_ct: ?[]const u8 = null;
        var hit = req.iterateHeaders();
        while (hit.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "cookie") and std.mem.indexOf(u8, hdr.value, "AuthSession=mockcookie123") != null) {
                has_cookie = true;
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "x-custom-repl") and std.mem.eql(u8, hdr.value, "yes")) {
                state.seen_custom_header.store(true, .release);
            }
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                req_ct = hdr.value;
            }
        }

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(state.alloc);
        var body_buf: [2048]u8 = undefined;
        if (req.head.content_length) |clen| {
            if (clen > 0) {
                if (req.readerExpectContinue(&body_buf)) |r| {
                    var rem: usize = @intCast(clen);
                    while (rem > 0) {
                        const chunk = r.take(@min(rem, 256)) catch break;
                        if (chunk.len == 0) break;
                        body_list.appendSlice(state.alloc, chunk) catch break;
                        rem -= chunk.len;
                    }
                } else |_| {}
            }
        }

        if (std.mem.eql(u8, target, "/_session") and method == .POST) {
            _ = state.session_logins.fetchAdd(1, .acq_rel);
            const hdrs = [_]std.http.Header{
                .{ .name = "set-cookie", .value = "AuthSession=mockcookie123; Version=1; Path=/; HttpOnly" },
            };
            req.respond("{\"ok\":true,\"name\":\"alice\",\"roles\":[\"_admin\"]}", .{
                .status = .ok,
                .keep_alive = false,
                .extra_headers = &hdrs,
            }) catch {};
            continue;
        }

        if (state.require_session_cookie and !has_cookie) {
            req.respond("{\"error\":\"unauthorized\"}", .{ .status = .unauthorized, .keep_alive = false }) catch {};
            continue;
        }

        if (std.mem.startsWith(u8, target, "/_local/")) {
            if (method == .GET) {
                state.mutex.lockUncancelable(state.io);
                const cp = if (state.checkpoint_body) |s| state.alloc.dupe(u8, s) catch null else null;
                state.mutex.unlock(state.io);
                if (cp) |json_body| {
                    defer state.alloc.free(json_body);
                    req.respond(json_body, .{ .status = .ok, .keep_alive = false }) catch {};
                } else {
                    req.respond("{\"error\":\"not_found\"}", .{ .status = .not_found, .keep_alive = false }) catch {};
                }
            } else if (method == .PUT) {
                state.mutex.lockUncancelable(state.io);
                if (state.checkpoint_body) |old| state.alloc.free(old);
                state.checkpoint_body = state.alloc.dupe(u8, body_list.items) catch null;
                state.mutex.unlock(state.io);
                req.respond("{\"ok\":true,\"rev\":\"0-1\"}", .{ .status = .created, .keep_alive = false }) catch {};
            } else {
                req.respond("{}", .{ .status = .method_not_allowed, .keep_alive = false }) catch {};
            }
        } else if (std.mem.eql(u8, target, "/_revs_diff")) {
            _ = state.revs_diff_calls.fetchAdd(1, .acq_rel);
            var resp: std.ArrayListUnmanaged(u8) = .empty;
            defer resp.deinit(state.alloc);
            resp.append(state.alloc, '{') catch continue;
            if (std.json.parseFromSlice(std.json.Value, state.alloc, body_list.items, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .object) {
                    var first = true;
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        if (!first) resp.append(state.alloc, ',') catch break;
                        first = false;
                        jsonw.writeString(&resp, state.alloc, entry.key_ptr.*) catch break;
                        resp.appendSlice(state.alloc, ":{\"missing\":") catch break;
                        jsonw.writeValue(&resp, state.alloc, entry.value_ptr.*) catch break;
                        resp.append(state.alloc, '}') catch break;
                    }
                }
            } else |_| {}
            resp.append(state.alloc, '}') catch continue;
            req.respond(resp.items, .{ .status = .ok, .keep_alive = false }) catch {};
        } else if (std.mem.eql(u8, target, "/_bulk_docs")) {
            _ = state.bulk_docs_calls.fetchAdd(1, .acq_rel);
            req.respond("[]", .{ .status = .created, .keep_alive = false }) catch {};
        } else if (method == .PUT and std.mem.indexOf(u8, target, "new_edits=false") != null) {
            _ = state.multipart_puts.fetchAdd(1, .acq_rel);
            state.mutex.lockUncancelable(state.io);
            if (state.last_multipart_ct) |old| state.alloc.free(old);
            if (state.last_multipart_body) |old| state.alloc.free(old);
            state.last_multipart_ct = if (req_ct) |ct| (state.alloc.dupe(u8, ct) catch null) else null;
            state.last_multipart_body = state.alloc.dupe(u8, body_list.items) catch null;
            state.mutex.unlock(state.io);
            req.respond("{\"ok\":true,\"id\":\"attdoc\",\"rev\":\"1-abc\"}", .{ .status = .created, .keep_alive = false }) catch {};
        } else {
            req.respond("{}", .{ .status = .not_found, .keep_alive = false }) catch {};
        }
    }
}

test "pushIntoWithOptions checkpoints and respects worker_batch_size" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db_path = "zig-cache/zouch-repl-push-test";
    std.Io.Dir.cwd().deleteTree(io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, db_path) catch {};

    const db = try Db.open(alloc, io, db_path);
    defer db.close();

    _ = try db.putLocal("doc1", "{\"v\":1}", null, false);
    _ = try db.putLocal("doc2", "{\"v\":2}", null, false);
    _ = try db.putLocal("doc3", "{\"v\":3}", null, false);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const srv = try addr.listen(io, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    var state = MockPushState{
        .io = io,
        .server = srv,
        .alloc = alloc,
    };
    defer state.deinit();

    const thread = try std.Thread.spawn(.{}, mockPushServerLoop, .{&state});
    defer {
        state.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |wake_addr| {
            if (wake_addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        thread.join();
        state.server.deinit(io);
    }

    const target_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(target_url);

    // First push: 3 docs with worker_batch_size=2 -> 2 _revs_diff pages (2 + 1) and 2 _bulk_docs calls.
    const res1 = try pushIntoWithOptions(alloc, io, db, .{
        .target = target_url,
        .worker_batch_size = 2,
        .use_checkpoints = true,
    });
    defer if (res1.end_seq) |s| alloc.free(s);
    try std.testing.expectEqual(@as(usize, 3), res1.checked);
    try std.testing.expectEqual(@as(usize, 3), res1.pushed);
    try std.testing.expectEqual(@as(usize, 0), res1.failed);
    try std.testing.expectEqualStrings("3", res1.end_seq.?);
    try std.testing.expectEqual(@as(usize, 2), state.revs_diff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), state.bulk_docs_calls.load(.acquire));

    // Add 1 more doc and push again: checkpoint should skip docs 1..3 and only check/push doc4.
    _ = try db.putLocal("doc4", "{\"v\":4}", null, false);
    const res2 = try pushIntoWithOptions(alloc, io, db, .{
        .target = target_url,
        .worker_batch_size = 2,
        .use_checkpoints = true,
    });
    defer if (res2.end_seq) |s| alloc.free(s);
    try std.testing.expectEqual(@as(usize, 1), res2.checked);
    try std.testing.expectEqual(@as(usize, 1), res2.pushed);
    try std.testing.expectEqual(@as(usize, 0), res2.failed);
    try std.testing.expectEqualStrings("4", res2.end_seq.?);
    try std.testing.expectEqual(@as(usize, 3), state.revs_diff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), state.bulk_docs_calls.load(.acquire));
}

test "transient HTTP status and error classification" {
    try std.testing.expect(isTransientStatus(429));
    try std.testing.expect(isTransientStatus(500));
    try std.testing.expect(isTransientStatus(503));
    try std.testing.expect(!isTransientStatus(404));
    try std.testing.expect(!isTransientStatus(400));
    try std.testing.expect(!isTransientStatus(200));

    try std.testing.expect(isTransientError(error.ConnectionRefused));
    try std.testing.expect(!isTransientError(error.OutOfMemory));
    try std.testing.expect(!isTransientError(error.SourceHttpError));
}

test "R1: MD5 checkpoint id and session_id/history resume resolution" {
    const alloc = std.testing.allocator;
    const cp_id = try checkpointDocIdFor(alloc, .{
        .source = "http://src/db",
        .target = "http://dst/db",
    });
    defer alloc.free(cp_id);
    try std.testing.expect(std.mem.startsWith(u8, cp_id, "_local/"));
    try std.testing.expectEqual(@as(usize, "_local/".len + 32), cp_id.len);

    // Matching session_id resumes at source_last_seq.
    var s1 = parseCheckpointJson(alloc,
        \\{"session_id":"aaa","source_last_seq":"42","history":[{"session_id":"aaa","recorded_seq":"42"}]}
    , null).?;
    defer s1.deinit(alloc);
    var d1 = parseCheckpointJson(alloc,
        \\{"session_id":"aaa","source_last_seq":"42","history":[{"session_id":"aaa","recorded_seq":"42"}]}
    , null).?;
    defer d1.deinit(alloc);
    const seq_match = try resolveResumeSeq(alloc, &s1, &d1);
    defer alloc.free(seq_match);
    try std.testing.expectEqualStrings("42", seq_match);

    // Mismatched current session_id but shared history entry resumes at common recorded_seq.
    var s2 = parseCheckpointJson(alloc,
        \\{"session_id":"new_s","source_last_seq":"99","history":[{"session_id":"new_s","recorded_seq":"99"},{"session_id":"shared","recorded_seq":"30"}]}
    , null).?;
    defer s2.deinit(alloc);
    var d2 = parseCheckpointJson(alloc,
        \\{"session_id":"other_s","source_last_seq":"50","history":[{"session_id":"other_s","recorded_seq":"50"},{"session_id":"shared","recorded_seq":"30"}]}
    , null).?;
    defer d2.deinit(alloc);
    const seq_hist = try resolveResumeSeq(alloc, &s2, &d2);
    defer alloc.free(seq_hist);
    try std.testing.expectEqualStrings("30", seq_hist);

    // Divergent histories with no common session_id reset to "0".
    var d3 = parseCheckpointJson(alloc,
        \\{"session_id":"unrelated","source_last_seq":"50","history":[{"session_id":"unrelated","recorded_seq":"50"}]}
    , null).?;
    defer d3.deinit(alloc);
    const seq_div = try resolveResumeSeq(alloc, &s2, &d3);
    defer alloc.free(seq_div);
    try std.testing.expectEqualStrings("0", seq_div);
}

test "R2 & R3: pushIntoWithOptions multipart/related attachments and /_session cookie auth" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db_path = "zig-cache/zouch-repl-r2-r3-test";
    std.Io.Dir.cwd().deleteTree(io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, db_path) catch {};

    const db = try Db.open(alloc, io, db_path);
    defer db.close();

    const payload = "hello-multipart-attachment";
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try db.writeBlob(&hex, payload);

    const doc_json = try std.fmt.allocPrint(
        alloc,
        "{{\"_attachments\":{{\"note.txt\":{{\"content_type\":\"text/plain\",\"blob\":\"{s}\",\"length\":{d}}}}}}}",
        .{ hex, payload.len },
    );
    defer alloc.free(doc_json);
    _ = try db.putLocal("attdoc", doc_json, null, false);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const srv = try addr.listen(io, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    var state = MockPushState{
        .io = io,
        .server = srv,
        .alloc = alloc,
        .require_session_cookie = true,
    };
    defer state.deinit();

    const thread = try std.Thread.spawn(.{}, mockPushServerLoop, .{&state});
    defer {
        state.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |wake_addr| {
            if (wake_addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        thread.join();
        state.server.deinit(io);
    }

    const target_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(target_url);

    const custom_hdrs = [_]std.http.Header{
        .{ .name = "x-custom-repl", .value = "yes" },
    };
    const res = try pushIntoWithOptions(alloc, io, db, .{
        .target = target_url,
        .username = "alice",
        .password = "secret",
        .headers = &custom_hdrs,
        .use_checkpoints = true,
    });
    defer if (res.end_seq) |s| alloc.free(s);

    try std.testing.expectEqual(@as(usize, 1), res.checked);
    try std.testing.expectEqual(@as(usize, 1), res.pushed);
    try std.testing.expectEqual(@as(usize, 0), res.failed);
    // Verify /_session login occurred and custom header was carried.
    try std.testing.expectEqual(@as(usize, 1), state.session_logins.load(.acquire));
    try std.testing.expect(state.seen_custom_header.load(.acquire));
    // Verify attachment doc was sent via PUT multipart/related, not _bulk_docs.
    try std.testing.expectEqual(@as(usize, 1), state.multipart_puts.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.bulk_docs_calls.load(.acquire));
    try std.testing.expect(state.last_multipart_ct != null);
    try std.testing.expect(std.mem.startsWith(u8, state.last_multipart_ct.?, "multipart/related; boundary="));
    try std.testing.expect(state.last_multipart_body != null);
    try std.testing.expect(std.mem.indexOf(u8, state.last_multipart_body.?, "\"follows\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.last_multipart_body.?, payload) != null);
    // Verify remote checkpoint doc contains session_id and history.
    try std.testing.expect(state.checkpoint_body != null);
    try std.testing.expect(std.mem.indexOf(u8, state.checkpoint_body.?, "\"session_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.checkpoint_body.?, "\"history\"") != null);
}

const MockPullState = struct {
    stop: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    server: std.Io.net.Server,
    alloc: std.mem.Allocator,
    saw_selector_post: std.atomic.Value(bool) = .init(false),
    saw_since_zero: std.atomic.Value(bool) = .init(false),
    remote_checkpoint: ?[]const u8 = null,
};

fn mockPullServerLoop(state: *MockPullState) void {
    while (!state.stop.load(.acquire)) {
        var stream = state.server.accept(state.io) catch break;
        defer stream.close(state.io);
        if (state.stop.load(.acquire)) break;

        var read_buf: [8192]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = stream.reader(state.io, &read_buf);
        var sw = stream.writer(state.io, &write_buf);
        var http_server = std.http.Server.init(&sr.interface, &sw.interface);

        var req = http_server.receiveHead() catch break;
        const target = req.head.target;
        const method = req.head.method;

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(state.alloc);
        var body_buf: [2048]u8 = undefined;
        if (req.head.content_length) |clen| {
            if (clen > 0) {
                if (req.readerExpectContinue(&body_buf)) |r| {
                    var rem: usize = @intCast(clen);
                    while (rem > 0) {
                        const chunk = r.take(@min(rem, 256)) catch break;
                        if (chunk.len == 0) break;
                        body_list.appendSlice(state.alloc, chunk) catch break;
                        rem -= chunk.len;
                    }
                } else |_| {}
            }
        }

        if (std.mem.startsWith(u8, target, "/_local/")) {
            if (method == .GET) {
                if (state.remote_checkpoint) |cp| {
                    req.respond(cp, .{ .status = .ok, .keep_alive = false }) catch {};
                } else {
                    req.respond("{\"error\":\"not_found\"}", .{ .status = .not_found, .keep_alive = false }) catch {};
                }
            } else if (method == .PUT) {
                req.respond("{\"ok\":true,\"rev\":\"0-1\"}", .{ .status = .created, .keep_alive = false }) catch {};
            } else {
                req.respond("{}", .{ .status = .method_not_allowed, .keep_alive = false }) catch {};
            }
        } else if (std.mem.startsWith(u8, target, "/_changes")) {
            if (std.mem.indexOf(u8, target, "since=0") != null) {
                state.saw_since_zero.store(true, .release);
            }
            if (method == .POST and std.mem.indexOf(u8, target, "filter=_selector") != null and
                std.mem.indexOf(u8, body_list.items, "\"selector\"") != null)
            {
                state.saw_selector_post.store(true, .release);
            }
            const changes_json =
                \\{"results":[
                \\  {"seq":"1","id":"d1","changes":[{"rev":"2-cccccccccccccccccccccccccccccccc"}]},
                \\  {"seq":"2","id":"d2","changes":[{"rev":"1-22222222222222222222222222222222"}]},
                \\  {"seq":"3","id":"d3","changes":[{"rev":"1-33333333333333333333333333333333"}]}
                \\],"last_seq":"3"}
            ;
            req.respond(changes_json, .{ .status = .ok, .keep_alive = false }) catch {};
        } else if (std.mem.startsWith(u8, target, "/_bulk_get")) {
            const bulk_get_json =
                \\{"results":[
                \\  {"id":"d1","docs":[{"ok":{"_id":"d1","_rev":"2-cccccccccccccccccccccccccccccccc","_revisions":{"start":2,"ids":["cccccccccccccccccccccccccccccccc","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]},"v":"remote"}}]},
                \\  {"id":"d3","docs":[{"ok":{"_id":"d3","_rev":"1-33333333333333333333333333333333","_revisions":{"start":1,"ids":["33333333333333333333333333333333"]},"v":"three"}}]}
                \\]}
            ;
            req.respond(bulk_get_json, .{ .status = .ok, .keep_alive = false }) catch {};
        } else {
            req.respond("{}", .{ .status = .not_found, .keep_alive = false }) catch {};
        }
    }
}

test "CouchDB pullInto: history mismatch fallback, doc_ids + selector, and conflict preservation" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db_path = "zig-cache/zouch-repl-pull-edge-test";
    std.Io.Dir.cwd().deleteTree(io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, db_path) catch {};

    const db = try Db.open(alloc, io, db_path);
    defer db.close();

    // Seed local d1 with a conflicting branch: 1-aaaa... -> 2-bbbb...
    const r1 = try Rev.parse("1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const r2_local = try Rev.parse("2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    _ = try db.putImported("d1", r2_local, &.{ r2_local, r1 }, "{\"v\":\"local\"}", false);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const srv = try addr.listen(io, .{ .reuse_address = true });
    const port = srv.socket.address.getPort();

    var state = MockPullState{
        .io = io,
        .server = srv,
        .alloc = alloc,
        .remote_checkpoint =
        \\{"session_id":"remote-other","source_last_seq":"9","history":[{"session_id":"remote-other","recorded_seq":"9"}]}
        ,
    };

    const thread = try std.Thread.spawn(.{}, mockPullServerLoop, .{&state});
    defer {
        state.stop.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |wake_addr| {
            if (wake_addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        thread.join();
        state.server.deinit(io);
    }

    const source_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(source_url);

    var doc_ids: IdFilter = .empty;
    defer doc_ids.deinit(alloc);
    try doc_ids.put(alloc, "d1", {});
    try doc_ids.put(alloc, "d3", {});

    const selector_json = "{\"type\":\"note\"}";
    // Pre-populate a mismatched local checkpoint for this exact replication key.
    const cp_id = try checkpointDocIdFor(alloc, .{
        .source = source_url,
        .target = db_path,
        .doc_ids = &doc_ids,
        .selector = selector_json,
    });
    defer alloc.free(cp_id);
    _ = try db.putLocalDoc(
        cp_id,
        \\{"session_id":"local-old","source_last_seq":"5","history":[{"session_id":"local-old","recorded_seq":"5"}]}
    ,
        null,
    );

    const res = try pullInto(alloc, io, db, .{
        .source = source_url,
        .target_path = db_path,
        .doc_ids = &doc_ids,
        .selector = selector_json,
        .use_checkpoints = true,
    });
    defer {
        if (res.start_seq) |s| alloc.free(s);
        if (res.end_seq) |s| alloc.free(s);
    }

    // Mismatched history fell back cleanly to "0".
    try std.testing.expectEqualStrings("0", res.start_seq.?);
    try std.testing.expectEqualStrings("3", res.end_seq.?);
    try std.testing.expect(state.saw_since_zero.load(.acquire));
    // Selector was POSTed with filter=_selector, and doc_ids excluded d2.
    try std.testing.expect(state.saw_selector_post.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), res.documents);
    try std.testing.expect(db.docs.get("d2") == null);
    try std.testing.expect(db.docs.get("d3") != null);
    // Conflict on d1 (2-bbbb vs 2-cccc) is preserved with 2 leaves and 2-cccc winning.
    const d1 = db.docs.get("d1").?;
    try std.testing.expectEqual(@as(usize, 2), d1.leaves.items.len);
    const r2_remote = try Rev.parse("2-cccccccccccccccccccccccccccccccc");
    try std.testing.expect(r2_remote.eql(d1.winnerLeaf().rev));
}
