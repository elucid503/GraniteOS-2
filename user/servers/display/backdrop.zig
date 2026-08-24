// Quartz: a cached glass look for chrome (launcher, menus, taskbar, title bars).

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const draw = lib.draw;
const sys = lib.sys;

const Handle = cap.Handle;
const Color = draw.Color;
const Rect = draw.Rect;
const Surface = draw.Surface;

const round = draw.round;

pub const default_alpha: u8 = 172;
pub const default_haze: u8 = 16;
pub const corner_radius: i32 = 8;

/// How hard the rim bends the picture behind the glass. 4 is the previous look; 5 is a little stronger.
pub const bend_amount: u32 = 5;

const max_small: u32 = 128 * 1024;

pub const Look = struct {

    color: Color,
    cover: u8,
    shine: u8,

};

const Point = struct {

    x: u32,
    y: u32,

};

var scratch_a: [max_small]u32 = undefined;
var scratch_b: [max_small]u32 = undefined;

pub const Cache = struct {

    region: Handle = 0,
    base: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    capacity: usize = 0,
    valid: bool = false,

    pub fn release(self: *Cache) void {

        if (self.base != 0) sys.unmap(cap.self_space, self.base) catch {};
        if (self.region != 0) sys.close(self.region) catch {};

        self.* = .{};

    }

    pub fn surface(self: *const Cache) ?Surface {

        if (self.base == 0 or self.width == 0 or self.height == 0) return null;

        return Surface.from_base(self.base, self.width, self.height, self.width * 4);

    }

};

pub fn ensure(cache: *Cache, width: u32, height: u32) bool {

    if (width == 0 or height == 0) return false;

    const bytes = std.math.mul(usize, @as(usize, width) * height, @sizeOf(u32)) catch return false;

    if (cache.region != 0 and bytes <= cache.capacity) {

        if (cache.width != width or cache.height != height) cache.valid = false;

        cache.width = width;
        cache.height = height;

        return true;

    }

    cache.release();

    const allocation = std.math.ceilPowerOfTwo(usize, bytes) catch return false;
    const region = sys.create(.region, allocation, cap.memory) catch return false;
    const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch {

        sys.close(region) catch {};

        return false;

    };

    cache.* = .{

        .region = region,
        .base = base,
        .width = width,
        .height = height,
        .capacity = allocation,
        .valid = false,

    };

    return true;

}

/// Paints Quartz glass for `src_rect` into `dst`.
pub fn make_glass(src: *const Surface, src_rect: Rect, dst: *const Surface, look: Look, bend_bottom: bool) void {

    make_glass_into(src, src_rect, dst, look, bend_bottom, &scratch_a, &scratch_b);

}

pub fn make_glass_into(src: *const Surface, src_rect: Rect, dst: *const Surface, look: Look, bend_bottom: bool, small_a: []u32, small_b: []u32) void {

    const dest = src_rect.intersect(src.bounds()).intersect(Rect{

        .x = src_rect.x,
        .y = src_rect.y,
        .w = @intCast(dst.width),
        .h = @intCast(dst.height),

    });

    if (dest.is_empty()) return;

    const width: u32 = @intCast(dest.w);
    const height: u32 = @intCast(dest.h);
    const limit = @min(small_a.len, small_b.len);
    const step: u32 = if (fits_small(width, height, 2, limit)) 2 else 4;
    const small_w: u32 = @max(1, (width + step - 1) / step);
    const small_h: u32 = @max(1, (height + step - 1) / step);

    if (width < 2 or height < 2 or small_w * small_h > limit) {

        tint_rect(src, dest, dst, dest.translated(-src_rect.x, -src_rect.y), look);

        return;

    }

    downsample_rect(src, dest, small_a, small_w, small_h);
    soften(small_a, small_b, small_w, small_h);
    enlarge_glass(small_b, small_w, small_h, dst, dest.translated(-src_rect.x, -src_rect.y), look, bend_bottom);

}

