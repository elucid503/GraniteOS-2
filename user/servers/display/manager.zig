// Window management policy (07-userspace-ddd.md Section 12.3), kept pure so it host-tests without a display:
// the window table, stacking order, focus, hit testing, drag arithmetic, and screen-resize clamping. The
// compositor in main.zig owns everything with a side effect (surfaces, rendering, IPC).

const std = @import("std");

const lib = @import("lib");

const gfx = lib.gfx;
const proto = lib.proto;

const Rect = gfx.Rect;

pub const max_windows = proto.window.max_windows;

pub const title_height: i32 = 28;
pub const chrome_size: i32 = 14;
pub const chrome_margin: i32 = 8;
pub const chrome_gap: i32 = 12;
pub const chrome_buttons: i32 = 3;
pub const title_padding: i32 = 10;

// The square, in the frame's bottom-right corner, that grabs an interactive resize.
pub const resize_grip: i32 = 18;

pub const min_content: u32 = 32;
pub const default_panel_height: i32 = 40;

pub const StackKind = enum {

    desktop,
    ordinary,
    panel,

};

pub const Window = struct {

    used: bool = false,

    id: u32 = 0,
    owner: u64 = 0,

    // Frame origin (the decoration's top-left corner) in screen coordinates.
    x: i32 = 0,
    y: i32 = 0,

    // Content size in pixels.
    width: u32 = 0,
    height: u32 = 0,

    flags: u64 = 0,

    title: [proto.window.max_title]u8 = [_]u8{0} ** proto.window.max_title,
    title_length: usize = 0,

    // Geometry to restore after un-maximize (content size + frame origin).
    restore_x: i32 = 0,
    restore_y: i32 = 0,
    restore_width: u32 = 0,
    restore_height: u32 = 0,

    pub fn decorated(self: *const Window) bool {

        return self.flags & (proto.window.flag_undecorated | proto.window.flag_fullscreen | proto.window.flag_panel | proto.window.flag_desktop) == 0;

    }

    pub fn is_maximized(self: *const Window) bool {

        return self.flags & proto.window.flag_maximized != 0;

    }

    pub fn is_taskbar_listed(self: *const Window) bool {

        if (!self.used) return false;
        if (self.is_panel() or self.is_desktop()) return false;
        if (self.flags & proto.window.flag_undecorated != 0) return false;
        if (self.flags & proto.window.flag_fullscreen != 0) return false;

        return true;

    }

    pub fn is_panel(self: *const Window) bool {

        return self.flags & proto.window.flag_panel != 0;

    }

    pub fn is_desktop(self: *const Window) bool {

        return self.flags & proto.window.flag_desktop != 0;

    }

    pub fn stack_kind(self: *const Window) StackKind {

        if (self.is_panel()) return .panel;
        if (self.is_desktop()) return .desktop;

        return .ordinary;

    }

    /// The full on-screen footprint, decorations included.
    pub fn frame(self: *const Window) Rect {

        if (!self.decorated()) {

            return .{ .x = self.x, .y = self.y, .w = @intCast(self.width), .h = @intCast(self.height) };

        }

        return .{

            .x = self.x,
            .y = self.y,

            .w = @intCast(self.width),
            .h = title_height + @as(i32, @intCast(self.height)),

        };

    }

    /// Where the client's surface lands on screen.
    pub fn content(self: *const Window) Rect {

        if (!self.decorated()) {

            return .{ .x = self.x, .y = self.y, .w = @intCast(self.width), .h = @intCast(self.height) };

        }

        return .{

            .x = self.x,
            .y = self.y + title_height,

            .w = @intCast(self.width),
            .h = @intCast(self.height),

        };

    }

    pub fn title_bar(self: *const Window) Rect {

        return .{

            .x = self.x,
            .y = self.y,

            .w = @intCast(self.width),
            .h = title_height,

        };

    }

    pub fn chrome_reserved_width() i32 {

        return chrome_buttons * chrome_size + (chrome_buttons - 1) * chrome_gap + chrome_margin * 2;

    }

    fn chrome_button(self: *const Window, index_from_right: i32) Rect {

        const bar = self.title_bar();
        const inset = @divTrunc(title_height - chrome_size, 2);
        const offset = chrome_margin + index_from_right * (chrome_size + chrome_gap);

        return .{

            .x = bar.x + bar.w - offset - chrome_size,
            .y = bar.y + inset,

            .w = chrome_size,
            .h = chrome_size,

        };

    }

    pub fn close_button(self: *const Window) Rect {

        return self.chrome_button(0);

    }

    pub fn maximize_button(self: *const Window) Rect {

        return self.chrome_button(1);

    }

    pub fn minimize_button(self: *const Window) Rect {

        return self.chrome_button(2);

    }

    /// The bottom-right resize grip, in screen coordinates. Only decorated, non-maximized windows carry one.
    pub fn resize_grip_rect(self: *const Window) Rect {

        if (self.is_maximized()) return Rect.empty;

        const f = self.frame();
        const grip = @min(resize_grip, @min(f.w, f.h - title_height));

        return .{

            .x = f.x + f.w - grip,
            .y = f.y + f.h - grip,

            .w = grip,
            .h = grip,

        };

    }

    pub fn set_title(self: *Window, text: []const u8) void {

        const length = @min(text.len, self.title.len);

        self.title = [_]u8{0} ** proto.window.max_title;
        @memcpy(self.title[0..length], text[0..length]);
        self.title_length = length;

    }

};

