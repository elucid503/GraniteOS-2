const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    var console = lib.stream.lookup("console", lib.cap.memory) catch return 1;

    lib.io.write(&console, "cat-via-name: resolved console through name service\n") catch return 1;

    return 0;

}
