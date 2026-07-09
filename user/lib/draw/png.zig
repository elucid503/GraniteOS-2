// PNG decoder: IHDR + zlib IDAT streams into XRGB pixel buffers. Supports 8-bit greyscale, RGB,
// greyscale+alpha, and RGBA (no interlacing, no palette). Integer-only; freestanding-safe via std.compress.flate.

const std = @import("std");

const draw = @import("draw.zig");

pub const Error = error{

    BadPng,
    Unsupported,
    OutOfMemory,
    Truncated,

};

const signature = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

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

    // Stream one scanline at a time so peak RAM is pixels + IDAT + two rows (not a full filtered frame).
    const pixels = allocator.alloc(u32, pixel_count) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    const prev = allocator.alloc(u8, stride) catch return error.OutOfMemory;
    defer allocator.free(prev);

    const curr = allocator.alloc(u8, stride) catch return error.OutOfMemory;
    defer allocator.free(curr);

    @memset(prev, 0);

    var input: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);

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
