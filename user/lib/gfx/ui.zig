// A small immediate-mode drawing toolkit shared by the desktop apps: a common dark theme plus flat widgets (buttons,
// cards, tabs) and chart primitives, all rendered straight onto a gfx.Surface with the Inter face. It keeps the four
// GUI programs visually consistent without a retained widget tree - each app repaints from its own state.

const std = @import("std");

const gfx = @import("gfx.zig");
const svg = @import("svg.zig");
const ttf = @import("ttf.zig");

const Surface = gfx.Surface;
const Rect = gfx.Rect;
const Color = gfx.Color;
const Face = ttf.Face;

pub const Theme = struct {

    window_bg: Color = gfx.rgb(30, 30, 30),
    surface: Color = gfx.rgb(38, 38, 38),
    surface_alt: Color = gfx.rgb(46, 46, 46),
    border: Color = gfx.rgb(58, 58, 58),

    hover: Color = gfx.rgb(52, 52, 52),
    active: Color = gfx.rgb(70, 70, 70),

    accent: Color = gfx.rgb(200, 200, 200),
    accent_dim: Color = gfx.rgb(100, 100, 100),

    text: Color = gfx.rgb(230, 230, 230),
    text_dim: Color = gfx.rgb(160, 160, 160),
    text_faint: Color = gfx.rgb(110, 110, 110),

    good: Color = gfx.rgb(190, 190, 190),
    warn: Color = gfx.rgb(140, 140, 140),

};

pub var theme = Theme{};

pub const MenuItem = struct {

    label: []const u8,

};

/// Flat highlight for a list row.
pub fn row_hover(surface: *const Surface, rect: Rect) void {

    surface.fill_rect(rect, theme.hover);

}

/// A flat panel: fill plus a 1px border.
pub fn panel(surface: *const Surface, rect: Rect, fill_color: Color) void {

    surface.fill_rect(rect, fill_color);
    surface.stroke_rect(rect, 1, theme.border);

}

/// A simple vertical context menu anchored at (x, y).
pub fn context_menu(surface: *const Surface, font: *const Face, x: i32, y: i32, items: []const MenuItem, hover: ?usize) void {

    const row_h: i32 = 28;
    const pad: i32 = 12;
    const width: i32 = 200;
    const height = row_h * @as(i32, @intCast(items.len));

    const rect = Rect{ .x = x, .y = y, .w = width, .h = height };

    panel(surface, rect, theme.surface);

    for (items, 0..) |item, index| {

        const row = Rect{ .x = rect.x, .y = rect.y + @as(i32, @intCast(index)) * row_h, .w = rect.w, .h = row_h };

        if (hover != null and hover.? == index) row_hover(surface, row);

        text_in(surface, font, row, pad, 13, item.label, theme.text);

    }

}

pub fn menu_rect(x: i32, y: i32, item_count: usize) Rect {

    const row_h: i32 = 28;
    const width: i32 = 200;

    return .{ .x = x, .y = y, .w = width, .h = row_h * @as(i32, @intCast(item_count)) };

}

pub fn menu_hit(x: i32, y: i32, origin_x: i32, origin_y: i32, item_count: usize) ?usize {

    const rect = menu_rect(origin_x, origin_y, item_count);

    if (!rect.contains(x, y)) return null;

    const row_h: i32 = 28;
    const row = @divTrunc(y - rect.y, row_h);

    if (row < 0 or row >= @as(i32, @intCast(item_count))) return null;

    return @intCast(row);

}

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

/// A dim caption at (x, y): the tone forms use for field labels and section headers.
pub fn label(surface: *const Surface, font: *const Face, x: i32, y: i32, size: u32, s: []const u8) void {

    font.draw(surface, x, y, size, s, theme.text_dim);

}

pub fn card(surface: *const Surface, rect: Rect, fill_color: Color) void {

    surface.fill_rect(rect, fill_color);

}

pub fn card_bordered(surface: *const Surface, rect: Rect, fill_color: Color, border_color: Color) void {

    surface.fill_rect(rect, fill_color);
    surface.stroke_rect(rect, 1, border_color);

}

pub fn button(surface: *const Surface, font: *const Face, rect: Rect, caption: []const u8, size: u32, style: ButtonStyle) void {

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

    text_center(surface, font, rect, size, caption, fg);

}

