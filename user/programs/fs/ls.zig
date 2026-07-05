// ls: list a directory (default "/") through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "ls: filesystem unavailable") catch {};

        return 1;

    };

    const path = if (args.len > 1) args[1] else "/";

    const entries = client.list(path) catch |failure| {

        lib.io.print(out, "ls: {s}: {s}\n", .{ path, lib.fs.describe(failure) }) catch {};

        return 1;

    };

    for (entries) |entry| {

        const name = entry.name[0..entry.name_len];
        const marker = if (entry.kind == lib.proto.filesystem.kind_directory) "/" else "";

        lib.io.print(out, "  {s}{s}", .{ name, marker }) catch return 1;

        var padding = name.len + marker.len;

        while (padding < 24) : (padding += 1) {

            lib.io.write(out, " ") catch return 1;

        }

        lib.io.print(out, "{d}\n", .{entry.length}) catch return 1;

    }

    if (entries.len == 0) {

        lib.io.writeln(out, "  (empty)") catch {};

    }

    return 0;

}
