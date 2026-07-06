// Tiny SVG icon renderer for monochrome UI assets. It supports the shape/path subset used by common outline
// icon sets: path M/L/H/V/Q/C/Z, line, polyline, polygon, circle, and rect.

const std = @import("std");

const gfx = @import("gfx.zig");

const fixed_one = 1 << 16;
const ViewBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 24 * fixed_one,
    h: i32 = 24 * fixed_one,
};

const Painter = struct {
    surface: *const gfx.Surface,
    rect: gfx.Rect,
    view_box: ViewBox,
    color: gfx.Color,
    stroke: i32,

    fn x(self: *const Painter, value: i32) i32 {
        return self.rect.x + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view_box.x) * self.rect.w, self.view_box.w)));
    }

    fn y(self: *const Painter, value: i32) i32 {
        return self.rect.y + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view_box.y) * self.rect.h, self.view_box.h)));
    }

    fn line(self: *const Painter, a: Point, b: Point) void {
        self.surface.stroke_line_smooth(self.x(a.x), self.y(a.y), self.x(b.x), self.y(b.y), self.stroke, self.color);
    }
};

const Point = struct {
    x: i32,
    y: i32,
};

pub fn draw_icon(surface: *const gfx.Surface, rect: gfx.Rect, svg: []const u8, color: gfx.Color) void {
    const view_box = parse_view_box(svg);
    const stroke = @max(1, @divTrunc(@min(rect.w, rect.h), 12));
    const painter = Painter{ .surface = surface, .rect = rect, .view_box = view_box, .color = color, .stroke = stroke };

    var offset: usize = 0;
    while (find_tag(svg, "path", &offset)) |tag| {
        if (attr(tag, "d")) |d| draw_path(&painter, d);
    }

    offset = 0;
    while (find_tag(svg, "line", &offset)) |tag| {
        const x1 = parse_attr_number(tag, "x1") orelse continue;
        const y1 = parse_attr_number(tag, "y1") orelse continue;
        const x2 = parse_attr_number(tag, "x2") orelse continue;
        const y2 = parse_attr_number(tag, "y2") orelse continue;

        painter.line(Point{ .x = x1, .y = y1 }, Point{ .x = x2, .y = y2 });
    }

    offset = 0;
    while (find_tag(svg, "polyline", &offset)) |tag| {
        if (attr(tag, "points")) |points| draw_points(&painter, points, false);
    }

    offset = 0;
    while (find_tag(svg, "polygon", &offset)) |tag| {
        if (attr(tag, "points")) |points| draw_points(&painter, points, true);
    }

    offset = 0;
    while (find_tag(svg, "circle", &offset)) |tag| {
        const cx = parse_attr_number(tag, "cx") orelse continue;
        const cy = parse_attr_number(tag, "cy") orelse continue;
        const r = parse_attr_number(tag, "r") orelse continue;
        const px_r = @max(1, @as(i32, @intCast(@divTrunc(@as(i64, r) * rect.w, view_box.w))));

        surface.stroke_circle_smooth(painter.x(cx), painter.y(cy), px_r, stroke, color);
    }

    offset = 0;
    while (find_tag(svg, "rect", &offset)) |tag| {
        const x = parse_attr_number(tag, "x") orelse 0;
        const y = parse_attr_number(tag, "y") orelse 0;
        const w = parse_attr_number(tag, "width") orelse continue;
        const h = parse_attr_number(tag, "height") orelse continue;
        const radius = parse_attr_number(tag, "rx") orelse 0;
        const px = painter.x(x);
        const py = painter.y(y);
        const pw = @max(1, painter.x(x + w) - px);
        const ph = @max(1, painter.y(y + h) - py);

        surface.stroke_rounded_rect_smooth(.{ .x = px, .y = py, .w = pw, .h = ph }, @as(i32, @intCast(@divTrunc(@as(i64, radius) * rect.w, view_box.w))), stroke, color);
    }
}

const max_polygon_points = 256;

