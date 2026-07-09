// Freeform widgets for canvas-style layouts (toolbars, tab strips, button grids, popup menus) that live outside Page's flex tree. Apps register hit rects while painting and query them on events, so layout math exists once.

const draw = @import("../draw/draw.zig");
const text_mod = @import("../draw/text.zig");
const vector = @import("../draw/vector.zig");

const ui = @import("ui.zig");

const Color = draw.Color;
const Face = text_mod.Face;
const Rect = draw.Rect;
const Surface = draw.Surface;

/// Freeform hover/hit tracking: rects registered during paint (topmost last), queried on pointer events.
pub const HitRegions = struct {

    pub const max_regions = 96;

    ids: [max_regions]u32 = undefined,
    rects: [max_regions]Rect = undefined,
    count: usize = 0,

    hover: u32 = 0,

    /// Drop all regions (hover state survives so the next paint can still highlight).
    pub fn reset(self: *HitRegions) void {

        self.count = 0;

    }

    pub fn add(self: *HitRegions, id: u32, rect: Rect) void {

        if (self.count >= max_regions or id == 0) return;

        self.ids[self.count] = id;
        self.rects[self.count] = rect;
        self.count += 1;

    }

    /// The topmost (latest-registered) id containing (x, y), or 0.
    pub fn hit(self: *const HitRegions, x: i32, y: i32) u32 {

        var index = self.count;

        while (index > 0) {

            index -= 1;

            if (self.rects[index].contains(x, y)) return self.ids[index];

        }

        return 0;

    }

    /// Track hover for (x, y); true when the hovered id changed (repaint).
    pub fn pointer_move(self: *HitRegions, x: i32, y: i32) bool {

        const now = self.hit(x, y);

        if (now == self.hover) return false;

        self.hover = now;

        return true;

    }

    /// Clear hover (pointer left the window); true when something was hovered (repaint).
    pub fn leave(self: *HitRegions) bool {

        if (self.hover == 0) return false;

        self.hover = 0;

        return true;

    }

    pub fn hovered(self: *const HitRegions, id: u32) bool {

        return self.hover != 0 and self.hover == id;

    }

    pub fn rect_of(self: *const HitRegions, id: u32) ?Rect {

        for (self.ids[0..self.count], 0..) |candidate, index| {

            if (candidate == id) return self.rects[index];

        }

        return null;

    }

};

// The one freeform button/chip idiom: rounded fill picked from the theme by state, centered label.

pub const ButtonState = struct {

    hovered: bool = false,
    selected: bool = false,

    /// Accent (accent_dim) fill when idle - primary actions, operator keys.
    accent: bool = false,

    /// Stroke a border (accent when selected, theme border otherwise).
    outlined: bool = false,

};

pub const ButtonStyle = struct {

    radius: i32 = 6,
    size: u32 = 14,
    color: ?Color = null,

    /// Idle fill override (defaults to surface_alt).
    idle: ?Color = null,

};

pub fn button(surface: *const Surface, font: *const Face, rect: Rect, label: []const u8, state: ButtonState, style: ButtonStyle) void {

    const fill = if (state.selected) ui.theme.active else if (state.hovered) ui.theme.hover else if (state.accent) ui.theme.accent_dim else style.idle orelse ui.theme.surface_alt;

    ui.fill_round_rect(surface, rect, style.radius, fill);

    if (state.outlined) {

        ui.stroke_round_rect(surface, rect, style.radius, 1, if (state.selected) ui.theme.accent else ui.theme.border);

    }

    label_in(surface, font, rect, label, style.size, style.color orelse ui.theme.text);

}

