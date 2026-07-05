// clear: erase the terminal screen.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    lib.term.clear_screen(out) catch return 1;

    return 0;

}
