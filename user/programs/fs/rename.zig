// rename: move a file or directory to a new path through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 3) {

        lib.io.writeln(out, "usage: rename <old> <new>") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "rename: filesystem unavailable") catch {};

        return 1;

    };

    client.rename(args[1], args[2]) catch |failure| {

        lib.io.print(out, "rename: {s}: {s}\n", .{ args[1], lib.fs.describe(failure) }) catch {};

        return 1;

    };

    return 0;

}
