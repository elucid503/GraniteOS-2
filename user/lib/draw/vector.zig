// SVG icon/cursor renderer for the outline icon set; icons cached as 8-bit coverage per source and size.

const std = @import("std");

const draw_mod = @import("draw.zig");
const path_mod = @import("path.zig");
const raster = @import("raster.zig");
const stroke = @import("stroke.zig");

const Color = draw_mod.Color;
const Path = path_mod.Path;
const Point = path_mod.Point;
const Rect = draw_mod.Rect;
const Surface = draw_mod.Surface;

const max_poly_points = 256;

const ViewBox = struct {

    x: f32 = 0,
    y: f32 = 0,

    w: f32 = 24,
    h: f32 = 24,

};

// Maps view-box user units into destination pixels.

const Transform = struct {

    view: ViewBox,
    dest: Rect,
    // Subpixel offset so stroke centres land on pixel centres (odd widths) or pixel edges (even).
    snap: f32 = 0,

    fn x(self: *const Transform, value: f32) f32 {

        return path_mod.from_px(self.dest.x) + (value - self.view.x) * path_mod.from_px(self.dest.w) / self.view.w + self.snap;

    }

    fn y(self: *const Transform, value: f32) f32 {

        return path_mod.from_px(self.dest.y) + (value - self.view.y) * path_mod.from_px(self.dest.h) / self.view.h + self.snap;

    }

    fn length(self: *const Transform, value: f32) f32 {

        return value * path_mod.from_px(@min(self.dest.w, self.dest.h)) / @min(self.view.w, self.view.h);

    }

    fn point(self: *const Transform, p: Point) Point {

        return .{ .x = self.x(p.x), .y = self.y(p.y) };

    }

};

/// Half-pixel snap for near-odd integer widths so hairlines sit on pixel centres.
fn stroke_snap(width: f32) f32 {

    const nearest = @round(width);

    // Fractional Lucide widths keep their true subpixel phase; only snap clean integers.
    if (@abs(width - nearest) > 0.05) return 0;

    const width_px: i32 = @intFromFloat(nearest);

    return if ((width_px & 1) != 0) 0.5 else 0;

}

/// Lucide default: stroke-width 2 in a 24-unit viewBox. Kept fractional for AA (the FP raster handles it).
fn icon_stroke_width(side_px: i32, width_in: f32) f32 {

    if (width_in > 0) return width_in;

    const side = path_mod.from_px(side_px);

    return @max(1.0 / 32.0, side * 2.0 / 24.0);

}

/// Build stroked SVG shapes into path; width zero uses the Lucide 2/24 default.
pub fn build_stroked(path: *Path, rect: Rect, svg: []const u8, width_in: f32) void {

    const side_px = @min(rect.w, rect.h);
    const width = icon_stroke_width(side_px, width_in);
    const transform = Transform{ .view = parse_view_box(svg), .dest = rect, .snap = stroke_snap(width) };

    var offset: usize = 0;

    while (find_tag(svg, "path", &offset)) |tag| {

        if (attr(tag, "d")) |d| stroke_path_data(path, &transform, d, width);

    }

    offset = 0;

    while (find_tag(svg, "line", &offset)) |tag| {

        const x1 = parse_attr_number(tag, "x1") orelse continue;
        const y1 = parse_attr_number(tag, "y1") orelse continue;
        const x2 = parse_attr_number(tag, "x2") orelse continue;
        const y2 = parse_attr_number(tag, "y2") orelse continue;

        const a = transform.point(.{ .x = x1, .y = y1 });
        const b = transform.point(.{ .x = x2, .y = y2 });

        stroke.segment(path, a.x, a.y, b.x, b.y, width);

    }

    offset = 0;

    while (find_tag(svg, "polyline", &offset)) |tag| {

        if (attr(tag, "points")) |points| stroke_points(path, &transform, points, false, width);

    }

    offset = 0;

    while (find_tag(svg, "polygon", &offset)) |tag| {

        if (attr(tag, "points")) |points| stroke_points(path, &transform, points, true, width);

    }

    offset = 0;

    while (find_tag(svg, "circle", &offset)) |tag| {

        const cx = parse_attr_number(tag, "cx") orelse continue;
        const cy = parse_attr_number(tag, "cy") orelse continue;
        const r = parse_attr_number(tag, "r") orelse continue;

        const center = transform.point(.{ .x = cx, .y = cy });

        stroke.circle_border(path, center.x, center.y, transform.length(r), width);

    }

    offset = 0;

    while (find_tag(svg, "rect", &offset)) |tag| {

        const x = parse_attr_number(tag, "x") orelse 0;
        const y = parse_attr_number(tag, "y") orelse 0;
        const w = parse_attr_number(tag, "width") orelse continue;
        const h = parse_attr_number(tag, "height") orelse continue;
        const radius = parse_attr_number(tag, "rx") orelse 0;

        const origin = transform.point(.{ .x = x, .y = y });
        const px_w = transform.x(x + w) - origin.x;
        const px_h = transform.y(y + h) - origin.y;
        const px_r = transform.length(radius);

        // Outline as a continuous stroke (not a fill-ring) so nested Lucide rects stay hollow at small sizes.
        stroke_round_rect_outline(path, origin.x, origin.y, px_w, px_h, px_r, width);

    }

}

