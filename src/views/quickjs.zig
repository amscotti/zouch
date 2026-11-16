const std = @import("std");

extern fn zx_new_rt() ?*anyopaque;
extern fn zx_free_rt(rt: ?*anyopaque) void;
extern fn zx_new_ctx(rt: ?*anyopaque) ?*anyopaque;
extern fn zx_free_ctx(ctx: ?*anyopaque) void;
extern fn zx_mem_limit(rt: ?*anyopaque, n: usize) void;
extern fn zx_eval_timeout(rt: ?*anyopaque, ctx: ?*anyopaque, code: [*:0]const u8, timeout_ms: u64) ?[*:0]const u8;
extern fn zx_free_str(ctx: ?*anyopaque, s: ?[*:0]const u8) void;

pub const DEFAULT_TIMEOUT_MS: u64 = 5000;

pub const Engine = struct {
    rt: *anyopaque,
    ctx: *anyopaque,
    timeout_ms: u64 = DEFAULT_TIMEOUT_MS,

    pub fn init() !Engine {
        return initWithTimeout(DEFAULT_TIMEOUT_MS);
    }

    pub fn initWithTimeout(timeout_ms: u64) !Engine {
        const rt = zx_new_rt() orelse return error.NoRuntime;
        errdefer zx_free_rt(rt);
        zx_mem_limit(rt, 64 * 1024 * 1024);
        const ctx = zx_new_ctx(rt) orelse return error.NoContext;
        return .{ .rt = rt, .ctx = ctx, .timeout_ms = timeout_ms };
    }

    pub fn deinit(self: *Engine) void {
        zx_free_ctx(self.ctx);
        zx_free_rt(self.rt);
    }

    pub fn setTimeout(self: *Engine, timeout_ms: u64) void {
        self.timeout_ms = timeout_ms;
    }

    pub fn eval(self: *Engine, code: []const u8) ![]u8 {
        const z = try std.heap.page_allocator.dupeSentinel(u8, code, 0);
        defer std.heap.page_allocator.free(z);
        const s = zx_eval_timeout(self.rt, self.ctx, z.ptr, self.timeout_ms) orelse return error.JsException;
        defer zx_free_str(self.ctx, s);
        return std.heap.page_allocator.dupe(u8, std.mem.span(s));
    }
};

test "quickjs evaluate" {
    var e = try Engine.init();
    defer e.deinit();
    const out = try e.eval("JSON.stringify([1,2,3])");
    defer std.heap.page_allocator.free(out);
    try std.testing.expectEqualStrings("[1,2,3]", out);
}

test "quickjs aborts infinite loop on timeout and remains usable" {
    var e = try Engine.initWithTimeout(50);
    defer e.deinit();
    try std.testing.expectError(error.JsException, e.eval("while (true) {}"));

    // Engine context should remain clean and usable after an interrupted eval.
    const out = try e.eval("1 + 2");
    defer std.heap.page_allocator.free(out);
    try std.testing.expectEqualStrings("3", out);
}

extern fn zouch_regex_match(pattern: [*]const u8, plen: usize, text: [*]const u8, tlen: usize) c_int;

fn regexMatch(pat: []const u8, text: []const u8) c_int {
    return zouch_regex_match(pat.ptr, pat.len, text.ptr, text.len);
}

test "quickjs libregexp PCRE features and inline flags" {
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("\\d+", "abc123def"));
    try std.testing.expectEqual(@as(c_int, 0), regexMatch("^\\d+$", "abc123"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^\\w+\\s+\\w+$", "hello world"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("(?i)hello", "HeLLo"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("(?m)^bar$", "foo\nbar\nbaz"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("(?s)a.b", "a\nb"));
    try std.testing.expectEqual(@as(c_int, 0), regexMatch("a.b", "a\nb"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^a.*?b$", "axb"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("foo\\x00bar", "foo\x00bar"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^caf.$", "café"));
    try std.testing.expectEqual(@as(c_int, -1), regexMatch("[", "abc"));

    // Non-NUL-terminated pattern & text slices (as produced by JSON parser).
    const non_nul_pat = "^Alpha-[0-9]+$\"extra"[0..14];
    const non_nul_txt = "Alpha-42\"extra"[0..8];
    try std.testing.expectEqual(@as(c_int, 1), regexMatch(non_nul_pat, non_nul_txt));

    // Verify zouch_regex_match works from a spawned worker thread (stack_top update).
    const t = try std.Thread.spawn(.{}, struct {
        fn run() void {
            std.debug.assert(regexMatch("^Alpha-[0-9]+$", "Alpha-42") == 1);
            std.debug.assert(regexMatch("(?i)hello", "HeLLo") == 1);
        }
    }.run, .{});
    t.join();
}

test "CouchDB $regex edge cases" {
    // Empty pattern matches any string (including empty).
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("", ""));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("", "abc"));

    // Anchors and alternation.
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^(foo|bar)$", "bar"));
    try std.testing.expectEqual(@as(c_int, 0), regexMatch("^(foo|bar)$", "foobar"));

    // Character classes and negated classes (\d, \D, \w, \W, \s, \S).
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^\\D+\\d+$", "item42"));
    try std.testing.expectEqual(@as(c_int, 0), regexMatch("^\\D+\\d+$", "123"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^\\S+\\s+\\S+$", "a\tb"));

    // Non-greedy quantifiers.
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^<.+?>", "<a><b>"));
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("^a+?b$", "aaab"));

    // Unicode case-insensitive inline flag.
    try std.testing.expectEqual(@as(c_int, 1), regexMatch("(?i)café", "CAFÉ"));
}

test "quickjs map/reduce error isolation across evaluations" {
    var e = try Engine.init();
    defer e.deinit();

    // Syntax error does not poison subsequent evals.
    try std.testing.expectError(error.JsException, e.eval("function( {"));
    const ok1 = try e.eval("JSON.stringify([10, 20].reduce(function(a, b) { return a + b; }, 0))");
    defer std.heap.page_allocator.free(ok1);
    try std.testing.expectEqualStrings("30", ok1);

    // Thrown runtime exception does not poison subsequent evals.
    try std.testing.expectError(error.JsException, e.eval("(function(){ throw new Error('boom'); })()"));
    const ok2 = try e.eval("JSON.stringify({ok: true})");
    defer std.heap.page_allocator.free(ok2);
    try std.testing.expectEqualStrings("{\"ok\":true}", ok2);
}