pub const Region = enum {

    title,
    close,
    maximize,
    minimize,
    resize,
    content,

};

pub const Hit = struct {

    id: u32,
    region: Region,

};

pub const Manager = struct {

    windows: [max_windows]Window = [_]Window{.{}} ** max_windows,

    // Stacking order, bottom to top, as indices into `windows`.
    order: [max_windows]usize = [_]usize{0} ** max_windows,
    count: usize = 0,

    next_id: u32 = 1,
    focus: u32 = 0,

    screen_width: u32 = 0,
    screen_height: u32 = 0,

    // Cascade placement for new windows.
    placed: u32 = 0,

    pub fn create(self: *Manager, owner: u64, width: u32, height: u32, flags: u64, title: []const u8) ?*Window {

        if (self.count >= max_windows) return null;

        const slot = self.free_slot() orelse return null;
        const window = &self.windows[slot];

        const id = self.next_id;
        self.next_id += 1;

        window.* = .{

            .used = true,

            .id = id,
            .owner = owner,

            .flags = flags,

        };

        if (flags & proto.window.flag_fullscreen != 0) {

            window.width = self.screen_width;
            window.height = self.screen_height;

        } else if (flags & proto.window.flag_panel != 0) {

            window.width = self.screen_width;
            window.height = self.clamp_content_height(height);

        } else if (flags & proto.window.flag_desktop != 0) {

            window.x = 0;
            window.y = 0;
            window.width = self.screen_width;
            window.height = self.screen_height;

        } else {

            window.width = self.clamp_content_width(width);
            window.height = self.clamp_content_height(height);

            const step: i32 = @intCast(32 * (self.placed % 8) + 48);

            window.x = step;
            window.y = step;
            self.placed += 1;

        }

        window.set_title(title);
        self.clamp(window);

        self.insert(slot, window.stack_kind());
        self.focus = id;

        return window;

    }

    pub fn resize_window(self: *Manager, window: *Window, width: u32, height: u32) Rect {

        const before = window.frame();

        if (window.flags & proto.window.flag_fullscreen != 0) {

            window.x = 0;
            window.y = 0;

            window.width = self.screen_width;
            window.height = self.screen_height;

        } else if (window.is_panel()) {

            window.width = self.screen_width;
            window.height = self.clamp_content_height(height);

            self.clamp(window);

        } else {

            // Do not clear flag_maximized here: clients reallocate their surface via resize after
            // maximize/unmaximize, and clearing the flag would strand the window full-size.

            window.width = self.clamp_content_width(width);
            window.height = self.clamp_content_height(height);

            self.clamp(window);

        }

        return before.cover(window.frame());

    }

    // Panels stay above ordinary windows; desktop layers stay beneath them. Ordinary windows live in the middle.

    fn insert(self: *Manager, slot: usize, kind: StackKind) void {

        const position = switch (kind) {

            .panel => self.count,
            .desktop => self.leading_desktops(),
            .ordinary => self.count - self.trailing_panels(),

        };

        var index = self.count;

        while (index > position) : (index -= 1) {

            self.order[index] = self.order[index - 1];

        }

        self.order[position] = slot;
        self.count += 1;

    }

    fn leading_desktops(self: *Manager) usize {

        var found: usize = 0;

        while (found < self.count and self.windows[self.order[found]].is_desktop()) {

            found += 1;

        }

        return found;

    }

    fn trailing_panels(self: *Manager) usize {

        var found: usize = 0;

        while (found < self.count and self.windows[self.order[self.count - 1 - found]].is_panel()) {

            found += 1;

        }

        return found;

    }

    /// Fill `out` with a record per taskbar-listed window, bottom to top; returns the count.
    pub fn list_info(self: *Manager, out: []proto.window.WindowInfo) usize {

        var written: usize = 0;
        var index: usize = 0;

        while (index < self.count and written < out.len) : (index += 1) {

            const window = &self.windows[self.order[index]];

            if (!window.is_taskbar_listed()) continue;

            const frame = window.frame();

            out[written] = .{

                .id = window.id,
                .flags = @truncate(window.flags),
                .focused = @intFromBool(self.focus == window.id),
                .minimized = @intFromBool(window.flags & proto.window.flag_minimized != 0),
                .title_len = @intCast(window.title_length),

                .x = frame.x,
                .y = frame.y,
                .width = @intCast(frame.w),
                .height = @intCast(frame.h),

                .title = window.title,

            };

            written += 1;

        }

        return written;

    }

    pub fn minimize(self: *Manager, id: u32) ?Rect {

        const window = self.by_id(id) orelse return null;

        if (window.is_panel() or window.is_desktop()) return null;
        if (window.flags & proto.window.flag_minimized != 0) return null;

        const damage = window.frame();

        window.flags |= proto.window.flag_minimized;

        if (self.focus == id) {

            self.focus = self.top_visible_id() orelse 0;

        }

        return damage;

    }

    pub fn restore(self: *Manager, id: u32) ?Rect {

        const window = self.by_id(id) orelse return null;

        if (window.flags & proto.window.flag_minimized == 0) return null;

        window.flags &= ~proto.window.flag_minimized;

        self.focus = id;
        self.raise(id);

        return window.frame();

    }

    fn panel_height(self: *const Manager) i32 {

        var index: usize = 0;

        while (index < self.count) : (index += 1) {

            const window = &self.windows[self.order[index]];

            if (window.is_panel()) return @intCast(window.height);

        }

        return default_panel_height;

    }

    pub const GeometryChange = struct {

        damage: Rect,
        resized: bool,

    };

    /// Maximize a decorated window into the free area above the panel. Returns damage and whether content size changed.
    pub fn maximize(self: *Manager, id: u32) ?GeometryChange {

        const window = self.by_id(id) orelse return null;

        if (!window.decorated()) return null;
        if (window.flags & proto.window.flag_minimized != 0) return null;
        if (window.is_maximized()) return null;

        const before = window.frame();

        window.restore_x = window.x;
        window.restore_y = window.y;
        window.restore_width = window.width;
        window.restore_height = window.height;

        const work_h = @max(0, @as(i32, @intCast(self.screen_height)) - self.panel_height());
        const content_h = @max(@as(i32, @intCast(min_content)), work_h - title_height);

        window.x = 0;
        window.y = 0;
        window.width = self.screen_width;
        window.height = @intCast(content_h);
        window.flags |= proto.window.flag_maximized;

        self.focus = id;
        self.raise(id);

        const after = window.frame();
        const resized = before.w != after.w or before.h != after.h;

        return .{ .damage = before.cover(after), .resized = resized };

    }

    /// Restore a maximized window to its pre-maximize geometry.
    pub fn unmaximize(self: *Manager, id: u32) ?GeometryChange {

        const window = self.by_id(id) orelse return null;

        if (!window.is_maximized()) return null;

        const before = window.frame();

        window.flags &= ~proto.window.flag_maximized;
        window.x = window.restore_x;
        window.y = window.restore_y;
        window.width = if (window.restore_width != 0) window.restore_width else window.width;
        window.height = if (window.restore_height != 0) window.restore_height else window.height;

        self.clamp(window);

        const after = window.frame();
        const resized = before.w != after.w or before.h != after.h;

        return .{ .damage = before.cover(after), .resized = resized };

    }

    /// Toggle maximize / restore for a decorated window.
    pub fn toggle_maximize(self: *Manager, id: u32) ?GeometryChange {

        const window = self.by_id(id) orelse return null;

        if (window.is_maximized()) return self.unmaximize(id);

        return self.maximize(id);

    }

    /// Clear maximized state after an interactive move or resize without changing geometry further.
    pub fn clear_maximized(self: *Manager, id: u32) void {

        const window = self.by_id(id) orelse return;

        window.flags &= ~proto.window.flag_maximized;

    }

    pub fn is_visible(_: *const Manager, window: *const Window) bool {

        return window.used and window.flags & proto.window.flag_minimized == 0;

    }

    fn top_visible_id(self: *Manager) ?u32 {

        var index = self.count;

        while (index > 0) {

            index -= 1;

            const window = &self.windows[self.order[index]];

            if (window.is_panel()) continue;
            if (window.flags & proto.window.flag_minimized != 0) continue;

            return window.id;

        }

        return null;

    }

    pub fn destroy(self: *Manager, id: u32) ?Rect {

        const index = self.order_index(id) orelse return null;
        const slot = self.order[index];
        const damage = self.windows[slot].frame();

        self.windows[slot].used = false;

        var position = index;

        while (position + 1 < self.count) : (position += 1) {

            self.order[position] = self.order[position + 1];

        }

        self.count -= 1;

        if (self.focus == id) {

            self.focus = if (self.count > 0) self.windows[self.order[self.count - 1]].id else 0;

        }

        return damage;

    }

    pub fn by_id(self: *Manager, id: u32) ?*Window {

        for (&self.windows) |*window| {

            if (window.used and window.id == id) return window;

        }

        return null;

    }

    pub fn by_title(self: *Manager, title: []const u8) ?*Window {

        var cursor = self.count;

        while (cursor > 0) {

            cursor -= 1;

            const window = &self.windows[self.order[cursor]];

            if (!window.is_taskbar_listed()) continue;
            if (std.ascii.eqlIgnoreCase(window.title[0..window.title_length], title)) return window;

        }

        return null;

    }

    pub fn focused(self: *Manager) ?*Window {

        if (self.focus == 0) return null;

        return self.by_id(self.focus);

    }

    /// Windows bottom to top, for painting.
    pub fn stacked(self: *Manager, index: usize) *Window {

        return &self.windows[self.order[index]];

    }

    pub fn raise(self: *Manager, id: u32) void {

        const index = self.order_index(id) orelse return;
        const slot = self.order[index];
        const kind = self.windows[slot].stack_kind();

        if (kind == .desktop) return;

        var position = index;

        while (position + 1 < self.count) : (position += 1) {

            self.order[position] = self.order[position + 1];

        }

        self.count -= 1;
        self.insert(slot, kind);

    }

    /// The topmost window under the point, with the decoration region it hit.
    pub fn hit_test(self: *Manager, x: i32, y: i32) ?Hit {

        var index = self.count;

        while (index > 0) {

            index -= 1;

            const window = &self.windows[self.order[index]];

            if (window.flags & proto.window.flag_minimized != 0) continue;
            if (!window.frame().contains(x, y)) continue;

            if (window.decorated()) {

                if (window.close_button().contains(x, y)) return .{ .id = window.id, .region = .close };
                if (window.maximize_button().contains(x, y)) return .{ .id = window.id, .region = .maximize };
                if (window.minimize_button().contains(x, y)) return .{ .id = window.id, .region = .minimize };
                if (window.title_bar().contains(x, y)) return .{ .id = window.id, .region = .title };

                const grip = window.resize_grip_rect();

                if (!grip.is_empty() and grip.contains(x, y)) return .{ .id = window.id, .region = .resize };

            }

            return .{ .id = window.id, .region = .content };

        }

        return null;

    }

    /// Move a window's frame origin; returns the combined damage of the old and new footprint, or null when
    /// clamping leaves the frame unchanged (so drags against a screen edge do not spam full repaints).
    pub fn move(self: *Manager, id: u32, x: i32, y: i32) ?Rect {

        const window = self.by_id(id) orelse return null;
        const before = window.frame();

        if (window.is_maximized()) window.flags &= ~proto.window.flag_maximized;

        window.x = x;
        window.y = y;
        self.clamp(window);

        const after = window.frame();

        if (before.x == after.x and before.y == after.y and before.w == after.w and before.h == after.h) return null;

        return before.cover(after);

    }

    pub fn resize_screen(self: *Manager, width: u32, height: u32) void {

        self.screen_width = width;
        self.screen_height = height;

        for (&self.windows) |*window| {

            if (!window.used) continue;

            if (window.flags & proto.window.flag_fullscreen != 0 or window.is_desktop()) {

                window.x = 0;
                window.y = 0;

                window.width = width;
                window.height = height;

            } else if (window.is_maximized()) {

                const work_h = @max(0, @as(i32, @intCast(self.screen_height)) - self.panel_height());
                const content_h = @max(@as(i32, @intCast(min_content)), work_h - title_height);

                window.x = 0;
                window.y = 0;
                window.width = self.screen_width;
                window.height = @intCast(content_h);

            } else {

                self.clamp(window);

            }

        }

    }

    /// True when a screen resize changes this window's content size (its owner must reallocate the surface).
    pub fn tracks_screen(_: *const Manager, window: *const Window) bool {

        if (window.flags & proto.window.flag_fullscreen != 0) return true;
        if (window.is_desktop()) return true;
        if (window.is_panel()) return true;

        return false;

    }

    fn clamp(self: *Manager, window: *Window) void {

        if (window.flags & proto.window.flag_fullscreen != 0) {

            window.x = 0;
            window.y = 0;

            return;

        }

        // A panel is pinned full-width to the screen bottom; it never moves off it.

        if (window.is_panel()) {

            window.width = self.screen_width;
            window.x = 0;
            window.y = @max(0, @as(i32, @intCast(self.screen_height)) - @as(i32, @intCast(window.height)));

            return;

        }

        const frame_w = @as(i32, @intCast(window.width));
        const frame_h = if (window.decorated()) title_height + @as(i32, @intCast(window.height)) else @as(i32, @intCast(window.height));

        const max_x = @max(0, @as(i32, @intCast(self.screen_width)) - frame_w);
        const max_y = @max(0, @as(i32, @intCast(self.screen_height)) - frame_h);

        window.x = @max(0, @min(window.x, max_x));
        window.y = @max(0, @min(window.y, max_y));

    }

    fn clamp_content_width(self: *Manager, width: u32) u32 {

        return clamp_content_extent(width, self.screen_width);

    }

    fn clamp_content_height(self: *Manager, height: u32) u32 {

        return clamp_content_extent(height, self.screen_height);

    }

    fn clamp_content_extent(requested: u32, screen: u32) u32 {

        const wanted = @max(min_content, requested);

        if (screen == 0) return wanted;

        return @min(wanted, @max(min_content, screen));

    }

    fn order_index(self: *Manager, id: u32) ?usize {

        for (self.order[0..self.count], 0..) |slot, index| {

            if (self.windows[slot].used and self.windows[slot].id == id) return index;

        }

        return null;

    }

    fn free_slot(self: *Manager) ?usize {

        for (&self.windows, 0..) |*window, index| {

            if (!window.used) return index;

        }

        return null;

    }

};

