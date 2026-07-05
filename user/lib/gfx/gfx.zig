// Software rendering over a mapped pixel Region (07-userspace-ddd.md Section 12.6): a Surface wraps any
// XRGB8888 buffer (a window surface, the compositor's back buffer, the scanout itself) and every primitive
// clips to it, so callers never reason about bounds. Damage accumulates as one bounding Rect per frame.

const std = @import("std");
const builtin = @import("builtin");

/// 32-bit little-endian XRGB: blue in the low byte, the high byte ignored (proto.display.format_xrgb).
pub const Color = u32;

pub fn rgb(r: u8, g: u8, b: u8) Color {

    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;

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

};

pub const Surface = struct {

    pixels: [*]u32,

    width: u32,
    height: u32,

    // In pixels, not bytes; rows may be padded (the scanout stride).
    stride: u32,

    pub fn from_base(base: usize, width: u32, height: u32, stride_bytes: u32) Surface {

        return .{

            .pixels = @ptrFromInt(base),

            .width = width,
            .height = height,

            .stride = stride_bytes / @sizeOf(u32),

        };

    }

    pub fn bounds(self: *const Surface) Rect {

        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };

    }

    pub fn fill(self: *const Surface, color: Color) void {

        self.fill_rect(self.bounds(), color);

    }

    pub fn fill_rect(self: *const Surface, rect: Rect, color: Color) void {

        const clipped = rect.intersect(self.bounds());

        if (clipped.is_empty()) return;

        var row: u32 = @intCast(clipped.y);
        const first: u32 = @intCast(clipped.x);
        const count: u32 = @intCast(clipped.w);
        const last_row: u32 = @intCast(clipped.y + clipped.h);

        while (row < last_row) : (row += 1) {

            const start = row * self.stride + first;

            @memset(self.pixels[start .. start + count], color);

        }

    }

    /// A `thickness`-pixel frame just inside `rect`.
    pub fn stroke_rect(self: *const Surface, rect: Rect, thickness: i32, color: Color) void {

        if (rect.is_empty()) return;

        self.fill_rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, color);
        self.fill_rect(.{ .x = rect.x, .y = rect.y + rect.h - thickness, .w = rect.w, .h = thickness }, color);
        self.fill_rect(.{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, color);
        self.fill_rect(.{ .x = rect.x + rect.w - thickness, .y = rect.y, .w = thickness, .h = rect.h }, color);

    }

    pub fn put_pixel(self: *const Surface, x: i32, y: i32, color: Color) void {

        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;

        self.pixels[@as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(x))] = color;

    }

    /// Bresenham line, clipped per pixel.
    pub fn line(self: *const Surface, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {

        var x = x0;
        var y = y0;

        const dx = @abs(x1 - x0);
        const dy = @abs(y1 - y0);
        const step_x: i32 = if (x0 < x1) 1 else -1;
        const step_y: i32 = if (y0 < y1) 1 else -1;

        var err: i64 = @as(i64, dx) - @as(i64, dy);

        while (true) {

            self.put_pixel(x, y, color);

            if (x == x1 and y == y1) return;

            const doubled = 2 * err;

            if (doubled > -@as(i64, dy)) {

                err -= @as(i64, dy);
                x += step_x;

            }

            if (doubled < dx) {

                err += @as(i64, dx);
                y += step_y;

            }

        }

    }

    /// Filled circle by scanline spans (no per-pixel sqrt).
    pub fn fill_circle(self: *const Surface, cx: i32, cy: i32, radius: i32, color: Color) void {

        if (radius <= 0) return;

        var dy = -radius;

        while (dy <= radius) : (dy += 1) {

            const span = isqrt(@as(u64, @intCast(radius * radius - dy * dy)));

            self.fill_rect(.{ .x = cx - @as(i32, @intCast(span)), .y = cy + dy, .w = 2 * @as(i32, @intCast(span)) + 1, .h = 1 }, color);

        }

    }

    /// Midpoint circle outline.
    pub fn stroke_circle(self: *const Surface, cx: i32, cy: i32, radius: i32, color: Color) void {

        if (radius <= 0) return;

        var x: i32 = radius;
        var y: i32 = 0;
        var err: i32 = 1 - radius;

        while (x >= y) {

            self.put_pixel(cx + x, cy + y, color);
            self.put_pixel(cx + y, cy + x, color);
            self.put_pixel(cx - y, cy + x, color);
            self.put_pixel(cx - x, cy + y, color);
            self.put_pixel(cx - x, cy - y, color);
            self.put_pixel(cx - y, cy - x, color);
            self.put_pixel(cx + y, cy - x, color);
            self.put_pixel(cx + x, cy - y, color);

            y += 1;

            if (err < 0) {

                err += 2 * y + 1;

            } else {

                x -= 1;
                err += 2 * (y - x) + 1;

            }

        }

    }

    /// Filled rectangle with quarter-circle corners.
    pub fn fill_rounded_rect(self: *const Surface, rect: Rect, radius_in: i32, color: Color) void {

        const radius = @min(radius_in, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2)));

        if (radius <= 0) return self.fill_rect(rect, color);

        self.fill_rect(.{ .x = rect.x, .y = rect.y + radius, .w = rect.w, .h = rect.h - 2 * radius }, color);
        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y, .w = rect.w - 2 * radius, .h = radius }, color);
        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y + rect.h - radius, .w = rect.w - 2 * radius, .h = radius }, color);

        var dy: i32 = 0;

        while (dy < radius) : (dy += 1) {

            const rest = radius - 1 - dy;
            const span: i32 = @intCast(isqrt(@as(u64, @intCast(radius * radius - rest * rest))));

            self.fill_rect(.{ .x = rect.x + radius - span, .y = rect.y + dy, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = rect.y + dy, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + radius - span, .y = rect.y + rect.h - 1 - dy, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = rect.y + rect.h - 1 - dy, .w = span, .h = 1 }, color);

        }

    }

    // A 4x4 ordered-dither vertical gradient: the Bayer offsets break the 8-bit quantization steps into
    // sub-pixel noise, so large fills show no banding.

    pub fn fill_gradient(self: *const Surface, rect: Rect, top: Color, bottom: Color) void {

        const clipped = rect.intersect(self.bounds());

        if (clipped.is_empty()) return;

        const span: i64 = @max(1, rect.h - 1);

        var y = clipped.y;

        while (y < clipped.y + clipped.h) : (y += 1) {

            const t = @as(i64, y - rect.y);

            var x = clipped.x;

            while (x < clipped.x + clipped.w) : (x += 1) {

                const dither = bayer[@intCast(@mod(y, 4))][@intCast(@mod(x, 4))];

                self.pixels[@as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(x))] =
                    mix_dithered(top, bottom, t, span, dither);

            }

        }

    }

    /// Copy `src_rect` out of `src` so its origin lands at (dst_x, dst_y), clipped to both surfaces.
    pub fn blit(self: *const Surface, dst_x: i32, dst_y: i32, src: *const Surface, src_rect: Rect) void {

        var from = src_rect.intersect(src.bounds());

        if (from.is_empty()) return;

        // Clip the destination placement, folding any cut back into the source origin.

        var to = Rect{ .x = dst_x, .y = dst_y, .w = from.w, .h = from.h };
        const clipped = to.intersect(self.bounds());

        if (clipped.is_empty()) return;

        from.x += clipped.x - to.x;
        from.y += clipped.y - to.y;
        to = clipped;

        var row: u32 = 0;

        while (row < to.h) : (row += 1) {

            const src_start = (@as(u32, @intCast(from.y)) + row) * src.stride + @as(u32, @intCast(from.x));
            const dst_start = (@as(u32, @intCast(to.y)) + row) * self.stride + @as(u32, @intCast(to.x));

            @memcpy(self.pixels[dst_start .. dst_start + @as(u32, @intCast(to.w))], src.pixels[src_start .. src_start + @as(u32, @intCast(to.w))]);

        }

    }

};

