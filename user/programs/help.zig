const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    lib.io.write(out, "programs:\n  echo\n  cat\n  help\n  cat-via-name\n") catch return 1;

    return 0;

}
