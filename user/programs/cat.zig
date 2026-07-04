const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    var input = lib.start.stdin() catch return 1;
    const out = lib.start.stdout() catch return 1;
    var buffer: [256]u8 = undefined;

    while (true) {

        const read = input.read(&buffer) catch return 1;

        if (read == 0) break;

        lib.io.write(out, buffer[0..read]) catch return 1;

    }

    return 0;

}