const Raster = struct {
    surface: gfx.Surface,
    rect: gfx.Rect,
    view_box: ViewBox,

    fn x(self: *const Raster, value: i32) i32 {
        return self.rect.x + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view_box.x) * self.rect.w, self.view_box.w)));
    }

    fn y(self: *const Raster, value: i32) i32 {
        return self.rect.y + @as(i32, @intCast(@divTrunc(@as(i64, value - self.view_box.y) * self.rect.h, self.view_box.h)));
    }

    fn stroke(self: *const Raster, a: Point, b: Point, thickness: i32, color: gfx.Color) void {
        stroke_segment_opaque(&self.surface, self.x(a.x), self.y(a.y), self.x(b.x), self.y(b.y), thickness, color);
    }

    fn fill_polygon(self: *const Raster, points: []const Point, color: gfx.Color) void {
        if (points.len < 3) return;

        var min_y: i32 = self.y(points[0].y);
        var max_y = min_y;

        for (points[1..]) |point| {

            const py = self.y(point.y);
            min_y = @min(min_y, py);
            max_y = @max(max_y, py);

        }

        var scan_y = min_y;

        while (scan_y <= max_y) : (scan_y += 1) {

            var intersections: [max_polygon_points]i32 = undefined;
            var count: usize = 0;

            var index: usize = 0;

            while (index < points.len) : (index += 1) {

                const next = (index + 1) % points.len;
                const y0 = self.y(points[index].y);
                const y1 = self.y(points[next].y);

                if (y0 == y1) continue;

                const low = @min(y0, y1);
                const high = @max(y0, y1);

                if (scan_y < low or scan_y >= high) continue;
                if (scan_y == high and y0 < y1) continue;

                const x0 = self.x(points[index].x);
                const x1 = self.x(points[next].x);
                const cross = x0 + @divTrunc((scan_y - y0) * (x1 - x0), y1 - y0);

                if (count < intersections.len) {

                    intersections[count] = cross;
                    count += 1;

                }

            }

            if (count < 2) continue;

            sort_intersections(intersections[0..count]);

            var pair: usize = 0;

            while (pair + 1 < count) : (pair += 2) {

                const left = intersections[pair];
                const right = intersections[pair + 1];

                self.surface.fill_rect(.{ .x = left, .y = scan_y, .w = right - left + 1, .h = 1 }, color);

            }

        }

    }
};

pub const CursorStyle = enum {

    filled,
    stroked,
    white_line,

};

