// The HTML-like UI toolkit (M10 GUI rewrite): apps rebuild a small node tree each frame - boxes with
// padding/gap/radius/background laid out as rows and columns, plus labels, icons, and text fields - then one
// layout pass sizes it (flexbox-lite: fixed, auto, and grow sizes) and one paint pass renders it through the
// analytic-AA renderer. Hit testing and hover tracking come with the tree, so an app's event handler is a
// switch on node ids. Rebuilding is cheap: the tree is a fixed pool, strings are borrowed, layout is integer.

const std = @import("std");

const draw = @import("../draw/draw.zig");
const path_mod = @import("../draw/path.zig");
const raster = @import("../draw/raster.zig");
const stroke = @import("../draw/stroke.zig");
const text_mod = @import("../draw/text.zig");
const vector = @import("../draw/vector.zig");

pub const chart = @import("chart.zig");

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

    // Interaction state persists across rebuilds, keyed by node id.
    hover_id: u32 = 0,

    pub fn begin(self: *Page, width: i32, height: i32, style: Style) void {

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

        self.paint_node(surface, root);

    }

    fn paint_node(self: *Page, surface: *const Surface, index: i16) void {

        const node = &self.nodes[@intCast(index)];
        const rect = node.rect;

        if (rect.intersect(surface.clip).is_empty() and node.kind != .box) return;

        const hovered = node.style.id != 0 and node.style.id == self.hover_id;
        const background = if (hovered and node.style.hover_background != null) node.style.hover_background else node.style.background;

        if (background) |color| {

            if (node.style.radius > 0) {

                var shape = path_mod.Path{};

                shape.add_round_rect(path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(node.style.radius));
                raster.fill(surface, &shape, color);

            } else {

                surface.fill_rect(rect, color);

            }

        }

        if (node.style.border) |color| {

            var shape = path_mod.Path{};

            stroke.round_rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(node.style.radius), path_mod.from_px(node.style.border_width));
            raster.fill(surface, &shape, color);

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

        const rect = node.rect;
        const size = node.style.size;
        const buffer = node.field orelse return;

        // Box: surface fill with accent border when focused (unless the style set its own).

        var shape = path_mod.Path{};
        const radius = if (node.style.radius > 0) node.style.radius else 6;

        if (node.style.background == null) {

            shape.add_round_rect(path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius));
            raster.fill(surface, &shape, theme.surface);

        }

        if (node.style.border == null) {

            shape.reset();
            stroke.round_rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius), path_mod.from_px(1));
            raster.fill(surface, &shape, if (node.field_focused) theme.accent else theme.border);

        }

        const pad: i32 = 8;
        const inner_x = rect.x + pad;
        const inner_w = rect.w - 2 * pad;

        if (inner_w <= 0) return;

        const clipped = surface.clipped(.{ .x = inner_x, .y = rect.y, .w = inner_w, .h = rect.h });
        const baseline = rect.y + @divTrunc(rect.h - self.font.line_height(size), 2);
        const content = buffer.slice();

        if (content.len == 0 and node.text.len > 0) {

            self.font.draw(&clipped, inner_x, baseline, size, truncate(self.font, node.text, size, inner_w), theme.text_faint);

        } else {

            const start = field_scroll_start(self.font, content, buffer.cursor, size, inner_w);

            self.font.draw(&clipped, inner_x, baseline, size, truncate(self.font, content[start..], size, inner_w), node.style.color orelse theme.text);

            if (node.field_focused and node.field_caret) {

                const before = content[start..@min(buffer.cursor, content.len)];
                const caret_x = @min(inner_x + self.font.text_width(before, size), inner_x + inner_w);
                const caret_h = @min(rect.h - 8, self.font.line_height(size));
                const caret_y = rect.y + @divTrunc(rect.h - caret_h, 2);

                surface.fill_rect(.{ .x = caret_x, .y = caret_y, .w = 1, .h = caret_h }, theme.text);

            }

        }

        if (content.len == 0 and node.field_focused and node.field_caret) {

            const caret_h = @min(rect.h - 8, self.font.line_height(size));

            surface.fill_rect(.{ .x = inner_x, .y = rect.y + @divTrunc(rect.h - caret_h, 2), .w = 1, .h = caret_h }, theme.text);

        }

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