pub fn blit_round(back: *const Surface, src: *const Surface, dest: Rect, clip: Rect) void {

    const visible = dest.intersect(clip);

    if (visible.is_empty()) return;

    const radius = corner_radius;

    if (dest.w <= 2 * radius or dest.h <= 2 * radius) {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    }

    const masks = round.masks_for(radius) orelse {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    };

    const r = radius;

    const top = Rect{ .x = dest.x + r, .y = dest.y, .w = dest.w - 2 * r, .h = r };
    const bottom = Rect{ .x = dest.x + r, .y = dest.y + dest.h - r, .w = dest.w - 2 * r, .h = r };

    const body = Rect{ .x = dest.x, .y = dest.y + r, .w = dest.w, .h = dest.h - 2 * r };

    for ([_]Rect{ top, body, bottom }) |part| {

        const part_visible = part.intersect(clip);

        if (part_visible.is_empty()) continue;

        back.blit(part_visible.x, part_visible.y, src, part_visible.translated(-dest.x, -dest.y));

    }

    const side: u32 = @intCast(r);
    const bottom_y = dest.y + dest.h - r;

    const Corner = struct { rect: Rect, mask: []const u8, opaque_rows: []const bool };

    const corners = [_]Corner{

        .{ .rect = .{ .x = dest.x, .y = dest.y, .w = r, .h = r }, .mask = masks.tl, .opaque_rows = masks.tl_opaque },
        .{ .rect = .{ .x = dest.x + dest.w - r, .y = dest.y, .w = r, .h = r }, .mask = masks.tr, .opaque_rows = masks.tr_opaque },
        .{ .rect = .{ .x = dest.x, .y = bottom_y, .w = r, .h = r }, .mask = masks.bl, .opaque_rows = masks.bl_opaque },
        .{ .rect = .{ .x = dest.x + dest.w - r, .y = bottom_y, .w = r, .h = r }, .mask = masks.br, .opaque_rows = masks.br_opaque },

    };

    for (corners) |corner| {

        if (corner.rect.intersect(clip).is_empty()) continue;

        const view = back.clipped(clip);

        view.blit_masked(corner.rect.x, corner.rect.y, src, corner.rect.translated(-dest.x, -dest.y), corner.mask, side, corner.opaque_rows);

    }

}

/// Title bars: round the top corners only so the bar meets the content flush.
pub fn blit_round_top(back: *const Surface, src: *const Surface, dest: Rect, clip: Rect) void {

    const visible = dest.intersect(clip);

    if (visible.is_empty()) return;

    const radius = corner_radius;

    if (dest.w <= 2 * radius or dest.h <= radius) {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    }

    const masks = round.masks_for(radius) orelse {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    };

    const r = radius;
    const top = Rect{ .x = dest.x + r, .y = dest.y, .w = dest.w - 2 * r, .h = r };
    const body = Rect{ .x = dest.x, .y = dest.y + r, .w = dest.w, .h = dest.h - r };

    for ([_]Rect{ top, body }) |part| {

        const part_visible = part.intersect(clip);

        if (part_visible.is_empty()) continue;

        back.blit(part_visible.x, part_visible.y, src, part_visible.translated(-dest.x, -dest.y));

    }

    const side: u32 = @intCast(r);

    const Corner = struct { rect: Rect, mask: []const u8, opaque_rows: []const bool };

    const corners = [_]Corner{

        .{ .rect = .{ .x = dest.x, .y = dest.y, .w = r, .h = r }, .mask = masks.tl, .opaque_rows = masks.tl_opaque },
        .{ .rect = .{ .x = dest.x + dest.w - r, .y = dest.y, .w = r, .h = r }, .mask = masks.tr, .opaque_rows = masks.tr_opaque },

    };

    for (corners) |corner| {

        if (corner.rect.intersect(clip).is_empty()) continue;

        const view = back.clipped(clip);

        view.blit_masked(corner.rect.x, corner.rect.y, src, corner.rect.translated(-dest.x, -dest.y), corner.mask, side, corner.opaque_rows);

    }

}

