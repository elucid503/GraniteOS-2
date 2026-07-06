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

fn draw_quadratic(painter: *const Painter, a: Point, b: Point, c: Point) void {
    const steps = 12;
    var last = a;
    var step: i32 = 1;

    while (step <= steps) : (step += 1) {
        const t = step;
        const mt = steps - step;
        const denom = steps * steps;
        const point = Point{
            .x = @divTrunc(mt * mt * a.x + 2 * mt * t * b.x + t * t * c.x, denom),
            .y = @divTrunc(mt * mt * a.y + 2 * mt * t * b.y + t * t * c.y, denom),
        };

        painter.line(last, point);
        last = point;
    }
}

fn draw_cubic(painter: *const Painter, a: Point, b: Point, c: Point, d: Point) void {
    const steps = 16;
    var last = a;
    var step: i32 = 1;

    while (step <= steps) : (step += 1) {
        const t = step;
        const mt = steps - step;
        const denom = steps * steps * steps;
        const point = Point{
            .x = @divTrunc(mt * mt * mt * a.x + 3 * mt * mt * t * b.x + 3 * mt * t * t * c.x + t * t * t * d.x, denom),
            .y = @divTrunc(mt * mt * mt * a.y + 3 * mt * mt * t * b.y + 3 * mt * t * t * c.y + t * t * t * d.y, denom),
        };

        painter.line(last, point);
        last = point;
    }
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
