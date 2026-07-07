// SVG icon and cursor renderer (M10 GUI rewrite): parses the shape subset used by the outline icon set
// (path M/L/H/V/Q/C/T/Z, line, polyline, polygon, circle, rect) and renders it through the analytic raster -
// fills as direct path contours, strokes through the round-cap stroker. Icons are cached as 8-bit coverage
// masks per (source, size), so per-frame cost is one blended blit.

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

const fixed_one = 1 << 16;
const max_poly_points = 256;

const ViewBox = struct {

    x: i32 = 0,
    y: i32 = 0,

    w: i32 = 24 * fixed_one,
    h: i32 = 24 * fixed_one,

};

// Maps 16.16 view-box coordinates into 26.6 destination space.

const Transform = struct {

    view: ViewBox,
    dest: Rect,
    snap_strokes: bool = false,

    fn x(self: *const Transform, value: i32) i32 {

        const snap: i32 = if (self.snap_strokes) 32 else 0;

        return path_mod.from_px(self.dest.x) + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view.x) * self.dest.w * 64, self.view.w))) + snap;

    }

    fn y(self: *const Transform, value: i32) i32 {

        const snap: i32 = if (self.snap_strokes) 32 else 0;

        return path_mod.from_px(self.dest.y) + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view.y) * self.dest.h * 64, self.view.h))) + snap;

    }

    fn length(self: *const Transform, value: i32) i32 {

        return @intCast(@divTrunc(@as(i64, value) * @min(self.dest.w, self.dest.h) * 64, @min(self.view.w, self.view.h)));

    }

    fn point(self: *const Transform, p: FixedPoint) Point {

        return .{ .x = self.x(p.x), .y = self.y(p.y) };

    }

};

const FixedPoint = struct {

    x: i32,
    y: i32,

};

/// Build the stroked outline of every shape in `svg` into `path`, sized to `rect`. `width_fx` zero picks the
/// icon-set default (a twelfth of the box).
pub fn build_stroked(path: *Path, rect: Rect, svg: []const u8, width_fx: i32) void {

    const transform = Transform{ .view = parse_view_box(svg), .dest = rect, .snap_strokes = true };
    const default_width = @as(i32, @intCast(@divTrunc(@as(i64, @min(rect.w, rect.h)) * 2 * 64 + 12, 24)));
    const width = if (width_fx > 0) width_fx else @max(96, default_width);

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

        // A ring border centered on the outline: expand outward by half the width.

        const half = @divTrunc(width, 2);

        path.add_round_rect(origin.x - half, origin.y - half, px_w + width, px_h + width, transform.length(radius) + half);
        path.add_round_rect_reversed(origin.x + half, origin.y + half, px_w - width, px_h - width, @max(0, transform.length(radius) - half));

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

    var path = Path{};

    build_stroked(&path, rect, svg, 0);
    raster.fill(surface, &path, color);

}

// Icon cache: static vector strokes rasterize once per (source, size) into a coverage mask, then blit in any
// tint. Same shape as the glyph cache; single render thread, no locking.

const icon_box: u32 = 48;
const icon_capacity: usize = 64;

const IconEntry = struct {

    used: bool = false,
    source: usize = 0,

    w: u16 = 0,
    h: u16 = 0,

};

var icon_meta = [_]IconEntry{.{}} ** icon_capacity;
var icon_coverage: [icon_capacity][icon_box * icon_box]u8 = undefined;

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

fn cached_icon(svg: []const u8, w: u32, h: u32) ?usize {

    const source = @intFromPtr(svg.ptr) ^ (@as(usize, w) << 20) ^ (@as(usize, h) << 28);
    const start = (source ^ (source >> 9)) % icon_capacity;

    var probe: usize = 0;
    var slot = start;

    while (probe < 8) : (probe += 1) {

        const entry = &icon_meta[slot];

        if (entry.used and entry.source == source) return slot;

        if (!entry.used) return render_icon(slot, svg, source, w, h);

        slot = (slot + 1) % icon_capacity;

    }

    return render_icon(start, svg, source, w, h);

}

fn render_icon(slot: usize, svg: []const u8, source: usize, w: u32, h: u32) ?usize {

    const cells = w * h;

    @memset(icon_coverage[slot][0..cells], 0);

    var path = Path{};

    build_stroked(&path, .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) }, svg, 0);

    if (path.overflowed) return null;

    raster.fill_coverage(&path, icon_coverage[slot][0..cells], w, h, 0, 0);

    icon_meta[slot] = .{

        .used = true,
        .source = source,

        .w = @intCast(w),
        .h = @intCast(h),

    };

    return slot;

}

