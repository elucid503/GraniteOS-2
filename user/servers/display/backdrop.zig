// Quartz: a cached crystal pane for chrome (launcher, menus, taskbar, title bars).

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

const max_small: u32 = 128 * 1024;
const max_planes: u32 = 5;
const max_regions: u32 = 1 << max_planes;
const prism_spread: i32 = 2;

/// Shard lighting, lips, and prism only. Glass tint (Look.cover) is separate.
const effect_cover: u8 = 128;

pub const Look = struct {

    color: Color,
    cover: u8,
    shine: u8,

};

/// Where this dest sits in a larger crystal (title + body share one pane).
pub const Pane = struct {

    width: u32 = 0,
    height: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,

};

const Point = struct {

    x: u32,
    y: u32,

};

const Hit = struct {

    id: u32,
    cover: u8,

};

const Plane = struct {

    a: i32,
    b: i32,
    c: i32,
    den: i32,

};

const Crystal = struct {

    count: u32 = 0,
    planes: [max_planes]Plane = [_]Plane{.{ .a = 0, .b = 0, .c = 0, .den = 1 }} ** max_planes,
    dx: [max_regions]i8 = [_]i8{0} ** max_regions,
    dy: [max_regions]i8 = [_]i8{0} ** max_regions,
    tone: [max_regions]i8 = [_]i8{0} ** max_regions,

};

var scratch_a: [max_small]u32 = undefined;
var scratch_b: [max_small]u32 = undefined;

pub const Cache = struct {

    region: Handle = 0,
    base: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    capacity: usize = 0,
    seed: u32 = 0,
    pane_w: u32 = 0,
    pane_h: u32 = 0,
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
        .seed = 0,
        .pane_w = 0,
        .pane_h = 0,
        .valid = false,

    };

    return true;

}

/// Paints Quartz for `src_rect` into `dst`. `seed` is the window id so the crystal stays put.
pub fn make_glass(src: *const Surface, src_rect: Rect, dst: *const Surface, look: Look, seed: u32, shade_bottom: bool, pane: Pane) void {

    make_glass_into(src, src_rect, dst, look, seed, shade_bottom, pane, &scratch_a, &scratch_b);

}

pub fn make_glass_into(src: *const Surface, src_rect: Rect, dst: *const Surface, look: Look, seed: u32, shade_bottom: bool, pane: Pane, small_a: []u32, small_b: []u32) void {

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
    enlarge_glass(small_a, small_w, small_h, dst, dest.translated(-src_rect.x, -src_rect.y), look, seed, shade_bottom, pane);

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
        const y1 = src_rect.y + @as(i32, @intCast(@min(src_h - 1, sy * src_h / small_h + 1)));

        var sx: u32 = 0;

        while (sx < small_w) : (sx += 1) {

            const x0 = src_rect.x + @as(i32, @intCast(sx * src_w / small_w));
            const x1 = src_rect.x + @as(i32, @intCast(@min(src_w - 1, sx * src_w / small_w + 1)));

            if (inside) {

                const row0 = @as(u32, @intCast(y0)) * src.stride + @as(u32, @intCast(x0));
                const row1 = @as(u32, @intCast(y1)) * src.stride + @as(u32, @intCast(x0));
                const a = src.pixels[row0];
                const b = src.pixels[row0 + @as(u32, @intCast(x1 - x0))];
                const c = src.pixels[row1];
                const d = src.pixels[row1 + @as(u32, @intCast(x1 - x0))];

                small[sy * small_w + sx] = average4(a, b, c, d);

            } else {

                small[sy * small_w + sx] = average4(
                    sample_pixel(src, x0, y0, 0),
                    sample_pixel(src, x1, y0, 0),
                    sample_pixel(src, x0, y1, 0),
                    sample_pixel(src, x1, y1, 0),
                );

            }

        }

    }

}

fn covers_bounds(outer: Rect, inner: Rect) bool {

    return outer.x <= inner.x and outer.y <= inner.y and outer.x + outer.w >= inner.x + inner.w and outer.y + outer.h >= inner.y + inner.h;

}

