// Display server / compositor (07-userspace-ddd.md Section 12.3): the policy layer over the display driver.
// It owns the screen, allocates window surfaces as shared Regions, composites them into the scanout with
// damage tracking (a cached back buffer, then one row-copy of the damaged band into the uncached
// framebuffer), and manages stacking, focus, and title-bar dragging. Input arrives over the input server's
// event ring; the hardware cursor plane means pointer motion costs one IPC, not a recomposite. Everything
// idles blocked in `receive` with a bound notification - no frame timer, no polling.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const manager_module = @import("manager.zig");

const Handle = cap.Handle;
const Manager = manager_module.Manager;
const Message = ipc.Message;
const Rect = gfx.Rect;
const Window = manager_module.Window;

comptime {

    _ = lib.start;

}

const input_bit: u64 = 1 << 0;
const display_bit: u64 = 1 << 1;

const input_ring_capacity: u32 = 512;
const worker_stack_pages = 16;
const page_size = 4096;

// Theme

const theme = .{

    .wallpaper = gfx.rgb(22, 22, 22),
    .title_focused = gfx.rgb(72, 72, 72),
    .title_blurred = gfx.rgb(56, 56, 56),
    .chrome = gfx.rgb(220, 220, 220),
    .title_font_size = @as(u32, 13),

};

var title_font: ?lib.ttf.Face = null;

var screen_width: u32 = 0;
var screen_height: u32 = 0;
var stride_bytes: u32 = 0;

// The scanout (uncached DMA) and the cached back buffer everything composes into.

var fb_region: Handle = 0;
var fb_base: usize = 0;
var fb: gfx.Surface = undefined;

var back_region: Handle = 0;
var back_base: usize = 0;
var back: gfx.Surface = undefined;

var manager = Manager{};

// Per-window surface bookkeeping, indexed like manager.windows.

const Surfaces = struct {

    region: [manager_module.max_windows]Handle = [_]Handle{0} ** manager_module.max_windows,
    base: [manager_module.max_windows]usize = [_]usize{0} ** manager_module.max_windows,
    width: [manager_module.max_windows]u32 = [_]u32{0} ** manager_module.max_windows,
    height: [manager_module.max_windows]u32 = [_]u32{0} ** manager_module.max_windows,

};

var surfaces = Surfaces{};

// Per-client event rings, keyed by the badge the name service minted for the client.

const ClientExtra = struct {

    notification: Handle = 0,

    // The taskbar's window-list buffer, mapped once on its first `list` call and reused after.
    info_base: usize = 0,

    pub fn release(self: *ClientExtra) void {

        if (self.notification != 0) sys.close(self.notification) catch {};
        if (self.info_base != 0) sys.unmap(cap.self_space, self.info_base) catch {};

    }

    pub fn evict(_: *ClientExtra, badge: u64) void {

        destroy_owner_windows(badge);

    }

};

const session_capacity = proto.window.max_windows * 2 + 8;
const Sessions = lib.session.Sessions(ClientExtra, session_capacity);

var sessions: Sessions = .{};

// Input state.

var input_ring: events.Ring = undefined;
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var input_attached = false;

var drag_id: u32 = 0;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;

// Interactive resize is drawn as a rubber-band outline while the grip is held; the surface is reallocated once, on
// release, so a drag never churns a fresh Region per pointer move.
var resize_id: u32 = 0;
var resize_outline: Rect = Rect.empty;

// Offset from the pointer to the frame's bottom-right at grab time, so the corner tracks the pointer without jumping.
var resize_dx: i32 = 0;
var resize_dy: i32 = 0;

var damage: Rect = Rect.empty;

const ListWatch = struct {

    badge: u64 = 0,
    notify: Handle = 0,
    info_base: usize = 0,

};

