// The HTML-like UI toolkit (M10 GUI rewrite)

const std = @import("std");

const draw = @import("../draw/draw.zig");
const text_mod = @import("../draw/text.zig");
const vector = @import("../draw/vector.zig");

pub const chart = @import("chart.zig");
pub const widgets = @import("widgets.zig");

// Freeform (non-flex-tree) widgets, re-exported so apps write `ui.TabStrip` like they write `ui.Page`.

pub const HitRegions = widgets.HitRegions;
pub const TabStrip = widgets.TabStrip;
pub const Menu = widgets.Menu;
pub const Grid = widgets.Grid;
pub const Slider = widgets.Slider;
pub const ButtonState = widgets.ButtonState;
pub const ButtonStyle = widgets.ButtonStyle;

const Color = draw.Color;
const Face = text_mod.Face;
const Rect = draw.Rect;
const Surface = draw.Surface;

// Theme: one process-global palette, applied by prefs. Field names are load-bearing (prefs writes them).

pub const Theme = struct {

    window_bg: Color = draw.rgb(30, 30, 30),
    surface: Color = draw.rgb(38, 38, 38),
    surface_alt: Color = draw.rgb(46, 46, 46),
    border: Color = draw.rgb(58, 58, 58),

    hover: Color = draw.rgb(52, 52, 52),
    active: Color = draw.rgb(70, 70, 70),

    accent: Color = draw.rgb(200, 200, 200),
    accent_dim: Color = draw.rgb(100, 100, 100),

    text: Color = draw.rgb(230, 230, 230),
    text_dim: Color = draw.rgb(160, 160, 160),
    text_faint: Color = draw.rgb(110, 110, 110),

    good: Color = draw.rgb(190, 190, 190),
    warn: Color = draw.rgb(140, 140, 140),

    wallpaper: Color = draw.rgb(22, 22, 22),

};

pub var theme = Theme{};

// Style model.

pub const Direction = enum {

    row,
    column,

};

pub const Size = union(enum) {

    /// Sized by content (boxes: children; labels: text extent).
    auto,

    /// Fixed pixels.
    px: i32,

    /// Share of the leftover main-axis space, by weight.
    grow: u16,

};

pub const MainAlign = enum {

    start,
    center,
    end,
    between,

};

pub const CrossAlign = enum {

    stretch,
    start,
    center,
    end,

};

pub const Edge = struct {

    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub fn all(value: i32) Edge {

        return .{ .top = value, .right = value, .bottom = value, .left = value };

    }

    pub fn symmetric(horizontal: i32, vertical: i32) Edge {

        return .{ .top = vertical, .right = horizontal, .bottom = vertical, .left = horizontal };

    }

    pub fn only(top: i32, right: i32, bottom: i32, left: i32) Edge {

        return .{ .top = top, .right = right, .bottom = bottom, .left = left };

    }

};

pub const Style = struct {

    id: u32 = 0,

    direction: Direction = .row,
    width: Size = .auto,
    height: Size = .auto,

    padding: Edge = .{},
    margin: Edge = .{},
    gap: i32 = 0,

    align_main: MainAlign = .start,
    align_cross: CrossAlign = .stretch,

    background: ?Color = null,
    hover_background: ?Color = null,

    border: ?Color = null,
    border_width: i32 = 1,

    radius: i32 = 0,

    // Text and icon.

    color: ?Color = null,
    size: u32 = 13,
    center_text: bool = false,

};

const Kind = enum {

    box,
    label,
    icon,
    field,
    canvas,

};

const none: i16 = -1;

const Node = struct {

    kind: Kind = .box,
    style: Style = .{},

    text: []const u8 = "",
    svg: []const u8 = "",
    field: ?*const EditBuffer = null,
    field_focused: bool = false,
    field_caret: bool = true,

    parent: i16 = none,
    first_child: i16 = none,
    next_sibling: i16 = none,
    last_child: i16 = none,

    // Computed by end(): margin box excluded, this is the border box.
    rect: Rect = Rect.empty,

    measured_w: i32 = 0,
    measured_h: i32 = 0,

};

pub const max_nodes = 512;

