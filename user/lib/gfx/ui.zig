// A small immediate-mode drawing toolkit shared by the desktop apps: a common dark theme plus flat widgets (buttons,
// cards, tabs) and chart primitives, all rendered straight onto a gfx.Surface with the Inter face. It keeps the four
// GUI programs visually consistent without a retained widget tree - each app repaints from its own state.

const gfx = @import("gfx.zig");
const svg = @import("svg.zig");
const ttf = @import("ttf.zig");

const Surface = gfx.Surface;
const Rect = gfx.Rect;
const Color = gfx.Color;
const Face = ttf.Face;

pub const theme = struct {

    pub const window_bg = gfx.rgb(30, 30, 30);
    pub const surface = gfx.rgb(38, 38, 38);
    pub const surface_alt = gfx.rgb(46, 46, 46);
    pub const border = gfx.rgb(58, 58, 58);

    pub const hover = gfx.rgb(52, 52, 52);
    pub const active = gfx.rgb(70, 70, 70);

    pub const accent = gfx.rgb(200, 200, 200);
    pub const accent_dim = gfx.rgb(100, 100, 100);

    pub const text = gfx.rgb(230, 230, 230);
    pub const text_dim = gfx.rgb(160, 160, 160);
    pub const text_faint = gfx.rgb(110, 110, 110);

    pub const good = gfx.rgb(190, 190, 190);
    pub const warn = gfx.rgb(140, 140, 140);

};

pub const ButtonStyle = enum {

    normal,
    hover,
    active,
    accent,

};

pub fn fill(surface: *const Surface, color: Color) void {

    surface.fill(color);

}

/// Draw `s` with its top-left at (x, y); a thin wrapper so apps don't repeat the face call.
pub fn text(surface: *const Surface, font: *const Face, x: i32, y: i32, size: u32, s: []const u8, color: Color) void {

    font.draw(surface, x, y, size, s, color);

}

/// The longest prefix of `s` whose width at `size` fits in `max_w`.
pub fn truncate(font: *const Face, s: []const u8, size: u32, max_w: i32) []const u8 {

    if (max_w <= 0) return s[0..0];

    var length = s.len;

    while (length > 0 and font.text_width(s[0..length], size) > max_w) : (length -= 1) {}

    return s[0..length];

}

/// Text vertically centered in `rect`, left-aligned at `pad` from its left edge, clipped to fit.
pub fn text_in(surface: *const Surface, font: *const Face, rect: Rect, pad: i32, size: u32, s: []const u8, color: Color) void {

    const clipped = truncate(font, s, size, rect.w - 2 * pad);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, rect.x + pad, y, size, clipped, color);

}

pub fn text_center(surface: *const Surface, font: *const Face, rect: Rect, size: u32, s: []const u8, color: Color) void {

    const clipped = truncate(font, s, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(clipped, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, clipped, color);

}

pub fn card(surface: *const Surface, rect: Rect, fill_color: Color) void {

    surface.fill_rect(rect, fill_color);

}

pub fn card_bordered(surface: *const Surface, rect: Rect, fill_color: Color, border_color: Color) void {

    surface.fill_rect(rect, fill_color);
    surface.stroke_rect(rect, 1, border_color);

}

pub fn button(surface: *const Surface, font: *const Face, rect: Rect, label: []const u8, size: u32, style: ButtonStyle) void {

    const bg = switch (style) {

        .normal => theme.surface_alt,
        .hover => theme.hover,
        .active => theme.active,
        .accent => theme.accent_dim,

    };

    const fg = switch (style) {

        .accent => theme.text,
        else => theme.text,

    };

    surface.fill_rect(rect, bg);

    if (style == .accent) surface.stroke_rect(rect, 1, theme.accent);

    text_center(surface, font, rect, size, label, fg);

}

// Icons are static vector strokes, so each (icon, size) is rasterized to an 8-bit coverage mask once and then blitted
// in whatever tint the caller wants - the supersampled SVG stroking never runs on the per-frame path.

const icon_box: u32 = 32;
const icon_capacity: usize = 48;

const IconEntry = struct {

    used: bool = false,
    source: usize = 0,

    w: u16 = 0,
    h: u16 = 0,

};

var icon_meta = [_]IconEntry{.{}} ** icon_capacity;
var icon_coverage: [icon_capacity][icon_box * icon_box]u8 = undefined;

pub fn icon(surface: *const Surface, rect: Rect, svg_bytes: []const u8, color: Color) void {

    if (rect.w > 0 and rect.h > 0 and rect.w <= icon_box and rect.h <= icon_box) {

        if (cached_icon(svg_bytes, @intCast(rect.w), @intCast(rect.h))) |slot| {

            const entry = icon_meta[slot];

            surface.blend_coverage(rect.x, rect.y, icon_coverage[slot][0 .. @as(u32, entry.w) * entry.h], entry.w, entry.h, color);

            return;

        }

    }

    svg.draw_icon(surface, rect, svg_bytes, color);

}

fn cached_icon(svg_bytes: []const u8, w: u32, h: u32) ?usize {

    const source = @intFromPtr(svg_bytes.ptr);
    const start = (source ^ (w *% 131) ^ (h *% 977)) % icon_capacity;

    var probe: usize = 0;
    var slot = start;

    while (probe < 8) : (probe += 1) {

        const entry = &icon_meta[slot];

        if (entry.used and entry.source == source and entry.w == w and entry.h == h) return slot;

        if (!entry.used) return render_icon(slot, svg_bytes, source, w, h);

        slot = (slot + 1) % icon_capacity;

    }

    return render_icon(start, svg_bytes, source, w, h);

}

fn render_icon(slot: usize, svg_bytes: []const u8, source: usize, w: u32, h: u32) ?usize {

    var pixels: [icon_box * icon_box]u32 = undefined;

    var temp = Surface{

        .pixels = &pixels,

        .width = w,
        .height = h,

        .stride = w,

    };

    // White strokes over black: the anti-aliased channel value is exactly the coverage we want to keep.

    temp.fill(gfx.rgb(0, 0, 0));
    svg.draw_icon(&temp, .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) }, svg_bytes, gfx.rgb(255, 255, 255));

    const cells = w * h;

    for (0..cells) |index| {

        icon_coverage[slot][index] = gfx.blue(pixels[index]);

    }

    icon_meta[slot] = .{

        .used = true,
        .source = source,

        .w = @intCast(w),
        .h = @intCast(h),

    };

    return slot;

}