/// Rasterize an SVG glyph into a square ARGB buffer for hardware cursors.
pub fn raster_cursor(
    side: usize,
    pixels: [*]u32,
    svg: []const u8,
    dst: gfx.Rect,
    fill: gfx.Color,
    outline: gfx.Color,
    style: CursorStyle,
) void {

    @memset(pixels[0 .. side * side], 0);

    const view_box = parse_view_box(svg);
    const surface = gfx.Surface.from_base(@intFromPtr(pixels), @intCast(side), @intCast(side), @intCast(side * 4));
    const raster = Raster{ .surface = surface, .rect = dst, .view_box = view_box };

    const thin = @max(1, @divTrunc(@min(dst.w, dst.h), 24));
    const thick = @max(2, @divTrunc(@min(dst.w, dst.h), 8));
    const inner = @max(1, thick - 1);

    if (style == .filled) {

        const edge = thin + 1;

        var offset: usize = 0;
        while (find_tag(svg, "path", &offset)) |tag| {
            if (attr(tag, "d")) |d| stroke_path(&raster, d, edge, outline);
        }

        offset = 0;
        while (find_tag(svg, "path", &offset)) |tag| {
            if (attr(tag, "d")) |d| fill_path(&raster, d, fill);
        }

        offset = 0;
        while (find_tag(svg, "polygon", &offset)) |tag| {
            if (attr(tag, "points")) |points| fill_points(&raster, points, fill);
        }

        offset = 0;
        while (find_tag(svg, "rect", &offset)) |tag| {
            const x = parse_attr_number(tag, "x") orelse 0;
            const y = parse_attr_number(tag, "y") orelse 0;
            const w = parse_attr_number(tag, "width") orelse continue;
            const h = parse_attr_number(tag, "height") orelse continue;
            const radius = parse_attr_number(tag, "rx") orelse 0;
            const px = raster.x(x);
            const py = raster.y(y);
            const pw = @max(1, raster.x(x + w) - px);
            const ph = @max(1, raster.y(y + h) - py);
            const pr = @as(i32, @intCast(@divTrunc(@as(i64, radius) * dst.w, view_box.w)));

            if (pr > 0) raster.surface.fill_rounded_rect(.{ .x = px, .y = py, .w = pw, .h = ph }, pr, fill)
            else raster.surface.fill_rect(.{ .x = px, .y = py, .w = pw, .h = ph }, fill);

        }

        return;

    }

    if (style == .white_line) {

        var offset: usize = 0;
        while (find_tag(svg, "line", &offset)) |tag| {
            const x1 = parse_attr_number(tag, "x1") orelse continue;
            const y1 = parse_attr_number(tag, "y1") orelse continue;
            const x2 = parse_attr_number(tag, "x2") orelse continue;
            const y2 = parse_attr_number(tag, "y2") orelse continue;

            raster.stroke(Point{ .x = x1, .y = y1 }, Point{ .x = x2, .y = y2 }, thin, fill);
        }

        return;

    }

    const outer = thick;

    var offset: usize = 0;
    while (find_tag(svg, "path", &offset)) |tag| {
        if (attr(tag, "d")) |d| stroke_path(&raster, d, outer, outline);
    }

    offset = 0;
    while (find_tag(svg, "line", &offset)) |tag| {
        const x1 = parse_attr_number(tag, "x1") orelse continue;
        const y1 = parse_attr_number(tag, "y1") orelse continue;
        const x2 = parse_attr_number(tag, "x2") orelse continue;
        const y2 = parse_attr_number(tag, "y2") orelse continue;

        raster.stroke(Point{ .x = x1, .y = y1 }, Point{ .x = x2, .y = y2 }, outer, outline);
    }

    offset = 0;
    while (find_tag(svg, "polyline", &offset)) |tag| {
        if (attr(tag, "points")) |points| stroke_points(&raster, points, false, outer, outline);
    }

    if (style != .stroked) return;

    offset = 0;
    while (find_tag(svg, "path", &offset)) |tag| {
        if (attr(tag, "d")) |d| stroke_path(&raster, d, inner, fill);
    }

    offset = 0;
    while (find_tag(svg, "line", &offset)) |tag| {
        const x1 = parse_attr_number(tag, "x1") orelse continue;
        const y1 = parse_attr_number(tag, "y1") orelse continue;
        const x2 = parse_attr_number(tag, "x2") orelse continue;
        const y2 = parse_attr_number(tag, "y2") orelse continue;

        raster.stroke(Point{ .x = x1, .y = y1 }, Point{ .x = x2, .y = y2 }, inner, fill);
    }

    offset = 0;
    while (find_tag(svg, "polyline", &offset)) |tag| {
        if (attr(tag, "points")) |points| stroke_points(&raster, points, false, inner, fill);
    }

}

fn stroke_segment_opaque(surface: *const gfx.Surface, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: gfx.Color) void {

    const radius = @max(1, thickness);
    const raw_bounds = gfx.Rect{

        .x = @min(x0, x1) - radius - 1,
        .y = @min(y0, y1) - radius - 1,

        .w = @as(i32, @intCast(@abs(x1 - x0))) + 2 * radius + 3,
        .h = @as(i32, @intCast(@abs(y1 - y0))) + 2 * radius + 3,

    };
    const clipped_line = raw_bounds.intersect(surface.bounds());

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

            if (covered >= 8) surface.put_pixel(x, y, color);

        }

    }

}

fn sample_hits_segment(px: i32, py: i32, vx: i32, vy: i32, length_sq: i64, radius: i64) bool {

    if (length_sq == 0) {

        const dist_sq = @as(i64, px) * px + @as(i64, py) * py;
        return dist_sq <= radius * radius;

    }

    const dot = @as(i64, px) * vx + @as(i64, py) * vy;

    if (dot <= 0) {

        const dist_sq = @as(i64, px) * px + @as(i64, py) * py;
        return dist_sq <= radius * radius;

    }

    if (dot >= length_sq) {

        const tx = px - vx;
        const ty = py - vy;
        const dist_sq = @as(i64, tx) * tx + @as(i64, ty) * ty;
        return dist_sq <= radius * radius;

    }

    const cross = @as(i64, px) * vy - @as(i64, py) * vx;
    const dist_sq = @divTrunc(cross * cross, length_sq);

    return dist_sq <= radius * radius;

}

