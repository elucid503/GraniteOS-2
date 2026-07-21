// PNG codec: decode/encode 8-bit images to XRGB; freestanding inflate via std.compress.flate, hand-rolled store deflate.

const std = @import("std");

const draw = @import("draw.zig");

pub const Error = error{

    BadPng,
    Unsupported,
    OutOfMemory,
    Truncated,

};

const signature = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn matches(bytes: []const u8) bool {

    return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &signature);

}

const color_grey: u8 = 0;
const color_rgb: u8 = 2;
const color_grey_a: u8 = 4;
const color_rgba: u8 = 6;

pub const Image = struct {

    pixels: []u32,
    width: u32,
    height: u32,

    pub fn surface(self: *const Image) draw.Surface {

        return draw.Surface.from_pixels(self.pixels.ptr, self.width, self.height);

    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {

        if (self.pixels.len != 0) allocator.free(self.pixels);

        self.* = .{ .pixels = &.{}, .width = 0, .height = 0 };

    }

};

const Header = struct {

    width: u32,
    height: u32,
    color_type: u8,

    fn bytes_per_pixel(self: Header) Error!u32 {

        return switch (self.color_type) {

            color_grey => 1,
            color_rgb => 3,
            color_grey_a => 2,
            color_rgba => 4,
            else => error.Unsupported,

        };

    }

    fn row_bytes(self: Header) Error!usize {

        const bpp = try self.bytes_per_pixel();

        return 1 + @as(usize, self.width) * bpp;

    }

};

/// Decode a complete PNG file into an owned XRGB pixel buffer (alpha blended over black).
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {

    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.BadPng;

    const header = try read_header(bytes);
    const bpp = try header.bytes_per_pixel();
    const stride = try header.row_bytes();
    const pixel_count = @as(usize, header.width) * @as(usize, header.height);

    if (pixel_count == 0) return error.BadPng;
    if (pixel_count > std.math.maxInt(usize) / @sizeOf(u32)) return error.OutOfMemory;

    const idat = try collect_idat(allocator, bytes);
    defer allocator.free(idat);

    if (idat.len == 0) return error.BadPng;

    // Scanline decode limits RAM; inflate window on heap to avoid 512 KiB on the user stack.
    const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    const prev = allocator.alloc(u8, stride) catch return error.OutOfMemory;
    defer allocator.free(prev);

    const curr = allocator.alloc(u8, stride) catch return error.OutOfMemory;
    defer allocator.free(curr);

    const window = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer allocator.free(window);

    @memset(prev, 0);

    var input: std.Io.Reader = .fixed(idat);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, window);

    var y: u32 = 0;

    while (y < header.height) : (y += 1) {

        inflate.reader.readSliceAll(curr[0..stride]) catch return error.BadPng;

        unfilter(curr[0..stride], prev[0..stride], bpp) catch return error.BadPng;

        const dest_row = pixels[@as(usize, y) * header.width ..][0..header.width];

        convert_row(curr[1..], dest_row, header.color_type);
        @memcpy(prev, curr);

    }

    return .{

        .pixels = pixels,
        .width = header.width,
        .height = header.height,

    };

}

/// Read width/height without decoding pixels.
pub fn dimensions(bytes: []const u8) Error!struct { width: u32, height: u32 } {

    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return error.BadPng;

    const header = try read_header(bytes);

    return .{ .width = header.width, .height = header.height };

}

/// Upper bound on encode output size for a width×height XRGB image (filter-None + zlib store).
pub fn max_encode_size(width: u32, height: u32) usize {

    const row_stride = 1 + @as(usize, width) * 3;
    const raw_len = row_stride * @as(usize, height);
    const max_store = 65535;
    const block_count = if (raw_len == 0) 0 else (raw_len + max_store - 1) / max_store;
    const zlib_len = 2 + block_count * 5 + raw_len + 4;

    // signature + IHDR(25) + IDAT(12+zlib) + IEND(12)
    return 8 + 25 + 12 + zlib_len + 12;

}

/// Scratch bytes needed for the filter-None raw scanline buffer.
pub fn raw_scratch_size(width: u32, height: u32) usize {

    return (1 + @as(usize, width) * 3) * @as(usize, height);

}