const testing = std.testing;

fn test_manager() Manager {

    var manager = Manager{};

    manager.resize_screen(640, 480);

    return manager;

}

test "create stacks focuses and cascades" {

    var manager = test_manager();

    const first = manager.create(1, 100, 100, 0, "one").?;
    const second = manager.create(1, 100, 100, 0, "two").?;

    try testing.expectEqual(second.id, manager.focus);
    try testing.expectEqual(first.id, manager.stacked(0).id);
    try testing.expectEqual(second.id, manager.stacked(1).id);
    try testing.expect(second.x != first.x);

}

test "hit test respects stacking and decorations" {

    var manager = test_manager();

    const below = manager.create(1, 200, 200, 0, "below").?;
    const above = manager.create(1, 200, 200, 0, "above").?;

    // Force overlap.

    _ = manager.move(below.id, 100, 100);
    _ = manager.move(above.id, 100, 100);

    const inside = manager.hit_test(150, 200).?;

    try testing.expectEqual(above.id, inside.id);
    try testing.expectEqual(Region.content, inside.region);

    const bar = manager.hit_test(110, 100 + 2).?;

    try testing.expectEqual(above.id, bar.id);
    try testing.expectEqual(Region.title, bar.region);

    const close = above.close_button();
    const on_close = manager.hit_test(close.x + 2, close.y + 2).?;

    try testing.expectEqual(Region.close, on_close.region);

    try testing.expectEqual(@as(?Hit, null), manager.hit_test(639, 479));

}