pub const Page = struct {

    font: *const Face,

    nodes: [max_nodes]Node = undefined,
    count: usize = 0,

    width: i32 = 0,
    height: i32 = 0,
    damage: Rect = Rect.empty,
    initialized: bool = false,

    // Interaction state persists across rebuilds, keyed by node id.
    hover_id: u32 = 0,

    pub fn begin(self: *Page, width: i32, height: i32, style: Style) void {

        if (!self.initialized or width != self.width or height != self.height) {

            self.damage = .{ .x = 0, .y = 0, .w = width, .h = height };
            self.initialized = true;

        }

        self.count = 1;
        self.width = width;
        self.height = height;

        self.nodes[0] = .{ .kind = .box, .style = style };

    }

    pub const root: i16 = 0;

    fn append(self: *Page, parent: i16, node: Node) i16 {

        if (self.count >= max_nodes) return root;

        const index: i16 = @intCast(self.count);

        self.nodes[self.count] = node;
        self.nodes[self.count].parent = parent;
        self.count += 1;

        const p = &self.nodes[@intCast(parent)];

        if (p.first_child == none) {

            p.first_child = index;

        } else {

            self.nodes[@intCast(p.last_child)].next_sibling = index;

        }

        p.last_child = index;

        return index;

    }

    pub fn box(self: *Page, parent: i16, style: Style) i16 {

        return self.append(parent, .{ .kind = .box, .style = style });

    }

    pub fn label(self: *Page, parent: i16, content: []const u8, style: Style) i16 {

        return self.append(parent, .{ .kind = .label, .style = style, .text = content });

    }

    pub fn icon(self: *Page, parent: i16, svg: []const u8, side: i32, style: Style) i16 {

        var styled = style;

        styled.width = .{ .px = side };
        styled.height = .{ .px = side };

        return self.append(parent, .{ .kind = .icon, .style = styled, .svg = svg });

    }

    /// A leaf the app paints itself after `paint` (query its rect with `rect_of`).
    pub fn canvas(self: *Page, parent: i16, style: Style) i16 {

        return self.append(parent, .{ .kind = .canvas, .style = style });

    }

    /// Single-line text input bound to a live edit buffer.
    pub fn field(self: *Page, parent: i16, buffer: *const EditBuffer, placeholder: []const u8, focused: bool, style: Style) i16 {

        return self.append(parent, .{

            .kind = .field,
            .style = style,

            .text = placeholder,
            .field = buffer,
            .field_focused = focused,

        });

    }

    /// A ready-made button: a hoverable box with centered text. Dispatch clicks on its id.
    pub fn button(self: *Page, parent: i16, id: u32, caption: []const u8, style_in: Style) i16 {

        var style = style_in;

        style.id = id;

        if (style.background == null) style.background = theme.surface_alt;
        if (style.hover_background == null) style.hover_background = theme.hover;
        if (style.radius == 0) style.radius = 6;

        style.center_text = true;

        const node = self.box(parent, style);

        _ = self.label(node, caption, .{

            .size = style.size,
            .color = style.color orelse theme.text,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .center_text = true,

        });

        return node;

    }

    /// Layout the tree into `width` x `height`.
    pub fn end(self: *Page) void {

        self.measure(root);

        self.nodes[0].rect = .{

            .x = self.nodes[0].style.margin.left,
            .y = self.nodes[0].style.margin.top,

            .w = self.resolve(self.nodes[0].style.width, self.width, self.nodes[0].measured_w) orelse self.width,
            .h = self.resolve(self.nodes[0].style.height, self.height, self.nodes[0].measured_h) orelse self.height,

        };

        self.place(root);

    }

    fn resolve(self: *Page, size: Size, available: i32, measured: i32) ?i32 {

        _ = self;

        return switch (size) {

            .auto => measured,
            .px => |value| value,
            .grow => @min(available, measured),

        };

    }

    // Bottom-up intrinsic sizes (border box, margins excluded).

    fn measure(self: *Page, index: i16) void {

        const node = &self.nodes[@intCast(index)];

        var child = node.first_child;

        while (child != none) : (child = self.nodes[@intCast(child)].next_sibling) {

            self.measure(child);

        }

        switch (node.kind) {

            .label => {

                node.measured_w = self.font.text_width(node.text, node.style.size);
                node.measured_h = self.font.line_height(node.style.size);

            },

            .icon => {

                node.measured_w = 0;
                node.measured_h = 0;

            },

            .field => {

                node.measured_w = 60;
                node.measured_h = self.font.line_height(node.style.size) + 12;

            },

            .canvas => {

                node.measured_w = 0;
                node.measured_h = 0;

            },

            .box => {

                var main: i32 = 0;
                var cross: i32 = 0;
                var visible: usize = 0;

                child = node.first_child;

                while (child != none) : (child = self.nodes[@intCast(child)].next_sibling) {

                    const c = &self.nodes[@intCast(child)];
                    const cw = (self.resolve(c.style.width, 0, c.measured_w) orelse 0) + c.style.margin.left + c.style.margin.right;
                    const ch = (self.resolve(c.style.height, 0, c.measured_h) orelse 0) + c.style.margin.top + c.style.margin.bottom;

                    if (node.style.direction == .row) {

                        main += cw;
                        cross = @max(cross, ch);

                    } else {

                        main += ch;
                        cross = @max(cross, cw);

                    }

                    visible += 1;

                }

                if (visible > 1) main += node.style.gap * @as(i32, @intCast(visible - 1));

                const pad_x = node.style.padding.left + node.style.padding.right;
                const pad_y = node.style.padding.top + node.style.padding.bottom;

                if (node.style.direction == .row) {

                    node.measured_w = main + pad_x;
                    node.measured_h = cross + pad_y;

                } else {

                    node.measured_w = cross + pad_x;
                    node.measured_h = main + pad_y;

                }

            },

        }

        switch (node.style.width) {

            .px => |value| node.measured_w = value,

            else => {},

        }

        switch (node.style.height) {

            .px => |value| node.measured_h = value,

            else => {},

        }

    }

    // Top-down placement within each node's computed rect.

    fn place(self: *Page, index: i16) void {

        const node = &self.nodes[@intCast(index)];

        if (node.first_child == none) return;

        const content = Rect{

            .x = node.rect.x + node.style.padding.left,
            .y = node.rect.y + node.style.padding.top,

            .w = node.rect.w - node.style.padding.left - node.style.padding.right,
            .h = node.rect.h - node.style.padding.top - node.style.padding.bottom,

        };

        const is_row = node.style.direction == .row;
        const main_extent = if (is_row) content.w else content.h;

        // First pass: fixed and auto sizes, grow weights.

        var used: i32 = 0;
        var weights: i32 = 0;
        var child_count: i32 = 0;

        var child = node.first_child;

        while (child != none) : (child = self.nodes[@intCast(child)].next_sibling) {

            const c = &self.nodes[@intCast(child)];
            const size = if (is_row) c.style.width else c.style.height;
            const margin_main = if (is_row) c.style.margin.left + c.style.margin.right else c.style.margin.top + c.style.margin.bottom;

            switch (size) {

                .grow => |weight| weights += @max(1, weight),

                else => used += (self.resolve(size, main_extent, if (is_row) c.measured_w else c.measured_h) orelse 0),

            }

            used += margin_main;
            child_count += 1;

        }

        if (child_count > 1) used += node.style.gap * (child_count - 1);

        const leftover = @max(0, main_extent - used);

        // Main-axis start position by alignment (grow children consume all leftover).

        var cursor: i32 = if (is_row) content.x else content.y;
        var between_extra: i32 = 0;

        if (weights == 0) {

            switch (node.style.align_main) {

                .start => {},
                .center => cursor += @divTrunc(leftover, 2),
                .end => cursor += leftover,

                .between => {

                    if (child_count > 1) between_extra = @divTrunc(leftover, child_count - 1);

                },

            }

        }

        var distributed: i32 = 0;

        child = node.first_child;

        while (child != none) : (child = self.nodes[@intCast(child)].next_sibling) {

            const c = &self.nodes[@intCast(child)];

            const main_size = if (is_row) c.style.width else c.style.height;
            const cross_size = if (is_row) c.style.height else c.style.width;
            const cross_extent = if (is_row) content.h else content.w;

            const margin_cross_lead = if (is_row) c.style.margin.top else c.style.margin.left;
            const margin_cross_total = if (is_row) c.style.margin.top + c.style.margin.bottom else c.style.margin.left + c.style.margin.right;

            var main: i32 = undefined;

            switch (main_size) {

                .grow => |weight| {

                    const w: i32 = @max(1, weight);
                    const share = @divTrunc(leftover * (distributed + w), weights) - @divTrunc(leftover * distributed, weights);

                    distributed += w;
                    main = share;

                },

                else => main = self.resolve(main_size, main_extent, if (is_row) c.measured_w else c.measured_h) orelse 0,

            }

            var cross: i32 = undefined;

            switch (cross_size) {

                .auto => cross = switch (node.style.align_cross) {

                    .stretch => cross_extent - margin_cross_total,

                    else => if (is_row) c.measured_h else c.measured_w,

                },

                .px => |value| cross = value,
                .grow => cross = cross_extent - margin_cross_total,

            }

            var cross_offset: i32 = margin_cross_lead;

            switch (node.style.align_cross) {

                .stretch, .start => {},
                .center => cross_offset += @divTrunc(cross_extent - margin_cross_total - cross, 2),
                .end => cross_offset += cross_extent - margin_cross_total - cross,

            }

            if (is_row) {

                cursor += c.style.margin.left;

                c.rect = .{ .x = cursor, .y = content.y + cross_offset, .w = main, .h = cross };

                cursor += main + c.style.margin.right;

            } else {

                cursor += c.style.margin.top;

                c.rect = .{ .x = content.x + cross_offset, .y = cursor, .w = cross, .h = main };

                cursor += main + c.style.margin.bottom;

            }

            cursor += node.style.gap + between_extra;

            self.place(child);

        }

    }

    pub fn paint(self: *Page, surface: *const Surface) void {

        const dirty = self.damage.intersect(surface.bounds());

        if (dirty.is_empty()) return;

        const clipped = surface.clipped(dirty);

        self.paint_node(&clipped, root);

    }

    pub fn mark_dirty(self: *Page, rect: Rect) void {

        self.damage = self.damage.cover(rect.intersect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }));

    }

    pub fn mark_all_dirty(self: *Page) void {

        self.damage = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };

    }

    pub fn present_dirty(self: *Page, window: anytype) !void {

        const dirty = self.damage.intersect(window.surface.bounds());

        if (dirty.is_empty()) return;

        self.paint(&window.surface);
        try window.present(dirty);

        self.damage = Rect.empty;

    }

    fn paint_node(self: *Page, surface: *const Surface, index: i16) void {

        const node = &self.nodes[@intCast(index)];
        const rect = node.rect;

        if (rect.intersect(surface.clip).is_empty() and node.kind != .box) return;

        const hovered = node.style.id != 0 and node.style.id == self.hover_id;
        const background = if (hovered and node.style.hover_background != null) node.style.hover_background else node.style.background;

        if (background) |color| {

            if (node.style.radius > 0) {

                fill_round_rect(surface, rect, node.style.radius, color);

            } else {

                surface.fill_rect(rect, color);

            }

        }

        if (node.style.border) |color| {

            draw.round.stroke_round_rect(surface, rect, node.style.radius, node.style.border_width, color);

        }

        switch (node.kind) {

            .label => self.paint_label(surface, node),
            .icon => vector.icon_in(surface, rect, node.svg, node.style.color orelse theme.text),
            .field => self.paint_field(surface, node),

            else => {},

        }

        var child = node.first_child;

        while (child != none) : (child = self.nodes[@intCast(child)].next_sibling) {

            self.paint_node(surface, child);

        }

    }

    fn paint_label(self: *Page, surface: *const Surface, node: *const Node) void {

        const rect = node.rect;
        const inner = Rect{

            .x = rect.x + node.style.padding.left,
            .y = rect.y + node.style.padding.top,
            .w = rect.w - node.style.padding.left - node.style.padding.right,
            .h = rect.h - node.style.padding.top - node.style.padding.bottom,

        };
        const color = node.style.color orelse theme.text;
        const size = node.style.size;

        const clipped = surface.clipped(inner);
        const visible = truncate(self.font, node.text, size, inner.w);

        var x = inner.x;

        if (node.style.center_text) {

            x = inner.x + @divTrunc(inner.w - self.font.text_width(visible, size), 2);

        }

        const y = inner.y + @divTrunc(inner.h - self.font.line_height(size), 2);

        self.font.draw(&clipped, x, y, size, visible, color);

    }

    fn paint_field(self: *Page, surface: *const Surface, node: *const Node) void {

        const buffer = node.field orelse return;

        paint_text_field(surface, self.font, node.rect, buffer, node.text, node.field_focused, node.field_focused and node.field_caret, node.style.size);

    }

    /// The id of the topmost identified node at (x, y), or 0.
    pub fn hit(self: *Page, x: i32, y: i32) u32 {

        var best: u32 = 0;

        for (self.nodes[0..self.count]) |*node| {

            if (node.style.id == 0) continue;
            if (node.rect.contains(x, y)) best = node.style.id;

        }

        return best;

    }

    /// Track hover for (x, y); returns true when the hovered id changed (repaint).
    pub fn pointer_move(self: *Page, x: i32, y: i32) bool {

        const now = self.hit(x, y);

        if (now == self.hover_id) return false;

        if (self.rect_of(self.hover_id)) |rect| self.mark_dirty(rect);
        if (self.rect_of(now)) |rect| self.mark_dirty(rect);

        self.hover_id = now;

        return true;

    }

    /// The layout rect of the first node carrying `id` (canvas painting, popup anchoring).
    pub fn rect_of(self: *Page, id: u32) ?Rect {

        for (self.nodes[0..self.count]) |*node| {

            if (node.style.id == id) return node.rect;

        }

        return null;

    }

};