fn enlarge_glass(small: []const u32, small_w: u32, small_h: u32, dst: *const Surface, dest: Rect, look: Look, seed: u32, shade_bottom: bool, pane: Pane) void {

    const width: u32 = @intCast(dest.w);
    const height: u32 = @intCast(dest.h);
    const pane_w = if (pane.width == 0) width else pane.width;
    const pane_h = if (pane.height == 0) height else pane.height;
    const crystal = build_crystal(seed, pane_w, pane_h);
    const lit = draw.mix(look.color, draw.rgb(255, 255, 255), 120);
    const shade = draw.mix(look.color, draw.rgb(0, 0, 0), 100);
    const lip_lit = draw.mix(look.color, draw.rgb(255, 255, 255), 160);
    const lip_shade = draw.mix(look.color, draw.rgb(0, 0, 0), 130);
    const lip_mid = draw.mix(look.color, draw.rgb(255, 255, 255), 90);
    const origin_x: i32 = @intCast(pane.x);
    const origin_y: i32 = @intCast(pane.y);
    const last_x: i32 = @intCast(width - 1);
    const last_y: i32 = @intCast(height - 1);

    var y: u32 = 0;

    while (y < height) : (y += 1) {

        const out_row = @as(u32, @intCast(dest.y + @as(i32, @intCast(y)))) * dst.stride + @as(u32, @intCast(dest.x));
        const py: i32 = origin_y + @as(i32, @intCast(y));
        var vs: [max_planes]i32 = undefined;
        var p: u32 = 0;

        while (p < crystal.count) : (p += 1) {

            const plane = crystal.planes[p];

            vs[p] = plane.a * origin_x + plane.b * py - plane.c;

        }

        var x: u32 = 0;

        while (x < width) : (x += 1) {

            const hit = classify_vs(&crystal, vs[0..crystal.count]);
            const from = displace(x, y, width, height, crystal.dx[hit.id], crystal.dy[hit.id]);
            const sample = sample_facet(small, small_w, small_h, x, y, from, width, height, hit.cover);
            var color = draw.mix(sample, look.color, look.cover);

            color = apply_tone(color, crystal.tone[hit.id], lit, shade);
            if (hit.cover != 0) color = cleavage_lip(color, crystal.tone[hit.id], lip_lit, lip_shade, lip_mid, hit.cover);
            if (look.shine != 0) color = shine(color, look.shine);

            if (x == 0 or y == 0 or @as(i32, @intCast(x)) == last_x or (shade_bottom and @as(i32, @intCast(y)) == last_y)) {

                color = rim_light(color, x, y, width, height, shade_bottom);

            }

            dst.pixels[out_row + x] = color;

            p = 0;

            while (p < crystal.count) : (p += 1) vs[p] += crystal.planes[p].a;

        }

    }

}

const steep = [_][2]i32{
    .{ 3, 1 }, .{ 4, 1 }, .{ 5, 1 }, .{ 6, 1 },
    .{ 3, -1 }, .{ 4, -1 }, .{ 5, -1 }, .{ 6, -1 },
};

const shallow = [_][2]i32{
    .{ 1, 3 }, .{ 1, 4 }, .{ 1, 5 }, .{ 1, 6 },
    .{ 1, -3 }, .{ 1, -4 }, .{ 1, -5 }, .{ 1, -6 },
};

const diagonal = [_][2]i32{
    .{ 1, 1 }, .{ 1, -1 }, .{ 2, 1 }, .{ 2, -1 },
    .{ 1, 2 }, .{ 1, -2 }, .{ 3, 2 }, .{ 2, 3 },
};