fn sort_intersections(values: []i32) void {
    var i: usize = 0;

    while (i < values.len) : (i += 1) {

        var best = i;
        var j = i + 1;

        while (j < values.len) : (j += 1) {

            if (values[j] < values[best]) best = j;

        }

        if (best != i) std.mem.swap(i32, &values[i], &values[best]);

    }

}

fn fill_path(raster: *const Raster, d: []const u8, color: gfx.Color) void {
    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var control = current;
    var polygon: [max_polygon_points]Point = undefined;
    var polygon_len: usize = 0;

    const flush = struct {
        fn go(r: *const Raster, points: []const Point, c: gfx.Color) void {
            if (points.len < 3) return;
            r.fill_polygon(points, c);
        }
    }.go;

    while (parser.more()) {
        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {
            'M' => {
                if (polygon_len >= 3) flush(raster, polygon[0..polygon_len], color);

                polygon_len = 0;

                const point = parser.point(relative, current) orelse break;
                current = point;
                start = point;

                if (polygon_len < polygon.len) {

                    polygon[polygon_len] = point;
                    polygon_len += 1;

                }

                command = if (relative) 'l' else 'L';
            },
            'L' => {
                const point = parser.point(relative, current) orelse break;

                if (polygon_len < polygon.len) {

                    polygon[polygon_len] = point;
                    polygon_len += 1;

                }

                current = point;
            },
            'H' => {
                const x = parser.number() orelse break;
                const point = Point{ .x = if (relative) current.x + x else x, .y = current.y };

                if (polygon_len < polygon.len) {

                    polygon[polygon_len] = point;
                    polygon_len += 1;

                }

                current = point;
            },
            'V' => {
                const y = parser.number() orelse break;
                const point = Point{ .x = current.x, .y = if (relative) current.y + y else y };

                if (polygon_len < polygon.len) {

                    polygon[polygon_len] = point;
                    polygon_len += 1;

                }

                current = point;
            },
            'Q' => {
                const c = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                flatten_quadratic(&polygon, &polygon_len, current, c, end);
                current = end;
                control = c;
            },
            'C' => {
                const c1 = parser.point(relative, current) orelse break;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                flatten_cubic(&polygon, &polygon_len, current, c1, c2, end);
                current = end;
                control = c2;
            },
            'T' => {
                const reflected = Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.point(relative, current) orelse break;
                flatten_quadratic(&polygon, &polygon_len, current, reflected, end);
                current = end;
                control = reflected;
            },
            'Z' => {
                if (polygon_len < polygon.len) {

                    polygon[polygon_len] = start;
                    polygon_len += 1;

                }

                flush(raster, polygon[0..polygon_len], color);
                polygon_len = 0;
                current = start;
            },
            else => break,
        }
    }

    if (polygon_len >= 3) flush(raster, polygon[0..polygon_len], color);

}

fn stroke_path(raster: *const Raster, d: []const u8, thickness: i32, color: gfx.Color) void {
    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var control = current;

    while (parser.more()) {
        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {
            'M' => {
                const point = parser.point(relative, current) orelse break;
                current = point;
                start = point;
                command = if (relative) 'l' else 'L';
            },
            'L' => {
                const point = parser.point(relative, current) orelse break;
                raster.stroke(current, point, thickness, color);
                current = point;
            },
            'H' => {
                const x = parser.number() orelse break;
                const point = Point{ .x = if (relative) current.x + x else x, .y = current.y };
                raster.stroke(current, point, thickness, color);
                current = point;
            },
            'V' => {
                const y = parser.number() orelse break;
                const point = Point{ .x = current.x, .y = if (relative) current.y + y else y };
                raster.stroke(current, point, thickness, color);
                current = point;
            },
            'Q' => {
                const c = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                stroke_quadratic(raster, current, c, end, thickness, color);
                current = end;
                control = c;
            },
            'C' => {
                const c1 = parser.point(relative, current) orelse break;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                stroke_cubic(raster, current, c1, c2, end, thickness, color);
                current = end;
                control = c2;
            },
            'T' => {
                const reflected = Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.point(relative, current) orelse break;
                stroke_quadratic(raster, current, reflected, end, thickness, color);
                current = end;
                control = reflected;
            },
            'Z' => {
                raster.stroke(current, start, thickness, color);
                current = start;
            },
            else => break,
        }
    }

}