/// Decorated window bodies: round the bottom corners only so they meet the title bar flush.
pub fn blit_round_bottom(back: *const Surface, src: *const Surface, dest: Rect, clip: Rect) void {

    const visible = dest.intersect(clip);

    if (visible.is_empty()) return;

    const radius = corner_radius;

    if (dest.w <= 2 * radius or dest.h <= radius) {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    }

    const masks = round.masks_for(radius) orelse {

        back.blit(visible.x, visible.y, src, visible.translated(-dest.x, -dest.y));

        return;

    };

    const r = radius;
    const body = Rect{ .x = dest.x, .y = dest.y, .w = dest.w, .h = dest.h - r };
    const bottom = Rect{ .x = dest.x + r, .y = dest.y + dest.h - r, .w = dest.w - 2 * r, .h = r };

    for ([_]Rect{ body, bottom }) |part| {

        const part_visible = part.intersect(clip);

        if (part_visible.is_empty()) continue;

        back.blit(part_visible.x, part_visible.y, src, part_visible.translated(-dest.x, -dest.y));

    }

    const side: u32 = @intCast(r);
    const bottom_y = dest.y + dest.h - r;

    const Corner = struct { rect: Rect, mask: []const u8, opaque_rows: []const bool };

    const corners = [_]Corner{

        .{ .rect = .{ .x = dest.x, .y = bottom_y, .w = r, .h = r }, .mask = masks.bl, .opaque_rows = masks.bl_opaque },
        .{ .rect = .{ .x = dest.x + dest.w - r, .y = bottom_y, .w = r, .h = r }, .mask = masks.br, .opaque_rows = masks.br_opaque },

    };

    for (corners) |corner| {

        if (corner.rect.intersect(clip).is_empty()) continue;

        const view = back.clipped(clip);

        view.blit_masked(corner.rect.x, corner.rect.y, src, corner.rect.translated(-dest.x, -dest.y), corner.mask, side, corner.opaque_rows);

    }

}

fn tint_rect(src: *const Surface, src_rect: Rect, dst: *const Surface, dst_rect: Rect, look: Look) void {

    var y: i32 = 0;

    while (y < src_rect.h) : (y += 1) {

        var x: i32 = 0;

        while (x < src_rect.w) : (x += 1) {

            const sample = sample_pixel(src, src_rect.x + x, src_rect.y + y, look.color);
            const glass = shine(draw.mix(sample, look.color, look.cover), look.shine);

            dst.put_pixel(dst_rect.x + x, dst_rect.y + y, glass);

        }

    }

}

fn downsample_rect(src: *const Surface, src_rect: Rect, small: []u32, small_w: u32, small_h: u32) void {

    const src_w: u32 = @intCast(src_rect.w);
    const src_h: u32 = @intCast(src_rect.h);
    const inside = covers_bounds(src.bounds(), src_rect);

    var sy: u32 = 0;

    while (sy < small_h) : (sy += 1) {

        const y0 = src_rect.y + @as(i32, @intCast(sy * src_h / small_h));
        const y1 = src_rect.y + @as(i32, @intCast(@min(src_h, (sy + 1) * src_h / small_h)));
        const y_end = @max(y0 + 1, y1);

        var sx: u32 = 0;

        while (sx < small_w) : (sx += 1) {

            const x0 = src_rect.x + @as(i32, @intCast(sx * src_w / small_w));
            const x1 = src_rect.x + @as(i32, @intCast(@min(src_w, (sx + 1) * src_w / small_w)));
            const x_end = @max(x0 + 1, x1);

            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var count: u32 = 0;

            var y = y0;

            while (y < y_end) : (y += 1) {

                if (inside) {

                    const row = @as(u32, @intCast(y)) * src.stride + @as(u32, @intCast(x0));
                    var x: u32 = 0;
                    const span: u32 = @intCast(x_end - x0);

                    while (x < span) : (x += 1) {

                        const pixel = src.pixels[row + x];

                        r += draw.red(pixel);
                        g += draw.green(pixel);
                        b += draw.blue(pixel);
                        count += 1;

                    }

                } else {

                    var x = x0;

                    while (x < x_end) : (x += 1) {

                        const pixel = sample_pixel(src, x, y, 0);

                        r += draw.red(pixel);
                        g += draw.green(pixel);
                        b += draw.blue(pixel);
                        count += 1;

                    }

                }

            }

            if (count == 0) count = 1;

            small[sy * small_w + sx] = draw.rgb(
                @intCast(r / count),
                @intCast(g / count),
                @intCast(b / count),
            );

        }

    }

}