/// The longest prefix of `s` whose width at `size` fits in `max_w`.
pub fn truncate(font: *const Face, s: []const u8, size: u32, max_w: i32) []const u8 {

    if (max_w <= 0) return s[0..0];
    if (font.text_width(s, size) <= max_w) return s;

    var length = s.len;

    while (length > 0 and font.text_width(s[0..length], size) > max_w) : (length -= 1) {}

    return s[0..length];

}

pub fn fill_round_rect(surface: *const Surface, rect: Rect, radius: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0) return;

    var shape = path_mod.Path{};

    shape.add_round_rect(path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius));
    raster.fill(surface, &shape, color);

}

pub fn stroke_round_rect(surface: *const Surface, rect: Rect, radius: i32, width: i32, color: Color) void {

    if (rect.w <= 0 or rect.h <= 0 or width <= 0) return;

    var shape = path_mod.Path{};

    stroke.round_rect_border(&shape, path_mod.from_px(rect.x), path_mod.from_px(rect.y), path_mod.from_px(rect.w), path_mod.from_px(rect.h), path_mod.from_px(radius), path_mod.from_px(width));
    raster.fill(surface, &shape, color);

}

fn field_scroll_start(font: *const Face, content: []const u8, cursor: usize, size: u32, width: i32) usize {

    if (width <= 0 or font.text_width(content, size) <= width) return 0;

    var start: usize = 0;

    while (start < cursor and font.text_width(content[start..cursor], size) > width) : (start += 1) {}

    return start;

}

// Text-editing model shared by every single-line field: a caret over caller-owned bytes.

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

    pub fn insert(self: *EditBuffer, byte: u8) bool {

        if (self.len >= self.bytes.len) return false;

        var index = self.len;

        while (index > self.cursor) : (index -= 1) self.bytes[index] = self.bytes[index - 1];

        self.bytes[self.cursor] = byte;
        self.len += 1;
        self.cursor += 1;

        return true;

    }

    pub fn backspace(self: *EditBuffer) bool {

        if (self.cursor == 0) return false;

        var index = self.cursor - 1;

        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];

        self.len -= 1;
        self.cursor -= 1;

        return true;

    }

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

    /// Apply one key's byte sequence straight from keymap.Keyboard.bytes; returns true when the buffer
    /// changed. Enter and other control bytes are left for the app to act on.
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

    var shape = path_mod.Path{};

    shape.add_round_rect(path_mod.from_px(track.x + 1), path_mod.from_px(track.y + t.pos), path_mod.from_px(@max(1, track.w - 2)), path_mod.from_px(t.len), path_mod.from_px(3));
    raster.fill(surface, &shape, theme.accent_dim);

}

const testing = std.testing;

test "edit buffer inserts at the caret and edits both directions" {

    var storage: [8]u8 = undefined;
    var buffer = EditBuffer.init(&storage);

    for ("ac") |byte| _ = buffer.insert(byte);

    try testing.expect(buffer.left());
    try testing.expect(buffer.insert('b'));
    try testing.expectEqualStrings("abc", buffer.slice());
    try testing.expectEqual(@as(usize, 2), buffer.cursor);

    try testing.expect(buffer.backspace());
    try testing.expectEqualStrings("ac", buffer.slice());
    try testing.expect(buffer.delete());
    try testing.expectEqualStrings("a", buffer.slice());

}

test "scroll clamps its offset and sizes the thumb" {

    const over = Scroll{ .offset = 999, .content = 100, .viewport = 40 };

    try testing.expect(over.overflowing());
    try testing.expectEqual(@as(i32, 60), over.max_offset());
    try testing.expectEqual(@as(i32, 60), over.clamped());

    const bottom = Scroll{ .offset = 100, .content = 200, .viewport = 100 };
    const bottom_thumb = bottom.thumb(100);

    try testing.expectEqual(@as(i32, 100), bottom_thumb.pos + bottom_thumb.len);

}
