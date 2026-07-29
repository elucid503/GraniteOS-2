// MPEG-1 Layer III decoder; tables from ISO 11172-3 Annex B. MPEG-2/2.5 returns Unsupported.

const std = @import("std");

const tables = @import("mp3_tables.zig");

pub const Error = error{

    NeedMoreData,
    InvalidFrame,
    Unsupported,
    Reservoir,

};

pub const Version = enum {

    mpeg1,
    mpeg2,
    mpeg2_5,

};

pub const Mode = enum(u2) {

    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,

};

pub const header_size = 4;

/// Longest possible Layer III frame (320 kbit/s at 32 kHz, padded).
pub const max_frame_size = 1441;

/// PCM produced by one MPEG-1 frame, per channel.
pub const frame_samples = 1152;

const granule_lines = 576;
const reservoir_capacity = 2048;

pub const Header = struct {

    version: Version,
    layer: u8,
    has_crc: bool,

    bitrate_index: u8,
    sample_rate_index: u8,
    padding: bool,

    mode: Mode,
    mode_extension: u8,

    pub fn sample_rate(self: Header) u32 {

        const base = [_]u32{ 44100, 48000, 32000 };
        const rate = base[self.sample_rate_index];

        return switch (self.version) {

            .mpeg1 => rate,
            .mpeg2 => rate / 2,
            .mpeg2_5 => rate / 4,

        };

    }

    pub fn bitrate(self: Header) u32 {

        if (self.version == .mpeg1) return tables.bitrates_layer3[self.bitrate_index];

        const lsf = [_]u32{ 0, 8000, 16000, 24000, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000, 160000 };

        return lsf[self.bitrate_index];

    }

    pub fn channels(self: Header) u16 {

        return if (self.mode == .mono) 1 else 2;

    }

    pub fn samples_per_frame(self: Header) usize {

        return if (self.version == .mpeg1) 1152 else 576;

    }

    pub fn frame_size(self: Header) usize {

        const rate = self.bitrate();
        const per_frame = self.samples_per_frame();
        const size = (per_frame / 8) * rate / self.sample_rate();

        return size + @intFromBool(self.padding);

    }

    fn side_info_size(self: Header) usize {

        if (self.version == .mpeg1) return if (self.mode == .mono) 17 else 32;

        return if (self.mode == .mono) 9 else 17;

    }

};

/// Parse a frame header from the first four bytes; null when this is not a valid Layer III header.
pub fn parse_header(bytes: []const u8) ?Header {

    if (bytes.len < header_size) return null;
    if (bytes[0] != 0xff or bytes[1] & 0xe0 != 0xe0) return null;

    const version_bits: u2 = @truncate(bytes[1] >> 3);
    const layer_bits: u2 = @truncate(bytes[1] >> 1);

    if (version_bits == 1 or layer_bits != 1) return null;

    const bitrate_index = bytes[2] >> 4;
    const sample_rate_index: u2 = @truncate(bytes[2] >> 2);

    if (bitrate_index == 0 or bitrate_index == 15 or sample_rate_index == 3) return null;

    return .{

        .version = switch (version_bits) {

            0 => .mpeg2_5,
            2 => .mpeg2,
            else => .mpeg1,

        },

        .layer = 3,
        .has_crc = bytes[1] & 1 == 0,

        .bitrate_index = bitrate_index,
        .sample_rate_index = sample_rate_index,
        .padding = bytes[2] & 2 != 0,

        .mode = @enumFromInt(@as(u2, @truncate(bytes[3] >> 6))),
        .mode_extension = (bytes[3] >> 4) & 3,

    };

}

/// Offset of the next plausible frame header in `bytes`, or null.
pub fn find_header(bytes: []const u8) ?usize {

    var index: usize = 0;

    while (index + header_size <= bytes.len) : (index += 1) {

        const header = parse_header(bytes[index..]) orelse continue;

        // Require the next frame to sync before trusting a lone header pattern.
        const size = header.frame_size();

        if (index + size + header_size > bytes.len) return index;
        if (parse_header(bytes[index + size ..]) != null) return index;

    }

    return null;

}

pub const Result = struct {

    consumed: usize,
    samples: usize,
    sample_rate: u32,
    channels: u16,
    bitrate: u32,

};