test "page damage accumulates and clips to bounds" {

    var page: Page = undefined;

    page.width = 100;
    page.height = 80;
    page.damage = Rect.empty;

    page.mark_dirty(.{ .x = 10, .y = 12, .w = 8, .h = 6 });
    page.mark_dirty(.{ .x = 30, .y = 20, .w = 100, .h = 100 });

    try std.testing.expectEqual(Rect{ .x = 10, .y = 12, .w = 90, .h = 68 }, page.damage);

}

/// The longest prefix of `s` whose width at `size` fits in `max_w`.
pub fn truncate(font: *const Face, s: []const u8, size: u32, max_w: i32) []const u8 {

    if (max_w <= 0) return s[0..0];
    if (font.text_width(s, size) <= max_w) return s;

    var length = s.len;

    while (length > 0 and font.text_width(s[0..length], size) > max_w) : (length -= 1) {}

    return s[0..length];

}

pub fn fill_round_rect(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    draw.round.fill_round_rect(surface, rect, radius, color);

}

pub fn stroke_round_rect(surface: *const Surface, rect: Rect, radius: i32, width: i32, color: Color) void {

    draw.round.stroke_round_rect(surface, rect, radius, width, color);

}

fn field_scroll_start(font: *const Face, content: []const u8, cursor: usize, size: u32, width: i32) usize {

    if (width <= 0 or font.text_width(content, size) <= width) return 0;

    var start: usize = 0;

    while (start < cursor and font.text_width(content[start..cursor], size) > width) : (start += 1) {}

    return start;

}

