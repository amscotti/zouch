const std = @import("std");

/// A CouchDB revision identifier: `<generation>-<32 hex chars>`.
pub const Rev = struct {
    gen: u32,
    hash: [32]u8,

    pub fn parse(s: []const u8) !Rev {
        const dash = std.mem.indexOfScalar(u8, s, '-') orelse return error.InvalidRev;
        if (dash == 0 or dash + 33 != s.len) return error.InvalidRev;
        const gen = std.fmt.parseInt(u32, s[0..dash], 10) catch return error.InvalidRev;
        if (gen == 0) return error.InvalidRev;
        var out: [32]u8 = undefined;
        for (s[dash + 1 ..], 0..) |c, i| {
            if (!std.ascii.isHex(c)) return error.InvalidRev;
            out[i] = std.ascii.toLower(c);
        }
        return .{ .gen = gen, .hash = out };
    }

    pub fn eql(a: Rev, b: Rev) bool {
        return a.gen == b.gen and std.mem.eql(u8, &a.hash, &b.hash);
    }

    /// CouchDB ordering: higher generation wins; ties break on the higher hash.
    pub fn order(a: Rev, b: Rev) std.math.Order {
        if (a.gen != b.gen) return std.math.order(a.gen, b.gen);
        return std.mem.order(u8, &a.hash, &b.hash);
    }

    pub fn write(self: Rev, buf: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}-{s}", .{ self.gen, self.hash[0..] }) catch unreachable;
    }
};

pub fn newRev(gen: u32, body: []const u8, parent: ?[]const u8) Rev {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(body);
    if (parent) |p| h.update(p);
    var digest: [16]u8 = undefined;
    h.final(&digest);

    var out: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return .{ .gen = gen, .hash = out };
}

test "parse and format" {
    const r = try Rev.parse("3-0123456789abcdef0123456789abcdef");
    try std.testing.expectEqual(@as(u32, 3), r.gen);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "3-0123456789abcdef0123456789abcdef",
        r.write(&buf),
    );
}

test "ordering: generation first, then hash" {
    const a = try Rev.parse("2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const b = try Rev.parse("2-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const c = try Rev.parse("3-00000000000000000000000000000000");
    try std.testing.expectEqual(std.math.Order.lt, Rev.order(a, b));
    try std.testing.expectEqual(std.math.Order.gt, Rev.order(c, b));
}

test "invalid revisions" {
    try std.testing.expectError(error.InvalidRev, Rev.parse(""));
    try std.testing.expectError(error.InvalidRev, Rev.parse("1-abc"));
    try std.testing.expectError(error.InvalidRev, Rev.parse("x-0123456789abcdef0123456789abcdef"));
    try std.testing.expectError(error.InvalidRev, Rev.parse("1-0123456789abcdef0123456789abcdeZ"));
}