const BitReader = struct {

    bytes: []const u8,
    pos: usize = 0,

    fn bits(self: *BitReader, count: u6) u32 {

        var value: u32 = 0;
        var left = count;

        while (left > 0) {

            const index = self.pos >> 3;

            if (index >= self.bytes.len) {

                self.pos += left;

                return value << @intCast(left);

            }

            const available: u6 = @intCast(8 - (self.pos & 7));
            const take = @min(left, available);
            const shift: u3 = @intCast(available - take);
            const mask: u32 = (@as(u32, 1) << @intCast(take)) - 1;

            value = (value << @intCast(take)) | ((@as(u32, self.bytes[index]) >> shift) & mask);

            self.pos += take;
            left -= take;

        }

        return value;

    }

    fn bit(self: *BitReader) u32 {

        return self.bits(1);

    }

    fn exhausted(self: *const BitReader) bool {

        return self.pos >= self.bytes.len * 8;

    }

};

const Granule = struct {

    part2_3_length: u32 = 0,
    big_values: u32 = 0,
    global_gain: u32 = 0,
    scalefac_compress: u32 = 0,

    window_switching: bool = false,
    block_type: u8 = 0,
    mixed_block: bool = false,

    table_select: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u32 = .{ 0, 0, 0 },

    region0_count: u8 = 0,
    region1_count: u8 = 0,

    preflag: bool = false,
    scalefac_scale: bool = false,
    count1_table: u8 = 0,

    nonzero: usize = 0,

};

const SideInfo = struct {

    main_data_begin: u32 = 0,
    scfsi: [2][4]bool = .{ .{false} ** 4, .{false} ** 4 },
    granules: [2][2]Granule = undefined,

};