/// Maps a click at `rel_x` pixels from `start`
fn field_index_at(font: *const Face, content: []const u8, size: u32, start: usize, rel_x: i32) usize {

    if (rel_x <= 0) return start;

    var index = start;
    var prev_w: i32 = 0;

    while (index < content.len) : (index += 1) {

        const w = font.text_width(content[start .. index + 1], size);

        if (w > rel_x) {

            const char_w = w - prev_w;
            const mid = prev_w + @divTrunc(char_w, 2);

            return if (rel_x < mid) index else index + 1;

        }

        prev_w = w;

    }

    return content.len;

}

/// Maps a click at `rel_x` pixels from the left edge of a field's inner content area to a byte index in `content`
pub fn field_click_index(font: *const Face, content: []const u8, size: u32, cursor: usize, width: i32, rel_x: i32) usize {

    const start = field_scroll_start(font, content, cursor, size, width);

    return field_index_at(font, content, size, start, rel_x);

}

pub const field_pad: i32 = 8;

/// Rounded background + border for a field-shaped surface
pub fn paint_field_chrome(surface: *const Surface, rect: Rect, focused: bool) void {

    const radius: i32 = 5;

    fill_round_rect(surface, rect, radius, theme.surface);
    stroke_round_rect(surface, rect, radius, if (focused) 2 else 1, if (focused) theme.accent_dim else theme.border);

}

