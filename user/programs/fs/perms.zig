// perms: set file write permission.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 4) {

        lib.io.writeln(out, "usage: perms <file> -write true|false") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "perms: filesystem unavailable") catch {};

        return 1;

    };
    defer client.close();

    const path = args[1];

    if (!equals(args[2], "-write")) {

        lib.io.writeln(out, "perms: expected -write flag") catch {};

        return 1;

    }

    const writable = parse_bool(args[3]) orelse {

        lib.io.writeln(out, "perms: expected true or false") catch {};

        return 1;

    };

    const stat = client.stat(path) catch |failure| {

        lib.io.print(out, "perms: {s}: {s}\n", .{ path, lib.fs.describe(failure) }) catch {};

        return 1;

    };

    const mask: u64 = if (writable)
        @as(u64, stat.permissions) | lib.proto.filesystem.permission_write
    else
        @as(u64, stat.permissions) & ~lib.proto.filesystem.permission_write;

    client.set_permissions(path, mask) catch |failure| {

        lib.io.print(out, "perms: {s}: {s}\n", .{ path, lib.fs.describe(failure) }) catch {};

        return 1;

    };

    return 0;

}

fn parse_bool(text: []const u8) ?bool {

    if (equals(text, "true")) return true;
    if (equals(text, "false")) return false;

    return null;

}

fn equals(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |left, right| {

        if (left != right) return false;

    }

    return true;

}