pub const Decoder = struct {

    reservoir: [reservoir_capacity]u8 = undefined,
    reservoir_len: usize = 0,

    side: SideInfo = .{},

    scalefac_l: [2][2][23]u8 = std.mem.zeroes([2][2][23]u8),
    scalefac_s: [2][2][13][3]u8 = std.mem.zeroes([2][2][13][3]u8),

    lines: [2][2][granule_lines]f32 = std.mem.zeroes([2][2][granule_lines]f32),

    overlap: [2][32][18]f32 = std.mem.zeroes([2][32][18]f32),
    synth: [2][1024]f32 = std.mem.zeroes([2][1024]f32),
    synth_head: [2]usize = .{ 0, 0 },

    pub fn init() Decoder {

        ensure_tables();

        return .{};

    }

    /// Drop all inter-frame state. Call after a seek or a stream discontinuity.
    pub fn reset(self: *Decoder) void {

        self.reservoir_len = 0;
        self.overlap = std.mem.zeroes([2][32][18]f32);
        self.synth = std.mem.zeroes([2][1024]f32);
        self.synth_head = .{ 0, 0 };

    }

    /// Decode one frame to interleaved s16 LE; header-aligned input, reservoir-only frames return 0 samples.
    pub fn decode(self: *Decoder, input: []const u8, out: []i16) Error!Result {

        const header = parse_header(input) orelse return error.InvalidFrame;

        if (header.version != .mpeg1) {

            // Still report the frame length so the caller can step over it.
            if (input.len < header.frame_size()) return error.NeedMoreData;

            return error.Unsupported;

        }

        const size = header.frame_size();

        if (size > input.len) return error.NeedMoreData;
        if (size <= header_size) return error.InvalidFrame;

        const channels = header.channels();

        if (out.len < frame_samples * channels) return error.InvalidFrame;

        var cursor: usize = header_size + @as(usize, if (header.has_crc) 2 else 0);
        const side_end = cursor + header.side_info_size();

        if (side_end > size) return error.InvalidFrame;

        self.read_side_info(input[cursor..side_end], channels);
        cursor = side_end;

        const main = input[cursor..size];

        if (!self.stage_main_data(main)) return .{

            .consumed = size,
            .samples = 0,

            .sample_rate = header.sample_rate(),
            .channels = channels,
            .bitrate = header.bitrate(),

        };

        var reader = BitReader{ .bytes = self.reservoir[0..self.reservoir_len] };

        for (0..2) |granule| {

            for (0..channels) |channel| {

                const start = reader.pos;

                const stop = start + self.side.granules[granule][channel].part2_3_length;

                self.read_scalefactors(&reader, granule, channel);
                self.read_lines(&reader, &header, granule, channel, stop);

                reader.pos = stop;

            }

            for (0..channels) |channel| {

                self.requantize(&header, granule, channel);
                self.reorder(&header, granule, channel);

            }

            if (channels == 2) self.stereo(&header, granule);

            for (0..channels) |channel| {

                self.antialias(granule, channel);
                self.hybrid(granule, channel);
                self.frequency_inversion(granule, channel);
                self.synthesize(granule, channel, channels, out);

            }

        }

        self.keep_reservoir();

        return .{

            .consumed = size,
            .samples = frame_samples * channels,

            .sample_rate = header.sample_rate(),
            .channels = channels,
            .bitrate = header.bitrate(),

        };

    }

    // Side information.

    fn read_side_info(self: *Decoder, bytes: []const u8, channels: u16) void {

        var reader = BitReader{ .bytes = bytes };

        self.side.main_data_begin = reader.bits(9);

        _ = reader.bits(if (channels == 1) 5 else 3);

        for (0..channels) |channel| {

            for (0..4) |band| {

                self.side.scfsi[channel][band] = reader.bit() != 0;

            }

        }

        for (0..2) |granule| {

            for (0..channels) |channel| {

                var info = Granule{};

                info.part2_3_length = reader.bits(12);
                info.big_values = reader.bits(9);
                info.global_gain = reader.bits(8);
                info.scalefac_compress = reader.bits(4);
                info.window_switching = reader.bit() != 0;

                if (info.window_switching) {

                    info.block_type = @intCast(reader.bits(2));
                    info.mixed_block = reader.bit() != 0;

                    for (0..2) |region| info.table_select[region] = @intCast(reader.bits(5));
                    for (0..3) |window| info.subblock_gain[window] = reader.bits(3);

                    // Short blocks carry no region layout; the spec fixes these counts.
                    info.region0_count = if (info.block_type == 2 and !info.mixed_block) 8 else 7;
                    info.region1_count = 20 - info.region0_count;

                } else {

                    for (0..3) |region| info.table_select[region] = @intCast(reader.bits(5));

                    info.region0_count = @intCast(reader.bits(4));
                    info.region1_count = @intCast(reader.bits(3));

                }

                info.preflag = reader.bit() != 0;
                info.scalefac_scale = reader.bit() != 0;
                info.count1_table = @intCast(reader.bits(1));

                self.side.granules[granule][channel] = info;

            }

        }

    }

    // Bit reservoir: main data for a frame may start up to 511 bytes before the frame itself.

    fn stage_main_data(self: *Decoder, main: []const u8) bool {

        const begin = self.side.main_data_begin;

        if (begin > self.reservoir_len) {

            // Lost the back-pointer (stream start, or a dropped frame): bank this frame and skip.
            self.append_reservoir(main);

            return false;

        }

        const keep = self.reservoir_len - begin;

        std.mem.copyForwards(u8, self.reservoir[0..begin], self.reservoir[keep..self.reservoir_len]);
        self.reservoir_len = begin;

        self.append_reservoir(main);

        return true;

    }

    fn append_reservoir(self: *Decoder, main: []const u8) void {

        const room = reservoir_capacity - self.reservoir_len;
        const amount = @min(main.len, room);

        if (amount < main.len) {

            self.reservoir_len = 0;

            const tail = @min(main.len, reservoir_capacity);

            @memcpy(self.reservoir[0..tail], main[main.len - tail ..]);
            self.reservoir_len = tail;

            return;

        }

        @memcpy(self.reservoir[self.reservoir_len..][0..amount], main[0..amount]);
        self.reservoir_len += amount;

    }

    fn keep_reservoir(self: *Decoder) void {

        const keep = @min(self.reservoir_len, 511);

        std.mem.copyForwards(u8, self.reservoir[0..keep], self.reservoir[self.reservoir_len - keep ..]);
        self.reservoir_len = keep;

    }

    // Scalefactors.

    fn read_scalefactors(self: *Decoder, reader: *BitReader, granule: usize, channel: usize) void {

        const info = &self.side.granules[granule][channel];
        const slen1: u6 = @intCast(tables.scalefac_sizes[info.scalefac_compress][0]);
        const slen2: u6 = @intCast(tables.scalefac_sizes[info.scalefac_compress][1]);

        if (info.window_switching and info.block_type == 2) {

            if (info.mixed_block) {

                for (0..8) |sfb| self.scalefac_l[granule][channel][sfb] = @intCast(reader.bits(slen1));

                for (3..6) |sfb| {

                    for (0..3) |window| self.scalefac_s[granule][channel][sfb][window] = @intCast(reader.bits(slen1));

                }

                for (6..12) |sfb| {

                    for (0..3) |window| self.scalefac_s[granule][channel][sfb][window] = @intCast(reader.bits(slen2));

                }

            } else {

                for (0..6) |sfb| {

                    for (0..3) |window| self.scalefac_s[granule][channel][sfb][window] = @intCast(reader.bits(slen1));

                }

                for (6..12) |sfb| {

                    for (0..3) |window| self.scalefac_s[granule][channel][sfb][window] = @intCast(reader.bits(slen2));

                }

            }

            for (0..3) |window| self.scalefac_s[granule][channel][12][window] = 0;

            return;

        }

        const groups = [4][2]usize{ .{ 0, 6 }, .{ 6, 11 }, .{ 11, 16 }, .{ 16, 21 } };

        for (groups, 0..) |group, band| {

            const width: u6 = if (band < 2) slen1 else slen2;

            if (granule == 1 and self.side.scfsi[channel][band]) {

                for (group[0]..group[1]) |sfb| {

                    self.scalefac_l[granule][channel][sfb] = self.scalefac_l[0][channel][sfb];

                }

                continue;

            }

            for (group[0]..group[1]) |sfb| {

                self.scalefac_l[granule][channel][sfb] = @intCast(reader.bits(width));

            }

        }

        for (21..23) |sfb| self.scalefac_l[granule][channel][sfb] = 0;

    }

    // Huffman-coded frequency lines.

    fn read_lines(self: *Decoder, reader: *BitReader, header: *const Header, granule: usize, channel: usize, stop_bit: usize) void {

        const info = &self.side.granules[granule][channel];
        const lines = &self.lines[granule][channel];

        @memset(lines, 0);

        info.nonzero = 0;

        if (info.part2_3_length == 0) return;

        const bands = &tables.sf_bands[header.sample_rate_index];

        var region1: usize = 0;
        var region2: usize = 0;

        if (info.window_switching and info.block_type == 2) {

            region1 = 36;
            region2 = granule_lines;

        } else {

            region1 = bands.long[@min(info.region0_count + 1, 22)];
            region2 = bands.long[@min(@as(usize, info.region0_count) + info.region1_count + 2, 22)];

        }

        var position: usize = 0;
        const big = @min(@as(usize, info.big_values) * 2, granule_lines);

        while (position < big) : (position += 2) {

            const table: usize = if (position < region1)
                info.table_select[0]
            else if (position < region2)
                info.table_select[1]
            else
                info.table_select[2];

            const pair = decode_pair(reader, table);

            lines[position] = @floatFromInt(pair[0]);
            lines[position + 1] = @floatFromInt(pair[1]);

        }

        const count1_table: usize = 32 + info.count1_table;

        while (position + 4 <= granule_lines and reader.pos < stop_bit) {

            const quad = decode_quad(reader, count1_table);

            if (reader.pos > stop_bit) break;

            lines[position] = @floatFromInt(quad[0]);
            lines[position + 1] = @floatFromInt(quad[1]);
            lines[position + 2] = @floatFromInt(quad[2]);
            lines[position + 3] = @floatFromInt(quad[3]);

            position += 4;

        }

        info.nonzero = @min(position, granule_lines);

    }

    // Requantization: quantized value ^ (4/3), scaled by the granule gain and scalefactors.

    fn requantize(self: *Decoder, header: *const Header, granule: usize, channel: usize) void {

        const info = &self.side.granules[granule][channel];
        const bands = &tables.sf_bands[header.sample_rate_index];
        const limit = info.nonzero;

        if (info.window_switching and info.block_type == 2) {

            var position: usize = 0;
            var sfb: usize = 0;

            if (info.mixed_block) {

                var next = bands.long[1];

                while (position < 36 and position < limit) : (position += 1) {

                    if (position == next) {

                        sfb += 1;
                        next = bands.long[@min(sfb + 1, 22)];

                    }

                    self.scale_long(info, granule, channel, position, sfb);

                }

                position = 36;
                sfb = 3;

            }

            var next = @as(usize, bands.short[sfb + 1]) * 3;
            var width = bands.short[sfb + 1] - bands.short[sfb];

            while (position < limit) {

                if (position == next) {

                    sfb += 1;

                    if (sfb + 1 >= bands.short.len) break;

                    next = @as(usize, bands.short[sfb + 1]) * 3;
                    width = bands.short[sfb + 1] - bands.short[sfb];

                }

                for (0..3) |window| {

                    for (0..width) |_| {

                        if (position >= limit) break;

                        self.scale_short(info, granule, channel, position, sfb, window);
                        position += 1;

                    }

                }

            }

            return;

        }

        var sfb: usize = 0;
        var next = bands.long[1];

        for (0..limit) |position| {

            if (position == next) {

                sfb += 1;
                next = bands.long[@min(sfb + 1, 22)];

            }

            self.scale_long(info, granule, channel, position, sfb);

        }

    }

    fn scale_long(self: *Decoder, info: *const Granule, granule: usize, channel: usize, position: usize, sfb: usize) void {

        const pretab = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0, 0 };
        const multiplier: f32 = if (info.scalefac_scale) 1.0 else 0.5;
        const preemphasis: f32 = if (info.preflag) pretab[@min(sfb, 22)] else 0;
        const scalefac: f32 = @floatFromInt(self.scalefac_l[granule][channel][@min(sfb, 22)]);

        const scale = std.math.exp2(-multiplier * (scalefac + preemphasis));
        const gain = gain_scale(info.global_gain);

        self.lines[granule][channel][position] = scale * gain * pow43(self.lines[granule][channel][position]);

    }

    fn scale_short(self: *Decoder, info: *const Granule, granule: usize, channel: usize, position: usize, sfb: usize, window: usize) void {

        const multiplier: f32 = if (info.scalefac_scale) 1.0 else 0.5;
        const scalefac: f32 = @floatFromInt(self.scalefac_s[granule][channel][@min(sfb, 12)][window]);

        const scale = std.math.exp2(-multiplier * scalefac);
        const gain = std.math.exp2(0.25 * (@as(f32, @floatFromInt(info.global_gain)) - 210.0 - 8.0 * @as(f32, @floatFromInt(info.subblock_gain[window]))));

        self.lines[granule][channel][position] = scale * gain * pow43(self.lines[granule][channel][position]);

    }

    // Short blocks arrive grouped by window; interleave them back into frequency order.

    fn reorder(self: *Decoder, header: *const Header, granule: usize, channel: usize) void {

        const info = &self.side.granules[granule][channel];

        if (!(info.window_switching and info.block_type == 2)) return;

        const bands = &tables.sf_bands[header.sample_rate_index];
        const lines = &self.lines[granule][channel];

        var scratch: [granule_lines]f32 = undefined;

        var sfb: usize = if (info.mixed_block) 3 else 0;
        var position: usize = if (info.mixed_block) 36 else 0;

        // Bands run to 12 inclusive: band 12 covers the top 168 lines of the granule.
        while (sfb < 13) : (sfb += 1) {

            const start = @as(usize, bands.short[sfb]) * 3;
            const width = bands.short[sfb + 1] - bands.short[sfb];
            const span = width * 3;

            if (start + span > granule_lines) break;

            for (0..3) |window| {

                for (0..width) |index| {

                    scratch[index * 3 + window] = lines[position];
                    position += 1;

                }

            }

            @memcpy(lines[start..][0..span], scratch[0..span]);

        }

    }

    // Joint-stereo recovery.

    fn stereo(self: *Decoder, header: *const Header, granule: usize) void {

        if (header.mode != .joint_stereo or header.mode_extension == 0) return;

        const bands = &tables.sf_bands[header.sample_rate_index];
        const left = &self.lines[granule][0];
        const right = &self.lines[granule][1];

        if (header.mode_extension & 1 != 0) {

            const bound = self.side.granules[granule][1].nonzero;
            const info = &self.side.granules[granule][0];

            if (info.window_switching and info.block_type == 2) {

                if (info.mixed_block) {

                    for (0..8) |sfb| {

                        if (bands.long[sfb] >= bound) self.intensity_long(header, granule, sfb);

                    }

                    for (3..12) |sfb| {

                        if (@as(usize, bands.short[sfb]) * 3 >= bound) self.intensity_short(header, granule, sfb);

                    }

                } else {

                    for (0..12) |sfb| {

                        if (@as(usize, bands.short[sfb]) * 3 >= bound) self.intensity_short(header, granule, sfb);

                    }

                }

            } else {

                for (0..21) |sfb| {

                    if (bands.long[sfb] >= bound) self.intensity_long(header, granule, sfb);

                }

            }

        }

        if (header.mode_extension & 2 != 0) {

            // Reorder affects all lines in a band, not just up to each channel's rzero bound.
            const inverse_root_two: f32 = 0.70710678;

            for (0..granule_lines) |index| {

                const mid = left[index];
                const side = right[index];

                left[index] = (mid + side) * inverse_root_two;
                right[index] = (mid - side) * inverse_root_two;

            }

        }

    }

    fn intensity_long(self: *Decoder, header: *const Header, granule: usize, sfb: usize) void {

        // The intensity position rides in the right channel's scalefactors; 7 means "not intensity".
        const position = self.scalefac_l[granule][1][sfb];

        if (position == 7) return;

        const bands = &tables.sf_bands[header.sample_rate_index];
        const ratio = intensity_ratio(position);

        for (bands.long[sfb]..bands.long[sfb + 1]) |index| {

            const value = self.lines[granule][0][index];

            self.lines[granule][0][index] = value * ratio[0];
            self.lines[granule][1][index] = value * ratio[1];

        }

    }

    fn intensity_short(self: *Decoder, header: *const Header, granule: usize, sfb: usize) void {

        const bands = &tables.sf_bands[header.sample_rate_index];
        const width = bands.short[sfb + 1] - bands.short[sfb];

        for (0..3) |window| {

            const position = self.scalefac_s[granule][1][sfb][window];

            if (position == 7) continue;

            const ratio = intensity_ratio(position);
            const start = @as(usize, bands.short[sfb]) * 3 + width * window;

            for (start..@min(start + width, granule_lines)) |index| {

                const value = self.lines[granule][0][index];

                self.lines[granule][0][index] = value * ratio[0];
                self.lines[granule][1][index] = value * ratio[1];

            }

        }

    }

    fn antialias(self: *Decoder, granule: usize, channel: usize) void {

        const info = &self.side.granules[granule][channel];
        const short = info.window_switching and info.block_type == 2;

        if (short and !info.mixed_block) return;

        const limit: usize = if (short) 2 else 32;
        const lines = &self.lines[granule][channel];

        var subband: usize = 1;

        while (subband < limit) : (subband += 1) {

            for (0..8) |index| {

                const lower = 18 * subband - 1 - index;
                const upper = 18 * subband + index;

                const a = lines[lower];
                const b = lines[upper];

                lines[lower] = a * tables.alias_cs[index] - b * tables.alias_ca[index];
                lines[upper] = b * tables.alias_cs[index] + a * tables.alias_ca[index];

            }

        }

    }

    fn hybrid(self: *Decoder, granule: usize, channel: usize) void {

        const info = &self.side.granules[granule][channel];
        const lines = &self.lines[granule][channel];

        var raw: [36]f32 = undefined;

        for (0..32) |subband| {

            const block: u8 = if (info.window_switching and info.mixed_block and subband < 2) 0 else info.block_type;

            imdct(lines[subband * 18 ..][0..18], &raw, block);

            for (0..18) |index| {

                lines[subband * 18 + index] = raw[index] + self.overlap[channel][subband][index];
                self.overlap[channel][subband][index] = raw[index + 18];

            }

        }

    }

    fn frequency_inversion(self: *Decoder, granule: usize, channel: usize) void {

        const lines = &self.lines[granule][channel];

        var subband: usize = 1;

        while (subband < 32) : (subband += 2) {

            var index: usize = 1;

            while (index < 18) : (index += 2) {

                lines[subband * 18 + index] = -lines[subband * 18 + index];

            }

        }

    }

    // Polyphase synthesis: 32 subbands to 32 time samples, 18 times per granule.

    fn synthesize(self: *Decoder, granule: usize, channel: usize, channels: u16, out: []i16) void {

        const lines = &self.lines[granule][channel];
        const v = &self.synth[channel];

        var subband_samples: [32]f32 = undefined;
        var windowed: [512]f32 = undefined;

        for (0..18) |slot| {

            for (0..32) |index| subband_samples[index] = lines[index * 18 + slot];

            self.synth_head[channel] = (self.synth_head[channel] + 1024 - 64) & 1023;

            const head = self.synth_head[channel];

            for (0..64) |row| {

                var sum: f32 = 0;

                for (0..32) |column| sum += synth_matrix[row][column] * subband_samples[column];

                v[(head + row) & 1023] = sum;

            }

            for (0..8) |block| {

                for (0..32) |index| {

                    windowed[(block << 6) + index] = v[(head + (block << 7) + index) & 1023];
                    windowed[(block << 6) + index + 32] = v[(head + (block << 7) + index + 96) & 1023];

                }

            }

            for (0..512) |index| windowed[index] *= tables.synth_window[index];

            for (0..32) |index| {

                var sum: f32 = 0;

                for (0..16) |block| sum += windowed[(block << 5) + index];

                const frame = granule * 576 + slot * 32 + index;

                out[frame * channels + channel] = clamp_sample(sum);

            }

        }

    }

};

