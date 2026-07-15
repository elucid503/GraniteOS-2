// Drawing library root: XRGB surfaces, colors, rects; integer fixed-point with optional NEON on hot paths.

const std = @import("std");
const builtin = @import("builtin");

pub const bitmap = @import("bitmap.zig");
pub const image = @import("image.zig");
pub const path = @import("path.zig");
pub const png = @import("png.zig");
pub const raster = @import("raster.zig");
pub const round = @import("round.zig");
pub const stroke = @import("stroke.zig");
pub const text = @import("text.zig");
pub const vector = @import("vector.zig");

/// 32-bit little-endian XRGB: blue in the low byte, the high byte ignored (proto.display.format_xrgb).
pub const Color = u32;

pub fn rgb(r: u8, g: u8, b: u8) Color {

    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;

}

pub fn red(color: Color) u8 {

    return @intCast((color >> 16) & 0xff);

}

pub fn green(color: Color) u8 {

    return @intCast((color >> 8) & 0xff);

}

pub fn blue(color: Color) u8 {

    return @intCast(color & 0xff);

}

/// Channel-wise blend of `src` over `dst` at `alpha` (0..255), rounding to nearest.
pub fn mix(dst: Color, src: Color, alpha: u8) Color {

    if (alpha == 0) return dst;
    if (alpha == 255) return src;

    const a: u32 = alpha;
    const inv = 255 - a;

    const r = divide_255(@as(u32, red(src)) * a + @as(u32, red(dst)) * inv);
    const g = divide_255(@as(u32, green(src)) * a + @as(u32, green(dst)) * inv);
    const b = divide_255(@as(u32, blue(src)) * a + @as(u32, blue(dst)) * inv);

    return rgb(@intCast(r), @intCast(g), @intCast(b));

}

fn divide_255(value: u32) u32 {

    const rounded = value + 128;

    return (rounded + (rounded >> 8)) >> 8;

}

const PixelVector = @Vector(4, u32);

fn mix_four(dst: PixelVector, src: PixelVector, alpha: PixelVector) PixelVector {

    const all: PixelVector = @splat(255);
    const inv = all - alpha;
    const mask: PixelVector = @splat(0xff);
    const rounding: PixelVector = @splat(128);

    var output: PixelVector = @splat(0);

    inline for (.{ 16, 8, 0 }) |shift| {

        const shifts: PixelVector = @splat(shift);
        const dst_channel = (dst >> shifts) & mask;
        const src_channel = (src >> shifts) & mask;
        const product = src_channel * alpha + dst_channel * inv;
        const rounded = product + rounding;
        const channel = (rounded + (rounded >> @as(PixelVector, @splat(8)))) >> @as(PixelVector, @splat(8));

        output |= channel << shifts;

    }

    return output;

}

/// Linear interpolation between two colors, t in 0..255.
pub fn lerp(from: Color, to: Color, t: u8) Color {

    return mix(from, to, t);

}

pub fn fence() void {

    if (comptime builtin.target.cpu.arch == .aarch64) {

        asm volatile ("dmb ish" ::: .{ .memory = true });

    }

}

pub const Rect = struct {

    x: i32,
    y: i32,

    w: i32,
    h: i32,

    pub const empty = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn make(x: i32, y: i32, w: i32, h: i32) Rect {

        return .{ .x = x, .y = y, .w = w, .h = h };

    }

    pub fn is_empty(self: Rect) bool {

        return self.w <= 0 or self.h <= 0;

    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {

        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;

    }

    pub fn intersect(a: Rect, b: Rect) Rect {

        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);

        if (x1 <= x0 or y1 <= y0) return empty;

        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };

    }

    /// The smallest rect covering both; damage tracking unions per-frame rects into one bound.
    pub fn cover(a: Rect, b: Rect) Rect {

        if (a.is_empty()) return b;
        if (b.is_empty()) return a;

        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);

        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };

    }

    pub fn translated(self: Rect, dx: i32, dy: i32) Rect {

        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w, .h = self.h };

    }

    pub fn inset(self: Rect, amount: i32) Rect {

        return .{ .x = self.x + amount, .y = self.y + amount, .w = self.w - 2 * amount, .h = self.h - 2 * amount };

    }

};