test "hit test grabs the bottom-right resize grip" {

    var manager = test_manager();

    const window = manager.create(1, 200, 200, 0, "app").?;
    _ = manager.move(window.id, 100, 100);

    const grip = window.resize_grip_rect();

    // A point inside the grip resizes; a point just inside the frame's interior is plain content.

    const on_grip = manager.hit_test(grip.x + 2, grip.y + 2).?;

    try testing.expectEqual(window.id, on_grip.id);
    try testing.expectEqual(Region.resize, on_grip.region);

    const inside = manager.hit_test(grip.x - 20, grip.y - 20).?;

    try testing.expectEqual(Region.content, inside.region);

    // An undecorated window exposes no grip.

    const bare = manager.create(2, 200, 200, proto.window.flag_undecorated, "bare").?;
    _ = manager.move(bare.id, 100, 100);

    try testing.expectEqual(Region.content, manager.hit_test(bare.x + bare.frame().w - 3, bare.y + bare.frame().h - 3).?.region);

}

test "raise reorders and destroy refocuses" {

    var manager = test_manager();

    const first = manager.create(1, 100, 100, 0, "one").?;
    const second = manager.create(1, 100, 100, 0, "two").?;

    manager.raise(first.id);

    try testing.expectEqual(first.id, manager.stacked(1).id);

    const damage = manager.destroy(second.id).?;

    try testing.expect(!damage.is_empty());
    try testing.expectEqual(@as(usize, 1), manager.count);

    manager.focus = first.id;

    _ = manager.destroy(first.id);

    try testing.expectEqual(@as(u32, 0), manager.focus);

}

