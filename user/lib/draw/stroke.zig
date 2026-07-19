// Stroke geometry as filled Path contours; round caps/joins with matching winding so overlaps do not cancel.

const std = @import("std");

const path_mod = @import("path.zig");

const Path = path_mod.Path;
const Point = path_mod.Point;

// Degenerate widths still need a visible hairline; matches the old 1/64-pixel floor.
const min_half: f32 = 1.0 / 64.0;

/// Append one stroked segment (pixel coordinates and width) with round caps.
pub fn segment(path: *Path, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {

    const half = @max(min_half, width * 0.5);

    segment_body(path, x0, y0, x1, y1, half);

    path.add_circle(x0, y0, half);
    path.add_circle(x1, y1, half);

}

fn segment_body(path: *Path, x0: f32, y0: f32, x1: f32, y1: f32, half: f32) void {

    const dx = x1 - x0;
    const dy = y1 - y0;
    const length = @sqrt(dx * dx + dy * dy);

    if (length == 0) {

        path.add_circle(x0, y0, half);

        return;

    }

    // Unit normal scaled to half the width.

    const nx = -dy * half / length;
    const ny = dx * half / length;

    // Match add_circle winding so cap/body overlap does not cancel sub-2px icon strokes.

    path.move_to(x0 + nx, y0 + ny);
    path.line_to(x0 - nx, y0 - ny);
    path.line_to(x1 - nx, y1 - ny);
    path.line_to(x1 + nx, y1 + ny);
    path.close();

}

/// Append a stroked open polyline with round joins.
pub fn polyline(path: *Path, points: []const Point, width: f32) void {

    if (points.len == 0) return;

    const half = @max(min_half, width * 0.5);

    if (points.len == 1) {

        path.add_circle(points[0].x, points[0].y, half);

        return;

    }

    var index: usize = 0;

    while (index + 1 < points.len) : (index += 1) {

        segment_body(path, points[index].x, points[index].y, points[index + 1].x, points[index + 1].y, half);

    }

    for (points) |point| {

        path.add_circle(point.x, point.y, half);

    }

}

/// Dense open polyline with round end caps only (no per-vertex join disks). For pre-smoothed polylines.
pub fn chain(path: *Path, points: []const Point, width: f32) void {

    if (points.len == 0) return;

    const half = @max(min_half, width * 0.5);

    if (points.len == 1) {

        path.add_circle(points[0].x, points[0].y, half);

        return;

    }

    var index: usize = 0;

    while (index + 1 < points.len) : (index += 1) {

        segment_body(path, points[index].x, points[index].y, points[index + 1].x, points[index + 1].y, half);

    }

    path.add_circle(points[0].x, points[0].y, half);
    path.add_circle(points[points.len - 1].x, points[points.len - 1].y, half);

}

/// Append a stroked closed polygon outline.
pub fn polygon(path: *Path, points: []const Point, width: f32) void {

    if (points.len < 2) return polyline(path, points, width);

    polyline(path, points, width);
    segment_body(path, points[points.len - 1].x, points[points.len - 1].y, points[0].x, points[0].y, @max(min_half, width * 0.5));

}

/// Append a rectangle border of `thickness`, drawn just inside the rect: an outer/inner ring fill.
pub fn rect_border(path: *Path, x: f32, y: f32, w: f32, h: f32, thickness: f32) void {

    round_rect_border(path, x, y, w, h, 0, thickness);

}

/// Append a rounded-rectangle border of `thickness`, drawn just inside the rect.
pub fn round_rect_border(path: *Path, x: f32, y: f32, w: f32, h: f32, radius: f32, thickness: f32) void {

    if (w <= 0 or h <= 0 or thickness <= 0) return;

    const t = @min(thickness, @min(w / 2, h / 2));

    path.add_round_rect(x, y, w, h, radius);
    path.add_round_rect_reversed(x + t, y + t, w - 2 * t, h - 2 * t, @max(0, radius - t));

}

/// Append a circle outline of `thickness` centered on the radius.
pub fn circle_border(path: *Path, cx: f32, cy: f32, radius: f32, thickness: f32) void {

    if (radius <= 0 or thickness <= 0) return;

    const half = @max(min_half, thickness * 0.5);

    path.add_ring(cx, cy, radius + half, @max(0, radius - half));

}

/// Append an arc stroke (clockwise from twelve o'clock) of `thickness`: the progress-ring primitive.
pub fn arc(path: *Path, cx: f32, cy: f32, radius: f32, start_deg: i32, sweep_deg: i32, thickness: f32) void {

    if (radius <= 0 or sweep_deg == 0) return;

    const steps: i32 = @max(2, @divTrunc(@as(i32, @intCast(@abs(sweep_deg))), 4) + 1);

    var previous = path_mod.polar(cx, cy, radius, start_deg);
    var step: i32 = 1;

    while (step <= steps) : (step += 1) {

        const angle = start_deg + @divTrunc(sweep_deg * step, steps);
        const point = path_mod.polar(cx, cy, radius, angle);

        segment(path, previous.x, previous.y, point.x, point.y, thickness);

        previous = point;

    }

}

const testing = std.testing;

const draw = @import("draw.zig");
const raster = @import("raster.zig");

test "stroked segment covers its spine and respects width" {

    var pixels: [16 * 16]u32 = [_]u32{0} ** (16 * 16);
    const surface = draw.Surface.from_pixels(&pixels, 16, 16);

    var path = Path{};

    segment(&path, path_mod.from_px(2), path_mod.from_px(8), path_mod.from_px(14), path_mod.from_px(8), path_mod.from_px(2));

    raster.fill(&surface, &path, 0xffffff);

    try testing.expectEqual(@as(u32, 0xffffff), pixels[8 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0), pixels[2 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0), pixels[14 * 16 + 8]);

}

test "round caps do not cancel the stroke body" {

    var buffer: [16 * 16]u8 = [_]u8{0} ** (16 * 16);

    var path = Path{};

    // Caps overlapping the body must stay solid under nonzero winding (endpoint sits in both).

    segment(&path, path_mod.from_px(4), path_mod.from_px(8), path_mod.from_px(12), path_mod.from_px(8), path_mod.from_px(4));

    raster.fill_coverage(&path, &buffer, 16, 16, 0, 0);

    try testing.expectEqual(@as(u8, 255), buffer[8 * 16 + 4]);
    try testing.expectEqual(@as(u8, 255), buffer[8 * 16 + 8]);

}

test "a continuous polyline has no interior gaps at its joins" {

    var buffer: [24 * 24]u8 = [_]u8{0} ** (24 * 24);

    var path = Path{};

    // Elbow join disc overlaps both bodies; the corner pixel must stay solid.

    const points = [_]Point{
        .{ .x = path_mod.from_px(4), .y = path_mod.from_px(6) },
        .{ .x = path_mod.from_px(12), .y = path_mod.from_px(6) },
        .{ .x = path_mod.from_px(12), .y = path_mod.from_px(18) },
    };

    polyline(&path, &points, path_mod.from_px(4));

    raster.fill_coverage(&path, &buffer, 24, 24, 0, 0);

    try testing.expectEqual(@as(u8, 255), buffer[6 * 24 + 12]);

}

test "border ring leaves the interior clear" {

    var pixels: [16 * 16]u32 = [_]u32{0} ** (16 * 16);
    const surface = draw.Surface.from_pixels(&pixels, 16, 16);

    var path = Path{};

    rect_border(&path, path_mod.from_px(2), path_mod.from_px(2), path_mod.from_px(12), path_mod.from_px(12), path_mod.from_px(1));

    raster.fill(&surface, &path, 0xffffff);

    try testing.expectEqual(@as(u32, 0xffffff), pixels[2 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0xffffff), pixels[8 * 16 + 2]);
    try testing.expectEqual(@as(u32, 0), pixels[8 * 16 + 8]);
    try testing.expectEqual(@as(u32, 0), pixels[0]);

}
