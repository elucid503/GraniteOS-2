// Image provider: decode PNG to XRGB, plus 1:1 blit and cover/contain scaling.

const std = @import("std");

const draw = @import("draw.zig");
const png = @import("png.zig");

const Color = draw.Color;
const Rect = draw.Rect;
const Surface = draw.Surface;

pub const Error = error{

    BadImage,
    Unsupported,
    OutOfMemory,
    Truncated,

};

pub const Format = enum {

    png,

};

/// Owned XRGB pixel buffer from a decoded image file.
pub const Buffer = struct {

    pixels: []u32,
    width: u32,
    height: u32,

    pub fn surface(self: *const Buffer) Surface {

        return Surface.from_pixels(self.pixels.ptr, self.width, self.height);

    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {

        if (self.pixels.len != 0) allocator.free(self.pixels);

        self.* = .{ .pixels = &.{}, .width = 0, .height = 0 };

    }

};

/// Sniff a supported on-disk image format from magic bytes.
pub fn detect(bytes: []const u8) ?Format {

    if (png.matches(bytes)) return .png;

    return null;

}

/// Decode any supported image format into an owned XRGB buffer.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Buffer {

    return switch (detect(bytes) orelse return error.Unsupported) {

        .png => map_png(png.decode(allocator, bytes)),

    };

}

/// Read width/height without fully decoding pixels when possible.
pub fn dimensions(bytes: []const u8) Error!struct { width: u32, height: u32 } {

    return switch (detect(bytes) orelse return error.Unsupported) {

        .png => map_png_dim(png.dimensions(bytes)),

    };

}

fn map_png(result: png.Error!png.Image) Error!Buffer {

    const image = result catch |err| return map_png_err(err);

    return .{

        .pixels = image.pixels,
        .width = image.width,
        .height = image.height,

    };

}

fn map_png_dim(result: png.Error!struct { width: u32, height: u32 }) Error!struct { width: u32, height: u32 } {

    return result catch |err| map_png_err(err);

}

fn map_png_err(err: png.Error) Error {

    return switch (err) {

        error.BadPng => error.BadImage,
        error.Unsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
        error.Truncated => error.Truncated,

    };

}

pub const Image = struct {

    pixels: []const u32,
    width: u32,
    height: u32,

    pub fn from_buffer(buffer: anytype) Image {

        return .{

            .pixels = buffer.pixels,
            .width = buffer.width,
            .height = buffer.height,

        };

    }

    /// Prefer `from_buffer`; kept for call-site compatibility.
    pub fn from_png(image: anytype) Image {

        return from_buffer(image);

    }

    pub fn from_pixels(pixels: []const u32, width: u32, height: u32) Image {

        return .{ .pixels = pixels, .width = width, .height = height };

    }

    pub fn is_empty(self: Image) bool {

        return self.width == 0 or self.height == 0 or self.pixels.len == 0;

    }

    pub fn get(self: Image, x: u32, y: u32) Color {

        return self.pixels[@as(usize, y) * self.width + x];

    }

    /// Copy 1:1 into `dest` at (`x`, `y`), clipped to the surface.
    pub fn blit(self: Image, surface: *const Surface, x: i32, y: i32) void {

        if (self.is_empty()) return;

        const dest = Rect.make(x, y, @intCast(self.width), @intCast(self.height)).intersect(surface.clip.intersect(surface.bounds()));

        if (dest.is_empty()) return;

        const src_x0: u32 = @intCast(dest.x - x);
        const src_y0: u32 = @intCast(dest.y - y);

        var row: i32 = 0;

        while (row < dest.h) : (row += 1) {

            const sy: u32 = src_y0 + @as(u32, @intCast(row));
            const dy: u32 = @intCast(dest.y + row);
            const src_off = @as(usize, sy) * self.width + src_x0;
            const dst_off = @as(usize, dy) * surface.stride + @as(usize, @intCast(dest.x));
            const count: usize = @intCast(dest.w);

            @memcpy(surface.pixels[dst_off .. dst_off + count], self.pixels[src_off .. src_off + count]);

        }

    }

    /// Scale with contain-fit into `dest`: the full image is visible, letterboxed if aspect differs.
    pub fn draw_fit(self: Image, surface: *const Surface, dest: Rect) void {

        if (self.is_empty() or dest.is_empty()) return;

        const fitted = fit_rect(self.width, self.height, dest);

        if (fitted.is_empty()) return;

        self.draw_scaled(surface, fitted);

    }

    /// Scale with cover-fit into `dest`: the image fully covers the rect, cropped centered if needed.
    pub fn draw_cover(self: Image, surface: *const Surface, dest: Rect) void {

        if (self.is_empty() or dest.is_empty()) return;

        const crop = cover_crop(self.width, self.height, @intCast(dest.w), @intCast(dest.h));

        scale_blit(self, surface, dest, crop);

    }

    fn draw_scaled(self: Image, surface: *const Surface, dest: Rect) void {

        if (self.is_empty() or dest.is_empty()) return;

        const crop = Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };

        scale_blit(self, surface, dest, crop);

    }

};