pub const Surface = struct {

    pixels: [*]u32,

    width: u32,
    height: u32,

    // In pixels, not bytes; rows may be padded (the scanout stride).
    stride: u32,

    // Every primitive clips to this rect as well as the surface bounds, so callers can scope painting to a pane.
    clip: Rect,

    pub fn from_base(base: usize, width: u32, height: u32, stride_bytes: u32) Surface {

        return .{

            .pixels = @ptrFromInt(base),

            .width = width,
            .height = height,

            .stride = stride_bytes / @sizeOf(u32),

            .clip = .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) },

        };

    }

    pub fn from_pixels(pixels: [*]u32, width: u32, height: u32) Surface {

        return .{

            .pixels = pixels,

            .width = width,
            .height = height,

            .stride = width,

            .clip = .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) },

        };

    }

    pub fn bounds(self: *const Surface) Rect {

        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };

    }

    /// A view of the same pixels with painting confined to `rect`; coordinates stay surface-absolute.
    pub fn clipped(self: *const Surface, rect: Rect) Surface {

        var view = self.*;

        view.clip = self.clip.intersect(rect);

        return view;

    }

    fn paint_bounds(self: *const Surface) Rect {

        return self.clip.intersect(self.bounds());

    }

    pub fn fill(self: *const Surface, color: Color) void {

        self.fill_rect(self.bounds(), color);

    }

    pub fn fill_rect(self: *const Surface, rect: Rect, color: Color) void {

        const clipped_rect = rect.intersect(self.paint_bounds());

        if (clipped_rect.is_empty()) return;

        var row: u32 = @intCast(clipped_rect.y);
        const first: u32 = @intCast(clipped_rect.x);
        const count: u32 = @intCast(clipped_rect.w);
        const last_row: u32 = @intCast(clipped_rect.y + clipped_rect.h);

        while (row < last_row) : (row += 1) {

            const start = row * self.stride + first;

            @memset(self.pixels[start .. start + count], color);

        }

    }

    pub fn stroke_rect(self: *const Surface, rect: Rect, width: i32, color: Color) void {

        if (width <= 0 or rect.w <= 0 or rect.h <= 0) return;

        const border = @min(width, @min(rect.w, rect.h));

        self.fill_rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = border }, color);
        self.fill_rect(.{ .x = rect.x, .y = rect.y + rect.h - border, .w = rect.w, .h = border }, color);
        self.fill_rect(.{ .x = rect.x, .y = rect.y, .w = border, .h = rect.h }, color);
        self.fill_rect(.{ .x = rect.x + rect.w - border, .y = rect.y, .w = border, .h = rect.h }, color);

    }

    pub fn fill_rect_alpha(self: *const Surface, rect: Rect, color: Color, alpha: u8) void {

        if (alpha == 0) return;
        if (alpha == 255) return self.fill_rect(rect, color);

        const clipped_rect = rect.intersect(self.paint_bounds());

        if (clipped_rect.is_empty()) return;

        var y = clipped_rect.y;

        while (y < clipped_rect.y + clipped_rect.h) : (y += 1) {

            const base = @as(u32, @intCast(y)) * self.stride;

            var x = clipped_rect.x;
            const end = clipped_rect.x + clipped_rect.w;
            const source: PixelVector = @splat(color);
            const alphas: PixelVector = @splat(alpha);

            while (x + 4 <= end) : (x += 4) {

                const index = base + @as(u32, @intCast(x));
                const pixels: *align(1) PixelVector = @ptrCast(&self.pixels[index]);

                pixels.* = mix_four(pixels.*, source, alphas);

            }

            while (x < end) : (x += 1) {

                const index = base + @as(u32, @intCast(x));

                self.pixels[index] = mix(self.pixels[index], color, alpha);

            }

        }

    }

    pub fn put_pixel(self: *const Surface, x: i32, y: i32, color: Color) void {

        if (!self.paint_bounds().contains(x, y)) return;

        self.pixels[@as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(x))] = color;

    }

    pub fn blend_pixel(self: *const Surface, x: i32, y: i32, color: Color, alpha: u8) void {

        if (alpha == 0) return;
        if (!self.paint_bounds().contains(x, y)) return;

        const index = @as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(x));

        self.pixels[index] = mix(self.pixels[index], color, alpha);

    }

    /// Blend one row of 8-bit coverage at (x, y); the raster fill path. `coverage[i]` lands on pixel (x + i, y).
    pub fn blend_row(self: *const Surface, x: i32, y: i32, coverage: []const u8, color: Color) void {

        const limit = self.paint_bounds();

        if (y < limit.y or y >= limit.y + limit.h) return;

        var first: usize = 0;
        var count = coverage.len;

        if (x < limit.x) {

            const cut: usize = @intCast(limit.x - x);

            if (cut >= count) return;

            first = cut;
            count -= cut;

        }

        const start_x = x + @as(i32, @intCast(first));

        // Guard right-of-clip runs so room does not wrap negative into a huge blend count.
        if (start_x >= limit.x + limit.w) return;

        const room: usize = @intCast(limit.x + limit.w - start_x);

        count = @min(count, room);

        if (count == 0) return;

        const base = @as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(start_x));
        const row = coverage[first .. first + count];

        // Long solid runs (shape interiors) use memset; short/AA rows skip the probe.
        if (count >= 32 and row[0] == 255) {

            var solid = true;
            var probe: usize = 1;

            while (solid and probe < count) : (probe += 1) {

                if (row[probe] != 255) solid = false;

            }

            if (solid) {

                @memset(self.pixels[base .. base + count], color);

                return;

            }

        }

        var index: usize = 0;
        const source: PixelVector = @splat(color);

        while (index + 4 <= count) : (index += 4) {

            const alpha_bytes = row[index..][0..4];
            const alphas = PixelVector{ alpha_bytes[0], alpha_bytes[1], alpha_bytes[2], alpha_bytes[3] };
            const pixels: *align(1) PixelVector = @ptrCast(&self.pixels[base + @as(u32, @intCast(index))]);

            pixels.* = mix_four(pixels.*, source, alphas);

        }

        while (index < count) : (index += 1) {

            const alpha = row[index];

            if (alpha == 0) continue;

            const at = base + @as(u32, @intCast(index));

            if (alpha == 255) {

                self.pixels[at] = color;

            } else {

                self.pixels[at] = mix(self.pixels[at], color, alpha);

            }

        }

    }

    /// Blend through a row-major w×h coverage mask (cached glyph/icon blit path).
    pub fn blend_coverage(self: *const Surface, x: i32, y: i32, coverage: []const u8, w: u32, h: u32, color: Color) void {

        var row: u32 = 0;

        while (row < h) : (row += 1) {

            const start = row * w;

            self.blend_row(x, y + @as(i32, @intCast(row)), coverage[start .. start + w], color);

        }

    }

    /// Copy `src_rect` out of `src` so its origin lands at (dst_x, dst_y), clipped to both surfaces.
    pub fn blit(self: *const Surface, dst_x: i32, dst_y: i32, src: *const Surface, src_rect: Rect) void {

        var from = src_rect.intersect(src.bounds());

        if (from.is_empty()) return;

        var to = Rect{ .x = dst_x, .y = dst_y, .w = from.w, .h = from.h };
        const clipped_to = to.intersect(self.paint_bounds());

        if (clipped_to.is_empty()) return;

        from.x += clipped_to.x - to.x;
        from.y += clipped_to.y - to.y;
        to = clipped_to;

        var row: u32 = 0;

        while (row < to.h) : (row += 1) {

            const src_start = (@as(u32, @intCast(from.y)) + row) * src.stride + @as(u32, @intCast(from.x));
            const dst_start = (@as(u32, @intCast(to.y)) + row) * self.stride + @as(u32, @intCast(to.x));

            @memcpy(self.pixels[dst_start .. dst_start + @as(u32, @intCast(to.w))], src.pixels[src_start .. src_start + @as(u32, @intCast(to.w))]);

        }

    }

    /// Masked blit for rounded windows; zero coverage leaves the destination untouched.
    pub fn blit_masked(self: *const Surface, dst_x: i32, dst_y: i32, src: *const Surface, src_rect: Rect, mask: []const u8, mask_w: u32, opaque_rows: ?[]const bool) void {

        var from = src_rect.intersect(src.bounds());

        if (from.is_empty()) return;

        var to = Rect{ .x = dst_x, .y = dst_y, .w = from.w, .h = from.h };
        const clipped_to = to.intersect(self.paint_bounds());

        if (clipped_to.is_empty()) return;

        const mask_dx: u32 = @intCast(clipped_to.x - to.x);
        const mask_dy: u32 = @intCast(clipped_to.y - to.y);

        from.x += clipped_to.x - to.x;
        from.y += clipped_to.y - to.y;
        to = clipped_to;

        var row: u32 = 0;

        const row_w: u32 = @intCast(to.w);

        while (row < to.h) : (row += 1) {

            const src_start = (@as(u32, @intCast(from.y)) + row) * src.stride + @as(u32, @intCast(from.x));
            const dst_start = (@as(u32, @intCast(to.y)) + row) * self.stride + @as(u32, @intCast(to.x));
            const mask_start = (mask_dy + row) * mask_w + mask_dx;
            const mask_end = @min(mask_start + row_w, @as(u32, @intCast(mask.len)));
            const row_mask = mask[mask_start..mask_end];
            const active_w = row_mask.len;
            const mask_row: usize = @intCast(mask_dy + row);

            var solid_row = active_w == row_w;
            var index: u32 = 0;

            if (opaque_rows) |rows| {

                solid_row = solid_row and mask_row < rows.len and rows[mask_row];

            }

            while (opaque_rows == null and solid_row and index < active_w) : (index += 1) {

                if (row_mask[index] != 255) solid_row = false;

            }

            if (solid_row and active_w == row_w) {

                @memcpy(self.pixels[dst_start .. dst_start + row_w], src.pixels[src_start .. src_start + row_w]);

                continue;

            }

            index = 0;

            while (index < active_w) : (index += 1) {

                const alpha = row_mask[index];

                if (alpha == 0) continue;

                const at = dst_start + index;

                if (alpha == 255) {

                    self.pixels[at] = src.pixels[src_start + index];

                } else {

                    self.pixels[at] = mix(self.pixels[at], src.pixels[src_start + index], alpha);

                }

            }

        }

    }

    // 4x4 Bayer-dithered vertical gradient to hide 8-bit banding on large fills.

    pub fn fill_gradient(self: *const Surface, rect: Rect, top: Color, bottom: Color) void {

        const clipped_rect = rect.intersect(self.paint_bounds());

        if (clipped_rect.is_empty()) return;

        const span: i64 = @max(1, rect.h - 1);

        var y = clipped_rect.y;

        while (y < clipped_rect.y + clipped_rect.h) : (y += 1) {

            const t = @as(i64, y - rect.y);

            var scaled: [3]i64 = undefined;

            inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {

                const a: i64 = (top >> shift) & 0xff;
                const b: i64 = (bottom >> shift) & 0xff;

                scaled[channel] = a * 16 + @divTrunc((b - a) * 16 * t, span);

            }

            const row_base = @as(u32, @intCast(y)) * self.stride;
            const dither_row = bayer[@intCast(@mod(y, 4))];

            var x = clipped_rect.x;

            while (x < clipped_rect.x + clipped_rect.w) : (x += 1) {

                const dither = dither_row[@intCast(@mod(x, 4))];
                var out: u32 = 0;

                inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {

                    const value: u32 = @intCast(std.math.clamp(@divTrunc(scaled[channel] + dither, 16), 0, 255));

                    out |= value << shift;

                }

                self.pixels[row_base + @as(u32, @intCast(x))] = out;

            }

        }

    }

};