/// Draws the scrolled text, selection highlight, and caret for a field into `inner`
pub fn paint_field_content(surface: *const Surface, font: *const Face, inner: Rect, buffer: *const EditBuffer, placeholder: []const u8, show_caret: bool, size: u32) void {

    if (inner.w <= 0) return;

    const clipped = surface.clipped(inner);
    const baseline = inner.y + @divTrunc(inner.h - font.line_height(size), 2);
    const content = buffer.slice();

    if (content.len == 0) {

        if (placeholder.len > 0) font.draw(&clipped, inner.x, baseline, size, truncate(font, placeholder, size, inner.w), theme.text_faint);
        if (show_caret) paint_field_caret(surface, inner.x, inner, size, font);

        return;

    }

    const start = field_scroll_start(font, content, buffer.cursor, size, inner.w);
    const visible = truncate(font, content[start..], size, inner.w);

    if (buffer.selection_range()) |range| {

        const sel_start = @max(range.start, start);
        const sel_end = @min(range.end, start + visible.len);

        if (sel_end > sel_start) {

            const x0 = inner.x + font.text_width(content[start..sel_start], size);
            const x1 = inner.x + font.text_width(content[start..sel_end], size);

            surface.fill_rect(.{ .x = x0, .y = inner.y + 3, .w = @max(1, x1 - x0), .h = @max(1, inner.h - 6) }, theme.accent_dim);

        }

    }

    font.draw(&clipped, inner.x, baseline, size, visible, theme.text);

    if (show_caret) {

        const before = content[start..@min(buffer.cursor, content.len)];
        const caret_x = @min(inner.x + font.text_width(before, size), inner.x + inner.w);

        paint_field_caret(surface, caret_x, inner, size, font);

    }

}