fn build_crystal(seed: u32, width: u32, height: u32) Crystal {

    var crystal: Crystal = .{};

    if (width < 12 or height < 12) return crystal;

    const shortest = @min(width, height);
    const wide = width >= height * 2;
    const tall = height >= width * 2;
    // Thin chrome needs extra cuts to read; large panes stay a handful so they don't shatter.
    const want: u32 = if (shortest < 48) 4 else 3;
    const pull: i32 = @intCast(@min(@as(u32, 6), @max(@as(u32, 4), shortest / 10)));

    var rng = seed ^ (width *% 0x51ed) ^ (height *% 0x7f4a7c15);
    if (rng == 0) rng = 1;

    if (wide) {

        add_from(&crystal, &rng, &shallow, width, height, want, 10);
        add_from(&crystal, &rng, &steep, width, height, want, 8);

    } else if (tall) {

        add_from(&crystal, &rng, &steep, width, height, want, 10);
        add_from(&crystal, &rng, &shallow, width, height, want, 8);

    }

    add_from(&crystal, &rng, &diagonal, width, height, want, 10);
    add_from(&crystal, &rng, &steep, width, height, want, 6);
    add_from(&crystal, &rng, &shallow, width, height, want, 6);

    if (crystal.count < 2) {

        _ = add_cut(&crystal, &rng, 1, 1, width, height);
        _ = add_cut(&crystal, &rng, 1, -1, width, height);

    }

    const regions: u32 = @as(u32, 1) << @intCast(crystal.count);
    var id: u32 = 0;

    while (id < regions) : (id += 1) {

        const h = mix_const(seed ^ (id *% 0x9e3779b9) ^ 0xa5a5a5a5);
        const mag: i32 = pull - 1 + @as(i32, @intCast(h % 3));
        const dir = (h >> 8) & 7;
        const dx_table = [_]i8{ 1, 1, 0, -1, -1, -1, 0, 1 };
        const dy_table = [_]i8{ 0, 1, 1, 1, 0, -1, -1, -1 };

        crystal.dx[id] = dx_table[dir] * @as(i8, @intCast(mag));
        crystal.dy[id] = dy_table[dir] * @as(i8, @intCast(mag));
        crystal.tone[id] = facet_tone(crystal.dx[id], crystal.dy[id]);

    }

    return crystal;

}

fn add_from(crystal: *Crystal, rng: *u32, table: []const [2]i32, width: u32, height: u32, want: u32, tries: u32) void {

    var n: u32 = 0;

    while (crystal.count < want and n < tries) : (n += 1) {

        const pick: u32 = mix(rng) % @as(u32, @intCast(table.len));

        _ = add_cut(crystal, rng, table[pick][0], table[pick][1], width, height);

    }

}

fn add_cut(crystal: *Crystal, rng: *u32, a: i32, b: i32, width: u32, height: u32) bool {

    if (crystal.count >= max_planes) return false;

    var i: u32 = 0;

    while (i < crystal.count) : (i += 1) {

        const p = crystal.planes[i];

        if ((p.a == a and p.b == b) or (p.a == -a and p.b == -b)) return false;

    }

    const span_ends = plane_span(a, b, width, height);
    const span = span_ends[1] - span_ends[0];

    if (span < 8) return false;

    const slack: u32 = @intCast(@divTrunc(span, 2));
    const c = span_ends[0] + @divTrunc(span, 4) + @as(i32, @intCast(mix(rng) % @max(@as(u32, 1), slack)));

    crystal.planes[crystal.count] = .{ .a = a, .b = b, .c = c, .den = a * a + b * b };
    crystal.count += 1;

    return true;

}

fn plane_span(a: i32, b: i32, width: u32, height: u32) struct { i32, i32 } {

    const w: i32 = @intCast(width - 1);
    const h: i32 = @intCast(height - 1);
    const corners = [_]i32{ 0, a * w, b * h, a * w + b * h };
    var min_v = corners[0];
    var max_v = corners[0];

    for (corners[1..]) |v| {

        if (v < min_v) min_v = v;
        if (v > max_v) max_v = v;

    }

    return .{ min_v, max_v };

}

fn classify(crystal: *const Crystal, x: i32, y: i32) Hit {

    var vs: [max_planes]i32 = undefined;
    var i: u32 = 0;

    while (i < crystal.count) : (i += 1) {

        const p = crystal.planes[i];

        vs[i] = p.a * x + p.b * y - p.c;

    }

    return classify_vs(crystal, vs[0..crystal.count]);

}

