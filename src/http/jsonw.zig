const std = @import("std");

pub fn writeString(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x08 => try list.appendSlice(alloc, "\\b"),
            0x0c => try list.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    try list.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
    try list.append(alloc, '"');
}

/// Format a float without a fixed-size buffer: `{d}` prints every digit of
/// 1e100, so the output has to grow with the value. Magnitudes that plain
/// decimal notation would stretch over many digits use exponent form, like
/// JavaScript's `Number.prototype.toString`. JSON has no NaN or infinity.
pub fn writeFloat(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, f: f64) !void {
    if (!std.math.isFinite(f)) return list.appendSlice(alloc, "null");
    const mag = @abs(f);
    if (mag >= 1e21 or (mag != 0 and mag < 1e-6)) {
        try list.print(alloc, "{e}", .{f});
    } else {
        try list.print(alloc, "{d}", .{f});
    }
}

pub fn writeValue(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try list.appendSlice(alloc, "null"),
        .bool => |b| try list.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |i| try list.print(alloc, "{d}", .{i}),
        .float => |f| try writeFloat(list, alloc, f),
        .number_string => |s| try list.appendSlice(alloc, s),
        .string => |s| try writeString(list, alloc, s),
        .array => |arr| {
            try list.append(alloc, '[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try list.append(alloc, ',');
                try writeValue(list, alloc, item);
            }
            try list.append(alloc, ']');
        },
        .object => |obj| {
            try list.append(alloc, '{');
            const keys = obj.keys();
            const vals = obj.values();
            for (keys, vals, 0..) |k, val, i| {
                if (i != 0) try list.append(alloc, ',');
                try writeString(list, alloc, k);
                try list.append(alloc, ':');
                try writeValue(list, alloc, val);
            }
            try list.append(alloc, '}');
        },
    }
}

pub fn fieldString(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, key: []const u8, val: []const u8) !void {
    try writeString(list, alloc, key);
    try list.append(alloc, ':');
    try writeString(list, alloc, val);
}

pub fn fieldRaw(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, key: []const u8, raw: []const u8) !void {
    try writeString(list, alloc, key);
    try list.append(alloc, ':');
    try list.appendSlice(alloc, raw);
}

test "escapes and values" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try writeValue(&buf, alloc, .{ .string = "a\"b\n" });
    try std.testing.expectEqualStrings("\"a\\\"b\\n\"", buf.items);
}

fn oomWorkload(alloc: std.mem.Allocator) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "key", .{ .string = "value" });
    var nested: std.json.Array = .init(alloc);
    defer nested.deinit();
    try nested.append(.{ .integer = 1 });
    try nested.append(.{ .bool = true });
    try obj.put(alloc, "nested", .{ .array = nested });
    try writeValue(&buf, alloc, .{ .object = obj });
}

test "json writer survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomWorkload, .{});
}

test "floats of any magnitude format without overflow and round-trip" {
    const alloc = std.testing.allocator;
    const cases = [_]f64{ 1e100, 1.7976931348623157e308, 5e-324, 1e-63, 1.5, -2.5e-30, 0, 123456789.125, 1e21, 1e-7 };
    for (cases) |f| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        try writeValue(&buf, alloc, .{ .float = f });
        const back = try std.fmt.parseFloat(f64, buf.items);
        try std.testing.expectEqual(f, back);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try writeValue(&buf, alloc, .{ .float = std.math.inf(f64) });
    try std.testing.expectEqualStrings("null", buf.items);
}
