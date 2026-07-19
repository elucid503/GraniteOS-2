// Display server / compositor (part of the M10 GUI rewrite)

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const draw = lib.draw;
const events = lib.events;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const manager_module = @import("manager.zig");
const damage_module = @import("damage.zig");
const quartz_effect = @import("quartz.zig");
const render = @import("render.zig");
const surfaces_module = @import("surfaces.zig");

const Handle = cap.Handle;
const Manager = manager_module.Manager;
const Message = ipc.Message;
const Rect = draw.Rect;
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

const CompositorTheme = struct {

    wallpaper: draw.Color,
    title_focused: draw.Color,
    title_blurred: draw.Color,
    chrome: draw.Color,
    border: draw.Color,

};

var theme = CompositorTheme{

    .wallpaper = draw.rgb(22, 22, 22),
    .title_focused = draw.rgb(72, 72, 72),
    .title_blurred = draw.rgb(56, 56, 56),
    .chrome = draw.rgb(220, 220, 220),
    .border = draw.rgb(58, 58, 58),

};

var active_cursor: lib.cursor.Kind = .pointer;

var title_font: ?draw.text.Face = null;

var screen_width: u32 = 0;
var screen_height: u32 = 0;
var stride_bytes: u32 = 0;

// The scanout (uncached DMA) and the cached back buffer everything composes into.

var fb_region: Handle = 0;
var fb_base: usize = 0;
var fb: draw.Surface = undefined;

var back_region: Handle = 0;
var back_base: usize = 0;
var back: draw.Surface = undefined;

var manager = Manager{};
var surfaces = surfaces_module.Store(manager_module.max_windows){};
var quartz_renderer = quartz_effect.Renderer{};

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
var input_wake: Handle = 0;

var drag_id: u32 = 0;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;

// Last position that was actually glass-composited while dragging (not every pointer sample).
var drag_last_painted: Rect = Rect.empty;
var drag_moved_since_paint = false;
var last_drag_composite_ms: u64 = 0;

// Cap glass rebuilds only for large Quartz windows while dragging. Small glass surfaces stay
// per-sample (they were never the problem). Effects stay full-quality on each painted frame.
const drag_composite_interval_ms: u64 = 32;
// Roughly ≥ Files/default large windows; calculator/about/timer stay per-sample.
const drag_coalesce_min_pixels: u64 = 380_000;
const title_double_click_interval_ms: u64 = 400;

var last_title_click_id: u32 = 0;
var last_title_click_ms: u64 = 0;

// Interactive resize draws a rubber-band outline while the grip is held.

var resize_id: u32 = 0;
var resize_outline: Rect = Rect.empty;
var resize_dx: i32 = 0;
var resize_dy: i32 = 0;

var damage = damage_module.List{};
var resize_damage: [manager_module.max_windows]Rect = [_]Rect{Rect.empty} ** manager_module.max_windows;

const ListWatch = struct {

    badge: u64 = 0,
    notify: Handle = 0,
    info_base: usize = 0,

};

var list_watch = ListWatch{};

// Window open/close/minimize animations: short snapshot overlays composited above the scene.

const anim_open_ms: u64 = 140;
const anim_close_ms: u64 = 120;
const anim_minimize_ms: u64 = 170;
const anim_tick_ms: u64 = 8;

// Open/close endpoints scale about the frame center to ~93%.
const anim_scale_milli: i32 = 930;
const max_window_anims = 4;

const WindowAnim = struct {

    active: bool = false,

    // Nonzero while a fade-in suppresses the live window until the overlay lands.
    hidden_id: u32 = 0,

    region: Handle = 0,
    base: usize = 0,
    snapshot: draw.Surface = undefined,

    from: Rect = Rect.empty,
    to: Rect = Rect.empty,

    // Opacity endpoints in 0..=1000; equal endpoints give a pure geometry morph.
    alpha_from: i32 = 0,
    alpha_to: i32 = 0,
    accelerate: bool = false,

    start_ms: u64 = 0,
    duration_ms: u64 = 0,

};

var window_anims: [max_window_anims]WindowAnim = [_]WindowAnim{.{}} ** max_window_anims;

// Decorated app windows stay hidden between create and first present, then fade in.
var awaiting_present: [manager_module.max_windows]bool = [_]bool{false} ** manager_module.max_windows;

// Taskbar-local indicator center x per window slot (-1 = no hint yet).
var minimize_hints: [manager_module.max_windows]i32 = [_]i32{-1} ** manager_module.max_windows;

pub fn main(_: []const []const u8) u8 {

    run() catch {

        return 1;

    };

    return 0;

}

fn run() !void {

    try acquire_display();
    try load_font();
    load_compositor_theme();
    _ = draw.round.masks_for(render.corner_radius);
    upload_cursor(.pointer) catch {};

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

        if (window_anims_active()) {

            while (true) {

                in = Message.zeroed;
                const queued_badge = sys.receive_poll(cap.stdin, &in) catch break;

                process_message(queued_badge, &in);

            }

            tick_window_anims();
            composite() catch {};
            lib.time.sleep_ms(anim_tick_ms);

            continue;

        }

        const badge = sys.receive(cap.stdin, &in) catch continue;

        process_message(badge, &in);

        while (true) {

            in = Message.zeroed;
            const queued_badge = sys.receive_poll(cap.stdin, &in) catch |failure| switch (failure) {

                error.WouldBlock => break,
                else => break,

            };

            process_message(queued_badge, &in);

        }

        composite() catch {};

    }

}

fn process_message(badge: u64, in: *const Message) void {

    if (badge == cap.notification_wake) {

        const bits = in.data[0];

        if (input_attached and bits & input_bit != 0) drain_input();
        if (bits & display_bit != 0) handle_mode_change();

    } else {

        var out = Message.zeroed;
        const status = dispatch(badge, in.data[0], in, &out);

        if (in.data[0] == proto.window.present) {

            composite() catch {};

            out.data[0] = @bitCast(status);
            sys.reply(in.reply, &out) catch {};

            return;

        }

        out.data[0] = @bitCast(status);

        sys.reply(in.reply, &out) catch {};

    }

}