/// Encode into caller-owned scratch/dest buffers; returns the used prefix of dest.
pub fn encodeTo(dest: []u8, scratch: []u8, pixels: []const u32, width: u32, height: u32) Error![]u8 {

    if (width == 0 or height == 0) return error.BadPng;

    const pixel_count = @as(usize, width) * @as(usize, height);

    if (pixels.len < pixel_count) return error.BadPng;

    const row_stride = 1 + @as(usize, width) * 3;
    const raw_len = row_stride * @as(usize, height);

    if (scratch.len < raw_len) return error.OutOfMemory;
    if (dest.len < max_encode_size(width, height)) return error.OutOfMemory;

    const raw = scratch[0..raw_len];
    var raw_at: usize = 0;
    var y: u32 = 0;

    while (y < height) : (y += 1) {

        raw[raw_at] = 0; // filter None
        raw_at += 1;

        var x: u32 = 0;

        while (x < width) : (x += 1) {

            const pixel = pixels[@as(usize, y) * width + x];

            raw[raw_at] = draw.red(pixel);
            raw[raw_at + 1] = draw.green(pixel);
            raw[raw_at + 2] = draw.blue(pixel);
            raw_at += 3;

        }

    }

    // Batched Adler-32 (zlib's algorithm) — avoids per-byte modulo cost.
    const adler = adler32(raw);

    const max_store = 65535;
    const block_count = (raw_len + max_store - 1) / max_store;
    const zlib_len = 2 + block_count * 5 + raw_len + 4;
    const out_len = 8 + 25 + 12 + zlib_len + 12;

    if (dest.len < out_len) return error.OutOfMemory;

    const out = dest[0..out_len];
    var cursor: usize = 0;

    @memcpy(out[cursor..][0..8], &signature);
    cursor += 8;

    var ihdr: [13]u8 = undefined;

    write_be_u32(ihdr[0..4], width);
    write_be_u32(ihdr[4..8], height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = color_rgb;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    cursor = write_chunk(out, cursor, "IHDR", &ihdr);

    const idat_start = cursor;
    const idat_data_start = idat_start + 8;

    // zlib CMF/FLG: 0x78 0x01 (32K window, fastest; FCHECK makes 0x7801 % 31 == 0).
    out[idat_data_start] = 0x78;
    out[idat_data_start + 1] = 0x01;

    var zlib_cursor = idat_data_start + 2;
    var raw_offset: usize = 0;

    while (raw_offset < raw_len) {

        const chunk_len = @min(max_store, raw_len - raw_offset);
        const final = raw_offset + chunk_len == raw_len;

        // BFINAL | BTYPE=00, already byte-aligned (matches std.compress.flate store blocks).
        out[zlib_cursor] = if (final) 0x01 else 0x00;
        zlib_cursor += 1;

        const len16: u16 = @intCast(chunk_len);

        std.mem.writeInt(u16, out[zlib_cursor..][0..2], len16, .little);
        std.mem.writeInt(u16, out[zlib_cursor + 2 ..][0..2], ~len16, .little);
        zlib_cursor += 4;

        @memcpy(out[zlib_cursor .. zlib_cursor + chunk_len], raw[raw_offset .. raw_offset + chunk_len]);
        zlib_cursor += chunk_len;
        raw_offset += chunk_len;

    }

    // Adler-32 is big-endian in the zlib stream (RFC 1950).
    write_be_u32(out[zlib_cursor..][0..4], adler);
    zlib_cursor += 4;

    if (zlib_cursor - idat_data_start != zlib_len) return error.BadPng;

    const idat_len: u32 = @intCast(zlib_len);

    write_be_u32(out[idat_start..][0..4], idat_len);
    @memcpy(out[idat_start + 4 ..][0..4], "IDAT");

    const idat_crc = crc32(out[idat_start + 4 .. zlib_cursor]);

    write_be_u32(out[zlib_cursor..][0..4], idat_crc);
    cursor = zlib_cursor + 4;

    cursor = write_chunk(out, cursor, "IEND", &.{});

    if (cursor != out_len) return error.BadPng;

    return out[0..cursor];

}

/// Encode a complete RGB8 PNG file (owned slice; free with allocator).
pub fn encode(allocator: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) Error![]u8 {

    const scratch_len = raw_scratch_size(width, height);
    const dest_len = max_encode_size(width, height);

    const scratch = allocator.alloc(u8, scratch_len) catch return error.OutOfMemory;
    defer allocator.free(scratch);

    const dest = allocator.alloc(u8, dest_len) catch return error.OutOfMemory;

    const encoded = encodeTo(dest, scratch, pixels, width, height) catch |err| {

        allocator.free(dest);
        return err;

    };

    if (encoded.len == dest.len) return dest;

    // Prefer an exact-sized allocation so callers free the right length.
    const trimmed = allocator.alloc(u8, encoded.len) catch return dest[0..encoded.len];

    @memcpy(trimmed, encoded);
    allocator.free(dest);

    return trimmed;

}

fn write_chunk(out: []u8, start: usize, type_name: *const [4]u8, data: []const u8) usize {

    write_be_u32(out[start..][0..4], @intCast(data.len));
    @memcpy(out[start + 4 ..][0..4], type_name);
    if (data.len != 0) @memcpy(out[start + 8 ..][0..data.len], data);

    const crc_start = start + 4;
    const crc_end = start + 8 + data.len;
    const crc = crc32(out[crc_start..crc_end]);

    write_be_u32(out[crc_end..][0..4], crc);

    return crc_end + 4;

}

fn write_be_u32(dest: []u8, value: u32) void {

    std.mem.writeInt(u32, dest[0..4], value, .big);

}

fn crc32(bytes: []const u8) u32 {

    return std.hash.Crc32.hash(bytes);

}

/// RFC 1950 Adler-32 with the standard 5552-byte batching (fast, freestanding-safe).
fn adler32(data: []const u8) u32 {

    const base: u32 = 65521;
    const nmax: usize = 5552;

    var s1: u32 = 1;
    var s2: u32 = 0;
    var index: usize = 0;

    while (index + nmax <= data.len) {

        var n: usize = 0;

        while (n < nmax) : (n += 1) {

            s1 +%= data[index + n];
            s2 +%= s1;

        }

        s1 %= base;
        s2 %= base;
        index += nmax;

    }

    while (index < data.len) : (index += 1) {

        s1 +%= data[index];
        s2 +%= s1;

    }

    s1 %= base;
    s2 %= base;

    return (s2 << 16) | s1;

}

fn read_header(bytes: []const u8) Error!Header {

    var offset: usize = 8;

    while (offset + 12 <= bytes.len) {

        const length = read_be_u32(bytes, offset);
        const type_bytes = bytes[offset + 4 .. offset + 8];
        const data_start = offset + 8;
        const data_end = data_start + length;
        const chunk_end = data_end + 4;

        if (chunk_end > bytes.len) return error.Truncated;

        if (std.mem.eql(u8, type_bytes, "IHDR")) {

            if (length != 13) return error.BadPng;

            const width = read_be_u32(bytes, data_start);
            const height = read_be_u32(bytes, data_start + 4);
            const bit_depth = bytes[data_start + 8];
            const color_type = bytes[data_start + 9];
            const compression = bytes[data_start + 10];
            const filter_method = bytes[data_start + 11];
            const interlace = bytes[data_start + 12];

            if (width == 0 or height == 0) return error.BadPng;
            if (compression != 0 or filter_method != 0) return error.Unsupported;
            if (interlace != 0) return error.Unsupported;
            if (bit_depth != 8) return error.Unsupported;

            switch (color_type) {

                color_grey, color_rgb, color_grey_a, color_rgba => {},
                else => return error.Unsupported,

            }

            return .{

                .width = width,
                .height = height,
                .color_type = color_type,

            };

        }

        if (std.mem.eql(u8, type_bytes, "IEND")) return error.BadPng;

        offset = chunk_end;

    }

    return error.Truncated;

}

fn collect_idat(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {

    var total: usize = 0;
    var offset: usize = 8;

    while (offset + 12 <= bytes.len) {

        const length = read_be_u32(bytes, offset);
        const type_bytes = bytes[offset + 4 .. offset + 8];
        const data_end = offset + 8 + length;
        const chunk_end = data_end + 4;

        if (chunk_end > bytes.len) return error.Truncated;

        if (std.mem.eql(u8, type_bytes, "IDAT")) total += length;
        if (std.mem.eql(u8, type_bytes, "IEND")) break;

        offset = chunk_end;

    }

    const idat = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(idat);

    var written: usize = 0;
    offset = 8;

    while (offset + 12 <= bytes.len) {

        const length = read_be_u32(bytes, offset);
        const type_bytes = bytes[offset + 4 .. offset + 8];
        const data_start = offset + 8;
        const data_end = data_start + length;
        const chunk_end = data_end + 4;

        if (chunk_end > bytes.len) return error.Truncated;

        if (std.mem.eql(u8, type_bytes, "IDAT")) {

            @memcpy(idat[written .. written + length], bytes[data_start..data_end]);
            written += length;

        }

        if (std.mem.eql(u8, type_bytes, "IEND")) break;

        offset = chunk_end;

    }

    return idat;

}

fn unfilter(row: []u8, prev: []const u8, bpp: u32) Error!void {

    if (row.len == 0) return error.BadPng;

    const filter = row[0];
    const data = row[1..];
    const prev_data = prev[1..];
    const bpp_usize: usize = bpp;

    switch (filter) {

        0 => {},

        1 => {

            var i: usize = bpp_usize;

            while (i < data.len) : (i += 1) {

                data[i] +%= data[i - bpp_usize];

            }

        },

        2 => {

            for (data, prev_data) |*byte, up| {

                byte.* +%= up;

            }

        },

        3 => {

            var i: usize = 0;

            while (i < data.len) : (i += 1) {

                const left: u16 = if (i >= bpp_usize) data[i - bpp_usize] else 0;
                const up: u16 = prev_data[i];

                data[i] +%= @truncate((left + up) / 2);

            }

        },

        4 => {

            var i: usize = 0;

            while (i < data.len) : (i += 1) {

                const left: i32 = if (i >= bpp_usize) data[i - bpp_usize] else 0;
                const up: i32 = prev_data[i];
                const up_left: i32 = if (i >= bpp_usize) prev_data[i - bpp_usize] else 0;

                data[i] +%= paeth(left, up, up_left);

            }

        },

        else => return error.BadPng,

    }

    row[0] = 0;

}

fn paeth(a: i32, b: i32, c: i32) u8 {

    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);

    return @intCast(c);

}

fn convert_row(src: []const u8, dest: []u32, color_type: u8) void {

    switch (color_type) {

        color_grey => {

            for (dest, 0..) |*pixel, i| {

                const g = src[i];

                pixel.* = draw.rgb(g, g, g);

            }

        },

        color_rgb => {

            var i: usize = 0;

            for (dest) |*pixel| {

                pixel.* = draw.rgb(src[i], src[i + 1], src[i + 2]);
                i += 3;

            }

        },

        color_grey_a => {

            var i: usize = 0;

            for (dest) |*pixel| {

                const g = src[i];
                const a = src[i + 1];

                pixel.* = draw.mix(0, draw.rgb(g, g, g), a);
                i += 2;

            }

        },

        color_rgba => {

            var i: usize = 0;

            for (dest) |*pixel| {

                const color = draw.rgb(src[i], src[i + 1], src[i + 2]);
                const a = src[i + 3];

                pixel.* = if (a == 255) color else draw.mix(0, color, a);
                i += 4;

            }

        },

        else => unreachable,

    }

}

fn read_be_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .big);

}