// Cursor rasterization: cursors composite into an ARGB plane (alpha in the high byte), an outline pass under
// a fill or inner-stroke pass, so the pointer stays readable on any background.

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
    const thin = @max(64, path_mod.from_px(@divTrunc(@min(dst.w, dst.h), 24)));
    const thick = @max(128, path_mod.from_px(@divTrunc(@min(dst.w, dst.h), 8)));

    var path = Path{};

    switch (style) {

        .filled => {

            // Outline stroke beneath the filled interior.

            build_stroked(&path, dst, svg, thin + 64);
            raster.fill_coverage(&path, under[0 .. side * side], w, w, 0, 0);

            path.reset();
            build_filled(&path, dst, svg);
            raster.fill_coverage(&path, over[0 .. side * side], w, w, 0, 0);

        },

        .stroked => {

            build_stroked(&path, dst, svg, thick);
            raster.fill_coverage(&path, under[0 .. side * side], w, w, 0, 0);

            path.reset();
            build_stroked(&path, dst, svg, @max(96, thick - 64));
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

fn stroke_points(path: *Path, transform: *const Transform, text: []const u8, close: bool, width: i32) void {

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
    var current = FixedPoint{ .x = 0, .y = 0 };
    var start = current;
    var control = current;

    while (parser.more()) {

        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {

            'M' => {

                const p = parser.fixed_point(relative, current) orelse break;

                current = p;
                start = p;

                const mapped = transform.point(p);

                path.move_to(mapped.x, mapped.y);

                command = if (relative) 'l' else 'L';

            },

            'L' => {

                const p = parser.fixed_point(relative, current) orelse break;
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;

            },

            'H' => {

                const x = parser.number() orelse break;
                const p = FixedPoint{ .x = if (relative) current.x + x else x, .y = current.y };
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;

            },

            'V' => {

                const y = parser.number() orelse break;
                const p = FixedPoint{ .x = current.x, .y = if (relative) current.y + y else y };
                const mapped = transform.point(p);

                path.line_to(mapped.x, mapped.y);
                current = p;

            },

            'Q' => {

                const c = parser.fixed_point(relative, current) orelse break;
                const end = parser.fixed_point(relative, current) orelse break;

                const mc = transform.point(c);
                const me = transform.point(end);

                path.quad_to(mc.x, mc.y, me.x, me.y);

                current = end;
                control = c;

            },

            'C' => {

                const c1 = parser.fixed_point(relative, current) orelse break;
                const c2 = parser.fixed_point(relative, current) orelse break;
                const end = parser.fixed_point(relative, current) orelse break;

                const m1 = transform.point(c1);
                const m2 = transform.point(c2);
                const me = transform.point(end);

                path.cubic_to(m1.x, m1.y, m2.x, m2.y, me.x, me.y);

                current = end;
                control = c2;

            },

            'T' => {

                const reflected = FixedPoint{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.fixed_point(relative, current) orelse break;

                const mc = transform.point(reflected);
                const me = transform.point(end);

                path.quad_to(mc.x, mc.y, me.x, me.y);

                current = end;
                control = reflected;

            },

            'Z' => {

                path.close();
                current = start;

            },

            else => break,

        }

    }

    path.close();

}

fn stroke_path_data(path: *Path, transform: *const Transform, d: []const u8, width: i32) void {

    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = FixedPoint{ .x = 0, .y = 0 };
    var start = current;
    var control = current;

    while (parser.more()) {

        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {

            'M' => {

                const p = parser.fixed_point(relative, current) orelse break;

                current = p;
                start = p;
                command = if (relative) 'l' else 'L';

            },

            'L' => {

                const p = parser.fixed_point(relative, current) orelse break;

                stroke_between(path, transform, current, p, width);
                current = p;

            },

            'H' => {

                const x = parser.number() orelse break;
                const p = FixedPoint{ .x = if (relative) current.x + x else x, .y = current.y };

                stroke_between(path, transform, current, p, width);
                current = p;

            },

            'V' => {

                const y = parser.number() orelse break;
                const p = FixedPoint{ .x = current.x, .y = if (relative) current.y + y else y };

                stroke_between(path, transform, current, p, width);
                current = p;

            },

            'Q' => {

                const c = parser.fixed_point(relative, current) orelse break;
                const end = parser.fixed_point(relative, current) orelse break;

                stroke_quad(path, transform, current, c, end, width);

                current = end;
                control = c;

            },

            'C' => {

                const c1 = parser.fixed_point(relative, current) orelse break;
                const c2 = parser.fixed_point(relative, current) orelse break;
                const end = parser.fixed_point(relative, current) orelse break;

                stroke_cubic(path, transform, current, c1, c2, end, width);

                current = end;
                control = c2;

            },

            'T' => {

                const reflected = FixedPoint{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.fixed_point(relative, current) orelse break;

                stroke_quad(path, transform, current, reflected, end, width);

                current = end;
                control = reflected;

            },

            'Z' => {

                stroke_between(path, transform, current, start, width);
                current = start;

            },

            else => break,

        }

    }

}

fn stroke_between(path: *Path, transform: *const Transform, a: FixedPoint, b: FixedPoint, width: i32) void {

    const ma = transform.point(a);
    const mb = transform.point(b);

    stroke.segment(path, ma.x, ma.y, mb.x, mb.y, width);

}

fn stroke_quad(path: *Path, transform: *const Transform, a: FixedPoint, b: FixedPoint, c: FixedPoint, width: i32) void {

    const steps: i64 = 8;
    var points: [steps + 1]Point = undefined;

    var step: i64 = 0;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps;

        points[@intCast(step)] = transform.point(.{

            .x = @intCast(round_div(mt * mt * @as(i64, a.x) + 2 * mt * t * @as(i64, b.x) + t * t * @as(i64, c.x), denom)),
            .y = @intCast(round_div(mt * mt * @as(i64, a.y) + 2 * mt * t * @as(i64, b.y) + t * t * @as(i64, c.y), denom)),

        });

    }

    stroke.polyline(path, &points, width);

}

fn stroke_cubic(path: *Path, transform: *const Transform, a: FixedPoint, b: FixedPoint, c: FixedPoint, d: FixedPoint, width: i32) void {

    const steps: i64 = 12;
    var points: [steps + 1]Point = undefined;

    var step: i64 = 0;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps * steps;

        points[@intCast(step)] = transform.point(.{

            .x = @intCast(round_div(mt * mt * mt * @as(i64, a.x) + 3 * mt * mt * t * @as(i64, b.x) + 3 * mt * t * t * @as(i64, c.x) + t * t * t * @as(i64, d.x), denom)),
            .y = @intCast(round_div(mt * mt * mt * @as(i64, a.y) + 3 * mt * mt * t * @as(i64, b.y) + 3 * mt * t * t * @as(i64, c.y) + t * t * t * @as(i64, d.y), denom)),

        });

    }

    stroke.polyline(path, &points, width);

}

fn round_div(numerator: i64, denominator: i64) i64 {

    const half = @divTrunc(denominator, 2);

    if (numerator >= 0) return @divTrunc(numerator + half, denominator);

    return -@divTrunc(-numerator + half, denominator);

}

// Parsing (16.16 fixed-point numbers, tolerant of the icon set's formatting).

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

    fn fixed_point(self: *PathParser, relative: bool, current: FixedPoint) ?FixedPoint {

        const x = self.number() orelse return null;
        const y = self.number() orelse return null;

        if (relative) return .{ .x = current.x + x, .y = current.y + y };

        return .{ .x = x, .y = y };

    }

    fn number(self: *PathParser) ?i32 {

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

        if (!saw_digit) {

            self.offset = start;

            return null;

        }

        return parse_fixed(self.text[start..self.offset]);

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

fn parse_attr_number(tag: []const u8, name: []const u8) ?i32 {

    const value = attr(tag, name) orelse return null;

    return parse_fixed(value);

}

fn parse_fixed(bytes: []const u8) i32 {

    var negative = false;
    var offset: usize = 0;

    if (offset < bytes.len and (bytes[offset] == '-' or bytes[offset] == '+')) {

        negative = bytes[offset] == '-';
        offset += 1;

    }

    var whole: i64 = 0;

    while (offset < bytes.len and is_digit(bytes[offset])) : (offset += 1) {

        whole = whole * 10 + @as(i64, bytes[offset] - '0');

    }

    var frac: i64 = 0;
    var scale: i64 = 1;

    if (offset < bytes.len and bytes[offset] == '.') {

        offset += 1;

        while (offset < bytes.len and is_digit(bytes[offset])) : (offset += 1) {

            frac = frac * 10 + @as(i64, bytes[offset] - '0');
            scale *= 10;

        }

    }

    var value = whole * fixed_one + @divTrunc(frac * fixed_one, scale);

    if (negative) value = -value;

    return @intCast(value);

}

fn is_digit(c: u8) bool {

    return c >= '0' and c <= '9';

}

fn is_name_char(c: u8) bool {

    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';

}

const testing = std.testing;

test "parse fixed decimal numbers" {

    try testing.expectEqual(@as(i32, 12 * fixed_one + fixed_one / 2), parse_fixed("12.5"));
    try testing.expectEqual(@as(i32, -3 * fixed_one), parse_fixed("-3"));

}

test "read viewBox attribute" {

    const box = parse_view_box("<svg viewBox=\"0 0 24 24\"></svg>");

    try testing.expectEqual(@as(i32, 24 * fixed_one), box.w);

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
