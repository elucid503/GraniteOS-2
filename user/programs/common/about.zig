// about: print the GraniteOS banner and feature list.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    lib.catalog.write_about(out) catch return 1;

    return 0;

}