test "move clamps to the screen and reports covering damage" {

    var manager = test_manager();

    const window = manager.create(1, 100, 100, 0, "w").?;
    const damage = manager.move(window.id, -50, -50).?;

    try testing.expectEqual(@as(i32, 0), window.x);
    try testing.expectEqual(@as(i32, 0), window.y);
    try testing.expect(damage.w >= window.frame().w);

    _ = manager.move(window.id, 10_000, 10_000).?;

    const frame = window.frame();

    try testing.expectEqual(@max(0, 640 - frame.w), window.x);
    try testing.expectEqual(@max(0, 480 - frame.h), window.y);

    try testing.expectEqual(@as(?Rect, null), manager.move(window.id, 10_000, 10_000));

}

test "move against a clamped edge returns null" {

    var manager = test_manager();

    const window = manager.create(1, 100, 100, 200, "w").?;

    _ = manager.move(window.id, 0, 0).?;

    try testing.expectEqual(@as(i32, 0), window.x);
    try testing.expectEqual(@as(i32, 0), window.y);
    try testing.expectEqual(@as(?Rect, null), manager.move(window.id, -40, -20));
    try testing.expectEqual(@as(?Rect, null), manager.move(window.id, -1, 0));

}

test "fullscreen windows track the screen size" {

    var manager = test_manager();

    const window = manager.create(1, 0, 0, proto.window.flag_fullscreen, "shell").?;

    try testing.expectEqual(@as(u32, 640), window.width);

    manager.resize_screen(800, 600);

    try testing.expectEqual(@as(u32, 800), window.width);
    try testing.expectEqual(@as(u32, 600), window.height);
    try testing.expect(!window.decorated());

}

