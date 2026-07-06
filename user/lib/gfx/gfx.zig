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

pub fn red(color: Color) u8 {

    return @intCast((color >> 16) & 0xff);

}

pub fn green(color: Color) u8 {

    return @intCast((color >> 8) & 0xff);

}

pub fn blue(color: Color) u8 {

    return @intCast(color & 0xff);

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

    pub fn fill_rect_alpha(self: *const Surface, rect: Rect, color: Color, alpha: u8) void {

        if (alpha == 0) return;
        if (alpha == 255) return self.fill_rect(rect, color);

        const clipped = rect.intersect(self.bounds());

        if (clipped.is_empty()) return;

        var y = clipped.y;

        while (y < clipped.y + clipped.h) : (y += 1) {

            var x = clipped.x;

            while (x < clipped.x + clipped.w) : (x += 1) {

                self.blend_pixel(x, y, color, alpha);

            }

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

    pub fn blend_pixel(self: *const Surface, x: i32, y: i32, color: Color, alpha: u8) void {

        if (x < 0 or y < 0 or x >= self.width or y >= self.height or alpha == 0) return;

        if (alpha == 255) return self.put_pixel(x, y, color);

        const index = @as(u32, @intCast(y)) * self.stride + @as(u32, @intCast(x));
        const dst = self.pixels[index];
        const a: u32 = alpha;
        const inv = 255 - a;

        const r = (@as(u32, red(color)) * a + @as(u32, red(dst)) * inv + 127) / 255;
        const g = (@as(u32, green(color)) * a + @as(u32, green(dst)) * inv + 127) / 255;
        const b = (@as(u32, blue(color)) * a + @as(u32, blue(dst)) * inv + 127) / 255;

        self.pixels[index] = rgb(@intCast(r), @intCast(g), @intCast(b));

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

    /// Supersampled stroked segment with round caps.
    pub fn stroke_line_smooth(self: *const Surface, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: Color) void {

        const radius = @max(1, thickness);
        const raw_bounds = Rect{

            .x = @min(x0, x1) - radius - 1,
            .y = @min(y0, y1) - radius - 1,

            .w = @as(i32, @intCast(@abs(x1 - x0))) + 2 * radius + 3,
            .h = @as(i32, @intCast(@abs(y1 - y0))) + 2 * radius + 3,

        };
        const clipped_line = raw_bounds.intersect(self.bounds());

        if (clipped_line.is_empty()) return;

        const vx = x1 - x0;
        const vy = y1 - y0;
        const length_sq = @as(i64, vx) * vx + @as(i64, vy) * vy;
        const radius_64 = @max(32, @divTrunc(thickness * 64, 2));
        const sample_offsets = [_]i32{ 8, 24, 40, 56 };

        var y = clipped_line.y;

        while (y < clipped_line.y + clipped_line.h) : (y += 1) {

            var x = clipped_line.x;

            while (x < clipped_line.x + clipped_line.w) : (x += 1) {

                var covered: u32 = 0;

                for (sample_offsets) |sy| {

                    for (sample_offsets) |sx| {

                        if (sample_hits_segment((x - x0) * 64 + sx, (y - y0) * 64 + sy, vx * 64, vy * 64, length_sq * 4096, radius_64)) {

                            covered += 1;

                        }

                    }

                }

                if (covered != 0) self.blend_pixel(x, y, color, @intCast((covered * 255) / 16));

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

    /// Anti-aliased filled disc: interior pixels fill solid, boundary pixels take 4x4 supersampled coverage so the
    /// edge stays smooth instead of the stair-stepped span edges fill_circle leaves.
    pub fn fill_circle_smooth(self: *const Surface, cx: i32, cy: i32, radius: i32, color: Color) void {

        if (radius <= 0) return;

        const raw_bounds = Rect{ .x = cx - radius - 1, .y = cy - radius - 1, .w = 2 * radius + 3, .h = 2 * radius + 3 };
        const rect = raw_bounds.intersect(self.bounds());
        const sample_offsets = [_]i32{ 8, 24, 40, 56 };
        const r2: i64 = @as(i64, radius) * radius * 4096;

        var y = rect.y;

        while (y < rect.y + rect.h) : (y += 1) {

            var x = rect.x;

            while (x < rect.x + rect.w) : (x += 1) {

                var covered: u32 = 0;

                for (sample_offsets) |sy| {

                    for (sample_offsets) |sx| {

                        const dx = (x - cx) * 64 + sx - 32;
                        const dy = (y - cy) * 64 + sy - 32;

                        if (@as(i64, dx) * dx + @as(i64, dy) * dy <= r2) covered += 1;

                    }

                }

                if (covered == 16) {

                    self.put_pixel(x, y, color);

                } else if (covered != 0) {

                    self.blend_pixel(x, y, color, @intCast((covered * 255) / 16));

                }

            }

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

    pub fn stroke_circle_smooth(self: *const Surface, cx: i32, cy: i32, radius: i32, thickness: i32, color: Color) void {

        if (radius <= 0 or thickness <= 0) return;

        const outer = radius + @divTrunc(thickness + 1, 2);
        const inner = @max(0, radius - @divTrunc(thickness, 2));
        const raw_bounds = Rect{ .x = cx - outer - 1, .y = cy - outer - 1, .w = 2 * outer + 3, .h = 2 * outer + 3 };
        const rect = raw_bounds.intersect(self.bounds());
        const sample_offsets = [_]i32{ 8, 24, 40, 56 };

        var y = rect.y;

        while (y < rect.y + rect.h) : (y += 1) {

            var x = rect.x;

            while (x < rect.x + rect.w) : (x += 1) {

                var covered: u32 = 0;

                for (sample_offsets) |sy| {

                    for (sample_offsets) |sx| {

                        const dx = (x - cx) * 64 + sx - 32;
                        const dy = (y - cy) * 64 + sy - 32;
                        const d2 = dx * dx + dy * dy;

                        if (d2 <= outer * outer * 4096 and d2 >= inner * inner * 4096) covered += 1;

                    }

                }

                if (covered != 0) self.blend_pixel(x, y, color, @intCast((covered * 255) / 16));

            }

        }

    }

    /// Filled rectangle with rounded corners (scanline quarters — no stroked corner rings).
    pub fn fill_rounded_rect(self: *const Surface, rect: Rect, radius_in: i32, color: Color) void {

        const radius = @min(radius_in, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2)));

        if (radius <= 0) return self.fill_rect(rect, color);

        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y + radius, .w = rect.w - 2 * radius, .h = rect.h - 2 * radius }, color);
        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y, .w = rect.w - 2 * radius, .h = radius }, color);
        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y + rect.h - radius, .w = rect.w - 2 * radius, .h = radius }, color);
        self.fill_rect(.{ .x = rect.x, .y = rect.y + radius, .w = radius, .h = rect.h - 2 * radius }, color);
        self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = rect.y + radius, .w = radius, .h = rect.h - 2 * radius }, color);

        var dy: i32 = 0;

        while (dy < radius) : (dy += 1) {

            const rest = radius - 1 - dy;
            const span: i32 = @intCast(isqrt(@as(u64, @intCast(radius * radius - rest * rest))));

            self.fill_rect(.{ .x = rect.x + radius - span, .y = rect.y + dy, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = rect.y + dy, .w = span, .h = 1 }, color);

            const bottom_y = rect.y + rect.h - radius + dy;

            self.fill_rect(.{ .x = rect.x + radius - span, .y = bottom_y, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = bottom_y, .w = span, .h = 1 }, color);

        }

    }

    /// Filled rectangle with rounded top corners only.
    pub fn fill_rounded_rect_top(self: *const Surface, rect: Rect, radius_in: i32, color: Color) void {

        const radius = @min(radius_in, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2)));

        if (radius <= 0) return self.fill_rect(rect, color);

        self.fill_rect(.{ .x = rect.x, .y = rect.y + radius, .w = rect.w, .h = rect.h - radius }, color);
        self.fill_rect(.{ .x = rect.x + radius, .y = rect.y, .w = rect.w - 2 * radius, .h = radius }, color);

        var dy: i32 = 0;

        while (dy < radius) : (dy += 1) {

            const rest = radius - 1 - dy;
            const span: i32 = @intCast(isqrt(@as(u64, @intCast(radius * radius - rest * rest))));

            self.fill_rect(.{ .x = rect.x + radius - span, .y = rect.y + dy, .w = span, .h = 1 }, color);
            self.fill_rect(.{ .x = rect.x + rect.w - radius, .y = rect.y + dy, .w = span, .h = 1 }, color);

        }

    }

    /// Anti-aliased clip of square bottom corners against an outside color (typically the wallpaper).
    pub fn mask_rounded_rect_bottom_smooth(self: *const Surface, rect: Rect, radius_in: i32, outside_color: Color) void {

        const radius = @max(0, @min(radius_in, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2))));

        if (radius <= 1) return;

        const clipped = rect.intersect(self.bounds());
        const sample_offsets = [_]i32{ 8, 24, 40, 56 };
        const y_start = @max(clipped.y, rect.y + rect.h - radius);

        var y = y_start;

        while (y < clipped.y + clipped.h) : (y += 1) {

            var x = clipped.x;

            while (x < clipped.x + clipped.w) : (x += 1) {

                if (x >= rect.x + radius and x < rect.x + rect.w - radius) continue;

                var covered: u32 = 0;

                for (sample_offsets) |sy| {

                    for (sample_offsets) |sx| {

                        if (rounded_rect_contains(rect, radius, x * 64 + sx, y * 64 + sy)) covered += 1;

                    }

                }

                if (covered >= 16) continue;

                const alpha: u8 = @intCast(((16 - covered) * 255) / 16);

                self.blend_pixel(x, y, outside_color, alpha);

            }

        }

    }

    pub fn stroke_rounded_rect_smooth(self: *const Surface, rect: Rect, radius: i32, thickness: i32, color: Color) void {

        const r = @max(0, @min(radius, @min(@divTrunc(rect.w, 2), @divTrunc(rect.h, 2))));
        const left = rect.x + r;
        const right = rect.x + rect.w - r - 1;
        const top = rect.y + r;
        const bottom = rect.y + rect.h - r - 1;

        self.stroke_line_smooth(left, rect.y, right, rect.y, thickness, color);
        self.stroke_line_smooth(left, rect.y + rect.h - 1, right, rect.y + rect.h - 1, thickness, color);
        self.stroke_line_smooth(rect.x, top, rect.x, bottom, thickness, color);
        self.stroke_line_smooth(rect.x + rect.w - 1, top, rect.x + rect.w - 1, bottom, thickness, color);

        self.stroke_circle_smooth(left, top, r, thickness, color);
        self.stroke_circle_smooth(right, top, r, thickness, color);
        self.stroke_circle_smooth(left, bottom, r, thickness, color);
        self.stroke_circle_smooth(right, bottom, r, thickness, color);

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

            // The channel interpolation depends only on the row, so resolve it once and let the inner loop apply
            // only the per-pixel Bayer offset. Values are pre-scaled by 16 to keep the dither at sub-step precision.

            var scaled: [3]i64 = undefined;

            inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {

                const a: i64 = (top >> shift) & 0xff;
                const b: i64 = (bottom >> shift) & 0xff;

                scaled[channel] = a * 16 + @divTrunc((b - a) * 16 * t, span);

            }

            const row_base = @as(u32, @intCast(y)) * self.stride;
            const dither_row = bayer[@intCast(@mod(y, 4))];

            var x = clipped.x;

            while (x < clipped.x + clipped.w) : (x += 1) {

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

    /// Blend `color` onto the surface through a `w`x`h` 8-bit coverage mask (row-major, 0 = clear, 255 = opaque),
    /// its top-left at (x, y). This is the blit path for cached glyph and icon bitmaps: rasterize once, paint many.
    /// The column span is clipped once and the source color channels are hoisted out of the inner loop - this runs
    /// for every glyph and icon of every frame, so it stays free of the per-pixel bounds checks blend_pixel repeats.
    pub fn blend_coverage(self: *const Surface, x: i32, y: i32, coverage: []const u8, w: u32, h: u32, color: Color) void {

        const width_i: i32 = @intCast(self.width);

        if (x >= width_i or w == 0) return;

        const col_start: u32 = if (x < 0) @intCast(-x) else 0;
        const col_end: u32 = if (x + @as(i32, @intCast(w)) > width_i) @intCast(width_i - x) else w;

        if (col_start >= col_end) return;

        const start_x: i32 = x + @as(i32, @intCast(col_start));

        const cr: u32 = red(color);
        const cg: u32 = green(color);
        const cb: u32 = blue(color);

        var row: u32 = 0;

        while (row < h) : (row += 1) {

            const dst_y = y + @as(i32, @intCast(row));

            if (dst_y < 0 or dst_y >= self.height) continue;

            const cov_base = row * w;
            const pix_base = @as(u32, @intCast(dst_y)) * self.stride + @as(u32, @intCast(start_x));

            var col = col_start;

            while (col < col_end) : (col += 1) {

                const alpha = coverage[cov_base + col];

                if (alpha == 0) continue;

                const index = pix_base + (col - col_start);

                if (alpha == 255) {

                    self.pixels[index] = color;
                    continue;

                }

                const dst = self.pixels[index];
                const a: u32 = alpha;
                const inv = 255 - a;

                const r = (cr * a + @as(u32, red(dst)) * inv + 127) / 255;
                const g = (cg * a + @as(u32, green(dst)) * inv + 127) / 255;
                const b = (cb * a + @as(u32, blue(dst)) * inv + 127) / 255;

                self.pixels[index] = rgb(@intCast(r), @intCast(g), @intCast(b));

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

fn sample_hits_segment(px: i32, py: i32, vx: i32, vy: i32, length_sq: i64, radius: i32) bool {

    if (length_sq <= 0) return px * px + py * py <= radius * radius;

    const dot = @as(i64, px) * vx + @as(i64, py) * vy;

    if (dot <= 0) return @as(i64, px) * px + @as(i64, py) * py <= @as(i64, radius) * radius;
    if (dot >= length_sq) {

        const dx = px - vx;
        const dy = py - vy;

        return @as(i64, dx) * dx + @as(i64, dy) * dy <= @as(i64, radius) * radius;

    }

    const cross = @as(i64, px) * vy - @as(i64, py) * vx;

    return cross * cross <= @as(i64, radius) * radius * length_sq;

}

fn rounded_rect_contains(rect: Rect, radius: i32, sample_x: i32, sample_y: i32) bool {

    const x = @divTrunc(sample_x, 64);
    const y = @divTrunc(sample_y, 64);

    if (!rect.contains(x, y)) return false;

    const left = (rect.x + radius) * 64;
    const right = (rect.x + rect.w - radius) * 64;
    const top = (rect.y + radius) * 64;
    const bottom = (rect.y + rect.h - radius) * 64;

    const cx = std.math.clamp(sample_x, left, right);
    const cy = std.math.clamp(sample_y, top, bottom);
    const dx = sample_x - cx;
    const dy = sample_y - cy;

    return @as(i64, dx) * dx + @as(i64, dy) * dy <= @as(i64, radius) * radius * 4096;

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

test "smooth circle fills solid at the center and leaves the corners clear" {

    var buffer: [256]u32 = undefined;
    const surface = test_surface(&buffer, 16, 16);

    surface.fill_circle_smooth(8, 8, 5, 0xffffff);

    try testing.expectEqual(@as(u32, 0xffffff), buffer[8 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0), buffer[15 * 16 + 15]);

}

test "blend_coverage clips its column span and honors opaque coverage" {

    var buffer: [16]u32 = undefined;
    const surface = test_surface(&buffer, 4, 4);

    // A 3-wide opaque run placed one pixel off the left edge: the first cell is clipped, the rest land in row 0.

    const coverage = [_]u8{ 255, 255, 255 };

    surface.blend_coverage(-1, 0, &coverage, 3, 1, 0xabcdef);

    try testing.expectEqual(@as(u32, 0xabcdef), buffer[0]);
    try testing.expectEqual(@as(u32, 0xabcdef), buffer[1]);
    try testing.expectEqual(@as(u32, 0), buffer[2]);

    // Half coverage over a black destination is a rounded 50% of the source channels.

    surface.blend_coverage(0, 1, &[_]u8{128}, 1, 1, rgb(200, 100, 40));

    try testing.expectEqual(@as(u32, 100), red(buffer[4]));

    // Fully off the right and left edges: no write, no panic.

    surface.blend_coverage(4, 2, &[_]u8{255}, 1, 1, 0x123456);
    surface.blend_coverage(-1, 2, &[_]u8{255}, 1, 1, 0x123456);

    try testing.expectEqual(@as(u32, 0), buffer[2 * 4]);

}