fn covers_bounds(outer: Rect, inner: Rect) bool {

    return outer.x <= inner.x and outer.y <= inner.y and outer.x + outer.w >= inner.x + inner.w and outer.y + outer.h >= inner.y + inner.h;

}

fn soften(src: []u32, dst: []u32, width: u32, height: u32) void {

    var y: u32 = 0;

    while (y < height) : (y += 1) {

        var x: u32 = 0;

        while (x < width) : (x += 1) {

            const left = src[y * width + if (x == 0) x else x - 1];
            const mid = src[y * width + x];
            const right = src[y * width + if (x + 1 >= width) x else x + 1];

            dst[y * width + x] = average3(left, mid, right);

        }

    }

    y = 0;

    while (y < height) : (y += 1) {

        const up_row = if (y == 0) y else y - 1;
        const down_row = if (y + 1 >= height) y else y + 1;

        var x: u32 = 0;

        while (x < width) : (x += 1) {

            const up = dst[up_row * width + x];
            const mid = dst[y * width + x];
            const down = dst[down_row * width + x];

            src[y * width + x] = average3(up, mid, down);

        }

    }

    @memcpy(dst[0 .. width * height], src[0 .. width * height]);

}

fn enlarge_glass(small: []const u32, small_w: u32, small_h: u32, dst: *const Surface, dest: Rect, look: Look, bend_bottom: bool) void {

    const width: u32 = @intCast(dest.w);
    const height: u32 = @intCast(dest.h);
    const band = edge_band(width, height);
    const pull = scaled_pull(band);

    var y: u32 = 0;

    while (y < height) : (y += 1) {

        const out_row = @as(u32, @intCast(dest.y + @as(i32, @intCast(y)))) * dst.stride + @as(u32, @intCast(dest.x));
        var x: u32 = 0;

        while (x < width) : (x += 1) {

            const from = pull_inward(x, y, width, height, band, pull, bend_bottom);
            const sample = sample_bent(small, small_w, small_h, x, y, from, width, height);
            var color = draw.mix(sample, look.color, look.cover);

            if (look.shine != 0) color = shine(color, look.shine);

            color = rim_light(color, x, y, width, height, bend_bottom);
            dst.pixels[out_row + x] = color;

        }

    }

}

/// How wide the bent rim is, in pixels. Tiny panels skip the bend so they stay readable.
fn edge_band(width: u32, height: u32) u32 {

    const shortest = @min(width, height);

    if (shortest < 8) return 0;

    const base = @min(@as(u32, 14), shortest / 3);

    return @max(@as(u32, 1), base * bend_amount / 4);

}

fn scaled_pull(band: u32) u32 {

    if (band == 0) return 0;

    const base = @max(@as(u32, 1), (band * 2) / 3);

    return @max(@as(u32, 1), base * bend_amount / 4);

}

/// Near the rim, look toward the middle of the panel. Strongest at the very edge, none inside.
fn pull_inward(x: u32, y: u32, width: u32, height: u32, band: u32, pull: u32, bend_bottom: bool) Point {

    if (band == 0 or pull == 0) return .{ .x = x, .y = y };

    var sample_x = x;
    var sample_y = y;

    if (x < band) sample_x = x + (band - x) * pull / band;

    const right_gap = width - 1 - x;

    if (right_gap < band) {

        const extra = (band - right_gap) * pull / band;

        sample_x = if (sample_x > extra) sample_x - extra else 0;

    }

    if (y < band) sample_y = y + (band - y) * pull / band;

    if (bend_bottom) {

        const bottom_gap = height - 1 - y;

        if (bottom_gap < band) {

            const extra = (band - bottom_gap) * pull / band;

            sample_y = if (sample_y > extra) sample_y - extra else 0;

        }

    }

    if (sample_x >= width) sample_x = width - 1;
    if (sample_y >= height) sample_y = height - 1;

    return .{ .x = sample_x, .y = sample_y };

}