/// Build the filled interior of every closed shape in `svg` into `path`, sized to `rect`.
pub fn build_filled(path: *Path, rect: Rect, svg: []const u8) void {

    const transform = Transform{ .view = parse_view_box(svg), .dest = rect };

    var offset: usize = 0;

    while (find_tag(svg, "path", &offset)) |tag| {

        if (attr(tag, "d")) |d| fill_path_data(path, &transform, d);

    }

    offset = 0;

    while (find_tag(svg, "polygon", &offset)) |tag| {

        if (attr(tag, "points")) |points| fill_points(path, &transform, points);

    }

    offset = 0;

    while (find_tag(svg, "circle", &offset)) |tag| {

        const cx = parse_attr_number(tag, "cx") orelse continue;
        const cy = parse_attr_number(tag, "cy") orelse continue;
        const r = parse_attr_number(tag, "r") orelse continue;

        const center = transform.point(.{ .x = cx, .y = cy });

        path.add_circle(center.x, center.y, transform.length(r));

    }

    offset = 0;

    while (find_tag(svg, "rect", &offset)) |tag| {

        const x = parse_attr_number(tag, "x") orelse 0;
        const y = parse_attr_number(tag, "y") orelse 0;
        const w = parse_attr_number(tag, "width") orelse continue;
        const h = parse_attr_number(tag, "height") orelse continue;
        const radius = parse_attr_number(tag, "rx") orelse 0;

        const origin = transform.point(.{ .x = x, .y = y });

        path.add_round_rect(origin.x, origin.y, transform.x(x + w) - origin.x, transform.y(y + h) - origin.y, transform.length(radius));

    }

}

/// Stroke-render `svg` into `rect` on `surface` without caching.
pub fn draw_icon(surface: *const Surface, rect: Rect, svg: []const u8, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0) return;

    if (rect.w <= icon_box and rect.h <= icon_box) {

        var coverage: [icon_box * icon_box]u8 = undefined;
        const cells: usize = @intCast(rect.w * rect.h);

        if (!rasterize_icon(svg, @intCast(rect.w), @intCast(rect.h), coverage[0..cells])) return;

        surface.blend_coverage(rect.x, rect.y, coverage[0..cells], @intCast(rect.w), @intCast(rect.h), color);

        return;

    }

    var path = Path{};

    build_stroked(&path, rect, svg, 0);
    raster.fill(surface, &path, color);

}

// Icon cache: one coverage mask per static SVG pointer and size; single-threaded like the glyph cache.

const icon_box: u32 = 48;
const icon_hi_box: u32 = 96;
const icon_capacity: usize = 96;
const icon_ss: u32 = 2;

const IconEntry = struct {

    used: bool = false,
    key: u64 = 0,

    w: u16 = 0,
    h: u16 = 0,

};

var icon_meta = [_]IconEntry{.{}} ** icon_capacity;
var icon_coverage: [icon_capacity][icon_box * icon_box]u8 = undefined;
var icon_hi: [icon_hi_box * icon_hi_box]u8 = undefined;

/// Cached stroke-rendered icon; the everyday entry point.
pub fn icon(surface: *const Surface, rect: Rect, svg: []const u8, color: Color) void {

    if (rect.w > 0 and rect.h > 0 and rect.w <= icon_box and rect.h <= icon_box) {

        if (cached_icon(svg, @intCast(rect.w), @intCast(rect.h))) |slot| {

            const entry = icon_meta[slot];

            surface.blend_coverage(rect.x, rect.y, icon_coverage[slot][0 .. @as(u32, entry.w) * entry.h], entry.w, entry.h, color);

            return;

        }

    }

    draw_icon(surface, rect, svg, color);

}

/// Icon centered in `rect` at its shorter side.
pub fn icon_in(surface: *const Surface, rect: Rect, svg: []const u8, color: Color) void {

    const size = @min(rect.w, rect.h);

    const x = rect.x + @divTrunc(rect.w - size, 2);
    const y = rect.y + @divTrunc(rect.h - size, 2);

    icon(surface, .{ .x = x, .y = y, .w = size, .h = size }, svg, color);

}

// Static Lucide embeds are unique by pointer; size fits in the high bits.
fn icon_key(svg: []const u8, w: u32, h: u32) u64 {

    return @intFromPtr(svg.ptr) ^ (@as(u64, svg.len) *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, w) << 40) ^ (@as(u64, h) << 48);

}

fn cached_icon(svg: []const u8, w: u32, h: u32) ?usize {

    const key = icon_key(svg, w, h);
    const start: usize = @intCast((key ^ (key >> 32)) % icon_capacity);

    var probe: usize = 0;
    var slot = start;

    while (probe < 12) : (probe += 1) {

        const entry = &icon_meta[slot];

        if (entry.used and entry.key == key) return slot;

        if (!entry.used) return render_icon(slot, svg, key, w, h);

        slot = (slot + 1) % icon_capacity;

    }

    return render_icon(start, svg, key, w, h);

}

fn render_icon(slot: usize, svg: []const u8, key: u64, w: u32, h: u32) ?usize {

    const cells = w * h;

    if (!rasterize_icon(svg, w, h, icon_coverage[slot][0..cells])) return null;

    icon_meta[slot] = .{

        .used = true,
        .key = key,

        .w = @intCast(w),
        .h = @intCast(h),

    };

    return slot;

}

