// VT100 terminal helpers for interactive programs (write, view).

const std = @import("std");

const io = @import("io.zig");
const proto = @import("../ipc/proto.zig");
const start = @import("../runtime/start.zig");
const stream = @import("stream.zig");
const sys = @import("../syscall/sys.zig");

pub const Error = sys.Error;

pub const rows: usize = 24;
pub const content_rows: usize = rows - 4;

pub fn is_tty() bool {

    return start.flags() & proto.init.stdin_ring == 0;

}

pub fn set_raw(input: *stream.Stream) Error!void {

    try input.set_mode(proto.stream.mode_raw);

}

pub fn set_cooked(input: *stream.Stream) Error!void {

    try input.set_mode(proto.stream.mode_cooked);

}

pub fn read_char(input: *stream.Stream) Error!u8 {

    var byte: [1]u8 = undefined;

    while (true) {

        const length = try input.read(&byte);

        if (length > 0) return byte[0];

    }

}

pub fn write(out: *stream.Stream, text: []const u8) Error!void {

    try io.write(out, text);

}

pub fn writeln(out: *stream.Stream, text: []const u8) Error!void {

    try io.writeln(out, text);

}

pub fn print_int(out: *stream.Stream, value: usize) Error!void {

    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.Invalid;

    try write(out, text);

}

pub fn clear_screen(out: *stream.Stream) Error!void {

    try write(out, "\x1B[2J\x1B[H");

}

pub fn home(out: *stream.Stream) Error!void {

    try write(out, "\x1B[H");

}

pub fn clear_line(out: *stream.Stream) Error!void {

    try write(out, "\x1B[K");

}

pub fn move_cursor(out: *stream.Stream, row: usize, col: usize) Error!void {

    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "\x1B[{d};{d}H", .{ row, col }) catch return error.Invalid;

    try write(out, text);

}