var list_watch = ListWatch{};

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try acquire_display();
    try load_font();

    // Flint already registered "window" against this endpoint; clients queue here until the loop starts.

    manager.resize_screen(screen_width, screen_height);

    pointer_x = @intCast(screen_width / 2);
    pointer_y = @intCast(screen_height / 2);

    move_cursor();

    add_damage(screen_bounds());
    try composite();

    start_startup_worker() catch {};

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(cap.stdin, &in) catch continue;

        if (badge == cap.notification_wake) {

            const bits = in.data[0];

            if (input_attached and bits & input_bit != 0) drain_input();
            if (bits & display_bit != 0) handle_mode_change();

        } else {

            var out = Message.zeroed;
            out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

            sys.reply(in.reply, &out) catch {};

        }

        composite() catch {};

    }

}

fn load_font() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.compositor.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    title_font = lib.ttf.Face.parse(bundle.find("font-ttf") orelse return error.NotFound) catch return error.Invalid;

}

// Startup wiring

fn start_startup_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&startup_worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn startup_worker() callconv(.c) noreturn {

    attach_input() catch exit_thread();

    input_attached = true;
    upload_cursor() catch {};
    move_cursor();

    exit_thread();

}

fn exit_thread() noreturn {

    while (true) sys.close(cap.self_thread) catch {};

}

fn acquire_display() !void {

    const wake = try sys.create(.notification, 0, 0);

    try sys.configure(cap.self_thread, .bound_notification, wake);

    const mode = try ipc.request(cap.compositor.display, proto.display.mode_info, &.{}, &.{});

    screen_width = @intCast(mode.data[1] >> 32);
    screen_height = @truncate(mode.data[1]);
    stride_bytes = @intCast(mode.data[2]);

    try map_scanout();
    try build_back_buffer();

    _ = try ipc.request(cap.compositor.display, proto.display.attach_events, &.{display_bit}, &.{

        .{ .handle = wake, .move = false },

    });

    input_wake = wake;

}

var input_wake: Handle = 0;

fn attach_input() !void {

    const region = try sys.create(.region, events.ring_bytes(input_ring_capacity), cap.memory);
    const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);

    input_ring = events.Ring.init(base, input_ring_capacity);

    _ = try ipc.request(cap.compositor.input, proto.input.attach, &.{ input_ring_capacity, input_bit }, &.{

        .{ .handle = region, .move = false },
        .{ .handle = input_wake, .move = false },

    });

    sys.close(region) catch {};

}

fn map_scanout() !void {

    const reply = try ipc.request(cap.compositor.display, proto.display.map_framebuffer, &.{}, &.{});

    if (reply.handle_count < 1) return error.Invalid;

    if (fb_base != 0) sys.unmap(cap.self_space, fb_base) catch {};
    if (fb_region != 0) sys.close(fb_region) catch {};

    fb_region = reply.handles[0].handle;
    fb_base = try sys.map(cap.self_space, fb_region, 0, sys.read | sys.write);
    fb = gfx.Surface.from_base(fb_base, screen_width, screen_height, stride_bytes);

}

fn build_back_buffer() !void {

    if (back_base != 0) sys.unmap(cap.self_space, back_base) catch {};
    if (back_region != 0) sys.close(back_region) catch {};

    const bytes = @as(usize, screen_width) * screen_height * 4;

    back_region = try sys.create(.region, bytes, cap.memory);
    back_base = try sys.map(cap.self_space, back_region, 0, sys.read | sys.write);
    back = gfx.Surface.from_base(back_base, screen_width, screen_height, screen_width * 4);

}

// The classic arrow, rasterized into a 64x64 ARGB Region for the device's cursor plane.

const arrow = [_][]const u8{

    "X           ",
    "XX          ",
    "X.X         ",
    "X..X        ",
    "X...X       ",
    "X....X      ",
    "X.....X     ",
    "X......X    ",
    "X.......X   ",
    "X........X  ",
    "X.....XXXXX ",
    "X..X..X     ",
    "X.X X..X    ",
    "XX  X..X    ",
    "X    X..X   ",
    "     X..X   ",
    "      X..X  ",
    "      X..X  ",
    "       XX   ",

};