/// A left-to-right line chart of `samples` (most recent last) scaled so `max` reaches the top; the area beneath the
/// line is lightly filled. Used by the Status app's realtime graphs.
pub fn line_chart(surface: *const Surface, rect: Rect, samples: []const u32, max_in: u32, color: Color) void {

    surface.fill_rect(rect, theme.surface);
    surface.stroke_rect(rect, 1, theme.border);

    if (samples.len < 2) return;

    const max: i64 = @max(1, max_in);
    const inner = Rect{ .x = rect.x + 2, .y = rect.y + 2, .w = rect.w - 4, .h = rect.h - 4 };

    if (inner.w <= 0 or inner.h <= 0) return;

    // Gridlines: quarters of the plot height, faint, so magnitudes read at a glance.

    var g: i32 = 1;

    while (g < 4) : (g += 1) {

        const gy = inner.y + @divTrunc(inner.h * g, 4);

        surface.fill_rect(.{ .x = inner.x, .y = gy, .w = inner.w, .h = 1 }, theme.surface_alt);

    }

    const last = samples.len - 1;

    var index: usize = 0;

    while (index < last) : (index += 1) {

        const x0 = inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index)) * inner.w, @as(i64, @intCast(last)))));
        const x1 = inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index + 1)) * inner.w, @as(i64, @intCast(last)))));

        const y0 = plot_y(inner, samples[index], max);
        const y1 = plot_y(inner, samples[index + 1], max);

        // Column fill under the segment, then the stroke on top.

        const fill_top = @min(y0, y1);

        surface.fill_rect_alpha(.{ .x = x0, .y = fill_top, .w = @max(1, x1 - x0), .h = inner.y + inner.h - fill_top }, color, 40);
        surface.stroke_line_smooth(x0, y0, x1, y1, 2, color);

    }

}

fn plot_y(inner: Rect, value: u32, max: i64) i32 {

    const clamped: i64 = @min(@as(i64, value), max);

    return inner.y + inner.h - @as(i32, @intCast(@divTrunc(clamped * inner.h, max)));

}

pub const PieSlice = struct {

    value: u64,
    color: Color,

};

/// A filled pie chart of `slices` (most significant first), centered at (cx, cy).
pub fn pie_chart(surface: *const Surface, cx: i32, cy: i32, radius: i32, slices: []const PieSlice) void {

    if (radius <= 0) return;

    var total: u64 = 0;

    for (slices) |slice| total += slice.value;

    if (total == 0) {

        surface.fill_circle(cx, cy, radius, theme.surface);
        surface.stroke_circle_smooth(cx, cy, radius, 1, theme.border);

        return;

    }

    var bounds: [8]struct { start: u16, end: u16, color: Color } = undefined;
    var bound_count: usize = 0;
    var start: u16 = 0;

    for (slices) |slice| {

        if (slice.value == 0) continue;

        const sweep: u16 = @intCast(@min(360, slice.value * 360 / total));

        bounds[bound_count] = .{
            .start = start,
            .end = start +% sweep,
            .color = slice.color,
        };

        bound_count += 1;
        start +%= sweep;

    }

    const radius_sq = radius * radius;

    var dy: i32 = -radius;

    while (dy <= radius) : (dy += 1) {

        var dx: i32 = -radius;

        while (dx <= radius) : (dx += 1) {

            if (dx * dx + dy * dy > radius_sq) continue;

            const angle = point_angle_cw(dx, dy);

            for (bounds[0..bound_count]) |bound| {

                if (angle_in_wedge(angle, bound.start, bound.end)) {

                    surface.put_pixel(cx + dx, cy + dy, bound.color);
                    break;

                }

            }

        }

    }

    surface.stroke_circle_smooth(cx, cy, radius, 1, theme.border);

}