fn clamp_sample(value: f32) i16 {

    const scaled = value * 32767.0;

    if (scaled >= 32767.0) return 32767;
    if (scaled <= -32768.0) return -32768;

    return @intFromFloat(scaled);

}

fn intensity_ratio(position: u8) [2]f32 {

    // position 6 is tan(pi/2): all energy to the left channel.
    if (position == 6) return .{ 1.0, 0.0 };

    const ratio = tables.intensity_ratios[@min(position, 5)];

    return .{ ratio / (1.0 + ratio), 1.0 / (1.0 + ratio) };

}

// Huffman tables are 16-bit binary trees; high byte zero marks a leaf.

fn walk_tree(reader: *BitReader, table: usize) u16 {

    const entry = tables.huffman_tables[table];

    if (entry.tree_len == 0) return 0;

    const tree = tables.huffman_tree[entry.offset..][0..entry.tree_len];

    var point: usize = 0;
    var guard: usize = 32;

    while (guard > 0) : (guard -= 1) {

        if (tree[point] & 0xff00 == 0) return tree[point];

        // Hops of 250 or more are chained: keep stepping until the final hop lands.
        if (reader.bit() != 0) {

            while ((tree[point] & 0xff) >= 250) point += tree[point] & 0xff;

            point += tree[point] & 0xff;

        } else {

            while ((tree[point] >> 8) >= 250) point += tree[point] >> 8;

            point += tree[point] >> 8;

        }

        if (point >= tree.len) return 0;

    }

    return 0;

}

