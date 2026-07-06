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

    pub const window_bg = gfx.rgb(30, 32, 38);
    pub const surface = gfx.rgb(38, 41, 49);
    pub const surface_alt = gfx.rgb(46, 49, 58);
    pub const border = gfx.rgb(58, 62, 73);

    pub const hover = gfx.rgb(52, 56, 67);
    pub const active = gfx.rgb(70, 76, 90);

    pub const accent = gfx.rgb(94, 160, 240);
    pub const accent_dim = gfx.rgb(58, 92, 144);

    pub const text = gfx.rgb(228, 232, 240);
    pub const text_dim = gfx.rgb(150, 158, 172);
    pub const text_faint = gfx.rgb(104, 111, 126);

    pub const good = gfx.rgb(120, 200, 140);
    pub const warn = gfx.rgb(232, 184, 96);

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
