// write: put text into a file (created or truncated). Content comes from the remaining arguments, or from stdin
// when piped: `echo hello | write /notes`.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len < 2) {

        lib.io.writeln(out, "usage: write <path> [text ...]") catch {};

        return 1;

    }

    var client = lib.fs.Client.connect(lib.cap.memory) catch {

        lib.io.writeln(out, "write: filesystem unavailable") catch {};

        return 1;

    };

    const flags = lib.proto.filesystem.open_create | lib.proto.filesystem.open_truncate;

    const file = client.open_path(args[1], flags) catch |failure| {

        lib.io.print(out, "write: {s}: {s}\n", .{ args[1], lib.fs.describe(failure) }) catch {};

        return 1;

    };

    var offset: u64 = 0;

    if (args.len > 2) {

        for (args[2..], 0..) |word, index| {

            if (index > 0) offset += put(&client, file, offset, " ") catch return 1;

            offset += put(&client, file, offset, word) catch return 1;

        }

        _ = put(&client, file, offset, "\n") catch return 1;

    } else {

        var input = lib.start.stdin() catch return 1;
        var buffer: [1024]u8 = undefined;

        while (true) {

            const length = input.read(&buffer) catch return 1;

            if (length == 0) break;

            offset += put(&client, file, offset, buffer[0..length]) catch return 1;

        }

    }

    client.close_file(file) catch {};

    return 0;

}

fn put(client: *lib.fs.Client, file: u64, offset: u64, bytes: []const u8) !u64 {

    var written: u64 = 0;

    while (written < bytes.len) {

        written += try client.write(file, offset + written, bytes[@intCast(written)..]);

    }

    return written;

}