/// On a bent pixel, red looks one step farther in and blue one step less far (a tiny prism).
/// Interior pixels (no bend) keep a single lookup.
fn sample_bent(
    small: []const u32,
    small_w: u32,
    small_h: u32,
    x: u32,
    y: u32,
    from: Point,
    dst_w: u32,
    dst_h: u32,
) Color {

    const mid = sample_small(small, small_w, small_h, from.x, from.y, dst_w, dst_h);

    if (from.x == x and from.y == y) return mid;

    const red = sample_small(small, small_w, small_h, nudge(from.x, x, dst_w, 1), nudge(from.y, y, dst_h, 1), dst_w, dst_h);
    const blue = sample_small(small, small_w, small_h, nudge(from.x, x, dst_w, -1), nudge(from.y, y, dst_h, -1), dst_w, dst_h);

    return draw.rgb(draw.red(red), draw.green(mid), draw.blue(blue));

}

fn nudge(from: u32, origin: u32, limit: u32, step: i32) u32 {

    if (from == origin or limit == 0) return from;

    const along: i32 = if (from > origin) 1 else -1;
    const next: i32 = @as(i32, @intCast(from)) + along * step;

    if (next < 0) return 0;

    return @min(@as(u32, @intCast(next)), limit - 1);

}

fn fits_small(width: u32, height: u32, step: u32, limit: usize) bool {

    const small_w: u32 = @max(1, (width + step - 1) / step);
    const small_h: u32 = @max(1, (height + step - 1) / step);

    return small_w * small_h <= limit;

}

fn sample_small(small: []const u32, small_w: u32, small_h: u32, x: u32, y: u32, dst_w: u32, dst_h: u32) Color {

    if (dst_w == 0 or dst_h == 0 or small_w == 0 or small_h == 0) return 0;

    const sx = @min(x * small_w / dst_w, small_w - 1);
    const sy = @min(y * small_h / dst_h, small_h - 1);
    const sx1 = @min(sx + 1, small_w - 1);
    const row = sy * small_w;
    const t: u8 = @intCast(@min(@as(u32, 255), (x * small_w % dst_w) * 255 / dst_w));

    return draw.mix(small[row + sx], small[row + sx1], t);

}

/// A bright lip on the top and left, a little shade on the bottom and right.
fn rim_light(color: Color, x: u32, y: u32, width: u32, height: u32, bend_bottom: bool) Color {

    var out = color;

    // One pixel only: a second top row sat just under the panel border and read as a washed-gray line.
    if (y == 0) out = draw.mix(out, draw.rgb(255, 255, 255), 28);
    if (x == 0) out = draw.mix(out, draw.rgb(255, 255, 255), 28);
    if (bend_bottom and y + 1 == height) out = draw.mix(out, draw.rgb(0, 0, 0), 28);
    if (x + 1 == width) out = draw.mix(out, draw.rgb(0, 0, 0), 20);

    return out;

}

fn shine(color: Color, amount: u8) Color {

    return draw.mix(color, draw.rgb(255, 255, 255), amount);

}

fn sample_pixel(surface: *const Surface, x: i32, y: i32, fallback: Color) Color {

    if (!surface.bounds().contains(x, y)) return fallback;

    return surface.pixels[@as(u32, @intCast(y)) * surface.stride + @as(u32, @intCast(x))];

}

fn average3(a: Color, b: Color, c: Color) Color {

    return draw.rgb(
        @intCast((@as(u32, draw.red(a)) + draw.red(b) + draw.red(c)) / 3),
        @intCast((@as(u32, draw.green(a)) + draw.green(b) + draw.green(c)) / 3),
        @intCast((@as(u32, draw.blue(a)) + draw.blue(b) + draw.blue(c)) / 3),
    );

}

const testing = std.testing;