fn point_angle_cw(dx: i32, dy: i32) u16 {

    if (dx == 0 and dy == 0) return 0;

    const ax: u32 = @intCast(@abs(dx));
    const ay: u32 = @intCast(@abs(dy));
    var deg: u32 = 0;

    if (ax >= ay) {

        deg = @intCast((ay * 45) / ax);

        if (dx > 0 and dy < 0) {

            deg = 90 - deg;

        } else if (dx > 0 and dy >= 0) {

            deg = 90 + deg;

        } else if (dx < 0 and dy >= 0) {

            deg = 270 - deg;

        } else {

            deg = 270 + deg;

        }

    } else {

        deg = @intCast((ax * 45) / ay);

        if (dx >= 0 and dy < 0) {

            deg = 0 + deg;

        } else if (dx >= 0 and dy > 0) {

            deg = 180 - deg;

        } else if (dx < 0 and dy > 0) {

            deg = 180 + deg;

        } else {

            deg = 360 - deg;

        }

    }

    return @intCast(deg % 360);

}

fn angle_in_wedge(angle: u16, start: u16, end: u16) bool {

    if (end <= 360) return angle >= start and angle < end;

    return angle >= start or angle < (end - 360);

}

/// Vertically center an icon inside `rect`.
pub fn icon_in(surface: *const Surface, rect: Rect, svg_bytes: []const u8, color: Color) void {

    const size = @min(rect.w, rect.h);

    const x = rect.x + @divTrunc(rect.w - size, 2);
    const y = rect.y + @divTrunc(rect.h - size, 2);

    icon(surface, .{ .x = x, .y = y, .w = size, .h = size }, svg_bytes, color);

}

pub const GanttSample = struct {

    pid: u32,
    tid: u32,

};

const gantt_palette = [_]Color{
    theme.accent,
    theme.text,
    theme.text_dim,
    theme.good,
    theme.warn,
    theme.accent_dim,
    theme.hover,
    theme.active,
};

fn gantt_color(pid: u32, tid: u32) Color {

    if (tid == 0) return theme.surface_alt;

    return gantt_palette[pid % gantt_palette.len];

}

/// Per-core occupancy over time: one row per entry in `rows`, oldest sample left, newest right.
pub fn gantt_chart(surface: *const Surface, rect: Rect, rows: []const []const GanttSample) void {

    surface.fill_rect(rect, theme.surface);
    surface.stroke_rect(rect, 1, theme.border);

    if (rows.len == 0) return;

    const inner = Rect{ .x = rect.x + 2, .y = rect.y + 2, .w = rect.w - 4, .h = rect.h - 4 };

    if (inner.w <= 0 or inner.h <= 0) return;

    const row_h = @divTrunc(inner.h, @as(i32, @intCast(rows.len)));

    if (row_h <= 0) return;

    for (rows, 0..) |row, row_index| {

        const y = inner.y + @as(i32, @intCast(row_index)) * row_h;

        if (row_index > 0) {

            surface.fill_rect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, theme.border);

        }

        if (row.len == 0) continue;

        if (row.len == 1) {

            const sample = row[0];

            surface.fill_rect(.{ .x = inner.x, .y = y + 1, .w = inner.w, .h = row_h - 2 }, gantt_color(sample.pid, sample.tid));

            continue;

        }

        const last = row.len - 1;

        var index: usize = 0;

        while (index < row.len) : (index += 1) {

            const x0 = inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index)) * inner.w, @as(i64, @intCast(last)))));
            const x1 = if (index == last) inner.x + inner.w else inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index + 1)) * inner.w, @as(i64, @intCast(last)))));
            const sample = row[index];

            surface.fill_rect(.{ .x = x0, .y = y + 1, .w = @max(1, x1 - x0), .h = row_h - 2 }, gantt_color(sample.pid, sample.tid));

        }

    }

}

/// A horizontal proportion bar (used → total), for the disk view.
pub fn meter(surface: *const Surface, rect: Rect, fraction_num: u64, fraction_den: u64, color: Color) void {

    surface.fill_rect(rect, theme.surface);
    surface.stroke_rect(rect, 1, theme.border);

    if (fraction_den == 0) return;

    const span: u64 = @intCast(@max(0, rect.w - 2));
    const filled: i32 = @intCast(@min(span, span * fraction_num / fraction_den));

    surface.fill_rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = filled, .h = rect.h - 2 }, color);

}

pub fn contains(rect: Rect, x: i32, y: i32) bool {

    return rect.contains(x, y);

}