fn scale_blit(self: Image, surface: *const Surface, dest: Rect, crop: Rect) void {

    const clipped = dest.intersect(surface.clip.intersect(surface.bounds()));

    if (clipped.is_empty() or crop.w <= 0 or crop.h <= 0) return;

    // 16.16 fixed steps map destination pixels onto the source without per-pixel division.
    const step_x: i64 = @divTrunc(@as(i64, crop.w) << 16, dest.w);
    const step_y: i64 = @divTrunc(@as(i64, crop.h) << 16, dest.h);
    const origin_x: i64 = (@as(i64, crop.x) << 16) + (@as(i64, clipped.x - dest.x) * step_x);
    const origin_y: i64 = (@as(i64, crop.y) << 16) + (@as(i64, clipped.y - dest.y) * step_y);
    const max_x: u32 = self.width - 1;
    const max_y: u32 = self.height - 1;

    var y = clipped.y;
    var src_y_fx = origin_y;

    while (y < clipped.y + clipped.h) {

        const sy: u32 = @intCast(@min(@max(@as(i32, @intCast(src_y_fx >> 16)), 0), @as(i32, @intCast(max_y))));
        const dy: u32 = @intCast(y);
        const src_row = @as(usize, sy) * self.width;
        const dst_row = @as(usize, dy) * surface.stride;

        var x = clipped.x;
        var src_x_fx = origin_x;

        while (x < clipped.x + clipped.w) {

            const sx: u32 = @intCast(@min(@max(@as(i32, @intCast(src_x_fx >> 16)), 0), @as(i32, @intCast(max_x))));

            surface.pixels[dst_row + @as(usize, @intCast(x))] = self.pixels[src_row + sx];

            x += 1;
            src_x_fx += step_x;

        }

        y += 1;
        src_y_fx += step_y;

    }

}

/// Destination rect for contain-fit of an image of `src_w` x `src_h` into `frame`.
pub fn fit_rect(src_w: u32, src_h: u32, frame: Rect) Rect {

    if (src_w == 0 or src_h == 0 or frame.is_empty()) return Rect.empty;

    const src_w_i: i64 = src_w;
    const src_h_i: i64 = src_h;
    const frame_w: i64 = frame.w;
    const frame_h: i64 = frame.h;

    var out_w: i32 = undefined;
    var out_h: i32 = undefined;

    if (src_w_i * frame_h > frame_w * src_h_i) {

        out_w = frame.w;
        out_h = @intCast(@divTrunc(frame_w * src_h_i, src_w_i));

    } else {

        out_h = frame.h;
        out_w = @intCast(@divTrunc(frame_h * src_w_i, src_h_i));

    }

    return .{

        .x = frame.x + @divTrunc(frame.w - out_w, 2),
        .y = frame.y + @divTrunc(frame.h - out_h, 2),
        .w = out_w,
        .h = out_h,

    };

}

/// Source crop rectangle (in image pixels) that cover-fits into a dest of `dst_w` x `dst_h`.
pub fn cover_crop(src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) Rect {

    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return Rect.empty;

    // Prefer cropping the axis where the source is relatively wider/taller than the destination.
    const src_w_i: i64 = src_w;
    const src_h_i: i64 = src_h;
    const dst_w_i: i64 = dst_w;
    const dst_h_i: i64 = dst_h;

    if (src_w_i * dst_h_i > dst_w_i * src_h_i) {

        const crop_w: i32 = @intCast(@divTrunc(src_h_i * dst_w_i, dst_h_i));
        const crop_x: i32 = @intCast(@divTrunc(@as(i64, src_w) - crop_w, 2));

        return .{ .x = crop_x, .y = 0, .w = crop_w, .h = @intCast(src_h) };

    }

    const crop_h: i32 = @intCast(@divTrunc(src_w_i * dst_h_i, dst_w_i));
    const crop_y: i32 = @intCast(@divTrunc(@as(i64, src_h) - crop_h, 2));

    return .{ .x = 0, .y = crop_y, .w = @intCast(src_w), .h = crop_h };

}

const testing = std.testing;

test "cover crop matches aspect without gaps" {

    // 16:9 source into 1:1 dest crops left/right.
    const square = cover_crop(1920, 1080, 800, 800);

    try testing.expectEqual(@as(i32, 1080), square.w);
    try testing.expectEqual(@as(i32, 1080), square.h);
    try testing.expectEqual(@as(i32, (1920 - 1080) / 2), square.x);
    try testing.expectEqual(@as(i32, 0), square.y);

    // 1:1 source into 16:9 dest crops top/bottom.
    const wide = cover_crop(1000, 1000, 1600, 900);

    try testing.expectEqual(@as(i32, 1000), wide.w);
    try testing.expectEqual(@as(i32, 562), wide.h); // 1000 * 900 / 1600
    try testing.expectEqual(@as(i32, 0), wide.x);
    try testing.expectEqual(@as(i32, (1000 - 562) / 2), wide.y);

}

test "image provider detects png only" {

    const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    const jpeg_sig = [_]u8{ 0xff, 0xd8, 0xff, 0xe0 };

    try testing.expect(detect(&png_sig) == .png);
    try testing.expect(detect(&jpeg_sig) == null);
    try testing.expect(detect(&[_]u8{ 1, 2, 3 }) == null);

}