/// Rasterize `svg` into `out` (w×h coverage). 2× supersample when it fits for crisper small icons.
fn rasterize_icon(svg: []const u8, w: u32, h: u32, out: []u8) bool {

    const cells = w * h;

    if (out.len < cells) return false;

    @memset(out[0..cells], 0);

    const ss: u32 = if (w * icon_ss <= icon_hi_box and h * icon_ss <= icon_hi_box) icon_ss else 1;
    const rw = w * ss;
    const rh = h * ss;
    const hi_cells = rw * rh;

    var path = Path{};

    build_stroked(&path, .{ .x = 0, .y = 0, .w = @intCast(rw), .h = @intCast(rh) }, svg, 0);

    if (path.overflowed) return false;

    if (ss == 1) {

        raster.fill_coverage(&path, out[0..cells], w, h, 0, 0);

        return true;

    }

    @memset(icon_hi[0..hi_cells], 0);
    raster.fill_coverage(&path, icon_hi[0..hi_cells], rw, rh, 0, 0);

    // Box-filter 2×2 → 1 coverage sample per destination pixel.
    var y: u32 = 0;

    while (y < h) : (y += 1) {

        var x: u32 = 0;

        while (x < w) : (x += 1) {

            const base = (y * ss) * rw + x * ss;
            const sum: u32 = @as(u32, icon_hi[base]) + icon_hi[base + 1] + icon_hi[base + rw] + icon_hi[base + rw + 1];

            out[y * w + x] = @intCast((sum + 2) / 4);

        }

    }

    return true;

}

// Cursor rasterization: ARGB plane with outline under fill/stroke so the pointer reads on any background.

pub const CursorStyle = enum {

    filled,
    stroked,
    white_line,

};

pub fn raster_cursor(side: usize, pixels: [*]u32, svg: []const u8, dst: Rect, fill_color: Color, outline_color: Color, style: CursorStyle) void {

    @memset(pixels[0 .. side * side], 0);

    var under: [cursor_box * cursor_box]u8 = undefined;
    var over: [cursor_box * cursor_box]u8 = undefined;

    if (side > cursor_box) return;

    @memset(under[0 .. side * side], 0);
    @memset(over[0 .. side * side], 0);

    const w: u32 = @intCast(side);
    const thin = @max(1, path_mod.from_px(@divTrunc(@min(dst.w, dst.h), 24)));
    const thick = @max(2, path_mod.from_px(@divTrunc(@min(dst.w, dst.h), 8)));

    var path = Path{};

    switch (style) {

        .filled => {

            // Outline stroke beneath the filled interior.

            build_stroked(&path, dst, svg, thin + 1);
            raster.fill_coverage(&path, under[0 .. side * side], w, w, 0, 0);

            path.reset();
            build_filled(&path, dst, svg);
            raster.fill_coverage(&path, over[0 .. side * side], w, w, 0, 0);

        },

        .stroked => {

            build_stroked(&path, dst, svg, thick);
            raster.fill_coverage(&path, under[0 .. side * side], w, w, 0, 0);

            path.reset();
            build_stroked(&path, dst, svg, @max(1.5, thick - 1));
            raster.fill_coverage(&path, over[0 .. side * side], w, w, 0, 0);

        },

        .white_line => {

            path.reset();
            build_stroked(&path, dst, svg, thin);
            raster.fill_coverage(&path, over[0 .. side * side], w, w, 0, 0);

        },

    }

    var index: usize = 0;

    while (index < side * side) : (index += 1) {

        const outline_alpha = under[index];
        const fill_alpha = over[index];

        if (outline_alpha == 0 and fill_alpha == 0) continue;

        pixels[index] = argb_over(argb(outline_color, outline_alpha), argb(fill_color, fill_alpha));

    }

}

const cursor_box = 64;

fn argb(color: Color, alpha: u8) u32 {

    return (@as(u32, alpha) << 24) | (color & 0x00ff_ffff);

}

/// Source-over compositing of two ARGB pixels.
fn argb_over(under_px: u32, over_px: u32) u32 {

    const oa: u32 = over_px >> 24;

    if (oa == 255) return over_px;
    if (oa == 0) return under_px;

    const ua: u32 = under_px >> 24;
    const inv = 255 - oa;

    const out_a = oa + (ua * inv + 127) / 255;

    if (out_a == 0) return 0;

    var out: u32 = out_a << 24;

    inline for ([_]u5{ 16, 8, 0 }) |shift| {

        const oc = (over_px >> shift) & 0xff;
        const uc = (under_px >> shift) & 0xff;

        // Straight-alpha over: (oc*oa + uc*ua*(1-oa)) / out_a.

        const value = (oc * oa + (uc * ua * inv + 127) / 255 + out_a / 2) / out_a;

        out |= @as(u32, @min(value, 255)) << shift;

    }

    return out;

}

// Shape walkers.

fn stroke_points(path: *Path, transform: *const Transform, text: []const u8, close: bool, width: f32) void {

    var parser = PathParser{ .text = text };
    var points: [max_poly_points]Point = undefined;
    var count: usize = 0;

    while (parser.point(false, .{ .x = 0, .y = 0 })) |p| {

        if (count >= points.len) break;

        points[count] = transform.point(.{ .x = p.x, .y = p.y });
        count += 1;

    }

    if (close) {

        stroke.polygon(path, points[0..count], width);

    } else {

        stroke.polyline(path, points[0..count], width);

    }

}