fn upload_cursor() !void {

    const side = proto.display.cursor_size;
    const bytes = side * side * 4;

    const region = try sys.create(.region, bytes, cap.memory);
    const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
    const pixels: [*]u32 = @ptrFromInt(base);

    @memset(pixels[0 .. side * side], 0);

    for (arrow, 0..) |row, y| {

        for (row, 0..) |cell, x| {

            pixels[y * side + x] = switch (cell) {

                'X' => 0xff00_0000,
                '.' => 0xffff_ffff,

                else => 0,

            };

        }

    }

    sys.unmap(cap.self_space, base) catch {};

    _ = try ipc.request(cap.compositor.display, proto.display.set_cursor, &.{0}, &.{

        .{ .handle = region, .move = true },

    });

    sys.close(region) catch {};

}

// Window interface

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.window.create => create_window(badge, in, out),
        proto.window.present => present(badge, in),
        proto.window.set_title => set_title(badge, in),
        proto.window.destroy => destroy_window(badge, in.data[1]),
        proto.window.attach_events => attach_events(badge, in),
        proto.window.resize => resize_window(badge, in, out),
        proto.window.list => list_windows(badge, in, out),
        proto.window.activate => activate_window(in.data[1]),
        proto.window.screen_info => screen_info(out),
        proto.window.move => move_window(badge, in),
        proto.window.minimize => minimize_window(in.data[1]),
        proto.window.restore => restore_window(in.data[1]),
        proto.window.subscribe_list => subscribe_list(badge, in, out),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.window.interface_id;
    out.data[2] = proto.window.version;

    return 0;

}

fn create_window(badge: u64, in: *const Message, out: *Message) i64 {

    var title_bytes: [proto.window.max_title]u8 = undefined;
    const title = lib.window.unpack_title(.{ in.data[3], in.data[4], in.data[5] }, &title_bytes);

    const width = lib.window.unpack_high(in.data[1]);
    const height = lib.window.unpack_low(in.data[1]);

    const previous_focus = manager.focus;
    const window = manager.create(badge, width, height, in.data[2], title) orelse return -3;

    const slot = slot_of(window);

    surfaces.region[slot] = 0;
    surfaces.base[slot] = 0;

    if (allocate_surface(window, slot)) |failure| {

        _ = manager.destroy(window.id);

        return failure;

    }

    notify_focus(previous_focus, window.id);
    add_damage(window.frame());
    publish_list();

    out.data[1] = window.id;
    out.data[2] = lib.window.pack_pair(window.width, window.height);
    out.data[3] = window.width * 4;
    out.handles[0] = .{ .handle = surfaces.region[slot], .move = false };
    out.handle_count = 1;

    return 0;

}

fn allocate_surface(window: *Window, slot: usize) ?i64 {

    const bytes = surface_bytes(window.width, window.height) orelse return -7;

    const region = sys.create(.region, bytes, cap.memory) catch return -3;
    const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch {

        sys.close(region) catch {};

        return -3;

    };

    const pixels: [*]u8 = @ptrFromInt(base);
    @memset(pixels[0..bytes], 0);

    surfaces.region[slot] = region;
    surfaces.base[slot] = base;
    surfaces.width[slot] = window.width;
    surfaces.height[slot] = window.height;

    return null;

}

fn release_surface(slot: usize) void {

    if (surfaces.base[slot] != 0) sys.unmap(cap.self_space, surfaces.base[slot]) catch {};
    if (surfaces.region[slot] != 0) sys.close(surfaces.region[slot]) catch {};

    surfaces.base[slot] = 0;
    surfaces.region[slot] = 0;
    surfaces.width[slot] = 0;
    surfaces.height[slot] = 0;

}