const bayer = [4][4]i64{

    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },

};

fn mix_dithered(top: Color, bottom: Color, t: i64, span: i64, dither: i64) Color {

    var out: u32 = 0;

    inline for (.{ 16, 8, 0 }) |shift| {

        const a: i64 = (top >> shift) & 0xff;
        const b: i64 = (bottom >> shift) & 0xff;

        // channel*16 interpolation, with the Bayer offset applied before truncation.

        const scaled = a * 16 + @divTrunc((b - a) * 16 * t, span);
        const channel: u32 = @intCast(std.math.clamp(@divTrunc(scaled + dither, 16), 0, 255));

        out |= channel << shift;

    }

    return out;

}

fn isqrt(value: u64) u64 {

    return std.math.sqrt(value);

}

const testing = std.testing;

fn test_surface(buffer: []u32, width: u32, height: u32) Surface {

    @memset(buffer, 0);

    return .{

        .pixels = buffer.ptr,

        .width = width,
        .height = height,

        .stride = width,

    };

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

    try testing.expectEqual(@as(i32, 12), Rect.empty.cover(.{ .x = 1, .y = 1, .w = 12, .h = 3 }).w);

}

test "fill_rect clips to the surface" {

    var buffer: [16]u32 = undefined;
    const surface = test_surface(&buffer, 4, 4);

    surface.fill_rect(.{ .x = 2, .y = 2, .w = 10, .h = 10 }, 0xff0000);

    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0xff0000), buffer[2 * 4 + 2]);
    try testing.expectEqual(@as(u32, 0xff0000), buffer[3 * 4 + 3]);
    try testing.expectEqual(@as(u32, 0), buffer[1 * 4 + 3]);

}