fn fill_points(path: *Path, transform: *const Transform, text: []const u8) void {

    var parser = PathParser{ .text = text };
    var first = true;

    while (parser.point(false, .{ .x = 0, .y = 0 })) |p| {

        const mapped = transform.point(.{ .x = p.x, .y = p.y });

        if (first) {

            path.move_to(mapped.x, mapped.y);
            first = false;

        } else {

            path.line_to(mapped.x, mapped.y);

        }

    }

    path.close();

}

fn fill_path_data(path: *Path, transform: *const Transform, d: []const u8) void {

    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var control = current;
    var last_was_cubic = false;

    while (parser.more()) {

        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {

            'M' => {

                const p = parser.point(relative, current) orelse break;

                current = p;
                start = p;
                control = p;
                last_was_cubic = false;

                const mapped = transform.point(p);

                path.move_to(mapped.x, mapped.y);

                command = if (relative) 'l' else 'L';

            },

            'L' => {

                const p = parser.point(relative, current) orelse break;
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'H' => {

                const x = parser.number() orelse break;
                const p = Point{ .x = if (relative) current.x + x else x, .y = current.y };
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'V' => {

                const y = parser.number() orelse break;
                const p = Point{ .x = current.x, .y = if (relative) current.y + y else y };
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'Q' => {

                const c = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                const mc = transform.point(c);
                const me = transform.point(end);

                path.quad_to(mc.x, mc.y, me.x, me.y);

                current = end;
                control = c;
                last_was_cubic = false;

            },

            'C' => {

                const c1 = parser.point(relative, current) orelse break;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                const m1 = transform.point(c1);
                const m2 = transform.point(c2);
                const me = transform.point(end);

                path.cubic_to(m1.x, m1.y, m2.x, m2.y, me.x, me.y);

                current = end;
                control = c2;
                last_was_cubic = true;

            },

            'S' => {

                const c1 = if (last_was_cubic)
                    Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y }
                else
                    current;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                const m1 = transform.point(c1);
                const m2 = transform.point(c2);
                const me = transform.point(end);

                path.cubic_to(m1.x, m1.y, m2.x, m2.y, me.x, me.y);

                current = end;
                control = c2;
                last_was_cubic = true;

            },

            'T' => {

                const reflected = Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.point(relative, current) orelse break;

                const mc = transform.point(reflected);
                const me = transform.point(end);

                path.quad_to(mc.x, mc.y, me.x, me.y);

                current = end;
                control = reflected;
                last_was_cubic = false;

            },

            'A' => {

                const rx = parser.number() orelse break;
                const ry = parser.number() orelse break;
                const rotation = parser.number() orelse break;
                const large = parser.number() orelse break;
                const sweep = parser.number() orelse break;
                const end = parser.point(relative, current) orelse break;

                fill_arc(path, transform, current, end, rx, ry, rotation, large != 0, sweep != 0);

                current = end;
                control = end;
                last_was_cubic = false;

            },

            'Z' => {

                path.close();
                current = start;
                control = start;
                last_was_cubic = false;

            },

            else => break,

        }

    }

    path.close();

}

fn stroke_path_data(path: *Path, transform: *const Transform, d: []const u8, width: f32) void {

    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var control = current;
    var last_was_cubic = false;

    while (parser.more()) {

        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {

            'M' => {

                const p = parser.point(relative, current) orelse break;

                current = p;
                start = p;
                control = p;
                last_was_cubic = false;
                command = if (relative) 'l' else 'L';

            },

            'L' => {

                const p = parser.point(relative, current) orelse break;

                stroke_between(path, transform, current, p, width);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'H' => {

                const x = parser.number() orelse break;
                const p = Point{ .x = if (relative) current.x + x else x, .y = current.y };

                stroke_between(path, transform, current, p, width);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'V' => {

                const y = parser.number() orelse break;
                const p = Point{ .x = current.x, .y = if (relative) current.y + y else y };

                stroke_between(path, transform, current, p, width);
                current = p;
                control = p;
                last_was_cubic = false;

            },

            'Q' => {

                const c = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                stroke_quad(path, transform, current, c, end, width);

                current = end;
                control = c;
                last_was_cubic = false;

            },

            'C' => {

                const c1 = parser.point(relative, current) orelse break;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                stroke_cubic(path, transform, current, c1, c2, end, width);

                current = end;
                control = c2;
                last_was_cubic = true;

            },

            'S' => {

                const c1 = if (last_was_cubic)
                    Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y }
                else
                    current;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;

                stroke_cubic(path, transform, current, c1, c2, end, width);

                current = end;
                control = c2;
                last_was_cubic = true;

            },

            'T' => {

                const reflected = Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.point(relative, current) orelse break;

                stroke_quad(path, transform, current, reflected, end, width);

                current = end;
                control = reflected;
                last_was_cubic = false;

            },

            'A' => {

                const rx = parser.number() orelse break;
                const ry = parser.number() orelse break;
                const rotation = parser.number() orelse break;
                const large = parser.number() orelse break;
                const sweep = parser.number() orelse break;
                const end = parser.point(relative, current) orelse break;

                stroke_arc(path, transform, current, end, rx, ry, rotation, large != 0, sweep != 0, width);

                current = end;
                control = end;
                last_was_cubic = false;

            },

            'Z' => {

                stroke_between(path, transform, current, start, width);
                current = start;
                control = start;
                last_was_cubic = false;

            },

            else => break,

        }

    }

}

fn stroke_between(path: *Path, transform: *const Transform, a: Point, b: Point, width: f32) void {

    const ma = transform.point(a);
    const mb = transform.point(b);

    stroke.segment(path, ma.x, ma.y, mb.x, mb.y, width);

}

/// Stroke a rounded-rect outline as a continuous chain (no per-sample join discs).
fn stroke_round_rect_outline(path: *Path, x: f32, y: f32, w: f32, h: f32, radius_in: f32, width: f32) void {

    if (w <= 0 or h <= 0 or width <= 0) return;

    const radius = @max(0, @min(radius_in, @min(w, h) * 0.5));
    const half = width * 0.5;

    // Analytic ring: exact hollow border, no tessellation noise at nested Lucide rects.
    if (w > width and h > width) {

        path.add_round_rect(x - half, y - half, w + width, h + width, radius + half);
        path.add_round_rect_reversed(x + half, y + half, w - width, h - width, @max(0, radius - half));

        return;

    }

    // Too small for a clear hole: filled rounded rect of the stroke footprint.
    path.add_round_rect(x - half, y - half, w + width, h + width, radius + half);

}

// Elliptical arc → cubics (SVG impl note). Used heavily by Lucide rounded corners.

const ArcCubic = struct {

    c1: Point,
    c2: Point,
    end: Point,

};

fn fill_arc(path: *Path, transform: *const Transform, from: Point, to: Point, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep: bool) void {

    var cubics: [4]ArcCubic = undefined;
    const count = arc_to_cubics(from, to, rx_in, ry_in, rotation_deg, large, sweep, &cubics);

    for (cubics[0..count]) |seg| {

        const m1 = transform.point(seg.c1);
        const m2 = transform.point(seg.c2);
        const me = transform.point(seg.end);

        path.cubic_to(m1.x, m1.y, m2.x, m2.y, me.x, me.y);

    }

}

fn stroke_arc(path: *Path, transform: *const Transform, from: Point, to: Point, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep: bool, width: f32) void {

    var cubics: [4]ArcCubic = undefined;
    const count = arc_to_cubics(from, to, rx_in, ry_in, rotation_deg, large, sweep, &cubics);

    var prev = from;

    for (cubics[0..count]) |seg| {

        stroke_cubic(path, transform, prev, seg.c1, seg.c2, seg.end, width);
        prev = seg.end;

    }

}

fn arc_to_cubics(from: Point, to: Point, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep: bool, out: *[4]ArcCubic) usize {

    var rx = @abs(rx_in);
    var ry = @abs(ry_in);

    if (rx == 0 or ry == 0 or (from.x == to.x and from.y == to.y)) {

        out[0] = .{ .c1 = from, .c2 = to, .end = to };

        return 1;

    }

    const phi = rotation_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    const dx = (from.x - to.x) * 0.5;
    const dy = (from.y - to.y) * 0.5;

    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // Scale radii when the ellipse is too small for the endpoints.
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);

    if (lambda > 1) {

        const scale = @sqrt(lambda);

        rx *= scale;
        ry *= scale;

    }

    const rx_sq = rx * rx;
    const ry_sq = ry * ry;
    const x1p_sq = x1p * x1p;
    const y1p_sq = y1p * y1p;

    var num = rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq;
    const den = rx_sq * y1p_sq + ry_sq * x1p_sq;

    num = if (num < 0) 0 else num;

    var coef = if (den == 0) 0 else @sqrt(num / den);

    if (large == sweep) coef = -coef;

    const cxp = coef * (rx * y1p) / ry;
    const cyp = coef * -(ry * x1p) / rx;

    const cx = cos_phi * cxp - sin_phi * cyp + (from.x + to.x) * 0.5;
    const cy = sin_phi * cxp + cos_phi * cyp + (from.y + to.y) * 0.5;

    const start_vec_x = (x1p - cxp) / rx;
    const start_vec_y = (y1p - cyp) / ry;
    const end_vec_x = (-x1p - cxp) / rx;
    const end_vec_y = (-y1p - cyp) / ry;

    const theta1 = vector_angle(1, 0, start_vec_x, start_vec_y);
    var delta = vector_angle(start_vec_x, start_vec_y, end_vec_x, end_vec_y);

    if (!sweep and delta > 0) delta -= 2 * std.math.pi;
    if (sweep and delta < 0) delta += 2 * std.math.pi;

    // One cubic covers at most a quarter turn.
    const segments: usize = @intFromFloat(@ceil(@abs(delta) / (std.math.pi * 0.5)));
    const count = @max(@as(usize, 1), @min(segments, 4));
    const delta_seg = delta / @as(f32, @floatFromInt(count));

    // alpha = 4/3 * tan(delta/4) for the unit-circle cubic approximation.
    const alpha = 4.0 / 3.0 * @tan(delta_seg * 0.25);

    var index: usize = 0;

    while (index < count) : (index += 1) {

        const t0 = theta1 + delta_seg * @as(f32, @floatFromInt(index));
        const t1 = t0 + delta_seg;

        const cos0 = @cos(t0);
        const sin0 = @sin(t0);
        const cos1 = @cos(t1);
        const sin1 = @sin(t1);

        const p0 = ellipse_point(cx, cy, rx, ry, cos_phi, sin_phi, cos0, sin0);
        const p1 = ellipse_point(cx, cy, rx, ry, cos_phi, sin_phi, cos1, sin1);

        const e0x = -rx * cos_phi * sin0 - ry * sin_phi * cos0;
        const e0y = -rx * sin_phi * sin0 + ry * cos_phi * cos0;
        const e1x = -rx * cos_phi * sin1 - ry * sin_phi * cos1;
        const e1y = -rx * sin_phi * sin1 + ry * cos_phi * cos1;

        out[index] = .{

            .c1 = .{ .x = p0.x + alpha * e0x, .y = p0.y + alpha * e0y },
            .c2 = .{ .x = p1.x - alpha * e1x, .y = p1.y - alpha * e1y },
            .end = p1,

        };

    }

    // Snap the first sample to the true start so floating error does not open a gap.
    if (count > 0) {

        const e0x = -rx * cos_phi * @sin(theta1) - ry * sin_phi * @cos(theta1);
        const e0y = -rx * sin_phi * @sin(theta1) + ry * cos_phi * @cos(theta1);

        out[0].c1 = .{ .x = from.x + alpha * e0x, .y = from.y + alpha * e0y };
        out[count - 1].end = to;

    }

    return count;

}

fn ellipse_point(cx: f32, cy: f32, rx: f32, ry: f32, cos_phi: f32, sin_phi: f32, cos_t: f32, sin_t: f32) Point {

    return .{

        .x = cx + rx * cos_phi * cos_t - ry * sin_phi * sin_t,
        .y = cy + rx * sin_phi * cos_t + ry * cos_phi * sin_t,

    };

}

fn vector_angle(ux: f32, uy: f32, vx: f32, vy: f32) f32 {

    const dot = ux * vx + uy * vy;
    const len = @sqrt(ux * ux + uy * uy) * @sqrt(vx * vx + vy * vy);

    if (len == 0) return 0;

    const cos_a = std.math.clamp(dot / len, -1, 1);
    const angle = std.math.acos(cos_a);

    return if (ux * vy - uy * vx < 0) -angle else angle;

}

const max_curve_steps = 24;

// Steps follow the control polygon's length in destination pixels: tiny icons stop over-tessellating
// (every extra vertex used to cost a join disc) and large ones stop faceting.

fn curve_steps(transform: *const Transform, hull: []const Point) usize {

    var span: f32 = 0;

    for (hull[1..], 0..) |p, index| {

        span += @abs(p.x - hull[index].x) + @abs(p.y - hull[index].y);

    }

    return @intFromFloat(std.math.clamp(transform.length(span) * 0.5, 3, max_curve_steps));

}

fn stroke_quad(path: *Path, transform: *const Transform, a: Point, b: Point, c: Point, width: f32) void {

    const steps = curve_steps(transform, &.{ a, b, c });

    var points: [max_curve_steps + 1]Point = undefined;

    for (points[0 .. steps + 1], 0..) |*out, step| {

        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const mt = 1 - t;

        out.* = transform.point(.{

            .x = mt * mt * a.x + 2 * mt * t * b.x + t * t * c.x,
            .y = mt * mt * a.y + 2 * mt * t * b.y + t * t * c.y,

        });

    }

    stroke.chain(path, points[0 .. steps + 1], width);

}

fn stroke_cubic(path: *Path, transform: *const Transform, a: Point, b: Point, c: Point, d: Point, width: f32) void {

    const steps = curve_steps(transform, &.{ a, b, c, d });

    var points: [max_curve_steps + 1]Point = undefined;

    for (points[0 .. steps + 1], 0..) |*out, step| {

        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const mt = 1 - t;

        out.* = transform.point(.{

            .x = mt * mt * mt * a.x + 3 * mt * mt * t * b.x + 3 * mt * t * t * c.x + t * t * t * d.x,
            .y = mt * mt * mt * a.y + 3 * mt * mt * t * b.y + 3 * mt * t * t * c.y + t * t * t * d.y,

        });

    }

    stroke.chain(path, points[0 .. steps + 1], width);

}

// Parsing (decimal numbers, tolerant of the icon set's formatting).

const PathParser = struct {

    text: []const u8,
    offset: usize = 0,

    fn more(self: *PathParser) bool {

        self.skip();

        return self.offset < self.text.len;

    }

    fn peek_command(self: *PathParser) ?u8 {

        self.skip();

        if (self.offset >= self.text.len) return null;

        const c = self.text[self.offset];

        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {

            self.offset += 1;

            return c;

        }

        return null;

    }

    fn point(self: *PathParser, relative: bool, current: Point) ?Point {

        const x = self.number() orelse return null;
        const y = self.number() orelse return null;

        if (relative) return .{ .x = current.x + x, .y = current.y + y };

        return .{ .x = x, .y = y };

    }

    fn number(self: *PathParser) ?f32 {

        self.skip();

        if (self.offset >= self.text.len) return null;

        const start = self.offset;

        if (self.text[self.offset] == '-' or self.text[self.offset] == '+') self.offset += 1;

        var saw_digit = false;

        while (self.offset < self.text.len and is_digit(self.text[self.offset])) : (self.offset += 1) saw_digit = true;

        if (self.offset < self.text.len and self.text[self.offset] == '.') {

            self.offset += 1;

            while (self.offset < self.text.len and is_digit(self.text[self.offset])) : (self.offset += 1) saw_digit = true;

        }

        if (saw_digit and self.offset < self.text.len and (self.text[self.offset] == 'e' or self.text[self.offset] == 'E')) {

            const mark = self.offset;

            self.offset += 1;

            if (self.offset < self.text.len and (self.text[self.offset] == '-' or self.text[self.offset] == '+')) self.offset += 1;

            if (self.offset < self.text.len and is_digit(self.text[self.offset])) {

                while (self.offset < self.text.len and is_digit(self.text[self.offset])) : (self.offset += 1) {}

            } else self.offset = mark;

        }

        if (!saw_digit) {

            self.offset = start;

            return null;

        }

        return parse_number(self.text[start..self.offset]);

    }

    fn skip(self: *PathParser) void {

        while (self.offset < self.text.len) : (self.offset += 1) {

            switch (self.text[self.offset]) {

                ' ', '\n', '\r', '\t', ',' => {},

                else => return,

            }

        }

    }

};

fn parse_view_box(svg: []const u8) ViewBox {

    const value = attr(svg, "viewBox") orelse return .{};
    var parser = PathParser{ .text = value };

    const x = parser.number() orelse return .{};
    const y = parser.number() orelse return .{};
    const w = parser.number() orelse return .{};
    const h = parser.number() orelse return .{};

    if (w <= 0 or h <= 0) return .{};

    return .{ .x = x, .y = y, .w = w, .h = h };

}

fn find_tag(svg: []const u8, name: []const u8, offset: *usize) ?[]const u8 {

    while (std.mem.indexOfScalarPos(u8, svg, offset.*, '<')) |start| {

        offset.* = start + 1;

        if (offset.* + name.len > svg.len) return null;
        if (!std.mem.eql(u8, svg[offset.* .. offset.* + name.len], name)) continue;

        const end = std.mem.indexOfScalarPos(u8, svg, offset.*, '>') orelse return null;

        offset.* = end + 1;

        return svg[start .. end + 1];

    }

    return null;

}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {

    var offset: usize = 0;

    while (std.mem.indexOfPos(u8, tag, offset, name)) |start| {

        offset = start + name.len;

        if (start > 0 and is_name_char(tag[start - 1])) continue;
        if (offset >= tag.len or tag[offset] != '=') continue;
        if (offset + 1 >= tag.len) return null;

        const quote = tag[offset + 1];

        if (quote != '"' and quote != '\'') return null;

        const value_start = offset + 2;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;

        return tag[value_start..value_end];

    }

    return null;

}

fn parse_attr_number(tag: []const u8, name: []const u8) ?f32 {

    const value = attr(tag, name) orelse return null;

    return parse_number(value);

}

fn parse_number(bytes: []const u8) f32 {

    return std.fmt.parseFloat(f32, bytes) catch 0;

}

fn is_digit(c: u8) bool {

    return c >= '0' and c <= '9';

}

fn is_name_char(c: u8) bool {

    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';

}

const testing = std.testing;

test "parse decimal numbers" {

    try testing.expectEqual(@as(f32, 12.5), parse_number("12.5"));
    try testing.expectEqual(@as(f32, -3), parse_number("-3"));
    try testing.expectEqual(@as(f32, 0.25), parse_number("2.5e-1"));
    try testing.expectEqual(@as(f32, 0), parse_number("nonsense"));

}

test "read viewBox attribute" {

    const box = parse_view_box("<svg viewBox=\"0 0 24 24\"></svg>");

    try testing.expectEqual(@as(f32, 24), box.w);

}

test "stroked icon covers its geometry" {

    var pixels: [24 * 24]u32 = [_]u32{0} ** (24 * 24);
    const surface = Surface.from_pixels(&pixels, 24, 24);

    const svg =
        \\<svg viewBox="0 0 24 24"><line x1="4" y1="12" x2="20" y2="12"/></svg>
    ;

    icon(&surface, .{ .x = 0, .y = 0, .w = 24, .h = 24 }, svg, 0xffffff);

    try testing.expect(draw_mod.blue(pixels[12 * 24 + 12]) > 128);
    try testing.expectEqual(@as(u32, 0), pixels[2 * 24 + 12]);

    // Second call hits the cache and blends identically.

    var again: [24 * 24]u32 = [_]u32{0} ** (24 * 24);
    const surface2 = Surface.from_pixels(&again, 24, 24);

    icon(&surface2, .{ .x = 0, .y = 0, .w = 24, .h = 24 }, svg, 0xffffff);

    try testing.expectEqual(pixels[12 * 24 + 12], again[12 * 24 + 12]);

}

test "small icon strokes keep a solid spine with Lucide width" {

    var buffer: [16 * 16]u8 = [_]u8{0} ** (16 * 16);

    const svg =
        \\<svg viewBox="0 0 24 24"><line x1="4" y1="12" x2="20" y2="12"/></svg>
    ;

    var path = Path{};

    build_stroked(&path, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, svg, 0);
    raster.fill_coverage(&path, &buffer, 16, 16, 0, 0);

    // Lucide 2/24 at 16px ≈ 1.33 — centre row must be solid; at most two rows carry ink.
    try testing.expectEqual(@as(u8, 255), buffer[8 * 16 + 8]);

    var rows: usize = 0;

    for (0..16) |y| {

        if (buffer[y * 16 + 8] > 32) rows += 1;

    }

    try testing.expect(rows >= 1 and rows <= 3);

}

test "a small icon keeps its interior open instead of blobbing" {

    var buffer: [16 * 16]u8 = [_]u8{0} ** (16 * 16);

    const svg =
        \\<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 3 Q17 12 12 21"/><path d="M12 3 Q7 12 12 21"/></svg>
    ;

    var path = Path{};

    build_stroked(&path, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, svg, 0);
    raster.fill_coverage(&path, &buffer, 16, 16, 0, 0);

    // Heavy strokes plus a join disc per flattened vertex used to merge rim and meridians into a solid disc.

    try testing.expect(buffer[5 * 16 + 4] < 64);

}

test "curve flattening scales with the destination size" {

    const svg =
        \\<svg viewBox="0 0 24 24"><path d="M12 3 Q17 12 12 21"/></svg>
    ;

    var small = Path{};
    var large = Path{};

    build_stroked(&small, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, svg, 0);
    build_stroked(&large, .{ .x = 0, .y = 0, .w = 48, .h = 48 }, svg, 0);

    try testing.expect(small.verb_count < large.verb_count);

    // Smooth curves carry two cap discs, not one per flattened vertex.

    try testing.expect(small.verb_count < 60);

}

test "filled cursor produces opaque interior with outline" {

    var pixels: [64 * 64]u32 = undefined;

    const svg =
        \\<svg viewBox="0 0 24 24"><path d="M4 4l7 16 2-7 7-2z"/></svg>
    ;

    raster_cursor(64, &pixels, svg, .{ .x = 0, .y = 0, .w = 48, .h = 48 }, 0xffffff, 0x000000, .filled);

    // Somewhere inside the arrow: opaque white fill. Corner: fully transparent.

    var found_fill = false;

    for (pixels) |p| {

        if (p >> 24 == 255 and (p & 0xffffff) == 0xffffff) found_fill = true;

    }

    try testing.expect(found_fill);
    try testing.expectEqual(@as(u32, 0), pixels[63 * 64 + 63]);

}

test "elliptical arcs from Lucide path data stroke without overflowing" {

    const svg =
        \\<svg viewBox="0 0 24 24"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg>
    ;

    var path = Path{};

    build_stroked(&path, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, svg, 0);

    try testing.expect(!path.overflowed);
    try testing.expect(path.verb_count > 8);

    var buffer: [20 * 20]u8 = [_]u8{0} ** (20 * 20);

    raster.fill_coverage(&path, &buffer, 20, 20, 0, 0);

    // Folder outline leaves the center mostly empty.
    try testing.expect(buffer[10 * 20 + 10] < 64);

    var ink: usize = 0;

    for (buffer) |cell| {

        if (cell > 0) ink += 1;

    }

    try testing.expect(ink > 20);

}

test "cached icons at the same size do not bleed into each other" {

    var pixels: [40 * 24]u32 = [_]u32{0} ** (40 * 24);
    const surface = Surface.from_pixels(&pixels, 40, 24);

    const left =
        \\<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/></svg>
    ;
    const right =
        \\<svg viewBox="0 0 24 24"><line x1="4" y1="12" x2="20" y2="12"/></svg>
    ;

    icon(&surface, .{ .x = 0, .y = 2, .w = 16, .h = 16 }, left, 0xffffff);
    icon(&surface, .{ .x = 20, .y = 2, .w = 16, .h = 16 }, right, 0xffffff);

    // Right icon is a mid-row line: left half of that cell pair should stay dark at the top.
    try testing.expectEqual(@as(u32, 0), pixels[2 * 40 + 20]);

}

test "nested rect icons stay hollow at tab size" {

    // CPU-like nested rounded rects used to fill solid at 20px with ring strokes.
    const svg =
        \\<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="8" y="8" width="8" height="8" rx="1"/></svg>
    ;

    var buffer: [20 * 20]u8 = [_]u8{0} ** (20 * 20);

    try testing.expect(rasterize_icon(svg, 20, 20, &buffer));

    // Centre of the inner rect must stay open.
    try testing.expect(buffer[10 * 20 + 10] < 48);

    // Outer frame mid-top edge carries ink.
    try testing.expect(buffer[4 * 20 + 10] > 64);

}

test "supersampled icon spine is opaque" {

    var buffer: [20 * 20]u8 = [_]u8{0} ** (20 * 20);

    const svg =
        \\<svg viewBox="0 0 24 24"><line x1="4" y1="12" x2="20" y2="12"/></svg>
    ;

    try testing.expect(rasterize_icon(svg, 20, 20, &buffer));
    try testing.expect(buffer[10 * 20 + 10] > 200);

}