test "the table refuses a seventeenth window" {

    var manager = test_manager();

    for (0..max_windows) |index| {

        try testing.expect(manager.create(1, 50, 50, 0, "w") != null);

        _ = index;

    }

    try testing.expectEqual(@as(?*Window, null), manager.create(1, 50, 50, 0, "overflow"));

}

test "a panel docks to the bottom and stays above ordinary windows" {

    var manager = test_manager();

    const panel = manager.create(1, 0, 44, proto.window.flag_panel, "taskbar").?;

    try testing.expectEqual(@as(u32, 640), panel.width);
    try testing.expectEqual(@as(i32, 480 - 44), panel.y);
    try testing.expect(!panel.decorated());

    const app = manager.create(1, 200, 200, 0, "app").?;

    // The panel is created first but must remain the topmost window.

    try testing.expectEqual(panel.id, manager.stacked(manager.count - 1).id);
    try testing.expectEqual(app.id, manager.stacked(0).id);

    // Raising the app keeps it beneath the panel.

    manager.raise(app.id);

    try testing.expectEqual(panel.id, manager.stacked(manager.count - 1).id);
    try testing.expectEqual(app.id, manager.stacked(0).id);

}

test "list_info reports ordinary windows and skips panels" {

    var manager = test_manager();

    _ = manager.create(1, 0, 44, proto.window.flag_panel, "taskbar").?;
    const first = manager.create(1, 100, 100, 0, "first").?;
    const second = manager.create(1, 100, 100, 0, "second").?;

    var records: [max_windows]proto.window.WindowInfo = undefined;
    const count = manager.list_info(&records);

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(first.id, records[0].id);
    try testing.expectEqual(second.id, records[1].id);
    try testing.expectEqual(@as(u32, 1), records[1].focused);
    try testing.expectEqualStrings("second", records[1].title[0..records[1].title_len]);

}