fn decode_pair(reader: *BitReader, table: usize) [2]i32 {

    const leaf = walk_tree(reader, table);
    const linbits: u6 = @intCast(tables.huffman_tables[table].linbits);

    var x: i32 = @intCast((leaf >> 4) & 0xf);
    var y: i32 = @intCast(leaf & 0xf);

    if (linbits > 0 and x == 15) x += @intCast(reader.bits(linbits));
    if (x != 0 and reader.bit() != 0) x = -x;

    if (linbits > 0 and y == 15) y += @intCast(reader.bits(linbits));
    if (y != 0 and reader.bit() != 0) y = -y;

    return .{ x, y };

}

fn decode_quad(reader: *BitReader, table: usize) [4]i32 {

    const leaf = walk_tree(reader, table);

    var values = [4]i32{

        @intCast((leaf >> 3) & 1),
        @intCast((leaf >> 2) & 1),
        @intCast((leaf >> 1) & 1),
        @intCast(leaf & 1),

    };

    for (&values) |*value| {

        if (value.* != 0 and reader.bit() != 0) value.* = -value.*;

    }

    return values;

}

// Derived tables. Built once on first `Decoder.init`; the decode path is single-threaded.

var tables_ready = false;

var pow43_lut: [pow43_size]f32 = undefined;
var gain_lut: [256]f32 = undefined;
var imdct_window: [4][36]f32 = undefined;
var cos_long: [18][36]f32 = undefined;
var cos_short: [6][12]f32 = undefined;
var synth_matrix: [64][32]f32 = undefined;