const bayer = [4][4]i64{

    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },

};

const testing = std.testing;

fn test_surface(buffer: []u32, width: u32, height: u32) Surface {

    @memset(buffer, 0);

    return Surface.from_pixels(buffer.ptr, width, height);

}

test "rect intersect cover and contains" {

    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };

    const both = a.intersect(b);

    try testing.expectEqual(@as(i32, 5), both.x);
    try testing.expectEqual(@as(i32, 5), both.w);

    const covered = a.cover(b);

    try testing.expectEqual(@as(i32, 15), covered.w);
    try testing.expect(a.intersect(.{ .x = 20, .y = 20, .w = 4, .h = 4 }).is_empty());
    try testing.expect(a.contains(9, 9));
    try testing.expect(!a.contains(10, 9));

}

test "divide-free mix matches rounded scalar division" {

    var alpha: u16 = 0;

    while (alpha <= 255) : (alpha += 1) {

        var source: u16 = 0;

        while (source <= 255) : (source += 17) {

            var destination: u16 = 0;

            while (destination <= 255) : (destination += 17) {

                const expected = (@as(u32, source) * alpha + @as(u32, destination) * (255 - alpha) + 127) / 255;
                const actual = red(mix(rgb(@intCast(destination), 0, 0), rgb(@intCast(source), 0, 0), @intCast(alpha)));

                try testing.expectEqual(expected, actual);

            }

        }

    }

}