test "minimize hides a window and restore brings it back" {

    var manager = test_manager();

    const window = manager.create(1, 200, 200, 0, "app").?;

    if (manager.minimize(window.id)) |damage| {

        try testing.expect(!damage.is_empty());

    }

    try testing.expect(window.flags & proto.window.flag_minimized != 0);

    if (manager.restore(window.id)) |damage| {

        try testing.expect(!damage.is_empty());

    }

    try testing.expect(window.flags & proto.window.flag_minimized == 0);
    try testing.expectEqual(window.id, manager.focus);

}

test "maximize fills work area and unmaximize restores geometry" {

    var manager = test_manager();

    _ = manager.create(1, 0, 40, proto.window.flag_panel, "taskbar").?;
    const window = manager.create(1, 200, 180, 0, "app").?;

    const saved_x = window.x;
    const saved_y = window.y;
    const saved_w = window.width;
    const saved_h = window.height;

    const maxed = manager.maximize(window.id).?;

    try testing.expect(maxed.resized);
    try testing.expect(window.is_maximized());
    try testing.expectEqual(@as(i32, 0), window.x);
    try testing.expectEqual(@as(i32, 0), window.y);
    try testing.expectEqual(@as(u32, 640), window.width);
    try testing.expectEqual(@as(u32, 480 - 40 - title_height), window.height);

    const restored = manager.unmaximize(window.id).?;

    try testing.expect(restored.resized);
    try testing.expect(!window.is_maximized());
    try testing.expectEqual(saved_x, window.x);
    try testing.expectEqual(saved_y, window.y);
    try testing.expectEqual(saved_w, window.width);
    try testing.expectEqual(saved_h, window.height);

}

test "list_info skips undecorated chrome windows" {

    var manager = test_manager();

    _ = manager.create(1, 0, 44, proto.window.flag_panel, "taskbar").?;
    _ = manager.create(1, 200, 200, proto.window.flag_undecorated, "menu").?;
    const app = manager.create(1, 100, 100, 0, "app").?;

    var records: [max_windows]proto.window.WindowInfo = undefined;
    const count = manager.list_info(&records);

    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(app.id, records[0].id);

}

test "desktop layers track the screen size" {

    var manager = test_manager();

    const desktop = manager.create(1, 0, 0, proto.window.flag_desktop, "desktop").?;

    try testing.expectEqual(@as(u32, 640), desktop.width);

    manager.resize_screen(1024, 768);

    try testing.expectEqual(@as(u32, 1024), desktop.width);
    try testing.expectEqual(@as(u32, 768), desktop.height);
    try testing.expect(manager.tracks_screen(desktop));

}

test "panels reposition when the screen resizes" {

    var manager = test_manager();

    const panel = manager.create(1, 0, 40, proto.window.flag_panel, "taskbar").?;

    manager.resize_screen(1024, 768);

    try testing.expectEqual(@as(u32, 1024), panel.width);
    try testing.expectEqual(@as(i32, 768 - 40), panel.y);

}
