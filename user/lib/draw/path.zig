// Floating-point path tape for the analytic rasterizer; coordinates are pixels, curves flatten at raster time.

const std = @import("std");

/// Bridge whole-pixel integers into path space.
pub fn from_px(px: i32) f32 {

    return @floatFromInt(px);

}

/// Round a path coordinate to the nearest whole pixel, halves toward +infinity.
pub fn to_px(value: f32) i32 {

    return @intFromFloat(@floor(value + 0.5));

}

pub const Point = struct {

    x: f32,
    y: f32,

};

pub const Verb = enum(u8) {

    move,
    line,
    quad,
    cubic,
    close,

};

pub const max_verbs = 2048;
pub const max_points = 4096;

pub const Path = struct {

    verbs: [max_verbs]Verb = undefined,
    points: [max_points]Point = undefined,

    verb_count: usize = 0,
    point_count: usize = 0,

    // Set when a verb or point would overflow the tape; the raster refuses truncated paths.
    overflowed: bool = false,

    start: Point = .{ .x = 0, .y = 0 },
    current: Point = .{ .x = 0, .y = 0 },
    open: bool = false,

    pub fn reset(self: *Path) void {

        self.verb_count = 0;
        self.point_count = 0;
        self.overflowed = false;
        self.open = false;

    }

    fn push(self: *Path, verb: Verb, pts: []const Point) void {

        if (self.verb_count >= max_verbs or self.point_count + pts.len > max_points) {

            self.overflowed = true;

            return;

        }

        self.verbs[self.verb_count] = verb;
        self.verb_count += 1;

        for (pts) |p| {

            self.points[self.point_count] = p;
            self.point_count += 1;

        }

    }

    pub fn move_to(self: *Path, x: f32, y: f32) void {

        if (self.open) self.close();

        const p = Point{ .x = x, .y = y };

        self.push(.move, &.{p});

        self.start = p;
        self.current = p;
        self.open = true;

    }

    pub fn line_to(self: *Path, x: f32, y: f32) void {

        const p = Point{ .x = x, .y = y };

        self.push(.line, &.{p});
        self.current = p;

    }

    pub fn quad_to(self: *Path, cx: f32, cy: f32, x: f32, y: f32) void {

        self.push(.quad, &.{ .{ .x = cx, .y = cy }, .{ .x = x, .y = y } });
        self.current = .{ .x = x, .y = y };

    }

    pub fn cubic_to(self: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {

        self.push(.cubic, &.{ .{ .x = c1x, .y = c1y }, .{ .x = c2x, .y = c2y }, .{ .x = x, .y = y } });
        self.current = .{ .x = x, .y = y };

    }

    pub fn close(self: *Path) void {

        if (!self.open) return;

        self.push(.close, &.{});

        self.current = self.start;
        self.open = false;

    }

    // Shape helpers. All take pixel coordinates; use from_px to lift whole-pixel integers.

    pub fn add_rect(self: *Path, x: f32, y: f32, w: f32, h: f32) void {

        if (w <= 0 or h <= 0) return;

        self.move_to(x, y);
        self.line_to(x + w, y);
        self.line_to(x + w, y + h);
        self.line_to(x, y + h);
        self.close();

    }

    /// Rounded rectangle; the radius clamps to half the shorter side. Quarter circles are cubic arcs.
    pub fn add_round_rect(self: *Path, x: f32, y: f32, w: f32, h: f32, radius_in: f32) void {

        if (w <= 0 or h <= 0) return;

        const radius = @max(0, @min(radius_in, @min(w / 2, h / 2)));

        if (radius == 0) return self.add_rect(x, y, w, h);

        const k = kappa(radius);

        self.move_to(x + radius, y);
        self.line_to(x + w - radius, y);
        self.cubic_to(x + w - radius + k, y, x + w, y + radius - k, x + w, y + radius);
        self.line_to(x + w, y + h - radius);
        self.cubic_to(x + w, y + h - radius + k, x + w - radius + k, y + h, x + w - radius, y + h);
        self.line_to(x + radius, y + h);
        self.cubic_to(x + radius - k, y + h, x, y + h - radius + k, x, y + h - radius);
        self.line_to(x, y + radius);
        self.cubic_to(x, y + radius - k, x + radius - k, y, x + radius, y);
        self.close();

    }

    /// Counter-clockwise round rect paired with add_round_rect to cut a border ring in one fill.
    pub fn add_round_rect_reversed(self: *Path, x: f32, y: f32, w: f32, h: f32, radius_in: f32) void {

        if (w <= 0 or h <= 0) return;

        const radius = @max(0, @min(radius_in, @min(w / 2, h / 2)));
        const k = kappa(radius);

        self.move_to(x + w - radius, y);
        self.line_to(x + radius, y);

        if (radius > 0) self.cubic_to(x + radius - k, y, x, y + radius - k, x, y + radius);

        self.line_to(x, y + h - radius);

        if (radius > 0) self.cubic_to(x, y + h - radius + k, x + radius - k, y + h, x + radius, y + h);

        self.line_to(x + w - radius, y + h);

        if (radius > 0) self.cubic_to(x + w - radius + k, y + h, x + w, y + h - radius + k, x + w, y + h - radius);

        self.line_to(x + w, y + radius);

        if (radius > 0) self.cubic_to(x + w, y + radius - k, x + w - radius + k, y, x + w - radius, y);

        self.close();

    }

    pub fn add_circle(self: *Path, cx: f32, cy: f32, radius: f32) void {

        if (radius <= 0) return;

        const k = kappa(radius);

        self.move_to(cx + radius, cy);
        self.cubic_to(cx + radius, cy + k, cx + k, cy + radius, cx, cy + radius);
        self.cubic_to(cx - k, cy + radius, cx - radius, cy + k, cx - radius, cy);
        self.cubic_to(cx - radius, cy - k, cx - k, cy - radius, cx, cy - radius);
        self.cubic_to(cx + k, cy - radius, cx + radius, cy - k, cx + radius, cy);
        self.close();

    }

    /// Ring between two radii (a donut): the inner contour winds the other way and cuts the hole.
    pub fn add_ring(self: *Path, cx: f32, cy: f32, outer: f32, inner: f32) void {

        if (outer <= 0) return;

        self.add_circle(cx, cy, outer);

        if (inner <= 0 or inner >= outer) return;

        const k = kappa(inner);

        // Reverse winding: counter-clockwise in screen space.

        self.move_to(cx + inner, cy);
        self.cubic_to(cx + inner, cy - k, cx + k, cy - inner, cx, cy - inner);
        self.cubic_to(cx - k, cy - inner, cx - inner, cy - k, cx - inner, cy);
        self.cubic_to(cx - inner, cy + k, cx - k, cy + inner, cx, cy + inner);
        self.cubic_to(cx + k, cy + inner, cx + inner, cy + k, cx + inner, cy);
        self.close();

    }

    /// Arc polyline clockwise from twelve o'clock; ~4° steps keep chords within a subpixel.
    pub fn arc_to(self: *Path, cx: f32, cy: f32, radius: f32, start_deg: i32, sweep_deg: i32) void {

        if (radius <= 0 or sweep_deg == 0) return;

        const steps: i32 = @max(2, @divTrunc(@as(i32, @intCast(@abs(sweep_deg))), 4) + 1);

        var step: i32 = 0;

        while (step <= steps) : (step += 1) {

            const angle = start_deg + @divTrunc(sweep_deg * step, steps);
            const p = polar(cx, cy, radius, angle);

            if (step == 0 and !self.open) {

                self.move_to(p.x, p.y);

            } else {

                self.line_to(p.x, p.y);

            }

        }

    }

    /// A filled pie wedge: center, then the arc, closed. Angles clockwise from twelve o'clock.
    pub fn add_wedge(self: *Path, cx: f32, cy: f32, radius: f32, start_deg: i32, sweep_deg: i32) void {

        if (radius <= 0 or sweep_deg <= 0) return;

        if (sweep_deg >= 360) return self.add_circle(cx, cy, radius);

        self.move_to(cx, cy);
        self.arc_to(cx, cy, radius, start_deg, sweep_deg);
        self.close();

    }

};

// Control-point offset that makes a cubic match a quarter circle.
const kappa_ratio: f32 = 0.552284749830793;

fn kappa(radius: f32) f32 {

    return radius * kappa_ratio;

}

/// Point on a circle at `deg` clockwise from twelve o'clock, in the caller's pixel space.
pub fn polar(cx: f32, cy: f32, radius: f32, deg: i32) Point {

    const radians = @as(f32, @floatFromInt(deg)) * std.math.pi / 180.0;

    return .{

        .x = cx + radius * @sin(radians),
        .y = cy - radius * @cos(radians),

    };

}

const testing = std.testing;

test "path records verbs and closes contours" {

    var path = Path{};

    path.move_to(0, 0);
    path.line_to(1, 0);
    path.quad_to(1, 1, 0, 1);
    path.close();

    try testing.expectEqual(@as(usize, 4), path.verb_count);
    try testing.expectEqual(@as(usize, 4), path.point_count);
    try testing.expect(!path.overflowed);
    try testing.expect(!path.open);

}

test "round rect degrades to a rect at radius zero" {

    var path = Path{};

    path.add_round_rect(0, 0, 10, 10, 0);

    try testing.expectEqual(Verb.line, path.verbs[1]);

    path.reset();
    path.add_round_rect(0, 0, 10, 10, 2);

    try testing.expectEqual(Verb.cubic, path.verbs[2]);

}

test "polar walks clockwise from twelve o'clock" {

    const up = polar(0, 0, 10, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), up.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -10), up.y, 0.001);

    const right = polar(0, 0, 10, 90);

    try testing.expectApproxEqAbs(@as(f32, 10), right.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), right.y, 0.001);

    const down = polar(0, 0, 10, 180);

    try testing.expectApproxEqAbs(@as(f32, 10), down.y, 0.001);

}

test "to_px rounds halves toward positive infinity" {

    try testing.expectEqual(@as(i32, 3), to_px(2.5));
    try testing.expectEqual(@as(i32, 2), to_px(2.4));
    try testing.expectEqual(@as(i32, -2), to_px(-2.5));

}

test "overflow flags instead of writing past the tape" {

    var path = Path{};

    var index: usize = 0;

    while (index < max_verbs + 4) : (index += 1) {

        path.line_to(@floatFromInt(index), 0);

    }

    try testing.expect(path.overflowed);

}