// Text input. EditBuffer is the model - a caret over a caller-owned byte span with the line-editing operations a
// single-line field needs - and text_field is the view. Keeping the two apart lets an app store the text however it
// likes (a fixed array, a slice of a document) while sharing the caret behavior and rendering across every field.

pub const EditBuffer = struct {

    bytes: []u8,
    len: usize = 0,
    cursor: usize = 0,

    pub fn init(storage: []u8) EditBuffer {

        return .{ .bytes = storage };

    }

    pub fn slice(self: *const EditBuffer) []const u8 {

        return self.bytes[0..self.len];

    }

    pub fn clear(self: *EditBuffer) void {

        self.len = 0;
        self.cursor = 0;

    }

    /// Insert one byte at the caret, returning false when the storage is full.
    pub fn insert(self: *EditBuffer, byte: u8) bool {

        if (self.len >= self.bytes.len) return false;

        var index = self.len;

        while (index > self.cursor) : (index -= 1) self.bytes[index] = self.bytes[index - 1];

        self.bytes[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;

        return true;

    }

    /// Delete the byte before the caret (the Backspace key).
    pub fn backspace(self: *EditBuffer) bool {

        if (self.cursor == 0) return false;

        var index = self.cursor - 1;

        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];

        self.len -= 1;
        self.cursor -= 1;

        return true;

    }

    /// Delete the byte at the caret (the Delete key).
    pub fn delete(self: *EditBuffer) bool {

        if (self.cursor >= self.len) return false;

        var index = self.cursor;

        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];

        self.len -= 1;

        return true;

    }

    pub fn left(self: *EditBuffer) bool {

        if (self.cursor == 0) return false;

        self.cursor -= 1;

        return true;

    }

    pub fn right(self: *EditBuffer) bool {

        if (self.cursor >= self.len) return false;

        self.cursor += 1;

        return true;

    }

    pub fn home(self: *EditBuffer) bool {

        if (self.cursor == 0) return false;

        self.cursor = 0;

        return true;

    }

    pub fn end(self: *EditBuffer) bool {

        if (self.cursor == self.len) return false;

        self.cursor = self.len;

        return true;

    }

    /// Apply one key's byte sequence straight from keymap.Keyboard.bytes: printable bytes insert, Backspace/Delete
    /// edit, and the CSI arrow/Home/End escapes move the caret. Returns true when the buffer changed so the caller
    /// knows to repaint. Enter and other control bytes are left for the app to act on.
    pub fn feed(self: *EditBuffer, input: []const u8) bool {

        if (input.len == 3 and input[0] == 0x1b and input[1] == '[') {

            return switch (input[2]) {

                'C' => self.right(),
                'D' => self.left(),
                'H' => self.home(),
                'F' => self.end(),

                else => false,

            };

        }

        if (input.len == 1) {

            const byte = input[0];

            if (byte == 0x7f or byte == 0x08) return self.backspace();
            if (byte >= 0x20 and byte < 0x7f) return self.insert(byte);

        }

        return false;

    }

};

pub const FieldState = struct {

    focused: bool = false,

    // The caller flips this from its own clock so the caret blinks; a static field can leave it true.
    caret_on: bool = true,

};

const field_pad: i32 = 8;

/// A single-line text input: a bordered box (accent border when focused), the current text or a faint placeholder
/// when empty, and a caret at the edit cursor. Immediate-mode - pass the live buffer and repaint each change.
pub fn text_field(surface: *const Surface, font: *const Face, rect: Rect, size: u32, buffer: *const EditBuffer, placeholder: []const u8, state: FieldState) void {

    surface.fill_rect(rect, theme.surface);
    surface.stroke_rect(rect, 1, if (state.focused) theme.accent else theme.border);

    const inner_x = rect.x + field_pad;
    const inner_w = rect.w - 2 * field_pad;

    if (inner_w <= 0) return;

    const baseline = rect.y + @divTrunc(rect.h - font.line_height(size), 2);
    const content = buffer.slice();

    if (content.len == 0 and placeholder.len > 0) {

        font.draw(surface, inner_x, baseline, size, truncate(font, placeholder, size, inner_w), theme.text_faint);

    } else {

        // Scroll the text horizontally so the caret stays in view when the content overflows the box.

        const start = field_scroll_start(font, content, buffer.cursor, size, inner_w);

        font.draw(surface, inner_x, baseline, size, truncate(font, content[start..], size, inner_w), theme.text);

    }

    if (state.focused and state.caret_on) {

        const start = field_scroll_start(font, content, buffer.cursor, size, inner_w);
        const before = content[start..@min(buffer.cursor, content.len)];
        const caret_x = @min(inner_x + font.text_width(before, size), inner_x + inner_w);
        const caret_h = @min(rect.h - 6, font.line_height(size));
        const caret_y = rect.y + @divTrunc(rect.h - caret_h, 2);

        surface.fill_rect(.{ .x = caret_x, .y = caret_y, .w = 1, .h = caret_h }, theme.text);

    }

}