fn classify_vs(crystal: *const Crystal, vs: []const i32) Hit {

    var bits: u32 = 0;
    var near: u32 = 0;
    var best_num: i32 = 0;
    var best_den: i32 = 1;
    var i: u32 = 0;

    while (i < crystal.count) : (i += 1) {

        const v = vs[i];
        const den = crystal.planes[i].den;
        const d2 = v * v;

        if (v >= 0) bits |= @as(u32, 1) << @intCast(i);

        // One pixel of perpendicular distance: keeps diagonals thin instead of a blocky band.
        if (den > 0 and d2 <= den) {

            near += 1;
            const num = den - d2;

            if (near == 1 or num * best_den > best_num * den) {

                best_num = num;
                best_den = den;

            }

        }

    }

    if (near != 1) return .{ .id = bits, .cover = 0 };

    const cover: u8 = @intCast(@min(@as(i32, 255), @divTrunc(best_num * 255, best_den)));

    return .{ .id = bits, .cover = cover };

}

fn displace(x: u32, y: u32, width: u32, height: u32, dx: i8, dy: i8) Point {

    const nx = @as(i32, @intCast(x)) + dx;
    const ny = @as(i32, @intCast(y)) + dy;
    const last_x: i32 = @intCast(width - 1);
    const last_y: i32 = @intCast(height - 1);

    return .{
        .x = @intCast(@max(@as(i32, 0), @min(nx, last_x))),
        .y = @intCast(@max(@as(i32, 0), @min(ny, last_y))),
    };

}

/// Interior facets are one lookup. Pixels on a cleavage get a bilinear red/blue split.
fn sample_facet(small: []const u32, small_w: u32, small_h: u32, x: u32, y: u32, from: Point, dst_w: u32, dst_h: u32, cover: u8) Color {

    const mid = sample_small(small, small_w, small_h, from.x, from.y, dst_w, dst_h);

    if (cover == 0 or (from.x == x and from.y == y)) return mid;

    const dx: i32 = if (from.x > x) prism_spread else if (from.x < x) -prism_spread else 0;
    const dy: i32 = if (from.y > y) prism_spread else if (from.y < y) -prism_spread else 0;
    const red = sample_small(small, small_w, small_h, shift(from.x, dx, dst_w), shift(from.y, dy, dst_h), dst_w, dst_h);
    const blue = sample_small(small, small_w, small_h, shift(from.x, -dx, dst_w), shift(from.y, -dy, dst_h), dst_w, dst_h);
    const split = draw.rgb(draw.red(red), draw.green(mid), draw.blue(blue));
    const amount: u8 = @intCast(@as(u32, cover) * effect_cover / 255);

    return draw.mix(mid, split, amount);

}

fn shift(from: u32, step: i32, limit: u32) u32 {

    if (limit == 0) return from;

    const next: i32 = @as(i32, @intCast(from)) + step;

    if (next < 0) return 0;

    return @min(@as(u32, @intCast(next)), limit - 1);

}

/// Top-left light, same side as the rim. Facets that slant toward it read brighter.
fn facet_tone(dx: i8, dy: i8) i8 {

    const nl: i32 = -@as(i32, dx) - @as(i32, dy);

    if (nl >= 4) return @intCast(@min(@as(i32, 22), 12 + @divTrunc(nl, 2)));
    if (nl <= -4) return @intCast(-@min(@as(i32, 18), 10 + @divTrunc(-nl, 2)));

    return 0;

}

fn apply_tone(color: Color, tone: i8, lit: Color, shade: Color) Color {

    if (tone > 0) return draw.mix(color, lit, scale_effect(@intCast(tone)));
    if (tone < 0) return draw.mix(color, shade, scale_effect(@intCast(-tone)));

    return color;

}