/// Center `label` in `rect` (the shared truncate-then-center used by every freeform widget).
pub fn label_in(surface: *const Surface, font: *const Face, rect: Rect, label: []const u8, size: u32, color: Color) void {

    const visible = ui.truncate(font, label, size, rect.w - 4);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

/// The equal-width top tab strip shared by Status and Timer: active pill, hover pill, and a bottom border
/// with a gap under the active tab. Feed pointer events through `pointer_move`/`leave` and repaint on true.
pub const TabStrip = struct {

    pub const Item = struct {

        label: []const u8,
        svg: []const u8 = "",

    };

    items: []const Item,
    height: i32 = 42,

    hover: i32 = -1,

    pub fn bar_rect(self: *const TabStrip, width: i32) Rect {

        return .{ .x = 0, .y = 0, .w = width, .h = self.height };

    }

    /// The tab index at (x, y), or null outside the strip.
    pub fn index_at(self: *const TabStrip, width: i32, x: i32, y: i32) ?usize {

        if (y < 0 or y >= self.height or x < 0 or x >= width or self.items.len == 0) return null;

        const each = @divTrunc(width, @as(i32, @intCast(self.items.len)));

        if (each <= 0) return null;

        return @intCast(@min(@divTrunc(x, each), @as(i32, @intCast(self.items.len - 1))));

    }

    /// Track hover; true when the highlight changed (repaint the strip).
    pub fn pointer_move(self: *TabStrip, width: i32, x: i32, y: i32) bool {

        const now: i32 = if (self.index_at(width, x, y)) |index| @intCast(index) else -1;

        if (now == self.hover) return false;

        self.hover = now;

        return true;

    }

    pub fn leave(self: *TabStrip) bool {

        if (self.hover == -1) return false;

        self.hover = -1;

        return true;

    }

    pub fn paint(self: *const TabStrip, surface: *const Surface, font: *const Face, width: i32, active: usize) void {

        if (self.items.len == 0) return;

        const each = @divTrunc(width, @as(i32, @intCast(self.items.len)));
        const active_x = @as(i32, @intCast(active)) * each;
        const border_y = self.height - 1;
        const active_pill_left = active_x + 10;
        const active_pill_right = active_x + each - 10;

        surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = self.height }, ui.theme.surface_alt);

        for (self.items, 0..) |item, index| {

            const x = @as(i32, @intCast(index)) * each;
            const is_active = active == index;
            const is_hovered = self.hover == @as(i32, @intCast(index));
            const pill = Rect{ .x = x + 10, .y = 6, .w = each - 20, .h = self.height - 12 };

            if (is_active) {

                ui.fill_round_rect(surface, pill, 6, ui.theme.active);

            } else if (is_hovered) {

                ui.fill_round_rect(surface, pill, 6, ui.theme.hover);

            }

            const tint = if (is_active) ui.theme.text else ui.theme.text_dim;

            if (item.svg.len > 0) {

                vector.icon_in(surface, .{ .x = x + 18, .y = 11, .w = 20, .h = 20 }, item.svg, tint);

                const text_rect = Rect{ .x = x + 44, .y = 0, .w = each - 48, .h = self.height };
                const visible = ui.truncate(font, item.label, 14, text_rect.w);
                const text_y = @divTrunc(self.height - font.line_height(14), 2);

                font.draw(surface, text_rect.x, text_y, 14, visible, tint);

            } else {

                label_in(surface, font, .{ .x = x, .y = 0, .w = each, .h = self.height }, item.label, 14, tint);

            }

        }

        if (active_pill_left > 0) {

            surface.fill_rect(.{ .x = 0, .y = border_y, .w = active_pill_left, .h = 1 }, ui.theme.border);

        }

        if (active_pill_right < width) {

            surface.fill_rect(.{ .x = active_pill_right, .y = border_y, .w = width - active_pill_right, .h = 1 }, ui.theme.border);

        }

    }

};

// Popup menu: action rows and separators at an anchor point, clamped to its bounds.

pub const menu_max_rows = 16;