fn load_compositor_theme() void {

    // Force a re-read so the values packed into the broadcast are the ones just saved, not a cached generation.
    _ = lib.prefs.force_reload();

    const chrome = lib.prefs.chrome();

    theme.wallpaper = chrome.wallpaper;
    theme.title_focused = chrome.title_focused;
    theme.title_blurred = chrome.title_blurred;
    theme.chrome = chrome.chrome;
    theme.border = chrome.border;

    quartz_renderer.invalidate();

}

fn chrome_colors() render.Chrome {

    return .{

        .title_focused = theme.title_focused,
        .title_blurred = theme.title_blurred,
        .text = theme.chrome,

    };

}

fn load_font() !void {

    const length: usize = @intCast(lib.start.word(3));
    const offset: usize = @intCast(lib.start.word(4));

    const base = try sys.map(cap.self_space, cap.compositor.bundle, 0, sys.read);
    const bundle = try lib.bundle.Bundle.open(base + offset, length);

    title_font = draw.text.Face.parse(bundle.find("font-ttf") orelse return error.NotFound) catch return error.Invalid;

}

// Startup wiring: input attaches from a worker so a slow input server never blocks the first composite.

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
    upload_cursor(active_cursor) catch {};
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
    fb = draw.Surface.from_base(fb_base, screen_width, screen_height, stride_bytes);

}

fn build_back_buffer() !void {

    // Release both display-sized regions before reallocating so contiguous frames can coalesce.
    quartz_renderer.release();

    if (back_base != 0) sys.unmap(cap.self_space, back_base) catch {};
    if (back_region != 0) sys.close(back_region) catch {};

    const bytes = surfaces_module.surface_bytes(screen_width, screen_height, .xrgb) orelse return error.Invalid;

    back_region = try sys.create(.region, bytes, cap.memory);
    back_base = try sys.map(cap.self_space, back_region, 0, sys.read | sys.write);
    back = draw.Surface.from_base(back_base, screen_width, screen_height, screen_width * 4);

    quartz_renderer.resize(screen_width, screen_height) catch quartz_renderer.release();

}

// Cursor plane.

fn apply_cursor(kind: lib.cursor.Kind) void {

    if (kind == active_cursor) return;

    active_cursor = kind;

    upload_cursor(kind) catch {};

}

fn upload_cursor(kind: lib.cursor.Kind) !void {

    const side = proto.display.cursor_size;
    const bytes = side * side * 4;

    const region = try sys.create(.region, bytes, cap.memory);
    const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
    const pixels: [*]u32 = @ptrFromInt(base);

    lib.cursor.paint(side, kind, pixels);

    sys.unmap(cap.self_space, base) catch {};

    const hot = lib.cursor.hot_spot(kind);

    _ = try ipc.request(cap.compositor.display, proto.display.set_cursor, &.{

        lib.window.pack_pair(hot.x, hot.y),

    }, &.{

        .{ .handle = region, .move = true },

    });

    sys.close(region) catch {};

}

fn update_chrome_cursor() void {

    const hit = manager.hit_test(pointer_x, pointer_y) orelse {

        apply_cursor(.pointer);

        return;

    };

    switch (hit.region) {

        .close, .maximize, .minimize => apply_cursor(.clicker),
        .title, .resize => apply_cursor(.pointer),
        .content => {},

    }

}

fn move_cursor() void {

    _ = ipc.request(cap.compositor.display, proto.display.move_cursor, &.{

        lib.window.pack_pair(@intCast(pointer_x), @intCast(pointer_y)),

    }, &.{}) catch {};

}

// Window interface.

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
        proto.window.notify_prefs => notify_prefs_changed(),
        proto.window.set_cursor => set_client_cursor(in.data[1]),
        proto.window.activate_title => activate_title(in),
        proto.window.close_title => close_title(in),
        proto.window.place_relative => place_relative(badge, in),
        proto.window.minimize_hint => set_minimize_hint(in),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn requested_title(in: *const Message, out: *[proto.window.max_title]u8) []const u8 {

    return lib.window.unpack_title(.{ in.data[1], in.data[2], in.data[3] }, out);

}

fn activate_title(in: *const Message) i64 {

    var buffer: [proto.window.max_title]u8 = undefined;
    const target = manager.by_title(requested_title(in, &buffer)) orelse return -6;

    return activate_window(target.id);

}

fn close_title(in: *const Message) i64 {

    var buffer: [proto.window.max_title]u8 = undefined;
    const target = manager.by_title(requested_title(in, &buffer)) orelse return -6;

    send_to_owner(target, window_event(events.kind_window_close, target.id, 0, 0));

    return 0;

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

    if (width > surfaces_module.max_side or height > surfaces_module.max_side) return -7;

    const previous_focus = manager.focus;
    const window = manager.create(badge, width, height, in.data[2], title) orelse return -3;
    const slot = slot_of(window);

    resize_damage[slot] = Rect.empty;
    awaiting_present[slot] = window.is_taskbar_listed();
    minimize_hints[slot] = -1;

    _ = surfaces.allocate(slot, window.width, window.height, window_format(window)) catch {

        _ = manager.destroy(window.id);

        return -3;

    };

    notify_focus(previous_focus, window.id);
    add_window_damage(window, window.frame());
    publish_list();

    out.data[1] = window.id;
    out.data[2] = lib.window.pack_pair(window.width, window.height);
    out.data[3] = window.width * 4;
    out.handles[0] = .{ .handle = surfaces.region_of(slot), .move = false };
    out.handle_count = 1;

    return 0;

}

