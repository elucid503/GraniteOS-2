// Small formatting helpers over Stream; enough for the M6 shell and bundled programs.

const std = @import("std");

const stream = @import("stream.zig");
const sys = @import("sys.zig");

pub fn write(out: *stream.Stream, bytes: []const u8) sys.Error!void {

    var cursor: usize = 0;

    while (cursor < bytes.len) {

        const written = try out.write(bytes[cursor..]);

        if (written == 0) return error.Gone;

        cursor += written;

    }

}

pub fn print(out: *stream.Stream, comptime format: []const u8, args: anytype) sys.Error!void {

    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return error.Invalid;

    try write(out, text);

}
