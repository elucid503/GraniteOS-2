// Small formatting helpers over Stream; enough for Marble and bundled programs.

const std = @import("std");

const stream = @import("stream.zig");
const sys = @import("sys.zig");

pub const Error = sys.Error;

pub fn write(out: *stream.Stream, bytes: []const u8) sys.Error!void {

    var cursor: usize = 0;

    while (cursor < bytes.len) {

        const written = try out.write(bytes[cursor..]);

        if (written == 0) return error.Gone;

        cursor += written;

    }

}

pub fn writeln(out: *stream.Stream, text: []const u8) sys.Error!void {

    try write(out, text);
    try write(out, "\n");

}

pub fn write_entry(out: *stream.Stream, name: []const u8, description: []const u8) sys.Error!void {

    try write(out, "  ");
    try write(out, name);

    var padding = name.len;

    while (padding < 12) : (padding += 1) {

        try write(out, " ");

    }

    try write(out, "  ");
    try writeln(out, description);

}

pub fn print(out: *stream.Stream, comptime format: []const u8, args: anytype) sys.Error!void {

    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return error.Invalid;

    try write(out, text);

}