fn present(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;
    const slot = slot_of(window);
    const content = window.content();

    surfaces.commit(slot);

    if (awaiting_present[slot]) {

        awaiting_present[slot] = false;
        animate_reveal(window, false);

    }

    if (!resize_damage[slot].is_empty()) {

        add_window_damage(window, resize_damage[slot]);
        resize_damage[slot] = Rect.empty;

    }

    const local = Rect{

        .x = @intCast(@min(in.data[2] >> 32, window.width)),
        .y = @intCast(@min(in.data[2] & 0xffff_ffff, window.height)),

        .w = @intCast(@min(in.data[3] >> 32, window.width)),
        .h = @intCast(@min(in.data[3] & 0xffff_ffff, window.height)),

    };

    add_surface_damage(window, local.translated(content.x, content.y).intersect(content));

    return 0;

}

fn set_title(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;

    var title_bytes: [proto.window.max_title]u8 = undefined;

    window.set_title(lib.window.unpack_title(.{ in.data[3], in.data[4], in.data[5] }, &title_bytes));

    add_damage(window.frame());
    publish_list();

    return 0;

}

fn destroy_window(badge: u64, id: u64) i64 {

    const window = owned_window(badge, id) orelse return -7;
    const slot = slot_of(window);

    // A window mid-reveal (or never presented) is absent from back, so there is nothing to fade out.
    const visible = !window_hidden(window) and window.flags & proto.window.flag_minimized == 0;

    cancel_window_anim(window.id);
    awaiting_present[slot] = false;

    if (visible and window.is_taskbar_listed()) animate_close(window.frame());

    release_grabs(window.id);
    surfaces.release(slot);
    resize_damage[slot] = Rect.empty;

    if (manager.destroy(window.id)) |dead| add_damage(dead);

    publish_list();
    send_focus_to_top();

    return 0;

}

fn destroy_owner_windows(owner: u64) void {

    var index: usize = 0;
    var focus_changed = false;

    while (index < manager.windows.len) : (index += 1) {

        const window = &manager.windows[index];

        if (!window.used or window.owner != owner) continue;

        cancel_window_anim(window.id);
        awaiting_present[index] = false;

        release_grabs(window.id);

        if (manager.focus == window.id) focus_changed = true;

        surfaces.release(index);
        resize_damage[index] = Rect.empty;

        if (manager.destroy(window.id)) |dead| add_damage(dead);

    }

    publish_list();

    if (focus_changed) send_focus_to_top();

}

fn release_grabs(id: u32) void {

    if (drag_id == id) drag_id = 0;

    if (resize_id == id) {

        resize_id = 0;

        add_overlay_damage(resize_outline);

        resize_outline = Rect.empty;

    }

}

fn send_focus_to_top() void {

    if (manager.focused()) |now| send_to_owner(now, window_event(events.kind_window_focus, now.id, 0, 0));

}

fn attach_events(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 2) return -7;

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch {

        sys.close(in.handles[0].handle) catch {};
        sys.close(in.handles[1].handle) catch {};

        return -7;

    };

    session.capacity = @intCast(events.ring_bytes(@intCast(@min(in.data[1], 4096))));
    sys.close(in.handles[0].handle) catch {};

    session.extra.notification = in.handles[1].handle;

    return 0;

}

fn resize_window(badge: u64, in: *const Message, out: *Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;
    const slot = slot_of(window);

    const width = lib.window.unpack_high(in.data[2]);
    const height = lib.window.unpack_low(in.data[2]);

    if (width > surfaces_module.max_side or height > surfaces_module.max_side) return -7;

    const changed = manager.resize_window(window, @max(manager_module.min_content, width), @max(manager_module.min_content, height));

    resize_damage[slot] = resize_damage[slot].cover(changed);

    _ = surfaces.allocate(slot, window.width, window.height, window_format(window)) catch return -3;

    out.data[1] = in.data[1];
    out.data[2] = lib.window.pack_pair(window.width, window.height);
    out.data[3] = window.width * 4;
    out.handles[0] = .{ .handle = surfaces.region_of(slot), .move = false };
    out.handle_count = 1;

    return 0;

}

// The taskbar attaches an info Region on its first call, then polls for the open-window list.

fn list_windows(badge: u64, in: *const Message, out: *Message) i64 {

    const session = sessions.find(badge) orelse return -7;

    if (in.handle_count >= 1) {

        if (session.extra.info_base != 0) sys.unmap(cap.self_space, session.extra.info_base) catch {};

        session.extra.info_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
        sys.close(in.handles[0].handle) catch {};

    }

    // Prefer the session mapping; fall back to the subscribe publish mapping for the same client.
    var base = session.extra.info_base;

    if (base == 0 and list_watch.badge == badge) base = list_watch.info_base;

    if (base == 0) return -7;

    const records: [*]proto.window.WindowInfo = @ptrFromInt(base);

    out.data[1] = manager.list_info(records[0..manager_module.max_windows]);

    return 0;

}

fn activate_window(id: u64) i64 {

    const window = manager.by_id(id_of(id) orelse return -7) orelse return -7;

    if (window.flags & proto.window.flag_minimized != 0) {

        if (manager.restore(window.id)) |restored| {

            add_damage(restored);

            if (window.is_taskbar_listed()) animate_reveal(window, true);

        }

    }

    focus_and_raise(window);
    publish_list();
    return 0;

}

fn screen_info(out: *Message) i64 {

    out.data[1] = lib.window.pack_pair(screen_width, screen_height);

    return 0;

}

fn move_window(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;

    if (window.is_panel()) return -7;

    const x: i32 = @intCast(@as(u32, @truncate(in.data[2] >> 32)));
    const y: i32 = @intCast(@as(u32, @truncate(in.data[2])));
    const before = window.frame();

    if (manager.move(window.id, x, y) != null) {

        add_movement_damage(window, before, window.frame());
        publish_list();

    }

    return 0;

}