test "fill_rect clips to the surface and the clip rect" {

    var buffer: [16]u32 = undefined;
    var surface = test_surface(&buffer, 4, 4);

    surface.fill_rect(.{ .x = 2, .y = 2, .w = 10, .h = 10 }, 0xff0000);

    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0xff0000), buffer[2 * 4 + 2]);
    try testing.expectEqual(@as(u32, 0xff0000), buffer[3 * 4 + 3]);

    const pane = surface.clipped(.{ .x = 0, .y = 0, .w = 1, .h = 1 });

    pane.fill_rect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, 0x00ff00);

    try testing.expectEqual(@as(u32, 0x00ff00), buffer[0]);
    try testing.expectEqual(@as(u32, 0), buffer[1]);

}

test "blend_row clips both edges and honors full coverage" {

    var buffer: [16]u32 = undefined;
    const surface = test_surface(&buffer, 4, 4);

    const coverage = [_]u8{ 255, 255, 255 };

    surface.blend_row(-1, 0, &coverage, 0xabcdef);

    try testing.expectEqual(@as(u32, 0xabcdef), buffer[0]);
    try testing.expectEqual(@as(u32, 0xabcdef), buffer[1]);
    try testing.expectEqual(@as(u32, 0), buffer[2]);

    surface.blend_row(0, 1, &[_]u8{128}, rgb(200, 100, 40));

    try testing.expectEqual(@as(u32, 100), red(buffer[4]));

    surface.blend_row(4, 2, &[_]u8{255}, 0x123456);
    surface.blend_row(-2, 2, &[_]u8{ 255, 255 }, 0x123456);

    try testing.expectEqual(@as(u32, 0), buffer[2 * 4]);

}