fn fill_points(raster: *const Raster, text: []const u8, color: gfx.Color) void {
    var parser = PathParser{ .text = text };
    var polygon: [max_polygon_points]Point = undefined;
    var polygon_len: usize = 0;
    const first = parser.point(false, .{ .x = 0, .y = 0 }) orelse return;

    if (polygon_len < polygon.len) {

        polygon[polygon_len] = first;
        polygon_len += 1;

    }

    while (parser.point(false, first)) |point| {

        if (polygon_len < polygon.len) {

            polygon[polygon_len] = point;
            polygon_len += 1;

        }

    }

    raster.fill_polygon(polygon[0..polygon_len], color);

}

fn stroke_points(raster: *const Raster, text: []const u8, close: bool, thickness: i32, color: gfx.Color) void {
    var parser = PathParser{ .text = text };
    const first = parser.point(false, .{ .x = 0, .y = 0 }) orelse return;
    var last = first;

    while (parser.point(false, last)) |point| {

        raster.stroke(last, point, thickness, color);
        last = point;

    }

    if (close) raster.stroke(last, first, thickness, color);

}

fn push_point(polygon: *[max_polygon_points]Point, polygon_len: *usize, point: Point) void {
    if (polygon_len.* >= polygon.len) return;

    polygon[polygon_len.*] = point;
    polygon_len.* += 1;

}

fn flatten_quadratic(polygon: *[max_polygon_points]Point, polygon_len: *usize, a: Point, b: Point, c: Point) void {
    const steps: i64 = 16;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * ax + 2 * mt * t * bx + t * t * cx, denom)),
            .y = @intCast(round_div(mt * mt * ay + 2 * mt * t * by + t * t * cy, denom)),
        };

        push_point(polygon, polygon_len, point);

    }

}

fn flatten_cubic(polygon: *[max_polygon_points]Point, polygon_len: *usize, a: Point, b: Point, c: Point, d: Point) void {
    const steps: i64 = 24;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;
    const dx: i64 = d.x;
    const dy: i64 = d.y;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * mt * ax + 3 * mt * mt * t * bx + 3 * mt * t * t * cx + t * t * t * dx, denom)),
            .y = @intCast(round_div(mt * mt * mt * ay + 3 * mt * mt * t * by + 3 * mt * t * t * cy + t * t * t * dy, denom)),
        };

        push_point(polygon, polygon_len, point);

    }

}

fn stroke_quadratic(raster: *const Raster, a: Point, b: Point, c: Point, thickness: i32, color: gfx.Color) void {
    const steps: i64 = 16;
    var last = a;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * ax + 2 * mt * t * bx + t * t * cx, denom)),
            .y = @intCast(round_div(mt * mt * ay + 2 * mt * t * by + t * t * cy, denom)),
        };

        raster.stroke(last, point, thickness, color);
        last = point;

    }

}

fn stroke_cubic(raster: *const Raster, a: Point, b: Point, c: Point, d: Point, thickness: i32, color: gfx.Color) void {
    const steps: i64 = 24;
    var last = a;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;
    const dx: i64 = d.x;
    const dy: i64 = d.y;

    while (step <= steps) : (step += 1) {

        const t = step;
        const mt = steps - step;
        const denom = steps * steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * mt * ax + 3 * mt * mt * t * bx + 3 * mt * t * t * cx + t * t * t * dx, denom)),
            .y = @intCast(round_div(mt * mt * mt * ay + 3 * mt * mt * t * by + 3 * mt * t * t * cy + t * t * t * dy, denom)),
        };

        raster.stroke(last, point, thickness, color);
        last = point;

    }

}