fn place_relative(badge: u64, in: *const Message) i64 {

    const window = owned_window(badge, in.data[1]) orelse return -7;
    const anchor = owned_window(badge, in.data[2]) orelse return -7;

    if (window.is_panel() or window.id == anchor.id) return -7;

    const local_x: i32 = @intCast(@as(u32, @truncate(in.data[3] >> 32)));
    const local_y: i32 = @intCast(@as(u32, @truncate(in.data[3])));
    const content = anchor.content();
    const before = window.frame();

    if (manager.move(window.id, content.x + local_x, content.y + local_y) != null) {

        add_movement_damage(window, before, window.frame());
        publish_list();

    }

    return 0;

}

fn set_minimize_hint(in: *const Message) i64 {

    const window = manager.by_id(id_of(in.data[1]) orelse return -7) orelse return -7;

    minimize_hints[slot_of(window)] = @intCast(@min(in.data[2], std.math.maxInt(i32)));

    return 0;

}

fn minimize_window(id: u64) i64 {

    const window = manager.by_id(id_of(id) orelse return -7) orelse return -7;
    const visible = !window_hidden(window);

    cancel_window_anim(window.id);

    if (manager.minimize(window.id)) |hidden| {

        if (visible and window.is_taskbar_listed()) animate_minimize(window, hidden);

        add_damage(hidden);
        publish_list();
        send_focus_to_top();

    }

    return 0;

}

fn restore_window(id: u64) i64 {

    const window = manager.by_id(id_of(id) orelse return -7) orelse return -7;
    const previous = manager.focus;

    if (manager.restore(window.id)) |shown| {

        add_damage(shown);
        publish_list();
        notify_focus(previous, window.id);

        if (window.is_taskbar_listed()) animate_reveal(window, true);

    }

    return 0;

}

fn subscribe_list(badge: u64, in: *const Message, out: *Message) i64 {

    if (in.handle_count < 2) return -7;

    if (list_watch.info_base != 0) sys.unmap(cap.self_space, list_watch.info_base) catch {};
    if (list_watch.notify != 0) sys.close(list_watch.notify) catch {};

    list_watch = .{};

    list_watch.badge = badge;
    list_watch.notify = in.handles[1].handle;

    list_watch.info_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch {

        sys.close(in.handles[0].handle) catch {};
        sys.close(list_watch.notify) catch {};

        list_watch = .{};

        return -7;

    };

    sys.close(in.handles[0].handle) catch {};

    out.data[1] = write_list_buffer(list_watch.info_base);

    return 0;

}

fn notify_prefs_changed() i64 {

    load_compositor_theme();
    broadcast_prefs_changed();
    add_damage(screen_bounds());

    return 0;

}

fn set_client_cursor(kind_word: u64) i64 {

    if (kind_word > @intFromEnum(lib.cursor.Kind.selector)) return -7;

    apply_cursor(@enumFromInt(@as(u8, @truncate(kind_word))));

    return 0;

}

fn broadcast_prefs_changed() void {

    for (&sessions.slots) |*slot| {

        if (!slot.used or slot.base == 0) continue;

        const ring = events.Ring.open(slot.base);

        if (ring.push(lib.prefs.changed_event())) {

            sys.notify(slot.extra.notification, proto.window.ring_bit) catch {};

        }

    }

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

    const window = manager.by_id(id_of(id) orelse return null) orelse return null;

    if (window.owner != badge) return null;

    return window;

}

fn id_of(raw: u64) ?u32 {

    if (raw == 0 or raw > std.math.maxInt(u32)) return null;

    return @intCast(raw);

}

fn slot_of(window: *Window) usize {

    return (@intFromPtr(window) - @intFromPtr(&manager.windows[0])) / @sizeOf(Window);

}

// Input routing.