fn paint_field_caret(surface: *const Surface, x: i32, inner: Rect, size: u32, font: *const Face) void {

    const caret_h = @min(inner.h - 8, font.line_height(size));
    const caret_y = inner.y + @divTrunc(inner.h - caret_h, 2);

    surface.fill_rect(.{ .x = x, .y = caret_y, .w = 1, .h = caret_h }, theme.text);

}

/// Paints a complete single-line text field: chrome plus content, inset by the standard `field_pad`.
pub fn paint_text_field(surface: *const Surface, font: *const Face, rect: Rect, buffer: *const EditBuffer, placeholder: []const u8, focused: bool, show_caret: bool, size: u32) void {

    paint_field_chrome(surface, rect, focused);

    const inner = Rect{ .x = rect.x + field_pad, .y = rect.y, .w = rect.w - 2 * field_pad, .h = rect.h };

    paint_field_content(surface, font, inner, buffer, placeholder, show_caret, size);

}

// Text-editing model shared by every single-line field

pub const EditBuffer = struct {

    bytes: []u8,
    len: usize = 0,
    cursor: usize = 0,
    anchor: ?usize = null,

    pub fn init(storage: []u8) EditBuffer {

        return .{ .bytes = storage };

    }

    pub fn slice(self: *const EditBuffer) []const u8 {

        return self.bytes[0..self.len];

    }

    pub fn clear(self: *EditBuffer) void {

        self.len = 0;
        self.cursor = 0;
        self.anchor = null;

    }

    /// The current selection as a normalized (start <= end) byte range, or null when there is none.
    pub fn selection_range(self: *const EditBuffer) ?struct { start: usize, end: usize } {

        const anchor = self.anchor orelse return null;

        if (anchor == self.cursor) return null;

        return .{ .start = @min(anchor, self.cursor), .end = @max(anchor, self.cursor) };

    }

    pub fn clear_selection(self: *EditBuffer) void {

        self.anchor = null;

    }

    /// Removes the selected range, if any, and collapses the cursor to its start. Returns whether it did.
    pub fn delete_selection(self: *EditBuffer) bool {

        const range = self.selection_range() orelse return false;
        const tail_len = self.len - range.end;

        std.mem.copyForwards(u8, self.bytes[range.start..][0..tail_len], self.bytes[range.end..self.len]);

        self.len -= range.end - range.start;
        self.cursor = range.start;
        self.anchor = null;

        return true;

    }

    /// Move the cursor to `index` (clamped to content length).
    pub fn set_cursor(self: *EditBuffer, index: usize, extend: bool) bool {

        const clamped = @min(index, self.len);
        const had_selection = self.anchor != null;

        if (extend) {

            if (self.anchor == null) self.anchor = self.cursor;

        } else if (had_selection) {

            self.anchor = null;

        }

        if (clamped == self.cursor) return had_selection != (self.anchor != null);

        self.cursor = clamped;

        return true;

    }

    /// Select everything.
    pub fn select_all(self: *EditBuffer) bool {

        if (self.len == 0) return false;

        self.anchor = 0;
        self.cursor = self.len;

        return true;

    }

    pub fn insert(self: *EditBuffer, byte: u8) bool {

        _ = self.delete_selection();

        if (self.len >= self.bytes.len) return false;

        var index = self.len;

        while (index > self.cursor) : (index -= 1) self.bytes[index] = self.bytes[index - 1];

        self.bytes[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;

        return true;

    }

    pub fn backspace(self: *EditBuffer) bool {

        if (self.delete_selection()) return true;
        if (self.cursor == 0) return false;

        var index = self.cursor - 1;

        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];

        self.len -= 1;
        self.cursor -= 1;

        return true;

    }

    pub fn delete(self: *EditBuffer) bool {

        if (self.delete_selection()) return true;
        if (self.cursor >= self.len) return false;

        var index = self.cursor;

        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];

        self.len -= 1;

        return true;

    }

    /// Moves left
    pub fn left(self: *EditBuffer, extend: bool) bool {

        if (!extend) if (self.selection_range()) |range| return self.set_cursor(range.start, false);
        if (self.cursor == 0) return self.set_cursor(self.cursor, extend);

        return self.set_cursor(self.cursor - 1, extend);

    }

    pub fn right(self: *EditBuffer, extend: bool) bool {

        if (!extend) if (self.selection_range()) |range| return self.set_cursor(range.end, false);
        if (self.cursor >= self.len) return self.set_cursor(self.cursor, extend);

        return self.set_cursor(self.cursor + 1, extend);

    }

    pub fn home(self: *EditBuffer, extend: bool) bool {

        return self.set_cursor(0, extend);

    }

    pub fn end(self: *EditBuffer, extend: bool) bool {

        return self.set_cursor(self.len, extend);

    }

    /// Applies one key's byte sequence straight from keymap.Keyboard.bytes
    pub fn feed(self: *EditBuffer, input: []const u8, extend: bool) bool {

        if (input.len == 3 and input[0] == 0x1b and input[1] == '[') {

            return switch (input[2]) {

                'C' => self.right(extend),
                'D' => self.left(extend),
                'H' => self.home(extend),
                'F' => self.end(extend),

                else => false,

            };

        }

        if (input.len == 1) {

            const byte = input[0];

            if (byte == 0x7f or byte == 0x08) return self.backspace();
            if (byte == 0x01) return self.select_all(); // Ctrl+A - keymap folds letters to 0x01-0x1a under Ctrl
            if (byte >= 0x20 and byte < 0x7f) return self.insert(byte);

        }

        return false;

    }

};