const pow43_size = 8207;

fn ensure_tables() void {

    if (tables_ready) return;

    for (&pow43_lut, 0..) |*slot, index| {

        slot.* = std.math.pow(f32, @floatFromInt(index), 4.0 / 3.0);

    }

    for (&gain_lut, 0..) |*slot, index| {

        slot.* = std.math.exp2(0.25 * (@as(f32, @floatFromInt(index)) - 210.0));

    }

    const pi: f32 = std.math.pi;

    for (0..36) |index| {

        const offset: f32 = @as(f32, @floatFromInt(index)) + 0.5;

        imdct_window[0][index] = @sin(pi / 36.0 * offset);

        imdct_window[1][index] = if (index < 18)
            @sin(pi / 36.0 * offset)
        else if (index < 24)
            1.0
        else if (index < 30)
            @sin(pi / 12.0 * (offset - 18.0))
        else
            0.0;

        imdct_window[2][index] = if (index < 12) @sin(pi / 12.0 * offset) else 0.0;

        imdct_window[3][index] = if (index < 6)
            0.0
        else if (index < 12)
            @sin(pi / 12.0 * (offset - 6.0))
        else if (index < 18)
            1.0
        else
            @sin(pi / 36.0 * offset);

    }

    for (0..18) |m| {

        for (0..36) |p| {

            const a: f32 = @floatFromInt(2 * p + 1 + 18);
            const b: f32 = @floatFromInt(2 * m + 1);

            cos_long[m][p] = @cos(pi / 72.0 * a * b);

        }

    }

    for (0..6) |m| {

        for (0..12) |p| {

            const a: f32 = @floatFromInt(2 * p + 1 + 6);
            const b: f32 = @floatFromInt(2 * m + 1);

            cos_short[m][p] = @cos(pi / 24.0 * a * b);

        }

    }

    for (0..64) |row| {

        for (0..32) |column| {

            const a: f32 = @floatFromInt(16 + row);
            const b: f32 = @floatFromInt(2 * column + 1);

            synth_matrix[row][column] = @cos(a * b * (pi / 64.0));

        }

    }

    tables_ready = true;

}