fn drain_input() void {

    var moved = false;
    var motion_pending = false;

    while (input_ring.pop()) |event| {

        switch (event.kind) {

            events.kind_pointer_move => {

                // Coalesces motion by only using the last sample...

                pointer_x = scale(event.x, screen_width);
                pointer_y = scale(event.y, screen_height);

                moved = true;
                motion_pending = true;

            },

            else => {

                if (motion_pending) {

                    handle_pointer_move();
                    motion_pending = false;

                }

                switch (event.kind) {

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

            },

        }

    }

    if (motion_pending) handle_pointer_move();

    // One cursor-plane move per batch, after the last motion event.

    if (moved) {

        move_cursor();

    }

}

fn handle_pointer_move() void {

    if (resize_id != 0) {

        const window = manager.by_id(resize_id) orelse {

            resize_id = 0;

            return;

        };

        // Redraw the band spanning the old and new outline; the next composite restrokes it.

        add_overlay_damage(resize_outline);
        resize_outline = proposed_frame(window);
        add_overlay_damage(resize_outline);

        return;

    }

    if (drag_id != 0) {

        const window = manager.by_id(drag_id) orelse {

            drag_id = 0;
            drag_moved_since_paint = false;

            return;

        };

        const before = window.frame();

        if (manager.move(drag_id, pointer_x - drag_dx, pointer_y - drag_dy) != null) {

            // Large glass surfaces coalesce; everything else damags every sample so light apps stay snappy.
            if (drag_should_coalesce(window)) {

                drag_moved_since_paint = true;

            } else {

                add_movement_damage(window, before, window.frame());

            }

        }

        return;

    }

    // Skips chrome hit-testing while dragging/resizing. Only matters for idle.
    update_chrome_cursor();

    if (window_under_pointer()) |window| {

        forward(window, window_event(events.kind_pointer_move, window.id, pointer_x, pointer_y));

    }

}

fn handle_button_down(event: events.Event) void {

    const hit = manager.hit_test(pointer_x, pointer_y) orelse return;
    const window = manager.by_id(hit.id) orelse return;

    focus_and_raise(window);

    switch (hit.region) {

        .close => send_to_owner(window, window_event(events.kind_window_close, window.id, 0, 0)),

        .minimize => {

            _ = minimize_window(window.id);

        },

        .maximize => {

            apply_toggle_maximize(window);

        },

        .title => {

            const now = lib.time.now_ms();

            if (last_title_click_id == window.id and now -% last_title_click_ms <= title_double_click_interval_ms) {

                last_title_click_id = 0;
                apply_toggle_maximize(window);
                return;

            }

            last_title_click_id = window.id;
            last_title_click_ms = now;

            if (window.is_maximized()) {

                // Dragging a maximized title bar restores it first so the frame can move under the pointer.
                if (manager.unmaximize(window.id)) |result| {

                    if (result.resized) {

                        resize_damage[slot_of(window)] = resize_damage[slot_of(window)].cover(result.damage);

                        send_to_owner(window, window_event(events.kind_window_resize, window.id, @intCast(window.width), @intCast(window.height)));

                    } else {

                        add_damage(result.damage);

                    }

                    publish_list();

                }

            }

            drag_id = window.id;
            drag_dx = pointer_x - window.x;
            drag_dy = pointer_y - window.y;
            drag_last_painted = window.frame();
            drag_moved_since_paint = false;
            last_drag_composite_ms = lib.time.now_ms();

        },

        .resize => {

            const frame = window.frame();

            resize_id = window.id;
            resize_dx = frame.x + frame.w - pointer_x;
            resize_dy = frame.y + frame.h - pointer_y;
            resize_outline = frame;

            add_overlay_damage(resize_outline);

        },

        .content => forward(window, event),

    }

}

fn apply_toggle_maximize(window: *Window) void {

    if (manager.toggle_maximize(window.id)) |result| {

        if (result.resized) {

            resize_damage[slot_of(window)] = resize_damage[slot_of(window)].cover(result.damage);

            send_to_owner(window, window_event(events.kind_window_resize, window.id, @intCast(window.width), @intCast(window.height)));

        } else {

            add_damage(result.damage);

        }

        publish_list();

    }

}

fn handle_button_up(event: events.Event) void {

    if (resize_id != 0) {

        commit_resize();

        return;

    }

    if (drag_id != 0) {

        // Final glass pass for the resting place (may have been rate-limited mid-drag).
        if (drag_moved_since_paint) {

            if (manager.by_id(drag_id)) |window| {

                if (drag_should_coalesce(window)) enqueue_drag_paint(window.frame());

            }

        }

        drag_id = 0;
        drag_moved_since_paint = false;
        drag_last_painted = Rect.empty;

        return;

    }

    if (window_under_pointer()) |window| forward(window, event);

}

// The pointer sets the frame's bottom-right, clamped exactly as the commit will clamp, so the outline matches the final size.

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

    add_overlay_damage(resize_outline);
    resize_outline = Rect.empty;

    const window = manager.by_id(id) orelse return;
    const target = resize_target(window);

    if (target.width == window.width and target.height == window.height) return;

    // Interactive grip resize leaves maximized state.
    if (window.is_maximized()) manager.clear_maximized(window.id);

    const changed = manager.resize_window(window, target.width, target.height);
    const slot = slot_of(window);

    resize_damage[slot] = resize_damage[slot].cover(changed);

    send_to_owner(window, window_event(events.kind_window_resize, window.id, @intCast(window.width), @intCast(window.height)));

}

fn focus_and_raise(window: *Window) void {

    const previous = manager.focus;

    if (previous == window.id) return;

    manager.focus = window.id;
    manager.raise(window.id);

    notify_focus(previous, window.id);
    publish_list();

    if (manager.by_id(previous)) |old| add_damage(old.frame());

    add_damage(window.frame());

}

fn notify_focus(previous: u32, current: u32) void {

    if (previous == current) return;

    if (manager.by_id(previous)) |old| send_to_owner(old, window_event(events.kind_window_blur, old.id, 0, 0));
    if (manager.by_id(current)) |now| send_to_owner(now, window_event(events.kind_window_focus, now.id, 0, 0));

}

fn window_under_pointer() ?*Window {

    const hit = manager.hit_test(pointer_x, pointer_y) orelse return null;

    if (hit.region != .content) return null;

    return manager.by_id(hit.id);

}

