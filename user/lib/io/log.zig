// Boot/diagnostic logging for drivers and servers: one console session per process, opened lazily on the first
// line and reused forever - a session is a mapped Region and handles in both processes, so opening one per line
// would leak the console's tables dry.

const cap = @import("../cap/cap.zig");
const io = @import("io.zig");
const stream = @import("stream.zig");

var console: ?stream.Stream = null;

pub fn line(text: []const u8) void {

    io.write(session() orelse return, text) catch {};

}

pub fn fmt(comptime text: []const u8, args: anytype) void {

    io.print(session() orelse return, text, args) catch {};

}

fn session() ?*stream.Stream {

    if (console) |*opened| return opened;

    console = stream.lookup("console", cap.memory) catch return null;

    if (console) |*opened| return opened;
    return null;

}
