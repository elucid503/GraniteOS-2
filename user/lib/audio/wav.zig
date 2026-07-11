const std = @import("std");

pub const Format = struct {

    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    block_align: u16,

};

pub const Wave = struct {

    format: Format,
    samples: []const u8,

    pub fn frame_count(self: Wave) usize {

        return self.samples.len / self.format.block_align;

    }

    pub fn duration_ms(self: Wave) u64 {

        return @as(u64, self.frame_count()) * 1000 / self.format.sample_rate;

    }

};

pub fn parse(bytes: []const u8) !Wave {

    if (bytes.len < 12) return error.InvalidWave;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.InvalidWave;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWave;

    var format: ?Format = null;
    var samples: ?[]const u8 = null;
    var cursor: usize = 12;

    while (cursor + 8 <= bytes.len) {

        const size: usize = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
        const start = cursor + 8;

        if (size > bytes.len - start) return error.InvalidWave;

        const chunk = bytes[start .. start + size];

        if (std.mem.eql(u8, bytes[cursor .. cursor + 4], "fmt ")) {

            if (chunk.len < 16) return error.InvalidWave;
            if (std.mem.readInt(u16, chunk[0..2], .little) != 1) return error.UnsupportedEncoding;

            const channels = std.mem.readInt(u16, chunk[2..4], .little);
            const sample_rate = std.mem.readInt(u32, chunk[4..8], .little);
            const block_align = std.mem.readInt(u16, chunk[12..14], .little);
            const bits = std.mem.readInt(u16, chunk[14..16], .little);

            if ((channels != 1 and channels != 2) or sample_rate == 0) return error.UnsupportedFormat;
            if (bits != 8 and bits != 16) return error.UnsupportedFormat;
            if (block_align != channels * (bits / 8)) return error.InvalidWave;

            format = .{

                .channels = channels,
                .sample_rate = sample_rate,
                .bits_per_sample = bits,
                .block_align = block_align,

            };

        } else if (std.mem.eql(u8, bytes[cursor .. cursor + 4], "data")) {

            samples = chunk;

        }

        cursor = start + size + (size & 1);

    }

    const found_format = format orelse return error.InvalidWave;
    const found_samples = samples orelse return error.InvalidWave;

    if (found_samples.len % found_format.block_align != 0) return error.InvalidWave;

    return .{ .format = found_format, .samples = found_samples };

}

test "parse PCM wave with an unknown chunk" {

    const bytes = [_]u8{
        'R', 'I', 'F', 'F', 42, 0, 0, 0, 'W', 'A', 'V', 'E',
        'J', 'U', 'N', 'K', 1, 0, 0, 0, 0, 0,
        'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 1, 0,
        0x44, 0xac, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0,
        'd', 'a', 't', 'a', 2, 0, 0, 0, 1, 0,
    };

    const wave = try parse(&bytes);

    try std.testing.expectEqual(@as(u16, 1), wave.format.channels);
    try std.testing.expectEqual(@as(u32, 44_100), wave.format.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), wave.frame_count());

}

test "reject compressed wave" {

    const bytes = [_]u8{
        'R', 'I', 'F', 'F', 36, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0, 3, 0, 1, 0,
        0x80, 0xbb, 0, 0, 0, 0, 0, 0, 4, 0, 32, 0,
        'd', 'a', 't', 'a', 0, 0, 0, 0,
    };

    try std.testing.expectError(error.UnsupportedEncoding, parse(&bytes));

}