test "blend_row drops a run that starts past the right edge" {

    var buffer: [16]u32 = [_]u32{0} ** 16;
    const surface = test_surface(&buffer, 4, 4);

    // A run starting past the right clip edge must paint nothing (no negative room wrap).

    surface.blend_row(10, 1, &[_]u8{ 255, 255, 255 }, 0xabcdef);

    for (buffer) |pixel| {

        try testing.expectEqual(@as(u32, 0), pixel);

    }

}

test "blit clips negative destinations back into the source" {

    var src_buffer: [16]u32 = undefined;
    var dst_buffer: [16]u32 = undefined;

    const src = test_surface(&src_buffer, 4, 4);
    const dst = test_surface(&dst_buffer, 4, 4);

    src.fill(0x11);
    src.put_pixel(1, 1, 0x99);

    dst.blit(-1, -1, &src, .{ .x = 0, .y = 0, .w = 4, .h = 4 });

    try testing.expectEqual(@as(u32, 0x99), dst_buffer[0]);
    try testing.expectEqual(@as(u32, 0x11), dst_buffer[1]);
    try testing.expectEqual(@as(u32, 0), dst_buffer[3 * 4 + 3]);

}

test "blit_masked weights source pixels by the mask" {

    var src_buffer: [4]u32 = undefined;
    var dst_buffer: [4]u32 = undefined;

    const src = test_surface(&src_buffer, 2, 2);
    const dst = test_surface(&dst_buffer, 2, 2);

    src.fill(rgb(255, 255, 255));

    const mask = [_]u8{ 255, 0, 128, 255 };

    dst.blit_masked(0, 0, &src, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, &mask, 2, null);

    try testing.expectEqual(@as(u32, 0xffffff), dst_buffer[0]);
    try testing.expectEqual(@as(u32, 0), dst_buffer[1]);
    try testing.expectEqual(@as(u32, 128), blue(dst_buffer[2]));
    try testing.expectEqual(@as(u32, 0xffffff), dst_buffer[3]);

}

test "gradient endpoints hit the exact colors" {

    var buffer: [64]u32 = undefined;
    const surface = test_surface(&buffer, 4, 16);

    surface.fill_gradient(surface.bounds(), rgb(0, 0, 0), rgb(255, 255, 255));

    try testing.expectEqual(@as(u32, 0), buffer[0] & 0xff);
    try testing.expectEqual(@as(u32, 255), buffer[15 * 4] & 0xff);

}