fn present(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;
    const content = window.content();

    const local = Rect{

        .x = @intCast(@min(in.data[2] >> 32, window.width)),
        .y = @intCast(@min(in.data[2] & 0xffff_ffff, window.height)),

        .w = @intCast(@min(in.data[3] >> 32, window.width)),
        .h = @intCast(@min(in.data[3] & 0xffff_ffff, window.height)),

    };

    add_damage(local.translated(content.x, content.y).intersect(content));

    composite() catch return -7;

    return 0;

}

fn set_title(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;

    var title_bytes: [proto.window.max_title]u8 = undefined;

    window.set_title(lib.window.unpack_title(.{ in.data[3], in.data[4], in.data[5] }, &title_bytes));

    add_damage(window.frame());
    publish_list();

    composite() catch return -7;

    return 0;

}

fn destroy_window(badge: u64, id: u64) i64 {

    const window = owned_window(badge, id) orelse return -7;
    const slot = slot_of(window);

    if (drag_id == window.id) drag_id = 0;
    if (resize_id == window.id) resize_id = 0;

    release_surface(slot);

    if (manager.destroy(window.id)) |dead| add_damage(dead);

    publish_list();

    if (manager.focused()) |now| send_to_owner(now, .{

        .kind = events.kind_window_focus,
        .code = 0,
        .window = now.id,

        .x = 0,
        .y = 0,

        .value = 0,

    });

    composite() catch return -7;

    return 0;

}

fn destroy_owner_windows(owner: u64) void {

    var index: usize = 0;
    var focused_changed = false;

    while (index < manager.windows.len) : (index += 1) {

        const window = &manager.windows[index];

        if (!window.used or window.owner != owner) continue;

        if (drag_id == window.id) drag_id = 0;
        if (resize_id == window.id) resize_id = 0;
        if (manager.focus == window.id) focused_changed = true;

        release_surface(index);

        if (manager.destroy(window.id)) |dead| add_damage(dead);

    }

    if (focused_changed) {

        if (manager.focused()) |now| send_to_owner(now, .{

            .kind = events.kind_window_focus,
            .code = 0,
            .window = now.id,

            .x = 0,
            .y = 0,

            .value = 0,

        });

    }

}

fn attach_events(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 2) return -7;

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(events.ring_bytes(@intCast(in.data[1])));
    sys.close(in.handles[0].handle) catch {};

    session.extra.notification = in.handles[1].handle;

    return 0;

}

fn resize_window(badge: u64, in: *const Message, out: *Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;
    const slot = slot_of(window);

    const width = @max(manager_module.min_content, lib.window.unpack_high(in.data[2]));
    const height = @max(manager_module.min_content, lib.window.unpack_low(in.data[2]));

    release_surface(slot);

    add_damage(manager.resize_window(window, width, height));

    if (allocate_surface(window, slot)) |failure| return failure;

    add_damage(window.frame());

    out.data[1] = in.data[1];
    out.data[2] = lib.window.pack_pair(window.width, window.height);
    out.data[3] = window.width * 4;
    out.handles[0] = .{ .handle = surfaces.region[slot], .move = false };
    out.handle_count = 1;

    return 0;

}

// The taskbar attaches an info Region on its first call, then polls for the open-window list; the compositor is the
// authority on what windows exist, so the bar reflects it exactly.

fn list_windows(badge: u64, in: *const Message, out: *Message) i64 {

    const session = sessions.find(badge) orelse return -7;

    if (in.handle_count >= 1) {

        if (session.extra.info_base != 0) sys.unmap(cap.self_space, session.extra.info_base) catch {};

        session.extra.info_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
        sys.close(in.handles[0].handle) catch {};

    }

    if (session.extra.info_base == 0) return -7;

    const records: [*]proto.window.WindowInfo = @ptrFromInt(session.extra.info_base);

    out.data[1] = manager.list_info(records[0..manager_module.max_windows]);

    return 0;

}

