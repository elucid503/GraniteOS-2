// Window management policy (07-userspace-ddd.md Section 12.3), kept pure so it host-tests without a display:
// the window table, stacking order, focus, hit testing, drag arithmetic, and screen-resize clamping. The
// compositor in main.zig owns everything with a side effect (surfaces, rendering, IPC).

const std = @import("std");

const lib = @import("lib");

const gfx = lib.gfx;
const proto = lib.proto;

const Rect = gfx.Rect;

pub const max_windows = 16;

pub const title_height: i32 = 28;
pub const corner_radius: i32 = 8;
pub const chrome_size: i32 = 14;
pub const chrome_margin: i32 = 10;
pub const title_padding: i32 = 10;

pub const min_content: u32 = 32;

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

    pub fn decorated(self: *const Window) bool {

        return self.flags & (proto.window.flag_undecorated | proto.window.flag_fullscreen) == 0;

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

        return chrome_size + chrome_margin;

    }

    pub fn close_button(self: *const Window) Rect {

        const bar = self.title_bar();
        const inset = @divTrunc(title_height - chrome_size, 2);

        return .{

            .x = bar.x + bar.w - chrome_size - chrome_margin,
            .y = bar.y + inset,

            .w = chrome_size,
            .h = chrome_size,

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

        } else {

            window.width = @max(min_content, width);
            window.height = @max(min_content, height);

            const step: i32 = @intCast(32 * (self.placed % 8) + 48);

            window.x = step;
            window.y = step;
            self.placed += 1;

        }

        window.set_title(title);
        self.clamp(window);

        self.order[self.count] = slot;
        self.count += 1;
        self.focus = id;

        return window;

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

        var position = index;

        while (position + 1 < self.count) : (position += 1) {

            self.order[position] = self.order[position + 1];

        }

        self.order[self.count - 1] = slot;

    }

    /// The topmost window under the point, with the decoration region it hit.
    pub fn hit_test(self: *Manager, x: i32, y: i32) ?Hit {

        var index = self.count;

        while (index > 0) {

            index -= 1;

            const window = &self.windows[self.order[index]];

            if (!window.frame().contains(x, y)) continue;

            if (window.decorated()) {

                if (window.close_button().contains(x, y)) return .{ .id = window.id, .region = .close };
                if (window.title_bar().contains(x, y)) return .{ .id = window.id, .region = .title };

            }

            return .{ .id = window.id, .region = .content };

        }

        return null;

    }

    /// Move a window's frame origin; returns the combined damage of the old and new footprint.
    pub fn move(self: *Manager, id: u32, x: i32, y: i32) ?Rect {

        const window = self.by_id(id) orelse return null;
        const before = window.frame();

        window.x = x;
        window.y = y;
        self.clamp(window);

        return before.cover(window.frame());

    }

    pub fn resize_screen(self: *Manager, width: u32, height: u32) void {

        self.screen_width = width;
        self.screen_height = height;

        for (&self.windows) |*window| {

            if (!window.used) continue;

            if (window.flags & proto.window.flag_fullscreen != 0) {

                window.x = 0;
                window.y = 0;

                window.width = width;
                window.height = height;

            } else {

                self.clamp(window);

            }

        }

    }

    // Keep at least the title bar reachable: the frame may hang off the right/bottom, but its top-left
    // stays on screen.

    fn clamp(self: *Manager, window: *Window) void {

        if (window.flags & proto.window.flag_fullscreen != 0) {

            window.x = 0;
            window.y = 0;

            return;

        }

        const limit_x: i32 = @max(0, @as(i32, @intCast(self.screen_width)) - 32);
        const limit_y: i32 = @max(0, @as(i32, @intCast(self.screen_height)) - title_height);

        window.x = @max(0, @min(window.x, limit_x));
        window.y = @max(0, @min(window.y, limit_y));

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

    _ = manager.move(window.id, 10_000, 10_000);

    try testing.expect(window.x < 640);
    try testing.expect(window.y < 480);

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