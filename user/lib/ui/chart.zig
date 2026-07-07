// Chart painters for canvas nodes: line charts, pie charts, per-core gantt strips, and proportion meters.
// Everything renders through the analytic-AA renderer - pie slices are true filled wedges, chart lines are
// stroked paths - so the Status app's graphs are smooth down to the subpixel.

const std = @import("std");

const draw = @import("../draw/draw.zig");
const path_mod = @import("../draw/path.zig");
const raster = @import("../draw/raster.zig");
const stroke = @import("../draw/stroke.zig");

const ui = @import("ui.zig");

const Color = draw.Color;
const Path = path_mod.Path;
const Point = path_mod.Point;
const Rect = draw.Rect;
const Surface = draw.Surface;

const max_samples = 256;

/// A left-to-right line chart of `samples` (most recent last) scaled so `max` reaches the top, with a light
/// area fill beneath the stroke.
pub fn line(surface: *const Surface, rect: Rect, samples: []const u32, max_in: u32, color: Color) void {

    surface.fill_rect(rect, ui.theme.surface);

    var shape = Path{};

    stroke.rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(1));
    raster.fill(surface, &shape, ui.theme.border);

    if (samples.len < 2) return;

    const max: i64 = @max(1, max_in);
    const inner = rect.inset(2);

    if (inner.w <= 0 or inner.h <= 0) return;

    // Faint quarter gridlines.

    var g: i32 = 1;

    while (g < 4) : (g += 1) {

        const gy = inner.y + @divTrunc(inner.h * g, 4);

        surface.fill_rect(.{ .x = inner.x, .y = gy, .w = inner.w, .h = 1 }, ui.theme.surface_alt);

    }

    const count = @min(samples.len, max_samples);
    const window = samples[samples.len - count ..];
    const last = count - 1;

    var points: [max_samples]Point = undefined;

    for (window, 0..) |sample, index| {

        points[index] = .{

            .x = path_mod.from_px(inner.x) + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index)) * inner.w * 64, @as(i64, @intCast(last))))),
            .y = plot_y_fx(inner, sample, max),

        };

    }

    // Area fill: the polyline closed down to the baseline, then the stroke on top.

    const clipped = surface.clipped(inner);

    shape.reset();
    shape.move_to(points[0].x, path_mod.from_px(inner.y + inner.h));

    for (points[0..count]) |p| {

        shape.line_to(p.x, p.y);

    }

    shape.line_to(points[last].x, path_mod.from_px(inner.y + inner.h));
    shape.close();

    raster.fill(&clipped, &shape, draw.mix(ui.theme.surface, color, 48));

    shape.reset();
    stroke.polyline(&shape, points[0..count], path_mod.from_px(2));
    raster.fill(&clipped, &shape, color);

}

fn plot_y_fx(inner: Rect, value: u32, max: i64) i32 {

    const clamped: i64 = @min(@as(i64, value), max);

    return path_mod.from_px(inner.y + inner.h) - @as(i32, @intCast(@divTrunc(clamped * inner.h * 64, max)));

}

pub const PieSlice = struct {

    value: u64,
    color: Color,

};

/// A filled pie chart of `slices` (most significant first), centered at (cx, cy): true antialiased wedges.
pub fn pie(surface: *const Surface, cx: i32, cy: i32, radius: i32, slices: []const PieSlice) void {

    if (radius <= 0) return;

    var total: u64 = 0;

    for (slices) |slice| total += slice.value;

    var shape = Path{};

    if (total == 0) {

        shape.add_circle(path_mod.from_px(cx), path_mod.from_px(cy), path_mod.from_px(radius));
        raster.fill(surface, &shape, ui.theme.surface);

        shape.reset();
        stroke.circle_border(&shape, path_mod.from_px(cx), path_mod.from_px(cy), path_mod.from_px(radius), path_mod.from_px(1));
        raster.fill(surface, &shape, ui.theme.border);

        return;

    }

    const cfx = path_mod.from_px(cx);
    const cfy = path_mod.from_px(cy);
    const rfx = path_mod.from_px(radius);

    var start: i64 = 0;
    var consumed: u64 = 0;

    for (slices) |slice| {

        if (slice.value == 0) continue;

        consumed += slice.value;

        // Cumulative angles avoid rounding drift between adjacent wedges.

        const end: i64 = @intCast(@divTrunc(consumed * 360, total));

        if (end > start) {

            shape.reset();
            shape.add_wedge(cfx, cfy, rfx, @intCast(start), @intCast(end - start));
            raster.fill(surface, &shape, slice.color);

        }

        start = end;

    }

    shape.reset();
    stroke.circle_border(&shape, cfx, cfy, rfx, path_mod.from_px(1));
    raster.fill(surface, &shape, ui.theme.border);

}