fn activate_window(id: u64) i64 {

    const window = manager.by_id(@intCast(id)) orelse return -7;

    if (window.flags & proto.window.flag_minimized != 0) {

        if (manager.restore(window.id)) |restored| add_damage(restored);

    }

    focus_and_raise(window);
    publish_list();
    composite() catch return -7;

    return 0;

}

fn screen_info(out: *Message) i64 {

    out.data[1] = lib.window.pack_pair(screen_width, screen_height);

    return 0;

}

fn move_window(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;

    if (window.is_panel()) return -7;

    const x: i32 = @intCast(in.data[2] >> 32);
    const y: i32 = @intCast(@as(u32, @truncate(in.data[2])));

    if (manager.move(window.id, x, y)) |moved| {

        add_damage(moved);
        publish_list();

    }

    composite() catch return -7;

    return 0;

}

fn minimize_window(id: u64) i64 {

    const window = manager.by_id(@intCast(id)) orelse return -7;

    if (manager.minimize(window.id)) |hidden| {

        add_damage(hidden);
        publish_list();

        if (manager.focused()) |now| send_to_owner(now, .{

            .kind = events.kind_window_focus,
            .code = 0,
            .window = now.id,

            .x = 0,
            .y = 0,

            .value = 0,

        });

    }

    composite() catch return -7;

    return 0;

}

fn restore_window(id: u64) i64 {

    const window = manager.by_id(@intCast(id)) orelse return -7;

    if (manager.restore(window.id)) |shown| {

        add_damage(shown);
        publish_list();
        notify_focus(0, window.id);

    }

    composite() catch return -7;

    return 0;

}

fn subscribe_list(badge: u64, in: *const Message, out: *Message) i64 {

    if (in.handle_count < 2) return -7;

    if (list_watch.info_base != 0) sys.unmap(cap.self_space, list_watch.info_base) catch {};
    if (list_watch.notify != 0) sys.close(list_watch.notify) catch {};

    list_watch.badge = badge;
    list_watch.notify = in.handles[1].handle;
    list_watch.info_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;

    sys.close(in.handles[0].handle) catch {};

    out.data[1] = write_list_buffer(list_watch.info_base);

    return 0;

}

fn write_list_buffer(base: usize) u64 {

    const records: [*]proto.window.WindowInfo = @ptrFromInt(base);

    return manager.list_info(records[0..manager_module.max_windows]);

}

fn publish_list() void {

    if (list_watch.info_base == 0 or list_watch.notify == 0) return;

    _ = write_list_buffer(list_watch.info_base);

    sys.notify(list_watch.notify, proto.window.list_bit) catch {};

}

fn owned_window(badge: u64, id: u64) ?*Window {

    const window = manager.by_id(@intCast(id)) orelse return null;

    if (window.owner != badge) return null;

    return window;

}

fn slot_of(window: *Window) usize {

    return (@intFromPtr(window) - @intFromPtr(&manager.windows[0])) / @sizeOf(Window);

}

// Input routing

fn drain_input() void {

    var moved = false;

    while (input_ring.pop()) |event| {

        switch (event.kind) {

            events.kind_pointer_move => {

                pointer_x = scale(event.x, screen_width);
                pointer_y = scale(event.y, screen_height);
                moved = true;

                handle_pointer_move();

            },

            events.kind_button_down => handle_button_down(event),
            events.kind_button_up => handle_button_up(event),

            events.kind_key_down, events.kind_key_up => {

                if (manager.focused()) |window| forward(window, event);

            },

            events.kind_scroll => {

                if (window_under_pointer()) |window| forward(window, event);

            },

            else => {},

        }

    }

    // One cursor-plane move per batch, after the last motion event.

    if (moved) move_cursor();

}