test "blit clips negative destinations back into the source" {

    var src_buffer: [16]u32 = undefined;
    var dst_buffer: [16]u32 = undefined;

    const src = test_surface(&src_buffer, 4, 4);
    const dst = test_surface(&dst_buffer, 4, 4);

    src.fill(0x11);
    src.put_pixel(1, 1, 0x99);

    dst.blit(-1, -1, &src, .{ .x = 0, .y = 0, .w = 4, .h = 4 });

    // Source pixel (1,1) lands at destination (0,0).

    try testing.expectEqual(@as(u32, 0x99), dst_buffer[0]);
    try testing.expectEqual(@as(u32, 0x11), dst_buffer[1]);
    try testing.expectEqual(@as(u32, 0), dst_buffer[3 * 4 + 3]);

}

test "gradient endpoints hit the exact colors" {

    var buffer: [64]u32 = undefined;
    const surface = test_surface(&buffer, 4, 16);

    surface.fill_gradient(surface.bounds(), rgb(0, 0, 0), rgb(255, 255, 255));

    try testing.expectEqual(@as(u32, 0), buffer[0] & 0xff);
    try testing.expectEqual(@as(u32, 255), buffer[15 * 4] & 0xff);

    // Monotonic per column: no channel steps backward down the ramp.

    var y: usize = 1;

    while (y < 16) : (y += 1) {

        try testing.expect((buffer[y * 4] & 0xff) >= (buffer[(y - 1) * 4] & 0xff));

    }

}

test "circle stays inside its bounding box" {

    var buffer: [256]u32 = undefined;
    const surface = test_surface(&buffer, 16, 16);

    surface.fill_circle(8, 8, 5, 0xff);

    try testing.expectEqual(@as(u32, 0xff), buffer[8 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0xff), buffer[8 * 16 + 3]);
    try testing.expectEqual(@as(u32, 0), buffer[2 * 16 + 2]);

}
