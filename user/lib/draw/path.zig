// Vector path model in 26.6 fixed point (64 subpixel units per pixel), the input language of the analytic
// rasterizer. A Path is a bounded verb/point tape with shape helpers (rects, rounded rects, circles, arcs,
// pie wedges); curves stay curves here and are flattened adaptively at raster time.

const std = @import("std");

/// Subpixel units per pixel.
pub const one: i32 = 64;

pub fn from_px(px: i32) i32 {

    return px * one;

}

/// Round a 26.6 coordinate to whole pixels.
pub fn to_px(fx: i32) i32 {

    return @divFloor(fx + one / 2, one);

}

pub const Point = struct {

    x: i32,
    y: i32,

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

    pub fn move_to(self: *Path, x: i32, y: i32) void {

        if (self.open) self.close();

        const p = Point{ .x = x, .y = y };

        self.push(.move, &.{p});

        self.start = p;
        self.current = p;
        self.open = true;

    }

    pub fn line_to(self: *Path, x: i32, y: i32) void {

        const p = Point{ .x = x, .y = y };

        self.push(.line, &.{p});
        self.current = p;

    }

    pub fn quad_to(self: *Path, cx: i32, cy: i32, x: i32, y: i32) void {

        self.push(.quad, &.{ .{ .x = cx, .y = cy }, .{ .x = x, .y = y } });
        self.current = .{ .x = x, .y = y };

    }

    pub fn cubic_to(self: *Path, c1x: i32, c1y: i32, c2x: i32, c2y: i32, x: i32, y: i32) void {

        self.push(.cubic, &.{ .{ .x = c1x, .y = c1y }, .{ .x = c2x, .y = c2y }, .{ .x = x, .y = y } });
        self.current = .{ .x = x, .y = y };

    }

    pub fn close(self: *Path) void {

        if (!self.open) return;

        self.push(.close, &.{});

        self.current = self.start;
        self.open = false;

    }

    // Shape helpers. All take 26.6 coordinates; use from_px for whole pixels.

    pub fn add_rect(self: *Path, x: i32, y: i32, w: i32, h: i32) void {

        if (w <= 0 or h <= 0) return;

        self.move_to(x, y);
        self.line_to(x + w, y);
        self.line_to(x + w, y + h);
        self.line_to(x, y + h);
        self.close();

    }

    /// Rounded rectangle; the radius clamps to half the shorter side. Quarter circles are cubic arcs.
    pub fn add_round_rect(self: *Path, x: i32, y: i32, w: i32, h: i32, radius_in: i32) void {

        if (w <= 0 or h <= 0) return;

        const radius = @max(0, @min(radius_in, @min(@divTrunc(w, 2), @divTrunc(h, 2))));

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

    /// The same rounded rectangle traversed counter-clockwise: paired with add_round_rect it cuts a
    /// ring, which is how crisp borders are filled in one pass.
    pub fn add_round_rect_reversed(self: *Path, x: i32, y: i32, w: i32, h: i32, radius_in: i32) void {

        if (w <= 0 or h <= 0) return;

        const radius = @max(0, @min(radius_in, @min(@divTrunc(w, 2), @divTrunc(h, 2))));
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

    pub fn add_circle(self: *Path, cx: i32, cy: i32, radius: i32) void {

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
    pub fn add_ring(self: *Path, cx: i32, cy: i32, outer: i32, inner: i32) void {

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

    /// Arc as a polyline appended from the current point: clockwise from `start_deg` sweeping `sweep_deg`
    /// (degrees, 0 = up / twelve o'clock). Steps stay under ~4 degrees so the chords sit within a subpixel.
    pub fn arc_to(self: *Path, cx: i32, cy: i32, radius: i32, start_deg: i32, sweep_deg: i32) void {

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
    pub fn add_wedge(self: *Path, cx: i32, cy: i32, radius: i32, start_deg: i32, sweep_deg: i32) void {

        if (radius <= 0 or sweep_deg <= 0) return;

        if (sweep_deg >= 360) return self.add_circle(cx, cy, radius);

        self.move_to(cx, cy);
        self.arc_to(cx, cy, radius, start_deg, sweep_deg);
        self.close();

    }

};

// Cubic circle-arc control distance: radius * 0.5523 (the standard 4/3 * tan(pi/8) constant), computed as
// radius * 36195 / 65536 to stay integer-exact for large radii.

fn kappa(radius: i32) i32 {

    return @intCast(@divTrunc(@as(i64, radius) * 36195, 65536));

}

/// Point on a circle at `deg` clockwise from twelve o'clock, in the caller's 26.6 space.
pub fn polar(cx: i32, cy: i32, radius: i32, deg: i32) Point {

    const s = sin_deg(deg);
    const c = cos_deg(deg);

    return .{

        .x = cx + @as(i32, @intCast(@divTrunc(@as(i64, radius) * s, sin_one))),
        .y = cy - @as(i32, @intCast(@divTrunc(@as(i64, radius) * c, sin_one))),

    };

}

// Integer sine: quarter-wave table scaled to 1 << 14, indexed per degree.

pub const sin_one: i32 = 1 << 14;

const quarter_sin = [_]i16{
    0, 286, 572, 857, 1143, 1428, 1713, 1997, 2280, 2563,
    2845, 3126, 3406, 3686, 3964, 4240, 4516, 4790, 5063, 5334,
    5604, 5872, 6138, 6402, 6664, 6924, 7182, 7438, 7692, 7943,
    8192, 8438, 8682, 8923, 9162, 9397, 9630, 9860, 10087, 10311,
    10531, 10749, 10963, 11174, 11381, 11585, 11786, 11982, 12176, 12365,
    12551, 12733, 12911, 13085, 13255, 13421, 13583, 13741, 13894, 14044,
    14189, 14330, 14466, 14598, 14726, 14849, 14968, 15082, 15191, 15296,
    15396, 15491, 15582, 15668, 15749, 15826, 15897, 15964, 16026, 16083,
    16135, 16182, 16225, 16262, 16294, 16322, 16344, 16362, 16374, 16382,
    16384,
};

pub fn sin_deg(deg: i32) i32 {

    const wrapped: u32 = @intCast(@mod(deg, 360));

    if (wrapped <= 90) return quarter_sin[wrapped];
    if (wrapped <= 180) return quarter_sin[180 - wrapped];
    if (wrapped <= 270) return -@as(i32, quarter_sin[wrapped - 180]);

    return -@as(i32, quarter_sin[360 - wrapped]);

}

pub fn cos_deg(deg: i32) i32 {

    return sin_deg(deg + 90);

}

const testing = std.testing;

test "path records verbs and closes contours" {

    var path = Path{};

    path.move_to(0, 0);
    path.line_to(64, 0);
    path.quad_to(64, 64, 0, 64);
    path.close();

    try testing.expectEqual(@as(usize, 4), path.verb_count);
    try testing.expectEqual(@as(usize, 4), path.point_count);
    try testing.expect(!path.overflowed);
    try testing.expect(!path.open);

}

test "round rect degrades to a rect at radius zero" {

    var path = Path{};

    path.add_round_rect(0, 0, 640, 640, 0);

    try testing.expectEqual(Verb.line, path.verbs[1]);

    path.reset();
    path.add_round_rect(0, 0, 640, 640, 128);

    try testing.expectEqual(Verb.cubic, path.verbs[2]);

}

test "sine table hits the cardinal points" {

    try testing.expectEqual(@as(i32, 0), sin_deg(0));
    try testing.expectEqual(sin_one, sin_deg(90));
    try testing.expectEqual(@as(i32, 0), sin_deg(180));
    try testing.expectEqual(-sin_one, sin_deg(270));
    try testing.expectEqual(sin_one, cos_deg(0));
    try testing.expectEqual(@as(i32, 8192), sin_deg(30));

}

test "polar walks clockwise from twelve o'clock" {

    const up = polar(0, 0, from_px(10), 0);

    try testing.expectEqual(@as(i32, 0), up.x);
    try testing.expectEqual(from_px(-10), up.y);

    const right = polar(0, 0, from_px(10), 90);

    try testing.expectEqual(from_px(10), right.x);
    try testing.expectEqual(@as(i32, 0), right.y);

}

test "overflow flags instead of writing past the tape" {

    var path = Path{};

    var index: usize = 0;

    while (index < max_verbs + 4) : (index += 1) {

        path.line_to(@intCast(index), 0);

    }

    try testing.expect(path.overflowed);

}
