const lib = @import("lib");

const cap = lib.cap;

pub const program_meta = .{
    .description = "Play a PCM WAV audio file",
    .category = "media",
};

comptime {

    _ = lib.start;

}

const max_file_bytes = 8 * 1024 * 1024;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    if (args.len != 2) {

        lib.io.writeln(out, "usage: play <file.wav>") catch {};
        return 1;

    }

    run(args[1]) catch |failure| {

        lib.io.print(out, "play: {s}: {s}\n", .{ args[1], @errorName(failure) }) catch {};
        return 1;

    };

    return 0;

}

fn run(path: []const u8) !void {

    var files = try lib.fs.Client.connect(cap.memory);
    const info = try files.stat(path);
    const length: usize = @intCast(info.length);

    if (length > max_file_bytes) return error.NoMemory;

    const region = try lib.sys.create(.region, @max(length, 1), cap.memory);
    defer lib.sys.close(region) catch {};

    const base = try lib.sys.map(cap.self_space, region, 0, lib.sys.read | lib.sys.write);
    defer lib.sys.unmap(cap.self_space, base) catch {};

    const storage: [*]u8 = @ptrFromInt(base);
    const file = try files.open_path(path, 0);
    defer files.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < length) {

        const count = try files.read(file, offset, storage[offset..length]);

        if (count == 0) break;

        offset += count;

    }

    const wave = try lib.wav.parse(storage[0..offset]);
    var audio = try lib.audio.Client.connect(cap.memory);
    defer audio.deinit();

    try audio.configure(wave.format.sample_rate, wave.format.channels);

    var scratch: [lib.proto.audio.max_write]u8 = undefined;
    var sample_offset: usize = 0;

    while (sample_offset < wave.samples.len) {

        const source = lib.audio.convert(wave, sample_offset, &scratch, lib.audio.gain_unity);
        const written = try audio.write(source.bytes);

        if (written != source.bytes.len) return error.Invalid;

        sample_offset += source.consumed;

    }

    try audio.flush();

}
