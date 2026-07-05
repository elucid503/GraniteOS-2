// view: copy a file's contents to stdout through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        lib.io.writeln(out, "usage: view <path>") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "view: filesystem unavailable") catch {};

        return 1;

    };

    const file = client.open_path(args[1], 0) catch |failure| {

        lib.io.print(out, "view: {s}: {s}\n", .{ args[1], lib.fs.describe(failure) }) catch {};

        return 1;

    };

    var buffer: [1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {

        const length = client.read(file, offset, &buffer) catch return 1;

        if (length == 0) break;

        lib.io.write(out, buffer[0..length]) catch return 1;

        offset += length;

    }

    client.close_file(file) catch {};

    return 0;

}
