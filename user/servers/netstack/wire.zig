// Big-endian field access for on-wire network headers

pub fn get16(bytes: []const u8, offset: usize) u16 {

    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];

}

pub fn put16(bytes: []u8, offset: usize, value: u16) void {

    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);

}

pub fn get32(bytes: []const u8, offset: usize) u32 {

    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];

}

pub fn put32(bytes: []u8, offset: usize, value: u32) void {

    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);

}

const testing = @import("std").testing;

test "round-trips 16 and 32 bit fields in network order" {

    var buffer: [4]u8 = undefined;

    put16(&buffer, 0, 0xabcd);
    try testing.expectEqual(@as(u8, 0xab), buffer[0]);
    try testing.expectEqual(@as(u16, 0xabcd), get16(&buffer, 0));

    put32(&buffer, 0, 0x0102_0304);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &buffer);
    try testing.expectEqual(@as(u32, 0x0102_0304), get32(&buffer, 0));

}