fn pow43(value: f32) f32 {

    const magnitude = @abs(value);
    const index: usize = @intFromFloat(magnitude);

    const result = if (index < pow43_size) pow43_lut[index] else std.math.pow(f32, magnitude, 4.0 / 3.0);

    return if (value < 0) -result else result;

}

fn gain_scale(global_gain: u32) f32 {

    return gain_lut[@min(global_gain, 255)];

}

fn imdct(input: []const f32, out: *[36]f32, block_type: u8) void {

    @memset(out, 0);

    if (block_type == 2) {

        for (0..3) |window| {

            for (0..12) |p| {

                var sum: f32 = 0;

                for (0..6) |m| sum += input[window + 3 * m] * cos_short[m][p];

                out[6 * window + p + 6] += sum * imdct_window[2][p];

            }

        }

        return;

    }

    for (0..36) |p| {

        var sum: f32 = 0;

        for (0..18) |m| sum += input[m] * cos_long[m][p];

        out[p] = sum * imdct_window[block_type][p];

    }

}

const testing = std.testing;

test "parses a layer III frame header" {

    // 44.1 kHz, 128 kbit/s, joint stereo, no CRC.
    const bytes = [_]u8{ 0xff, 0xfb, 0x90, 0x64 };
    const header = parse_header(&bytes).?;

    try testing.expectEqual(Version.mpeg1, header.version);
    try testing.expectEqual(@as(u32, 44100), header.sample_rate());
    try testing.expectEqual(@as(u32, 128000), header.bitrate());
    try testing.expectEqual(Mode.joint_stereo, header.mode);
    try testing.expectEqual(@as(usize, 417), header.frame_size());
    try testing.expectEqual(@as(u16, 2), header.channels());

}

