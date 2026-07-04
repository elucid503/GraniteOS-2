const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    for (args[1..], 0..) |arg, index| {

        if (index != 0) lib.io.write(out, " ") catch return 1;

        lib.io.write(out, arg) catch return 1;

    }

    lib.io.write(out, "\n") catch return 1;

    return 0;

}