fn handle_pointer_move() void {

    if (resize_id != 0) {

        const window = manager.by_id(resize_id) orelse {

            resize_id = 0;

            return;

        };

        // Redraw the band spanning the old and new outline, then restroke at the new size on the next composite.

        add_damage(resize_outline);
        resize_outline = proposed_frame(window);
        add_damage(resize_outline);

        return;

    }

    if (drag_id != 0) {

        if (manager.move(drag_id, pointer_x - drag_dx, pointer_y - drag_dy)) |moved| add_damage(moved);

        return;

    }

    if (window_under_pointer()) |window| {

        forward(window, .{

            .kind = events.kind_pointer_move,
            .code = 0,
            .window = window.id,

            .x = pointer_x,
            .y = pointer_y,

            .value = 0,

        });

    }

}

fn handle_button_down(event: events.Event) void {

    const hit = manager.hit_test(pointer_x, pointer_y) orelse return;
    const window = manager.by_id(hit.id) orelse return;

    focus_and_raise(window);

    switch (hit.region) {

        .close => send_to_owner(window, .{

            .kind = events.kind_window_close,
            .code = 0,
            .window = window.id,

            .x = 0,
            .y = 0,

            .value = 0,

        }),

        .title => {

            drag_id = window.id;
            drag_dx = pointer_x - window.x;
            drag_dy = pointer_y - window.y;

        },

        .resize => {

            const f = window.frame();

            resize_id = window.id;
            resize_dx = f.x + f.w - pointer_x;
            resize_dy = f.y + f.h - pointer_y;
            resize_outline = f;

            add_damage(resize_outline);

        },

        .content => forward(window, event),

    }

}

fn handle_button_up(event: events.Event) void {

    if (resize_id != 0) {

        commit_resize();

        return;

    }

    if (drag_id != 0) {

        drag_id = 0;

        return;

    }

    if (window_under_pointer()) |window| forward(window, event);

}

// The proposed content extents for the window whose grip is being dragged: the pointer sets the frame's bottom-right,
// clamped the same way manager.resize_window will clamp on commit so the outline matches the committed size exactly.

fn resize_target(window: *const Window) struct { width: u32, height: u32 } {

    const content = window.content();

    const raw_w = @max(@as(i32, @intCast(manager_module.min_content)), pointer_x + resize_dx - content.x);
    const raw_h = @max(@as(i32, @intCast(manager_module.min_content)), pointer_y + resize_dy - content.y);

    const width = @min(@as(u32, @intCast(raw_w)), @max(manager_module.min_content, screen_width));
    const height = @min(@as(u32, @intCast(raw_h)), @max(manager_module.min_content, screen_height));

    return .{ .width = width, .height = height };

}

fn proposed_frame(window: *const Window) Rect {

    const target = resize_target(window);
    const decoration: i32 = if (window.decorated()) manager_module.title_height else 0;

    return .{

        .x = window.x,
        .y = window.y,

        .w = @intCast(target.width),
        .h = decoration + @as(i32, @intCast(target.height)),

    };

}

fn commit_resize() void {

    const id = resize_id;

    resize_id = 0;

    // Erase the outline; the window itself repaints once the client remaps its resized surface.

    add_damage(resize_outline);
    resize_outline = Rect.empty;

    const window = manager.by_id(id) orelse return;
    const target = resize_target(window);

    add_damage(manager.resize_window(window, target.width, target.height));
    add_damage(window.frame());

    send_to_owner(window, .{

        .kind = events.kind_window_resize,
        .code = 0,
        .window = window.id,

        .x = @intCast(window.width),
        .y = @intCast(window.height),

        .value = 0,

    });

}

fn focus_and_raise(window: *Window) void {

    const previous = manager.focus;

    if (previous == window.id) return;

    manager.focus = window.id;
    manager.raise(window.id);

    notify_focus(previous, window.id);
    publish_list();

    // Both title bars repaint, and the raise may reveal any part of the frame.

    if (manager.by_id(previous)) |old| add_damage(old.frame());

    add_damage(window.frame());

}