fn cleavage_lip(color: Color, tone: i8, lip_lit: Color, lip_shade: Color, lip_mid: Color, cover: u8) Color {

    const target = if (tone > 0) lip_lit else if (tone < 0) lip_shade else lip_mid;
    const base: u8 = if (tone > 0) 52 else if (tone < 0) 36 else 24;
    const amount: u8 = @intCast(@as(u32, scale_effect(base)) * cover / 255);

    return draw.mix(color, target, amount);

}

fn scale_effect(amount: u8) u8 {

    return @intCast(@as(u32, amount) * effect_cover / 255);

}

fn mix(state: *u32) u32 {

    state.* +%= 0x9e3779b9;
    var z = state.*;

    z = (z ^ (z >> 16)) *% 0x21f0aaad;
    z = (z ^ (z >> 15)) *% 0x735a2d97;

    return z ^ (z >> 15);

}

fn mix_const(value: u32) u32 {

    var state = value;

    return mix(&state);

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
    const tx: u8 = @intCast(@min(@as(u32, 255), (x * small_w % dst_w) * 255 / dst_w));
    const ty: u8 = @intCast(@min(@as(u32, 255), (y * small_h % dst_h) * 255 / dst_h));
    const row0 = sy * small_w;

    if (tx == 0) {

        if (ty == 0) return small[row0 + sx];

        const sy1 = @min(sy + 1, small_h - 1);

        return draw.mix(small[row0 + sx], small[sy1 * small_w + sx], ty);

    }

    const sx1 = @min(sx + 1, small_w - 1);
    const top = draw.mix(small[row0 + sx], small[row0 + sx1], tx);

    if (ty == 0) return top;

    const sy1 = @min(sy + 1, small_h - 1);
    const row1 = sy1 * small_w;

    return draw.mix(top, draw.mix(small[row1 + sx], small[row1 + sx1], tx), ty);

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

fn average4(a: Color, b: Color, c: Color, d: Color) Color {

    return draw.rgb(
        @intCast((@as(u32, draw.red(a)) + draw.red(b) + draw.red(c) + draw.red(d)) / 4),
        @intCast((@as(u32, draw.green(a)) + draw.green(b) + draw.green(c) + draw.green(d)) / 4),
        @intCast((@as(u32, draw.blue(a)) + draw.blue(b) + draw.blue(c) + draw.blue(d)) / 4),
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

    make_glass_into(&src, src.bounds(), &dst, look, 1, true, .{}, &work_a, &work_b);

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

    make_glass_into(&src, src.bounds(), &dst, Look{ .color = draw.rgb(0, 0, 0), .cover = default_alpha, .shine = default_haze }, 1, true, .{}, &work_a, &work_b);

    try testing.expect(draw.red(dst_pixels[3 * 8 + 3]) < 250);
    try testing.expect(draw.red(dst_pixels[3 * 8 + 4]) > 5);

}

test "same window seed paints the same crystal" {

    var src_pixels = [_]u32{0} ** (32 * 32);
    var first = [_]u32{0} ** (32 * 32);
    var second = [_]u32{0} ** (32 * 32);
    var work_a: [256]u32 = undefined;
    var work_b: [256]u32 = undefined;

    const src = Surface.from_pixels(&src_pixels, 32, 32);
    const dst_a = Surface.from_pixels(&first, 32, 32);
    const dst_b = Surface.from_pixels(&second, 32, 32);

    src.fill_rect(.{ .x = 0, .y = 0, .w = 16, .h = 32 }, draw.rgb(220, 40, 40));
    src.fill_rect(.{ .x = 16, .y = 0, .w = 16, .h = 32 }, draw.rgb(40, 40, 220));

    const look = Look{ .color = draw.rgb(0, 0, 0), .cover = 0, .shine = 0 };

    make_glass_into(&src, src.bounds(), &dst_a, look, 11, true, .{}, &work_a, &work_b);
    make_glass_into(&src, src.bounds(), &dst_b, look, 11, true, .{}, &work_a, &work_b);

    try testing.expectEqualSlices(u32, &first, &second);

}

test "a different window seed paints a different crystal" {

    var src_pixels = [_]u32{0} ** (32 * 32);
    var first = [_]u32{0} ** (32 * 32);
    var second = [_]u32{0} ** (32 * 32);
    var work_a: [256]u32 = undefined;
    var work_b: [256]u32 = undefined;

    const src = Surface.from_pixels(&src_pixels, 32, 32);
    const dst_a = Surface.from_pixels(&first, 32, 32);
    const dst_b = Surface.from_pixels(&second, 32, 32);

    src.fill_rect(.{ .x = 0, .y = 0, .w = 16, .h = 32 }, draw.rgb(220, 40, 40));
    src.fill_rect(.{ .x = 16, .y = 0, .w = 16, .h = 32 }, draw.rgb(40, 40, 220));

    const look = Look{ .color = draw.rgb(0, 0, 0), .cover = 0, .shine = 0 };

    make_glass_into(&src, src.bounds(), &dst_a, look, 11, true, .{}, &work_a, &work_b);
    make_glass_into(&src, src.bounds(), &dst_b, look, 29, true, .{}, &work_a, &work_b);

    try testing.expect(!std.mem.eql(u32, &first, &second));

}

test "a title-bar-sized pane still gets cleavage" {

    const crystal = build_crystal(11, 240, 28);

    try testing.expect(crystal.count >= 3);
    try testing.expect(crystal.dx[0] != 0 or crystal.dy[0] != 0);

    const a = classify(&crystal, 12, 8);
    var found_other = false;
    var x: i32 = 0;

    while (x < 240) : (x += 11) {

        if (classify(&crystal, x, 14).id != a.id) {

            found_other = true;
            break;

        }

    }

    try testing.expect(found_other);

}

test "a large pane keeps three cleavage planes" {

    const crystal = build_crystal(11, 440, 320);

    try testing.expectEqual(@as(u32, 3), crystal.count);

}

test "facet tone follows the tilt toward the light" {

    const crystal = build_crystal(11, 64, 48);
    const regions: u32 = @as(u32, 1) << @intCast(crystal.count);
    var id: u32 = 0;

    while (id < regions) : (id += 1) {

        const nl: i32 = -@as(i32, crystal.dx[id]) - crystal.dy[id];

        if (nl >= 4) try testing.expect(crystal.tone[id] > 0);
        if (nl <= -4) try testing.expect(crystal.tone[id] < 0);

    }

}

test "title and body of one pane share the same cuts" {

    const crystal = build_crystal(7, 200, 120);
    const p = crystal.planes[0];
    var title_x: i32 = -1;
    var body_x: i32 = -1;
    var x: i32 = 0;

    while (x < 200) : (x += 1) {

        const tv = p.a * x + p.b * 10 - p.c;
        const bv = p.a * x + p.b * 50 - p.c;

        if (title_x < 0 and tv * tv <= p.den) title_x = x;
        if (body_x < 0 and bv * bv <= p.den) body_x = x;

    }

    try testing.expect(title_x >= 0);
    try testing.expect(body_x >= 0);

}

test "cleavage splits a pane into more than one facet" {

    const crystal = build_crystal(11, 64, 48);

    try testing.expect(crystal.count == 3);

    const a = classify(&crystal, 8, 8);
    var found_other = false;
    var y: i32 = 0;

    while (y < 48) : (y += 7) {

        var x: i32 = 0;

        while (x < 64) : (x += 7) {

            if (classify(&crystal, x, y).id != a.id) {

                found_other = true;
                break;

            }

        }

        if (found_other) break;

    }

    try testing.expect(found_other);

}

test "a cleavage pixel sits on a plane" {

    const crystal = build_crystal(11, 64, 48);
    const p = crystal.planes[0];
    var found_edge = false;
    var x: i32 = 0;

    while (x < 64) : (x += 1) {

        var y: i32 = 0;

        while (y < 48) : (y += 1) {

            const v = p.a * x + p.b * y - p.c;

            if (v * v <= p.a * p.a + p.b * p.b and classify(&crystal, x, y).cover != 0) {

                found_edge = true;
                break;

            }

        }

        if (found_edge) break;

    }

    try testing.expect(found_edge);

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