test "glass of a solid rect is the tinted solid in the middle" {

    var src_pixels = [_]u32{draw.rgb(10, 20, 30)} ** 64;
    var dst_pixels = [_]u32{0} ** 64;
    var work_a: [16]u32 = undefined;
    var work_b: [16]u32 = undefined;

    const src = Surface.from_pixels(&src_pixels, 8, 8);
    const dst = Surface.from_pixels(&dst_pixels, 8, 8);
    const look = Look{ .color = draw.rgb(40, 40, 40), .cover = default_alpha, .shine = default_haze };

    make_glass_into(&src, src.bounds(), &dst, look, true, &work_a, &work_b);

    const expected = shine(draw.mix(draw.rgb(10, 20, 30), look.color, look.cover), look.shine);

    try testing.expectEqual(expected, dst_pixels[4 * 8 + 4]);

}

test "glass pulls neighbouring color across a hard edge" {

    var src_pixels = [_]u32{0} ** 64;
    var dst_pixels = [_]u32{0} ** 64;
    var work_a: [16]u32 = undefined;
    var work_b: [16]u32 = undefined;

    const src = Surface.from_pixels(&src_pixels, 8, 8);
    const dst = Surface.from_pixels(&dst_pixels, 8, 8);

    src.fill_rect(.{ .x = 0, .y = 0, .w = 4, .h = 8 }, draw.rgb(255, 255, 255));
    src.fill_rect(.{ .x = 4, .y = 0, .w = 4, .h = 8 }, draw.rgb(0, 0, 0));

    make_glass_into(&src, src.bounds(), &dst, Look{ .color = draw.rgb(0, 0, 0), .cover = default_alpha, .shine = default_haze }, true, &work_a, &work_b);

    try testing.expect(draw.red(dst_pixels[3 * 8 + 3]) < 250);
    try testing.expect(draw.red(dst_pixels[3 * 8 + 4]) > 5);

}

test "rim looks inward so the edge picks up interior colour" {

    var src_pixels = [_]u32{draw.rgb(200, 0, 0)} ** (32 * 32);
    var dst_pixels = [_]u32{0} ** (32 * 32);
    var work_a: [256]u32 = undefined;
    var work_b: [256]u32 = undefined;

    const src = Surface.from_pixels(&src_pixels, 32, 32);
    const dst = Surface.from_pixels(&dst_pixels, 32, 32);

    src.fill_rect(.{ .x = 8, .y = 0, .w = 4, .h = 32 }, draw.rgb(0, 200, 0));

    make_glass_into(&src, src.bounds(), &dst, Look{ .color = draw.rgb(0, 0, 0), .cover = 0, .shine = 0 }, true, &work_a, &work_b);

    try testing.expect(draw.green(dst_pixels[8 * 32]) > draw.green(dst_pixels[16 * 32 + 16]));

}

test "rounded blit leaves the outside of a corner untouched" {

    var src_pixels = [_]u32{draw.rgb(255, 0, 0)} ** (24 * 24);
    var dst_pixels = [_]u32{draw.rgb(0, 255, 0)} ** (24 * 24);

    const src = Surface.from_pixels(&src_pixels, 24, 24);
    const dst = Surface.from_pixels(&dst_pixels, 24, 24);

    blit_round(&dst, &src, dst.bounds(), dst.bounds());

    try testing.expectEqual(draw.rgb(0, 255, 0), dst_pixels[0]);
    try testing.expectEqual(draw.rgb(255, 0, 0), dst_pixels[12 * 24 + 12]);

}

test "top-rounded blit keeps the bottom corners of a title bar" {

    var src_pixels = [_]u32{draw.rgb(255, 0, 0)} ** (24 * 24);
    var dst_pixels = [_]u32{draw.rgb(0, 255, 0)} ** (24 * 24);

    const src = Surface.from_pixels(&src_pixels, 24, 24);
    const dst = Surface.from_pixels(&dst_pixels, 24, 24);

    blit_round_top(&dst, &src, dst.bounds(), dst.bounds());

    try testing.expectEqual(draw.rgb(0, 255, 0), dst_pixels[0]);
    try testing.expectEqual(draw.rgb(255, 0, 0), dst_pixels[23 * 24]);
    try testing.expectEqual(draw.rgb(255, 0, 0), dst_pixels[12 * 24 + 12]);

}
