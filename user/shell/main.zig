// The minimal shell (07-userspace-ddd.md Section 8; 08-roadmap.md M4): read a line through the console driver's Stream endpoint, echo happens in the driver as the user types, and a handful of in-process builtins run. External programs, pipelines, and the LineEditor arrive with M5/M6.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const page_size = 4096;

// The per-session shared buffer with the console driver: shared once at startup, reused for every read and write.

var session_base: usize = 0;

pub fn main(_: u64) callconv(.c) noreturn {

    run() catch {};

    lib.start.exit();

}

fn run() !void {

    var heap = lib.mem.Heap.init(cap.shell.memory);

    const line = try heap.alloc(256);

    try open_session();

    try put_text("\nGraniteOS shell - 'help' lists the builtins.\n");

    while (true) {

        try put_text("granite> ");

        const length = try read_line(line);

        try run_builtin(trimmed(line[0..length]));

    }

}

fn open_session() !void {

    const buffer = try sys.create(.region, page_size, cap.shell.memory);
    session_base = try sys.map(cap.self_space, buffer, 0, sys.read | sys.write);

    _ = try ipc.request(cap.shell.console, proto.stream.attach, &.{page_size}, &.{

        .{ .handle = buffer, .move = false },

    });

}

fn run_builtin(line: []const u8) !void {

    if (line.len == 0) return;

    if (equals(line, "help")) {

        return put_text("builtins:\n  help   list the builtins\n  about  describe this system\n");

    }

    if (equals(line, "about")) {

        return put_text("GraniteOS-2 M4 walking skeleton: kernel, console driver, and shell talking over IPC.\n");

    }

    try put_text("unknown command: '");
    try put_text(line);
    try put_text("' - try 'help'.\n");

}

// Stream client helpers: bytes ride the shared buffer, only offset/length cross the kernel.

fn read_line(into: []u8) !usize {

    const reply = try ipc.request(cap.shell.console, proto.stream.read, &.{ 0, into.len }, &.{});

    const length: usize = @intCast(reply.data[0]);
    const buffer: [*]const u8 = @ptrFromInt(session_base);

    @memcpy(into[0..length], buffer[0..length]);

    return length;

}

fn put_text(text: []const u8) !void {

    const buffer: [*]u8 = @ptrFromInt(session_base);

    @memcpy(buffer[0..text.len], text);

    _ = try ipc.request(cap.shell.console, proto.stream.write, &.{ 0, text.len }, &.{});

}

fn trimmed(line: []const u8) []const u8 {

    return std.mem.trim(u8, line, " \t\r\n");

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}