const testing = std.testing;

// 2x2 RGBA: red, green / blue, white (single IDAT).
const sample_png = [_]u8{
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,  73,  72,  68,  82,
    0,   0,   0,   2,   0,   0,   0,   2,   8,   6,   0,   0,   0,   114, 182, 13,
    36,  0,   0,   0,   18,  73,  68,  65,  84,  120, 218, 99,  248, 207, 192, 240,
    31,  12,  129, 52,  24,  0,   0,   73,  200, 9,   247, 3,   217, 100, 241, 0,
    0,   0,   0,   73,  69,  78,  68,  174, 66,  96,  130,
};

// Same image with the zlib stream split across two IDAT chunks.
const sample_png_split = [_]u8{
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,  73,  72,  68,  82,
    0,   0,   0,   2,   0,   0,   0,   2,   8,   6,   0,   0,   0,   114, 182, 13,
    36,  0,   0,   0,   9,   73,  68,  65,  84,  120, 218, 99,  248, 207, 192, 240,
    31,  12,  82,  41,  215, 47,  0,   0,   0,   9,   73,  68,  65,  84,  129, 52,
    24,  0,   0,   73,  200, 9,   247, 14,  19,  38,  200, 0,   0,   0,   0,   73,
    69,  78,  68,  174, 66,  96,  130,
};