fn notify_focus(previous: u32, current: u32) void {

    if (previous == current) return;

    if (manager.by_id(previous)) |old| send_to_owner(old, .{

        .kind = events.kind_window_blur,
        .code = 0,
        .window = old.id,

        .x = 0,
        .y = 0,

        .value = 0,

    });

    if (manager.by_id(current)) |now| send_to_owner(now, .{

        .kind = events.kind_window_focus,
        .code = 0,
        .window = now.id,

        .x = 0,
        .y = 0,

        .value = 0,

    });

}

fn window_under_pointer() ?*Window {

    const hit = manager.hit_test(pointer_x, pointer_y) orelse return null;

    if (hit.region != .content) return null;

    return manager.by_id(hit.id);

}

/// Forward an input event to the window's owner, translated into content-local coordinates.
fn forward(window: *Window, event: events.Event) void {

    const content = window.content();

    var routed = event;

    routed.window = window.id;

    if (event.kind == events.kind_pointer_move or event.kind == events.kind_button_down or
        event.kind == events.kind_button_up or event.kind == events.kind_scroll)
    {

        routed.x = pointer_x - content.x;
        routed.y = pointer_y - content.y;

    }

    send_to_owner(window, routed);

}

fn send_to_owner(window: *Window, event: events.Event) void {

    const session = sessions.find(window.owner) orelse return;

    if (session.base == 0) return;

    const ring = events.Ring.open(session.base);

    if (ring.push(event)) {

        sys.notify(session.extra.notification, proto.window.ring_bit) catch {};

    }

}

fn scale(normalized: i32, extent: u32) i32 {

    if (extent == 0) return 0;

    const range: i64 = @intCast(proto.input.pointer_range);
    const scaled = @divTrunc(@as(i64, normalized) * (@as(i64, extent) - 1), range);

    return @intCast(@max(0, @min(@as(i64, extent) - 1, scaled)));

}

fn move_cursor() void {

    _ = ipc.request(cap.compositor.display, proto.display.move_cursor, &.{

        lib.window.pack_pair(@intCast(pointer_x), @intCast(pointer_y)),

    }, &.{}) catch {};

}

// A mode change: refetch the mode, remap the scanout, rebuild the back buffer, tell fullscreen clients,
// repaint the world.

fn handle_mode_change() void {

    const mode = ipc.request(cap.compositor.display, proto.display.mode_info, &.{}, &.{}) catch return;

    screen_width = @intCast(mode.data[1] >> 32);
    screen_height = @truncate(mode.data[1]);
    stride_bytes = @intCast(mode.data[2]);

    map_scanout() catch return;
    build_back_buffer() catch return;

    manager.resize_screen(screen_width, screen_height);

    pointer_x = @min(pointer_x, @as(i32, @intCast(screen_width - 1)));
    pointer_y = @min(pointer_y, @as(i32, @intCast(screen_height - 1)));

    var index: usize = 0;

    while (index < manager.count) : (index += 1) {

        const window = manager.stacked(index);

        if (window.flags & proto.window.flag_fullscreen == 0) continue;

        send_to_owner(window, .{

            .kind = events.kind_window_resize,
            .code = 0,
            .window = window.id,

            .x = @intCast(screen_width),
            .y = @intCast(screen_height),

            .value = 0,

        });

    }

    add_damage(screen_bounds());
    composite() catch {};

    upload_cursor() catch {};
    move_cursor();

}

// Compositing

fn add_damage(rect: Rect) void {

    damage = damage.cover(rect.intersect(screen_bounds()));

}

fn screen_bounds() Rect {

    return .{ .x = 0, .y = 0, .w = @intCast(screen_width), .h = @intCast(screen_height) };

}

fn surface_bytes(width: u32, height: u32) ?usize {

    const pixels = std.math.mul(usize, width, height) catch return null;

    return std.math.mul(usize, pixels, 4) catch null;

}

