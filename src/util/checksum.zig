const std = @import("std");

pub const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub fn of(bytes: []const u8) u32 {
    return Crc32c.hash(bytes);
}

test "crc32c known vector" {
    try std.testing.expectEqual(@as(u32, 0xE3069283), of("123456789"));
}
