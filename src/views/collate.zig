const std = @import("std");
const builtin = @import("builtin");

const UErrorCode = c_int;
const U_ZERO_ERROR: UErrorCode = 0;

const OpenFn = *const fn ([*:0]const u8, *UErrorCode) callconv(.c) ?*anyopaque;
const CloseFn = *const fn (?*anyopaque) callconv(.c) void;
const CollFn = *const fn (?*anyopaque, [*]const u8, c_int, [*]const u8, c_int, *UErrorCode) callconv(.c) c_int;

fn zformat(buf: []u8, comptime format: []const u8, args: anytype) ?[:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], format, args) catch return null;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

const IcuLib = struct {
    lib: std.DynLib,
    open_fn: OpenFn,
    close_fn: CloseFn,
    coll_fn: CollFn,
};

const LibState = enum {
    uninitialized,
    loaded,
    unavailable,
};

const POOL_CAP = 16;
var state_lock: std.atomic.Value(bool) = .init(false);
var lib_state: LibState = .uninitialized;
var cached_lib: IcuLib = undefined;
var handle_pool: [POOL_CAP]?*anyopaque = @splat(null);
var pool_len: usize = 0;

fn acquireLock() void {
    while (state_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
}

fn releaseLock() void {
    state_lock.store(false, .release);
}

fn loadIcuLib() ?*const IcuLib {
    const candidates = if (builtin.os.tag == .macos) [_][]const u8{
        "/opt/homebrew/opt/icu4c/lib/libicui18n.dylib",
        "/usr/local/opt/icu4c/lib/libicui18n.dylib",
        "libicui18n.dylib",
    } else [_][]const u8{
        "libicui18n.so",
        "libicui18n.so.72",
        "libicui18n.so.73",
        "libicui18n.so.74",
        "libicui18n.so.75",
        "libicui18n.so.76",
        "libicui18n.so.77",
        "libicui18n.so.78",
        "libicui18n.so.79",
        "libicui18n.so.80",
    };
    for (candidates) |path| {
        var lib = std.DynLib.open(path) catch continue;
        var v: u32 = 60;
        while (v <= 99) : (v += 1) {
            var buf: [32]u8 = undefined;
            const open_name = zformat(&buf, "ucol_open_{d}", .{v}) orelse continue;
            const open_fn = lib.lookup(OpenFn, open_name) orelse continue;
            var cbuf: [32]u8 = undefined;
            const close_name = zformat(&cbuf, "ucol_close_{d}", .{v}) orelse continue;
            const close_fn = lib.lookup(CloseFn, close_name) orelse continue;
            var sbuf: [48]u8 = undefined;
            const coll_name = zformat(&sbuf, "ucol_strcollUTF8_{d}", .{v}) orelse continue;
            const coll_fn = lib.lookup(CollFn, coll_name) orelse continue;

            var status: UErrorCode = U_ZERO_ERROR;
            const probe = open_fn("", &status);
            if (probe == null or status > U_ZERO_ERROR) {
                if (probe != null) close_fn(probe);
                break;
            }
            close_fn(probe);

            cached_lib = .{
                .lib = lib,
                .open_fn = open_fn,
                .close_fn = close_fn,
                .coll_fn = coll_fn,
            };
            lib_state = .loaded;
            return &cached_lib;
        }
        lib.close();
    }
    lib_state = .unavailable;
    return null;
}

pub const Collator = struct {
    handle: ?*anyopaque,
    close_fn: CloseFn,
    coll_fn: CollFn,

    /// ICU is optional at build time but not at behaviour time: without it,
    /// string keys sort by byte order and `startkey`/`endkey` results differ
    /// from CouchDB. Warn once per process so a missing library is visible
    /// instead of silently changing query results.
    var warned_missing: std.atomic.Value(bool) = .init(false);

    fn warnMissingOnce() void {
        if (warned_missing.swap(true, .monotonic)) return;
        std.log.warn("libicui18n not found: view string keys fall back to byte order and will not match CouchDB collation (install libicu-dev or libicu72)", .{});
    }

    /// Acquire a Collator handle, reusing the process-wide loaded ICU library
    /// and a thread-safe pool of UCollator handles across requests.
    pub fn init() ?Collator {
        acquireLock();
        const icu: *const IcuLib = switch (lib_state) {
            .loaded => &cached_lib,
            .unavailable => {
                releaseLock();
                return null;
            },
            .uninitialized => loadIcuLib() orelse {
                releaseLock();
                warnMissingOnce();
                return null;
            },
        };
        if (pool_len > 0) {
            pool_len -= 1;
            const handle = handle_pool[pool_len];
            handle_pool[pool_len] = null;
            releaseLock();
            return .{
                .handle = handle,
                .close_fn = icu.close_fn,
                .coll_fn = icu.coll_fn,
            };
        }
        releaseLock();

        var status: UErrorCode = U_ZERO_ERROR;
        const handle = icu.open_fn("", &status);
        if (handle == null or status > U_ZERO_ERROR) {
            if (handle != null) icu.close_fn(handle);
            return null;
        }
        return .{
            .handle = handle,
            .close_fn = icu.close_fn,
            .coll_fn = icu.coll_fn,
        };
    }

    pub fn deinit(self: *Collator) void {
        const handle = self.handle orelse return;
        self.handle = null;

        acquireLock();
        if (pool_len < POOL_CAP) {
            handle_pool[pool_len] = handle;
            pool_len += 1;
            releaseLock();
            return;
        }
        releaseLock();

        self.close_fn(handle);
    }

    pub fn cmp(self: *const Collator, a: []const u8, b: []const u8) i32 {
        var status: UErrorCode = U_ZERO_ERROR;
        const r = self.coll_fn(self.handle, a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), &status);
        if (status > U_ZERO_ERROR) {
            return switch (std.mem.order(u8, a, b)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
        return r;
    }
};

test "ICU collation orders case like CouchDB" {
    var coll = Collator.init() orelse return error.SkipZigTest;
    defer coll.deinit();
    try std.testing.expect(coll.cmp("a", "B") < 0);
    try std.testing.expect(coll.cmp("B", "a") > 0);
    try std.testing.expect(coll.cmp("a", "a") == 0);
}

test "ICU collator pool reuse across requests" {
    var c1 = Collator.init() orelse return error.SkipZigTest;
    try std.testing.expect(c1.cmp("a", "B") < 0);
    c1.deinit();

    var c2 = Collator.init() orelse return error.SkipZigTest;
    defer c2.deinit();
    try std.testing.expect(c2.cmp("a", "B") < 0);

    var c3 = Collator.init() orelse return error.SkipZigTest;
    defer c3.deinit();
    try std.testing.expect(c3.cmp("B", "a") > 0);
}

test "CouchDB ICU string collation canonical order and Unicode" {
    var coll = Collator.init() orelse return error.SkipZigTest;
    defer coll.deinit();

    // CouchDB canonical string order: "" < "a" < "A" < "aa" < "b" < "B" < "ba" < "bb"
    const ordered = [_][]const u8{ "", "a", "A", "aa", "b", "B", "ba", "bb" };
    for (0..ordered.len) |i| {
        try std.testing.expectEqual(@as(i32, 0), coll.cmp(ordered[i], ordered[i]));
        for (i + 1..ordered.len) |j| {
            try std.testing.expect(coll.cmp(ordered[i], ordered[j]) < 0);
            try std.testing.expect(coll.cmp(ordered[j], ordered[i]) > 0);
        }
    }

    // Unicode diacritics and multi-byte UTF-8 collation (UCA root locale).
    try std.testing.expect(coll.cmp("a", "á") < 0);
    try std.testing.expect(coll.cmp("á", "b") < 0);
    try std.testing.expect(coll.cmp("café", "caff") < 0);
    try std.testing.expect(coll.cmp("résumé", "resume") > 0);
}