pub const Menu = struct {

    pub const Row = union(enum) {

        item: []const u8,
        separator,

    };

    width: i32 = 190,
    row_height: i32 = 30,
    separator_height: i32 = 9,
    inset: i32 = 4,

    rows: []const Row = &.{},

    open: bool = false,
    x: i32 = 0,
    y: i32 = 0,

    hover: ?usize = null,

    /// Open at (x, y) clamped so the panel stays inside `bounds_w` x `bounds_h`.
    pub fn open_at(self: *Menu, rows: []const Row, x: i32, y: i32, bounds_w: i32, bounds_h: i32) void {

        self.rows = rows;
        self.x = x;
        self.y = y;
        self.hover = null;
        self.open = true;

        const height = self.content_height() + self.inset * 2;

        if (self.x + self.width > bounds_w) self.x = @max(0, bounds_w - self.width);
        if (self.y + height > bounds_h) self.y = @max(0, bounds_h - height);

    }

    pub fn close(self: *Menu) void {

        self.open = false;
        self.hover = null;

    }

    pub fn content_height(self: *const Menu) i32 {

        var height: i32 = 0;

        for (self.rows) |row| {

            height += switch (row) {

                .item => self.row_height,
                .separator => self.separator_height,

            };

        }

        return height;

    }

    pub fn bounds(self: *const Menu) Rect {

        return .{ .x = self.x, .y = self.y, .w = self.width, .h = self.content_height() + self.inset * 2 };

    }

    /// The action-row index at (x, y); separators and misses return null.
    pub fn hit(self: *const Menu, x: i32, y: i32) ?usize {

        if (!self.open) return null;
        if (x < self.x or x >= self.x + self.width) return null;

        var cursor_y = self.y + self.inset;

        if (y < cursor_y) return null;

        for (self.rows, 0..) |row, index| {

            const span = switch (row) {

                .item => self.row_height,
                .separator => self.separator_height,

            };

            if (y >= cursor_y and y < cursor_y + span) {

                return switch (row) {

                    .item => index,
                    .separator => null,

                };

            }

            cursor_y += span;

        }

        return null;

    }

    /// Track hover; true when the highlight changed (repaint).
    pub fn pointer_move(self: *Menu, x: i32, y: i32) bool {

        const now = self.hit(x, y);

        if (now) |a| {

            if (self.hover) |b| {

                if (a == b) return false;

            }

        } else if (self.hover == null) return false;

        self.hover = now;

        return true;

    }

    pub fn paint(self: *const Menu, surface: *const Surface, font: *const Face) void {

        if (!self.open) return;

        const panel = self.bounds();

        ui.fill_round_rect(surface, panel, 6, ui.theme.surface);
        ui.stroke_round_rect(surface, panel, 6, 1, ui.theme.border);

        var cursor_y = self.y + self.inset;

        for (self.rows, 0..) |row, index| {

            switch (row) {

                .item => |label| {

                    const rect = Rect{ .x = self.x + self.inset, .y = cursor_y, .w = self.width - 2 * self.inset, .h = self.row_height - 1 };
                    const is_hovered = self.hover != null and self.hover.? == index;

                    if (is_hovered) ui.fill_round_rect(surface, rect, 4, ui.theme.hover);

                    const visible = ui.truncate(font, label, 13, rect.w - 24);
                    const text_y = rect.y + @divTrunc(rect.h - font.line_height(13), 2);

                    font.draw(surface, rect.x + 12, text_y, 13, visible, ui.theme.text);

                    cursor_y += self.row_height;

                },

                .separator => {

                    const line_y = cursor_y + @divTrunc(self.separator_height, 2);

                    surface.fill_rect(.{

                        .x = self.x + self.inset + 8,
                        .y = line_y,
                        .w = self.width - 2 * self.inset - 16,
                        .h = 1,

                    }, ui.theme.border);

                    cursor_y += self.separator_height;

                },

            }

        }

    }

};

// Uniform button grid (calculator-style): fixed columns, gapped cells, optional multi-column spans.

pub const Grid = struct {

    rect: Rect,
    columns: i32,
    rows: i32,
    gap: i32 = 6,

    /// The cell rect at (col, row), spanning `span` columns.
    pub fn cell(self: *const Grid, col: i32, row: i32, span: i32) Rect {

        const cell_w = @divTrunc(self.rect.w - self.gap * (self.columns - 1), self.columns);
        const cell_h = @divTrunc(self.rect.h - self.gap * (self.rows - 1), self.rows);

        return .{

            .x = self.rect.x + col * (cell_w + self.gap),
            .y = self.rect.y + row * (cell_h + self.gap),

            .w = cell_w * span + self.gap * (span - 1),
            .h = cell_h,

        };

    }

};