fn draw_path(painter: *const Painter, d: []const u8) void {
    var parser = PathParser{ .text = d };
    var command: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var control = current;

    while (parser.more()) {
        if (parser.peek_command()) |found| command = found;
        if (command == 0) break;

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;

        switch (upper) {
            'M' => {
                const point = parser.point(relative, current) orelse break;
                current = point;
                start = point;
                command = if (relative) 'l' else 'L';
            },
            'L' => {
                const point = parser.point(relative, current) orelse break;
                painter.line(current, point);
                current = point;
            },
            'H' => {
                const x = parser.number() orelse break;
                const point = Point{ .x = if (relative) current.x + x else x, .y = current.y };
                painter.line(current, point);
                current = point;
            },
            'V' => {
                const y = parser.number() orelse break;
                const point = Point{ .x = current.x, .y = if (relative) current.y + y else y };
                painter.line(current, point);
                current = point;
            },
            'Q' => {
                const c = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                draw_quadratic(painter, current, c, end);
                current = end;
                control = c;
            },
            'C' => {
                const c1 = parser.point(relative, current) orelse break;
                const c2 = parser.point(relative, current) orelse break;
                const end = parser.point(relative, current) orelse break;
                draw_cubic(painter, current, c1, c2, end);
                current = end;
                control = c2;
            },
            'T' => {
                const reflected = Point{ .x = current.x * 2 - control.x, .y = current.y * 2 - control.y };
                const end = parser.point(relative, current) orelse break;
                draw_quadratic(painter, current, reflected, end);
                current = end;
                control = reflected;
            },
            'Z' => {
                painter.line(current, start);
                current = start;
            },
            else => break,
        }
    }
}

// Coordinates are 16.16 fixed point, so the Bézier weights are accumulated in i64: a cubic term reaches
// steps^3 * coord, which overflows i32 for anything but the tiniest control net. Division rounds to the nearest
// unit to keep the flattened polyline centered on the true curve.

fn draw_quadratic(painter: *const Painter, a: Point, b: Point, c: Point) void {
    const steps: i64 = 16;
    var last = a;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;

    while (step <= steps) : (step += 1) {
        const t = step;
        const mt = steps - step;
        const denom = steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * ax + 2 * mt * t * bx + t * t * cx, denom)),
            .y = @intCast(round_div(mt * mt * ay + 2 * mt * t * by + t * t * cy, denom)),
        };

        painter.line(last, point);
        last = point;
    }
}

fn draw_cubic(painter: *const Painter, a: Point, b: Point, c: Point, d: Point) void {
    const steps: i64 = 24;
    var last = a;
    var step: i64 = 1;

    const ax: i64 = a.x;
    const ay: i64 = a.y;
    const bx: i64 = b.x;
    const by: i64 = b.y;
    const cx: i64 = c.x;
    const cy: i64 = c.y;
    const dx: i64 = d.x;
    const dy: i64 = d.y;

    while (step <= steps) : (step += 1) {
        const t = step;
        const mt = steps - step;
        const denom = steps * steps * steps;
        const point = Point{
            .x = @intCast(round_div(mt * mt * mt * ax + 3 * mt * mt * t * bx + 3 * mt * t * t * cx + t * t * t * dx, denom)),
            .y = @intCast(round_div(mt * mt * mt * ay + 3 * mt * mt * t * by + 3 * mt * t * t * cy + t * t * t * dy, denom)),
        };

        painter.line(last, point);
        last = point;
    }
}

fn round_div(numerator: i64, denominator: i64) i64 {
    const half = @divTrunc(denominator, 2);

    return if (numerator >= 0) @divTrunc(numerator + half, denominator) else -@divTrunc(-numerator + half, denominator);
}

fn draw_points(painter: *const Painter, text: []const u8, close: bool) void {
    var parser = PathParser{ .text = text };
    const first = parser.point(false, .{ .x = 0, .y = 0 }) orelse return;
    var last = first;

    while (parser.point(false, last)) |point| {
        painter.line(last, point);
        last = point;
    }

    if (close) painter.line(last, first);
}

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