/// The first visible byte so the caret at `cursor` stays within `width`: the whole string when it fits, otherwise the
/// widest suffix ending at the caret that still fits.
fn field_scroll_start(font: *const Face, content: []const u8, cursor: usize, size: u32, width: i32) usize {

    if (width <= 0 or font.text_width(content, size) <= width) return 0;

    var start: usize = 0;

    while (start < cursor and font.text_width(content[start..cursor], size) > width) : (start += 1) {}

    return start;

}

/// A caption above `rect`, then the field inside it. The label sits one line-height above the box's top edge.
pub fn labeled_field(surface: *const Surface, font: *const Face, rect: Rect, size: u32, caption: []const u8, buffer: *const EditBuffer, placeholder: []const u8, state: FieldState) void {

    label(surface, font, rect.x, rect.y - font.line_height(size) - 2, size, caption);
    text_field(surface, font, rect, size, buffer, placeholder, state);

}

/// A labeled checkbox: a small box (filled when checked) with the caption to its right, vertically centered in `rect`.
pub fn checkbox(surface: *const Surface, font: *const Face, rect: Rect, checked: bool, caption: []const u8, size: u32) void {

    const box: i32 = @min(rect.h - 4, 16);
    const box_y = rect.y + @divTrunc(rect.h - box, 2);
    const box_rect = Rect{ .x = rect.x, .y = box_y, .w = box, .h = box };

    surface.fill_rect(box_rect, theme.surface_alt);
    surface.stroke_rect(box_rect, 1, if (checked) theme.accent else theme.border);

    if (checked) {

        const inset = @max(2, @divTrunc(box, 4));

        surface.fill_rect(.{ .x = box_rect.x + inset, .y = box_rect.y + inset, .w = box - 2 * inset, .h = box - 2 * inset }, theme.accent);

    }

    const text_x = rect.x + box + 8;

    text_in(surface, font, .{ .x = text_x, .y = rect.y, .w = rect.x + rect.w - text_x, .h = rect.h }, 0, size, caption, theme.text);

}

// Scroll overflow. Scroll is a unit-agnostic model - the same shape works whether an app tracks its offset in rows or
// in pixels: a content extent, the viewport showing part of it, and the current offset. It clamps the offset and sizes
// the indicator; scrollbar draws the proportional thumb, and nothing shows while the content fits.

pub const scrollbar_width: i32 = 8;

const min_thumb: i32 = 16;

pub const Scroll = struct {

    offset: i32 = 0,
    content: i32 = 0,
    viewport: i32 = 0,

    pub fn max_offset(self: Scroll) i32 {

        return @max(0, self.content - self.viewport);

    }

    pub fn overflowing(self: Scroll) bool {

        return self.viewport > 0 and self.content > self.viewport;

    }

    /// `offset` forced into [0, max_offset]; keep an app's stored offset valid after content or viewport changes.
    pub fn clamped(self: Scroll) i32 {

        return @max(0, @min(self.offset, self.max_offset()));

    }

    const Thumb = struct {

        pos: i32,
        len: i32,

    };

    /// Thumb offset and length along a track of `track` units, proportional to the visible fraction.
    pub fn thumb(self: Scroll, track: i32) Thumb {

        if (!self.overflowing() or track <= 0) return .{ .pos = 0, .len = track };

        const len = @max(@min(min_thumb, track), @divTrunc(track * self.viewport, self.content));
        const span = track - len;
        const max = self.max_offset();
        const pos = if (max <= 0) 0 else @divTrunc(span * self.clamped(), max);

        return .{ .pos = pos, .len = len };

    }

};