pub const GanttSample = struct {

    pid: u32,
    tid: u32,

};

fn gantt_color(pid: u32, tid: u32) Color {

    if (tid == 0) return ui.theme.surface_alt;

    return switch (pid % 8) {

        0 => ui.theme.accent,
        1 => ui.theme.text,
        2 => ui.theme.text_dim,
        3 => ui.theme.good,
        4 => ui.theme.warn,
        5 => ui.theme.accent_dim,
        6 => ui.theme.hover,

        else => ui.theme.active,

    };

}

/// Per-core occupancy over time: one row per entry in `rows`, oldest sample left, newest right.
pub fn gantt(surface: *const Surface, rect: Rect, rows: []const []const GanttSample) void {

    surface.fill_rect(rect, ui.theme.surface);

    var shape = Path{};

    stroke.rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(1));
    raster.fill(surface, &shape, ui.theme.border);

    if (rows.len == 0) return;

    const inner = rect.inset(2);

    if (inner.w <= 0 or inner.h <= 0) return;

    const row_h = @divTrunc(inner.h, @as(i32, @intCast(rows.len)));

    if (row_h <= 0) return;

    for (rows, 0..) |row, row_index| {

        const y = inner.y + @as(i32, @intCast(row_index)) * row_h;

        if (row_index > 0) {

            surface.fill_rect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ui.theme.border);

        }

        if (row.len == 0) continue;

        if (row.len == 1) {

            surface.fill_rect(.{ .x = inner.x, .y = y + 1, .w = inner.w, .h = row_h - 2 }, gantt_color(row[0].pid, row[0].tid));

            continue;

        }

        const last = row.len - 1;

        for (row, 0..) |sample, index| {

            const x0 = inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index)) * inner.w, @as(i64, @intCast(last)))));
            const x1 = if (index == last) inner.x + inner.w else inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index + 1)) * inner.w, @as(i64, @intCast(last)))));

            surface.fill_rect(.{ .x = x0, .y = y + 1, .w = @max(1, x1 - x0), .h = row_h - 2 }, gantt_color(sample.pid, sample.tid));

        }

    }

}

/// A horizontal proportion bar (used over total), rounded.
pub fn meter(surface: *const Surface, rect: Rect, fraction_num: u64, fraction_den: u64, color: Color) void {

    var shape = Path{};
    const radius = @min(@divTrunc(rect.h, 2), 4);

    shape.add_round_rect(path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius));
    raster.fill(surface, &shape, ui.theme.surface);

    shape.reset();
    stroke.round_rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius), path_mod.from_px(1));
    raster.fill(surface, &shape, ui.theme.border);

    if (fraction_den == 0) return;

    const span: u64 = @intCast(@max(0, rect.w - 2));
    const filled: i32 = @intCast(@min(span, span * fraction_num / fraction_den));

    if (filled <= 0) return;

    shape.reset();
    shape.add_round_rect(path_mod.from_px(rect.x + 1), path_mod.from_px(rect.y + 1), path_mod.from_px(filled), path_mod.from_px(rect.h - 2), path_mod.from_px(@max(0, radius - 1)));
    raster.fill(surface, &shape, color);

}

const testing = std.testing;

test "pie fills complementary wedges without gaps at the center ring" {

    var pixels: [64 * 64]u32 = [_]u32{0} ** (64 * 64);
    const surface = Surface.from_pixels(&pixels, 64, 64);

    pie(&surface, 32, 32, 20, &.{

        .{ .value = 1, .color = 0xff0000 },
        .{ .value = 1, .color = 0x00ff00 },

    });

    // First wedge sweeps 0..180 (right half), second 180..360 (left half).

    try testing.expectEqual(@as(u32, 0xff0000), pixels[32 * 64 + 42]);
    try testing.expectEqual(@as(u32, 0x00ff00), pixels[32 * 64 + 22]);
    try testing.expectEqual(@as(u32, 0), pixels[2 * 64 + 2]);

}

test "meter clamps the filled span" {

    var pixels: [32 * 8]u32 = [_]u32{0} ** (32 * 8);
    const surface = Surface.from_pixels(&pixels, 32, 8);

    meter(&surface, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, 5, 4, 0xffffff);

    try testing.expectEqual(@as(u32, 0xffffff), pixels[4 * 32 + 15]);

}
