// wc: count lines and bytes from stdin.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(_: []const []const u8) u8 {

    var input = lib.start.stdin() catch return 1;
    const out = lib.start.stdout() catch return 1;
    var buffer: [512]u8 = undefined;

    var lines: usize = 0;
    var bytes: usize = 0;

    while (true) {

        const length = input.read(&buffer) catch return 1;

        if (length == 0) break;

        bytes += length;

        for (buffer[0..length]) |ch| {

            if (ch == '\n') lines += 1;

        }

    }

    lib.io.print(out, "  {d} line{s}, {d} byte{s}\n", .{

        lines,
        if (lines == 1) "" else "s",
        bytes,
        if (bytes == 1) "" else "s",

    }) catch return 1;

    return 0;

}