fn composite() !void {

    if (damage.is_empty()) return;

    const region = damage;

    damage = Rect.empty;

    back.fill_rect(region, theme.wallpaper);

    var index: usize = 0;

    while (index < manager.count) : (index += 1) {

        const window = manager.stacked(index);

        if (window.flags & proto.window.flag_minimized != 0) continue;
        if (window.frame().intersect(region).is_empty()) continue;

        draw_window(window, region);

    }

    // The resize rubber-band rides above every window; moves always damage its band, so restroking it each pass is
    // enough to keep the fed-back scanout consistent.

    if (resize_id != 0 and !resize_outline.is_empty()) {

        back.stroke_rect(resize_outline, 2, theme.chrome);

    }

    // One pass into the uncached scanout: only the damaged band's rows move.

    fb.blit(region.x, region.y, &back, region);
    gfx.fence();

    _ = try ipc.request(cap.compositor.display, proto.display.flush, &.{

        lib.window.pack_pair(@intCast(region.x), @intCast(region.y)),
        lib.window.pack_pair(@intCast(region.w), @intCast(region.h)),

    }, &.{});

}

fn draw_title_text(window: *const Window, title_bar: Rect) void {

    const font = title_font orelse return;
    const title = window.title[0..window.title_length];
    const max_w = title_bar.w - Window.chrome_reserved_width() - manager_module.title_padding;

    if (max_w <= 0 or title.len == 0) return;

    var length = title.len;

    while (length > 0 and font.text_width(title[0..length], theme.title_font_size) > max_w) : (length -= 1) {}

    const text_y = title_bar.y + @divTrunc(title_bar.h - font.line_height(theme.title_font_size), 2);

    font.draw(&back, title_bar.x + manager_module.title_padding, text_y, theme.title_font_size, title[0..length], theme.chrome);

}

fn draw_close_button(box: Rect) void {

    const cx = box.x + @divTrunc(box.w, 2);
    const cy = box.y + @divTrunc(box.h, 2);
    const arm = @max(2, @divTrunc(box.w, 4));

    back.stroke_line_smooth(cx - arm, cy - arm, cx + arm, cy + arm, 1, theme.chrome);
    back.stroke_line_smooth(cx + arm, cy - arm, cx - arm, cy + arm, 1, theme.chrome);

}

fn draw_window(window: *Window, clip: Rect) void {

    const slot = slot_of(window);
    const title_bar = window.title_bar();
    const content = window.content();

    if (window.decorated()) {

        const title_color = if (manager.focus == window.id) theme.title_focused else theme.title_blurred;

        back.fill_rounded_rect_top(title_bar, manager_module.corner_radius, title_color);
        draw_title_text(window, title_bar);
        draw_close_button(window.close_button());

    }

    if (surfaces.base[slot] == 0) return;

    // A host resize updates the window before the client reallocates its surface; skip stale bytes.
    if (surfaces.width[slot] != window.width or surfaces.height[slot] != window.height) return;

    const surface = gfx.Surface.from_base(surfaces.base[slot], surfaces.width[slot], surfaces.height[slot], surfaces.width[slot] * 4);
    const visible = content.intersect(clip);

    if (visible.is_empty()) return;

    // Client pixels were written in another process; publish before the compositor reads the shared Region.
    gfx.fence();

    back.blit(visible.x, visible.y, &surface, visible.translated(-content.x, -content.y));

    if (window.decorated()) {

        back.mask_rounded_rect_bottom_smooth(window.frame(), manager_module.corner_radius, theme.wallpaper);
        draw_resize_grip(window);

    }

}

// A trio of short diagonal ticks in the bottom-right corner: the affordance that the corner grabs a resize.

fn draw_resize_grip(window: *const Window) void {

    const grip = window.resize_grip_rect();
    const corner_x = grip.x + grip.w - 3;
    const corner_y = grip.y + grip.h - 3;

    var step: i32 = 4;

    while (step <= 12) : (step += 4) {

        back.stroke_line_smooth(corner_x - step, corner_y, corner_x, corner_y - step, 1, theme.title_blurred);

    }

}