test "rejects non-layer-III and reserved headers" {

    try testing.expect(parse_header(&[_]u8{ 0xff, 0xfd, 0x90, 0x64 }) == null); // layer II
    try testing.expect(parse_header(&[_]u8{ 0xff, 0xf3, 0x00, 0x64 }) == null); // free bitrate
    try testing.expect(parse_header(&[_]u8{ 0xff, 0xfb, 0x9c, 0x64 }) == null); // reserved rate
    try testing.expect(parse_header(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }) == null);

}

test "bit reader crosses byte boundaries" {

    var reader = BitReader{ .bytes = &[_]u8{ 0b1010_1100, 0b0111_0001 } };

    try testing.expectEqual(@as(u32, 0b101), reader.bits(3));
    try testing.expectEqual(@as(u32, 0b01100011), reader.bits(8));
    try testing.expectEqual(@as(u32, 0b10001), reader.bits(5));
    try testing.expect(reader.exhausted());

}

test "huffman tables stay inside the shared tree array" {

    for (tables.huffman_tables) |entry| {

        try testing.expect(entry.offset + entry.tree_len <= tables.huffman_tree.len);

    }

}

test "huffman table 1 decodes its four code words" {

    // Table 1 codes: (0,0)=1, (1,0)=01, (0,1)=001, (1,1)=000. Signs follow each non-zero value.
    const cases = [_]struct { bits: []const u8, x: i32, y: i32 }{

        .{ .bits = "1", .x = 0, .y = 0 },
        .{ .bits = "011", .x = -1, .y = 0 },
        .{ .bits = "0010", .x = 0, .y = 1 },
        .{ .bits = "00001", .x = 1, .y = -1 },

    };

    for (cases) |case| {

        var storage = [_]u8{0} ** 4;

        for (case.bits, 0..) |character, index| {

            if (character == '1') storage[index >> 3] |= @as(u8, 0x80) >> @intCast(index & 7);

        }

        var reader = BitReader{ .bytes = &storage };
        const pair = decode_pair(&reader, 1);

        try testing.expectEqual(case.x, pair[0]);
        try testing.expectEqual(case.y, pair[1]);
        try testing.expectEqual(case.bits.len, reader.pos);

    }

}

test "count1 table 33 decodes a fixed four-bit quadruple" {

    // Table 33: 4-bit code is 15-value; sign bits follow non-zero nibbles.
    var storage = [_]u8{ 0b1010_0100, 0 };
    var reader = BitReader{ .bytes = &storage };

    const quad = decode_quad(&reader, 33);

    try testing.expectEqual(@as(i32, 0), quad[0]);
    try testing.expectEqual(@as(i32, 1), quad[1]);
    try testing.expectEqual(@as(i32, 0), quad[2]);
    try testing.expectEqual(@as(i32, -1), quad[3]);
    try testing.expectEqual(@as(usize, 6), reader.pos);

}
