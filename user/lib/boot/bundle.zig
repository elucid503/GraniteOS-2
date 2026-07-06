// User-space reader for the module bundle mapped from Flint.

const std = @import("std");

const sys = @import("../syscall/sys.zig");

pub const Error = sys.Error;

pub const magic: u32 = 0x444e_4247;
pub const version: u32 = 1;

const header_size = 16;
const entry_size = 32;
const name_bytes = 24;

pub const Bundle = struct {

    bytes: []const u8,
    count: usize,

    pub fn open(region_base: usize, region_len: usize) Error!Bundle {

        const bytes: [*]const u8 = @ptrFromInt(region_base);
        return open_bytes(bytes[0..region_len]);

    }

    pub fn open_bytes(bytes: []const u8) Error!Bundle {

        if (bytes.len < header_size) return error.Invalid;
        if (read_u32(bytes, 0) != magic) return error.Invalid;
        if (read_u32(bytes, 4) != version) return error.Invalid;

        const count = read_u32(bytes, 8);
        const table_end = header_size + @as(usize, @intCast(count)) * entry_size;

        if (table_end > bytes.len) return error.Invalid;

        return .{

            .bytes = bytes,
            .count = @intCast(count),

        };

    }

    pub fn name_at(self: *const Bundle, index: usize) ?[]const u8 {

        if (index >= self.count) return null;

        const entry = header_size + index * entry_size;

        return entry_name(self.bytes[entry .. entry + name_bytes]);

    }

    pub fn find(self: *const Bundle, name: []const u8) ?[]const u8 {

        for (0..self.count) |index| {

            const entry = header_size + index * entry_size;
            const stored = entry_name(self.bytes[entry .. entry + name_bytes]);

            if (!std.mem.eql(u8, stored, name)) continue;

            const offset = read_u32(self.bytes, entry + 24);
            const length = read_u32(self.bytes, entry + 28);
            const start: usize = @intCast(offset);
            const end = start + @as(usize, @intCast(length));

            if (end > self.bytes.len) return null;

            return self.bytes[start..end];

        }

        return null;

    }

};

fn entry_name(raw: []const u8) []const u8 {

    return raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];

}

fn read_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .little);

}

const testing = std.testing;

test "finds modules and rejects malformed headers" {

    var bytes = [_]u8{0} ** 80;

    std.mem.writeInt(u32, bytes[0..4], magic, .little);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    std.mem.writeInt(u32, bytes[8..12], 1, .little);

    @memcpy(bytes[16..20], "echo");
    std.mem.writeInt(u32, bytes[40..44], 64, .little);
    std.mem.writeInt(u32, bytes[44..48], 5, .little);
    @memcpy(bytes[64..69], "hello");

    const bundle = try Bundle.open_bytes(&bytes);

    try testing.expectEqualStrings("hello", bundle.find("echo").?);
    try testing.expectEqual(@as(?[]const u8, null), bundle.find("marble"));

    bytes[4] = 9;
    try testing.expectError(error.Invalid, Bundle.open_bytes(&bytes));

}