// Scroll model: unit-agnostic offset/content/viewport with a proportional thumb.

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

    pub fn clamped(self: Scroll) i32 {

        return @max(0, @min(self.offset, self.max_offset()));

    }

    pub fn wheel(self: Scroll, delta: i64, step: i32) i32 {

        const direction: i32 = if (delta < 0) 1 else if (delta > 0) -1 else 0;

        return std.math.clamp(self.clamped() + direction * @max(0, step), 0, self.max_offset());

    }

    pub fn offset_at(self: Scroll, track: i32, pointer: i32) i32 {

        if (!self.overflowing() or track <= 0) return 0;

        const current_thumb = self.thumb(track);
        const span = track - current_thumb.len;

        if (span <= 0) return 0;

        const position = std.math.clamp(pointer - @divTrunc(current_thumb.len, 2), 0, span);

        return @intCast(@divTrunc(@as(i64, position) * @as(i64, self.max_offset()), @as(i64, span)));

    }

    const Thumb = struct {

        pos: i32,
        len: i32,

    };

    pub fn thumb(self: Scroll, track: i32) Thumb {

        if (!self.overflowing() or track <= 0) return .{ .pos = 0, .len = track };

        const len = @max(@min(min_thumb, track), @divTrunc(track * self.viewport, self.content));
        const span = track - len;
        const max = self.max_offset();
        const pos = if (max <= 0) 0 else @divTrunc(span * self.clamped(), max);

        return .{ .pos = pos, .len = len };

    }

};