test "png dimensions and decode rgba" {

    const size = try dimensions(&sample_png);

    try testing.expectEqual(@as(u32, 2), size.width);
    try testing.expectEqual(@as(u32, 2), size.height);

    var image = try decode(testing.allocator, &sample_png);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    try testing.expectEqual(draw.rgb(255, 0, 0), image.pixels[0]);
    try testing.expectEqual(draw.rgb(0, 255, 0), image.pixels[1]);
    try testing.expectEqual(draw.rgb(0, 0, 255), image.pixels[2]);
    try testing.expectEqual(draw.rgb(255, 255, 255), image.pixels[3]);

}

test "png decodes split idat streams" {

    var image = try decode(testing.allocator, &sample_png_split);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(draw.rgb(255, 0, 0), image.pixels[0]);
    try testing.expectEqual(draw.rgb(255, 255, 255), image.pixels[3]);

}

test "png rejects truncated and non-png input" {

    try testing.expectError(error.BadPng, dimensions(&[_]u8{ 1, 2, 3 }));

    // Signature + partial IHDR only — not enough to decode.
    try testing.expectError(error.Truncated, decode(testing.allocator, sample_png[0..20]));

}

test "png encode round-trips through decode" {

    const width: u32 = 3;
    const height: u32 = 2;
    const source = [_]u32{

        draw.rgb(10, 20, 30),
        draw.rgb(40, 50, 60),
        draw.rgb(70, 80, 90),
        draw.rgb(100, 110, 120),
        draw.rgb(130, 140, 150),
        draw.rgb(160, 170, 180),

    };

    const bytes = try encode(testing.allocator, &source, width, height);
    defer testing.allocator.free(bytes);

    var image = try decode(testing.allocator, bytes);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(width, image.width);
    try testing.expectEqual(height, image.height);

    for (source, image.pixels) |want, got| {

        try testing.expectEqual(want, got);

    }

}

test "png encode multi-store-block canvas size" {

    // Matches Chisel's 640x400 canvas — spans many zlib store blocks (>65535 bytes).
    const width: u32 = 640;
    const height: u32 = 400;
    const count = @as(usize, width) * height;
    const source = try testing.allocator.alloc(u32, count);
    defer testing.allocator.free(source);

    for (source, 0..) |*pixel, index| {

        const x: u32 = @intCast(index % width);
        const y: u32 = @intCast(index / width);

        pixel.* = draw.rgb(@truncate(x), @truncate(y), @truncate(x +% y));

    }

    const bytes = try encode(testing.allocator, source, width, height);
    defer testing.allocator.free(bytes);

    var image = try decode(testing.allocator, bytes);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(width, image.width);
    try testing.expectEqual(height, image.height);
    try testing.expectEqual(source[0], image.pixels[0]);
    try testing.expectEqual(source[count / 2], image.pixels[count / 2]);
    try testing.expectEqual(source[count - 1], image.pixels[count - 1]);

    // Spot-check a full row so multi-block boundaries cannot hide corruption.
    const row = height / 2;

    for (0..width) |x| {

        const index = @as(usize, row) * width + x;

        try testing.expectEqual(source[index], image.pixels[index]);

    }

}