fn window_event(kind: u16, id: u32, x: i32, y: i32) events.Event {

    return .{

        .kind = kind,
        .code = 0,
        .window = id,

        .x = x,
        .y = y,

        .value = 0,

    };

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

// On mode change, we refetch the mode, remap the scanout, rebuild the back buffer, resize every window whose content exceeds new bounds. We must notify owners.

fn handle_mode_change() void {

    const mode = ipc.request(cap.compositor.display, proto.display.mode_info, &.{}, &.{}) catch return;

    const new_width: u32 = @intCast(mode.data[1] >> 32);
    const new_height: u32 = @truncate(mode.data[1]);

    if (new_width == 0 or new_height == 0) return;

    screen_width = new_width;
    screen_height = new_height;
    stride_bytes = @intCast(mode.data[2]);

    map_scanout() catch return;
    build_back_buffer() catch return;

    manager.resize_screen(screen_width, screen_height);

    pointer_x = @min(pointer_x, @as(i32, @intCast(screen_width - 1)));
    pointer_y = @min(pointer_y, @as(i32, @intCast(screen_height - 1)));

    var index: usize = 0;

    while (index < manager.count) : (index += 1) {

        const window = manager.stacked(index);

        if (!manager.tracks_screen(window)) continue;

        send_to_owner(window, window_event(events.kind_window_resize, window.id, @intCast(window.width), @intCast(window.height)));

    }

    publish_list();

    add_damage(screen_bounds());
    upload_cursor(active_cursor) catch {};
    move_cursor();

}

// Compositing.

fn add_damage(rect: Rect) void {

    const clipped = rect.intersect(screen_bounds());

    if (clipped.is_empty()) return;

    // Invalidate glass caches with a halo; the paint list stays tight and expands once in composite().
    const halo = quartz_halo(clipped);

    if (halo > 0) quartz_renderer.invalidate_region(clipped.inset(-halo).intersect(screen_bounds()))
    else quartz_renderer.invalidate_region(clipped);

    damage.add(clipped);

}

fn add_surface_damage(window: *const Window, rect: Rect) void {

    add_window_damage(window, rect);

}

fn add_overlay_damage(rect: Rect) void {

    damage.add(rect.intersect(screen_bounds()));

}

fn add_window_damage(window: *const Window, rect: Rect) void {

    const clipped = rect.intersect(screen_bounds());

    if (clipped.is_empty()) return;

    // Cache invalidation needs the morph halo; the dirty rect stays tight and expands once when painted.
    const halo = quartz_halo_above(clipped, window);

    if (halo > 0) quartz_renderer.invalidate_region(clipped.inset(-halo).intersect(screen_bounds()))
    else quartz_renderer.invalidate_region(clipped);

    damage.add(clipped);

}

fn add_movement_damage(window: *const Window, before: Rect, after: Rect) void {

    const covered = before.cover(after);

    if (rect_area(covered) <= rect_area(before) + rect_area(after)) {

        add_window_damage(window, covered);

        return;

    }

    add_window_damage(window, before);
    add_window_damage(window, after);

}

fn quartz_halo(rect: Rect) i32 {

    return quartz_halo_above(rect, null);

}

fn window_needs_glass(window: *const Window) bool {

    return lib.prefs.quartz_enabled() and quartz_renderer.ready() and window.flags & proto.window.flag_quartz != 0;

}

fn drag_should_coalesce(window: *const Window) bool {

    if (!window_needs_glass(window)) return false;

    const frame = window.frame();
    const area = @as(u64, @intCast(@max(0, frame.w))) * @as(u64, @intCast(@max(0, frame.h)));

    return area >= drag_coalesce_min_pixels;

}

fn enqueue_drag_paint(current: Rect) void {

    const previous = if (drag_last_painted.is_empty()) current else drag_last_painted;
    const covered = previous.cover(current).intersect(screen_bounds());

    if (covered.is_empty()) return;

    // Geometry only — composite() applies a single frost halo when painting.
    const density: u8 = @intFromEnum(lib.prefs.quartz_level);
    const halo = quartz_effect.damage_halo(density);

    quartz_renderer.invalidate_region(covered.inset(-halo).intersect(screen_bounds()));
    damage.add(covered);
    drag_last_painted = current;
    drag_moved_since_paint = false;
    last_drag_composite_ms = lib.time.now_ms();

}

fn quartz_halo_above(rect: Rect, source: ?*const Window) i32 {

    if (!quartz_renderer.ready() or !lib.prefs.quartz_enabled()) return 0;

    const max_layers: i32 = 3;
    var first: usize = 0;

    if (source) |changed| {

        while (first < manager.count) : (first += 1) {

            if (manager.stacked(first).id == changed.id) {

                first += 1;

                break;

            }

        }

    }

    var index = first;

    while (index < manager.count) : (index += 1) {

        const window = manager.stacked(index);

        if (window.flags & proto.window.flag_minimized != 0) continue;
        if (window.flags & proto.window.flag_quartz != 0) continue;
        if (!covers(window.content(), rect)) continue;
        if (!surfaces.covers(slot_of(window), window.content(), rect)) continue;

        first = index + 1;

    }

    var affected = rect;
    var layers: i32 = 0;
    var halo: i32 = 0;
    const density: u8 = @intFromEnum(lib.prefs.quartz_level);

    index = first;

    while (index < manager.count) : (index += 1) {

        const window = manager.stacked(index);

        if (window.flags & proto.window.flag_minimized != 0) continue;

        var layer_halo: i32 = 0;

        if (window.flags & proto.window.flag_quartz != 0 and !window.content().intersect(affected).is_empty()) layer_halo = quartz_effect.damage_halo(density);
        if (window.decorated() and !window.title_bar().intersect(affected).is_empty()) layer_halo = @max(layer_halo, quartz_effect.header_damage_halo(density));

        if (layer_halo == 0) continue;

        layers += 1;
        // Take the max halo once — summing per stacked layer ballooned paint regions to 100+ px.
        halo = @max(halo, layer_halo);
        affected = affected.inset(-layer_halo).intersect(screen_bounds());

        // Bounds filter propagation through stacked Quartz surfaces without unbounded overdraw.
        if (layers == max_layers) break;

    }

    return halo;

}

fn rect_area(rect: Rect) u64 {

    if (rect.is_empty()) return 0;

    return @as(u64, @intCast(rect.w)) * @as(u64, @intCast(rect.h));

}

fn screen_bounds() Rect {

    return .{ .x = 0, .y = 0, .w = @intCast(screen_width), .h = @intCast(screen_height) };

}

// Window animation machinery: fade+scale a snapshot of the window's composited pixels, so
// chrome, glass and content all animate together and no client cooperation is needed.

fn window_anims_active() bool {

    for (&window_anims) |*anim| if (anim.active) return true;

    return false;

}

fn window_hidden(window: *Window) bool {

    if (awaiting_present[slot_of(window)]) return true;

    for (&window_anims) |*anim| {

        if (anim.active and anim.hidden_id == window.id) return true;

    }

    return false;

}

fn free_anim_slot() ?*WindowAnim {

    for (&window_anims) |*anim| if (!anim.active) return anim;

    return null;

}

fn capture_snapshot(anim: *WindowAnim, rect: Rect) bool {

    const width: u32 = @intCast(rect.w);
    const height: u32 = @intCast(rect.h);

    const region = sys.create(.region, @as(usize, width) * height * 4, cap.memory) catch return false;

    const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch {

        sys.close(region) catch {};

        return false;

    };

    anim.region = region;
    anim.base = base;
    anim.snapshot = draw.Surface.from_base(base, width, height, width * 4);

    anim.snapshot.blit(0, 0, &back, rect);

    return true;

}

/// Animate a snapshot of `capture` (already composited in `back`) between `from` and `to`.
fn start_window_anim(capture: Rect, from: Rect, to: Rect, alpha_from: i32, alpha_to: i32, accelerate: bool, duration: u64, hidden_id: u32) void {

    const anim = free_anim_slot() orelse return;

    if (!capture_snapshot(anim, capture)) return;

    anim.active = true;
    anim.hidden_id = hidden_id;

    anim.from = from;
    anim.to = to;

    anim.alpha_from = alpha_from;
    anim.alpha_to = alpha_to;
    anim.accelerate = accelerate;

    anim.start_ms = lib.time.now_ms();
    anim.duration_ms = duration;

    add_damage(from.cover(to));

}

fn scaled_about_center(rect: Rect, milli: i32) Rect {

    const width = @max(1, @divTrunc(rect.w * milli, lib.anim.unit));
    const height = @max(1, @divTrunc(rect.h * milli, lib.anim.unit));

    return .{

        .x = rect.x + @divTrunc(rect.w - width, 2),
        .y = rect.y + @divTrunc(rect.h - height, 2),

        .w = width,
        .h = height,

    };

}

/// A small chip over the window's taskbar indicator (or the taskbar center without a hint).
fn minimize_target(window: *Window, frame: Rect) Rect {

    var dock: ?Rect = null;

    for (&manager.windows) |*panel_window| {

        if (!panel_window.used or !panel_window.is_panel()) continue;

        const panel = panel_window.frame();

        if (dock == null or panel.y > dock.?.y) dock = panel;

    }

    const width = @max(40, @divTrunc(frame.w, 4));
    const height = @max(24, @divTrunc(frame.h, 4));

    var center_x = frame.x + @divTrunc(frame.w, 2);
    var center_y: i32 = @intCast(screen_height);

    if (dock) |bar| {

        const hint = minimize_hints[slot_of(window)];

        center_x = if (hint >= 0) bar.x + hint else center_x;
        center_x = std.math.clamp(center_x, bar.x, bar.x + bar.w);
        center_y = bar.y + @divTrunc(bar.h, 2);

    }

    return .{

        .x = center_x - @divTrunc(width, 2),
        .y = center_y - @divTrunc(height, 2),

        .w = width,
        .h = height,

    };

}

/// Fade a window in, either from a slight center scale (open) or from the taskbar (restore).
fn animate_reveal(window: *Window, from_minimized: bool) void {

    const frame = window.frame().intersect(screen_bounds());

    if (frame.is_empty()) return;

    const from = if (from_minimized) minimize_target(window, frame) else scaled_about_center(frame, anim_scale_milli);
    const duration: u64 = if (from_minimized) anim_minimize_ms else anim_open_ms;

    // The suppressed window is absent from back, so a direct draw captures chrome, glass and content in place.
    add_damage(frame);
    draw_window(window, frame);
    start_window_anim(frame, from, frame, 0, lib.anim.unit, false, duration, window.id);

}

fn animate_close(frame_raw: Rect) void {

    const frame = frame_raw.intersect(screen_bounds());

    if (frame.is_empty()) return;

    start_window_anim(frame, frame, scaled_about_center(frame, anim_scale_milli), lib.anim.unit, 0, true, anim_close_ms, 0);

}

fn animate_minimize(window: *Window, frame_raw: Rect) void {

    const frame = frame_raw.intersect(screen_bounds());

    if (frame.is_empty()) return;

    start_window_anim(frame, frame, minimize_target(window, frame), lib.anim.unit, 0, true, anim_minimize_ms, 0);

}

fn tick_window_anims() void {

    const now = lib.time.now_ms();

    for (&window_anims) |*anim| {

        if (!anim.active) continue;

        add_damage(anim.from.cover(anim.to));

        if (now -% anim.start_ms >= anim.duration_ms) finish_window_anim(anim);

    }

}

fn finish_window_anim(anim: *WindowAnim) void {

    if (anim.hidden_id != 0) {

        // The reveal may have moved or resized mid-flight; damage where the live window actually is.
        if (manager.by_id(anim.hidden_id)) |window| add_damage(window.frame());

    }

    if (anim.base != 0) sys.unmap(cap.self_space, anim.base) catch {};
    if (anim.region != 0) sys.close(anim.region) catch {};

    anim.* = .{};

}

fn cancel_window_anim(id: u32) void {

    for (&window_anims) |*anim| {

        if (anim.active and anim.hidden_id == id) {

            add_damage(anim.from.cover(anim.to));
            finish_window_anim(anim);

        }

    }

}

fn draw_window_anim_overlays(clip: Rect) void {

    const now = lib.time.now_ms();

    for (&window_anims) |*anim| {

        if (!anim.active) continue;

        const linear = lib.anim.progress(now -% anim.start_ms, anim.duration_ms);
        const eased = if (anim.accelerate) lib.anim.ease_in(linear) else lib.anim.ease_out(linear);

        const rect = Rect{

            .x = lib.anim.lerp(anim.from.x, anim.to.x, eased),
            .y = lib.anim.lerp(anim.from.y, anim.to.y, eased),

            .w = lib.anim.lerp(anim.from.w, anim.to.w, eased),
            .h = lib.anim.lerp(anim.from.h, anim.to.h, eased),

        };

        const alpha_milli = lib.anim.lerp(anim.alpha_from, anim.alpha_to, eased);
        const alpha: u8 = @intCast(std.math.clamp(@divTrunc(alpha_milli * 255, lib.anim.unit), 0, 255));

        blend_snapshot(anim, rect, alpha, clip);

    }

}

// ponytail: per-pixel nearest-neighbor sampling; row-batched blending if overlay cost ever shows.
fn blend_snapshot(anim: *const WindowAnim, rect: Rect, alpha: u8, clip: Rect) void {

    if (alpha == 0 or rect.w <= 0 or rect.h <= 0) return;

    const dst = rect.intersect(clip).intersect(screen_bounds());

    if (dst.is_empty()) return;

    const snap = &anim.snapshot;
    const src_w: i32 = @intCast(snap.width);
    const src_h: i32 = @intCast(snap.height);

    var y = dst.y;

    while (y < dst.y + dst.h) : (y += 1) {

        const sy = std.math.clamp(@divTrunc((y - rect.y) * src_h, rect.h), 0, src_h - 1);
        const row = @as(u32, @intCast(sy)) * snap.stride;

        var x = dst.x;

        while (x < dst.x + dst.w) : (x += 1) {

            const sx = std.math.clamp(@divTrunc((x - rect.x) * src_w, rect.w), 0, src_w - 1);

            back.blend_pixel(x, y, snap.pixels[row + @as(u32, @intCast(sx))], alpha);

        }

    }

}

fn composite() !void {

    // Fold coalesced *glass* drag geometry into the damage list (opaque drags already damag every sample).
    if (drag_id != 0 and drag_moved_since_paint) {

        if (manager.by_id(drag_id)) |window| {

            if (drag_should_coalesce(window)) {

                const now = lib.time.now_ms();
                const due = now -% last_drag_composite_ms >= drag_composite_interval_ms;

                // Rate-limit pure large-glass drag frames so one Files-sized window cannot pin the server.
                // Unrelated damage still forces an immediate pass and takes the drag with it.
                if (due or damage.len != 0) enqueue_drag_paint(window.frame());

            } else {

                drag_moved_since_paint = false;

            }

        }

    }

    if (damage.len == 0) return;

    const pending = damage;
    damage.clear();

    quartz_renderer.set_density(@intFromEnum(lib.prefs.quartz_level));

    // Client pixels may have been written in other processes; publish once before reading any surface.
    draw.fence();

    for (pending.rects[0..pending.len]) |region| {

        // One frost/morph margin for sampling — applied here only (not stacked with add_*).
        const density: u8 = @intFromEnum(lib.prefs.quartz_level);
        const paint_region = if (lib.prefs.quartz_enabled() and quartz_renderer.ready())
            region.inset(-quartz_effect.damage_halo(density)).intersect(screen_bounds())
        else
            region.intersect(screen_bounds());
        var first: usize = 0;
        var covered = false;

        var search = manager.count;

        while (search > 0) {

            search -= 1;

            const candidate = manager.stacked(search);

            if (candidate.flags & proto.window.flag_minimized != 0) continue;
            if (candidate.flags & proto.window.flag_quartz != 0) continue;
            if (window_hidden(candidate)) continue;
            if (!covers(candidate.content(), paint_region)) continue;
            if (!surfaces.covers(slot_of(candidate), candidate.content(), paint_region)) continue;

            first = search;
            covered = true;
            break;

        }

        if (!covered) back.fill_rect(paint_region, theme.wallpaper);

        var index = first;

        while (index < manager.count) : (index += 1) {

            const window = manager.stacked(index);

            if (window.flags & proto.window.flag_minimized != 0) continue;
            if (window_hidden(window)) continue;
            if (window.frame().intersect(paint_region).is_empty()) continue;

            draw_window(window, paint_region);

        }

        // The resize 'rubber band' rides above every window, and moves always damage its band, so restroking it each pass keeps the fed-back scanout consistent.

        if (resize_id != 0 and !resize_outline.is_empty()) {

            const view = back.clipped(paint_region);

            render.draw_outline(&view, resize_outline, theme.chrome);

        }

        draw_window_anim_overlays(paint_region);

        // Copy the finished band into uncached scanout. Large regions share independent row bands
        // across the compositor helper pool; small damage stays on this thread.

        quartz_effect.blit_scanout(&fb, &back, region);

    }

    draw.fence();

    for (pending.rects[0..pending.len]) |region| {

        _ = try ipc.request(cap.compositor.display, proto.display.flush, &.{

            lib.window.pack_pair(@intCast(region.x), @intCast(region.y)),
            lib.window.pack_pair(@intCast(region.w), @intCast(region.h)),

        }, &.{});

    }

}

fn covers(outer: Rect, inner: Rect) bool {

    if (outer.is_empty() or inner.is_empty()) return false;

    return outer.x <= inner.x and outer.y <= inner.y and outer.x + outer.w >= inner.x + inner.w and outer.y + outer.h >= inner.y + inner.h;

}

fn window_format(window: *const Window) draw.Format {

    return if (window.flags & proto.window.flag_quartz != 0) .alpha else .xrgb;

}

fn draw_window(window: *Window, clip: Rect) void {

    const slot = slot_of(window);
    const view = back.clipped(clip);

    if (window.decorated()) {

        const face: ?*const draw.text.Face = if (title_font) |*f| f else null;
        const focused = manager.focus == window.id;
        const colors = chrome_colors();
        const tint = if (focused) theme.title_focused else theme.title_blurred;
        const opacity: u8 = switch (lib.prefs.quartz_level) {

            .off => 0,
            .light => lib.quartz.material_opacity(.clear),
            .medium => lib.quartz.material_opacity(.regular),
            .dark => lib.quartz.material_opacity(.prominent),

        };

        const joined = window.flags & proto.window.flag_quartz != 0;

        if (!quartz_renderer.composite_header(&back, window.title_bar(), clip, window.id, tint, opacity, render.corner_radius, joined)) {

            render.draw_title_bar(&view, window, focused, colors, face);

        } else {

            render.draw_title_bar_overlay(&view, window, colors, face);

        }

    }

    // A stale surface (the client has not yet reallocated after a resize) is skipped, never misread.

    const surface = surfaces.surface_of(slot) orelse return;

    if (!lib.prefs.quartz_enabled() or window.flags & proto.window.flag_quartz == 0 or !quartz_renderer.composite(&back, &surface, window.content(), clip, window.id)) {

        render.blit_content(&back, window, &surface, clip, theme.border);

    }

    if (window.decorated()) {

        // Grip is idle-only chrome; skip during drag/resize to save a few stroke lines per frame

        if (drag_id == 0 and resize_id == 0) render.draw_resize_grip(&view, window, theme.title_blurred);
        render.draw_frame_border(&view, window, theme.border);

    }

}