/// A vertical scrollbar in `track`; draws nothing when the content fits.
pub fn scrollbar(surface: *const Surface, track: Rect, scroll: Scroll) void {

    if (!scroll.overflowing() or track.h <= 0) return;

    surface.fill_rect(track, theme.surface_alt);

    const t = scroll.thumb(track.h);
    const thumb_rect = Rect{ .x = track.x + 1, .y = track.y + t.pos, .w = @max(1, track.w - 2), .h = t.len };

    draw.round.fill_round_rect(surface, thumb_rect, 3, theme.accent_dim);

}

const testing = std.testing;

test "edit buffer inserts at the caret and edits both directions" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    for ("ac") |byte| _ = buffer.insert(byte);

    try testing.expect(buffer.left(false));
    try testing.expect(buffer.insert('b'));
    try testing.expectEqualStrings("abc", buffer.slice());
    try testing.expectEqual(@as(usize, 2), buffer.cursor);

    try testing.expect(buffer.backspace());
    try testing.expectEqualStrings("ac", buffer.slice());
    try testing.expect(buffer.delete());
    try testing.expectEqualStrings("a", buffer.slice());

}

test "shift+arrow grows a selection that plain arrows collapse" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    for ("abcde") |byte| _ = buffer.insert(byte);

    // Cursor is after 'e' (index 5); shift+Left twice selects "de".
    try testing.expect(buffer.left(true));
    try testing.expect(buffer.left(true));
    try testing.expectEqual(@as(?usize, 3), buffer.selection_range().?.start);
    try testing.expectEqual(@as(usize, 5), buffer.selection_range().?.end);

    // A plain arrow collapses to the near edge instead of moving one further.
    try testing.expect(buffer.left(false));
    try testing.expectEqual(@as(usize, 3), buffer.cursor);
    try testing.expect(buffer.selection_range() == null);

}

test "typing and backspace replace the active selection" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    for ("abcde") |byte| _ = buffer.insert(byte);

    _ = buffer.set_cursor(1, false);
    _ = buffer.set_cursor(4, true); // selects "bcd"

    try testing.expect(buffer.insert('X'));
    try testing.expectEqualStrings("aXe", buffer.slice());
    try testing.expectEqual(@as(usize, 2), buffer.cursor);
    try testing.expect(buffer.selection_range() == null);

    _ = buffer.set_cursor(0, false);
    _ = buffer.set_cursor(2, true); // selects "aX"

    try testing.expect(buffer.backspace());
    try testing.expectEqualStrings("e", buffer.slice());

}

test "scroll clamps its offset and sizes the thumb" {

    const over = Scroll{ .offset = 999, .content = 100, .viewport = 40 };

    try testing.expect(over.overflowing());
    try testing.expectEqual(@as(i32, 60), over.max_offset());
    try testing.expectEqual(@as(i32, 60), over.clamped());

    const bottom = Scroll{ .offset = 100, .content = 200, .viewport = 100 };
    const bottom_thumb = bottom.thumb(100);

    try testing.expectEqual(@as(i32, 100), bottom_thumb.pos + bottom_thumb.len);
    try testing.expectEqual(@as(i32, 60), over.wheel(-1, 10));
    try testing.expectEqual(@as(i32, 50), (Scroll{ .offset = 60, .content = 100, .viewport = 40 }).wheel(1, 10));
    try testing.expectEqual(@as(i32, 60), over.offset_at(100, 100));

}