/// A vertical scrollbar filling `track` (a thin strip at a pane's right edge). Draws nothing when the content fits.
pub fn scrollbar(surface: *const Surface, track: Rect, scroll: Scroll) void {

    if (!scroll.overflowing() or track.h <= 0) return;

    surface.fill_rect(track, theme.surface_alt);

    const t = scroll.thumb(track.h);

    surface.fill_rect(.{ .x = track.x + 1, .y = track.y + t.pos, .w = @max(1, track.w - 2), .h = t.len }, theme.accent_dim);

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

        surface.fill_circle_smooth(cx, cy, radius, theme.surface);
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

fn gantt_color(pid: u32, tid: u32) Color {

    if (tid == 0) return theme.surface_alt;

    return switch (pid % 8) {

        0 => theme.accent,
        1 => theme.text,
        2 => theme.text_dim,
        3 => theme.good,
        4 => theme.warn,
        5 => theme.accent_dim,
        6 => theme.hover,
        else => theme.active,

    };

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

const testing = std.testing;

test "edit buffer inserts at the caret and edits both directions" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    for ("ac") |byte| _ = buffer.insert(byte);

    // Caret between 'a' and 'c', then insert 'b'.

    try testing.expect(buffer.left());
    try testing.expect(buffer.insert('b'));
    try testing.expectEqualStrings("abc", buffer.slice());
    try testing.expectEqual(@as(usize, 2), buffer.cursor);

    // Backspace removes the byte before the caret; delete removes the one at it.

    try testing.expect(buffer.backspace());
    try testing.expectEqualStrings("ac", buffer.slice());
    try testing.expect(buffer.delete());
    try testing.expectEqualStrings("a", buffer.slice());

}

test "edit buffer refuses to overflow its storage and clamps caret moves" {

    var storage: [3]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    try testing.expect(buffer.insert('x'));
    try testing.expect(buffer.insert('y'));
    try testing.expect(buffer.insert('z'));
    try testing.expect(!buffer.insert('!'));
    try testing.expectEqualStrings("xyz", buffer.slice());

    // Caret cannot walk past either end.

    try testing.expect(!buffer.right());
    try testing.expect(buffer.home());
    try testing.expect(!buffer.left());

}

test "edit buffer feed routes printable bytes and CSI arrows" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    try testing.expect(buffer.feed("h"));
    try testing.expect(buffer.feed("i"));

    // Left-arrow escape moves the caret; the next insert lands before 'i'.

    try testing.expect(buffer.feed(&[_]u8{ 0x1b, '[', 'D' }));
    try testing.expect(buffer.feed("!"));
    try testing.expectEqualStrings("h!i", buffer.slice());

    // Enter is not an edit, so feed reports no change.

    try testing.expect(!buffer.feed(&[_]u8{'\r'}));

}

test "scroll clamps its offset and hides when content fits" {

    const fits = Scroll{ .offset = 5, .content = 10, .viewport = 20 };

    try testing.expect(!fits.overflowing());
    try testing.expectEqual(@as(i32, 0), fits.max_offset());
    try testing.expectEqual(@as(i32, 0), fits.clamped());

    const over = Scroll{ .offset = 999, .content = 100, .viewport = 40 };

    try testing.expect(over.overflowing());
    try testing.expectEqual(@as(i32, 60), over.max_offset());
    try testing.expectEqual(@as(i32, 60), over.clamped());

}

test "scroll thumb spans the track proportionally" {

    // Half the content is visible, so the thumb is half the track; at max offset it sits flush against the bottom.

    const top = Scroll{ .offset = 0, .content = 200, .viewport = 100 };
    const top_thumb = top.thumb(100);

    try testing.expectEqual(@as(i32, 0), top_thumb.pos);
    try testing.expectEqual(@as(i32, 50), top_thumb.len);

    const bottom = Scroll{ .offset = 100, .content = 200, .viewport = 100 };
    const bottom_thumb = bottom.thumb(100);

    try testing.expectEqual(@as(i32, 50), bottom_thumb.pos);
    try testing.expectEqual(@as(i32, 100), bottom_thumb.pos + bottom_thumb.len);

}
