// Client side of the Window interface (07-userspace-ddd.md Section 10.7)

const std = @import("std");

const cap = @import("../cap/cap.zig");
const clipboard = @import("../clipboard.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

const events = @import("events.zig");
const gfx = @import("../draw/draw.zig");

const Handle = cap.Handle;
const Error = sys.Error;

const ring_capacity = 256;
const max_tracked = 8;

const Tracked = struct {

    used: bool = false,
    id: u64 = 0,
    endpoint: Handle = 0,
    region: Handle = 0,
    base: usize = 0,

};

var tracked: [max_tracked]Tracked = [_]Tracked{.{}} ** max_tracked;

fn register(window: *const Window) void {

    for (&tracked) |*entry| {

        if (entry.used) continue;

        entry.* = .{

            .used = true,
            .id = window.id,
            .endpoint = window.connection.endpoint,
            .region = window.region,
            .base = window.base,

        };

        return;

    }

}

fn unregister(id: u64) void {

    for (&tracked) |*entry| {

        if (entry.used and entry.id == id) {

            entry.* = .{};

            return;

        }

    }

}

fn release_surface(region: Handle, base: usize) void {

    gfx.select.forget(base);

    sys.unmap(cap.self_space, base) catch {};
    sys.close(region) catch {};

}

fn covers_surface(rect: gfx.Rect, bounds: gfx.Rect) bool {

    return rect.x <= bounds.x and rect.y <= bounds.y and
        rect.x + rect.w >= bounds.x + bounds.w and rect.y + rect.h >= bounds.y + bounds.h;

}

var published_caret = gfx.Rect.empty;

fn surface_of(id: u32) ?usize {

    for (&tracked) |*entry| {

        if (entry.used and entry.id == id) return entry.base;

    }

    return null;

}

const key_leftctrl: u16 = 29;
const key_rightctrl: u16 = 97;
const key_c: u16 = 46;
const key_esc: u16 = 1;

var ctrl_held = false;

/// Feed a window event to the global text selection; true when the app should repaint.
/// Apps call this alongside their own handling: a press only arms a drag, so clicks still land,
/// and Ctrl+C here copies screen text that belongs to no editable field.
pub fn text_selection(event: events.Event) bool {

    if (event.kind == events.kind_key_down or event.kind == events.kind_key_up) {

        const down = event.kind == events.kind_key_down;

        if (event.code == key_leftctrl or event.code == key_rightctrl) {

            ctrl_held = down;

            return false;

        }

        if (!down) return false;

        if (event.code == key_esc) return gfx.select.clear();

        if (event.code == key_c and ctrl_held and gfx.select.has_selection()) {

            var text: [clipboard.max_entry]u8 = undefined;

            clipboard.copy(gfx.select.selection(&text));

        }

        return false;

    }

    const owner = surface_of(event.window) orelse return false;

    return switch (event.kind) {

        events.kind_button_down => if (event.code == events.button_left) gfx.select.press(owner, event.x, event.y) else false,
        events.kind_pointer_move => gfx.select.drag(owner, event.x, event.y),

        events.kind_button_up => {

            gfx.select.release();

            return false;

        },

        events.kind_window_blur => gfx.select.clear(),

        else => false,

    };

}

fn teardown(entry: *Tracked) void {

    _ = ipc.request(entry.endpoint, proto.window.destroy, &.{entry.id}, &.{}) catch {};

    release_surface(entry.region, entry.base);

    entry.* = .{};

}

/// Destroy tracked windows on exit so surfaces and launcher memory are reclaimed if the app forgets.
pub fn shutdown_all() void {

    for (&tracked) |*entry| {

        if (!entry.used) continue;

        teardown(entry);

    }

}

pub const Connection = struct {

    endpoint: Handle,
    ready: Handle,
    ring: events.Ring,
    authority: Handle,

    /// Resolve the compositor through the name service and attach the event ring.
    pub fn connect(authority: Handle) Error!Connection {

        return open(try stream.lookup_endpoint("window"), authority);

    }

    pub fn open(endpoint: Handle, authority: Handle) Error!Connection {

        const region = try sys.create(.region, events.ring_bytes(ring_capacity), authority);
        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
        const ready = try sys.create(.notification, 0, 0);

        const ring = events.Ring.init(base, ring_capacity);

        _ = try ipc.request(endpoint, proto.window.attach_events, &.{ring_capacity}, &.{

            .{ .handle = region, .move = false },
            .{ .handle = ready, .move = false },

        });

        return .{

            .endpoint = endpoint,
            .ready = ready,
            .ring = ring,
            .authority = authority,

        };

    }

    pub fn create_window(self: *Connection, width: u32, height: u32, flags: u64, title: []const u8) Error!Window {

        const packed_title = pack_title(title);

        const reply = try ipc.request(self.endpoint, proto.window.create, &.{

            pack_pair(width, height),
            flags,
            packed_title[0],
            packed_title[1],
            packed_title[2],

        }, &.{});

        if (reply.handle_count < 1) return error.Invalid;

        var window = try Window.from_reply(self, reply.data[1], flags, &reply);

        register(&window);

        return window;

    }

    /// Block until the compositor pushes an event.
    pub fn wait_event(self: *Connection) Error!events.Event {

        while (true) {

            if (self.ring.pop()) |event| return event;

            _ = try sys.wait(self.ready);

        }

    }

    pub fn poll_event(self: *Connection) ?events.Event {

        return self.ring.pop();

    }

};

pub const Window = struct {

    connection: *Connection,
    id: u64,
    flags: u64,

    surface: gfx.Surface,
    region: Handle,
    base: usize,

    fn from_reply(connection: *Connection, id: u64, flags: u64, reply: *const ipc.Message) Error!Window {

        const width: u32 = @intCast(reply.data[2] >> 32);
        const height: u32 = @truncate(reply.data[2]);
        const stride: u32 = @intCast(reply.data[3]);

        const region = reply.handles[0].handle;
        const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);
        const format: gfx.Format = if (flags & proto.window.flag_backdrop != 0) .alpha else .xrgb;
        const surface = gfx.Surface.from_base_format(base, width, height, stride, format);

        return .{

            .connection = connection,
            .id = id,
            .flags = flags,

            .surface = surface,
            .region = region,
            .base = base,

        };

    }

    pub fn present(self: *const Window, rect: gfx.Rect) Error!void {

        gfx.fence();

        // Only a whole-surface present retires the window's captured text runs and its caret; a
        // partial repaint redraws part of them and would otherwise drop the rest of the selection.
        if (covers_surface(rect, self.surface.bounds())) {

            gfx.select.end_frame(@intFromPtr(self.surface.pixels));

            self.publish_caret();

            gfx.select.caret = gfx.Rect.empty;

        }

        _ = try ipc.request(self.connection.endpoint, proto.window.present, &.{

            self.id,
            pack_pair(@intCast(@max(0, rect.x)), @intCast(@max(0, rect.y))),
            pack_pair(@intCast(@max(0, rect.w)), @intCast(@max(0, rect.h))),

        }, &.{});

    }

    pub fn present_all(self: *const Window) Error!void {

        try self.present(self.surface.bounds());

    }

    /// Tell the compositor where this window's caret sits, so popups can anchor to the insertion point.
    fn publish_caret(self: *const Window) void {

        const caret = gfx.select.caret;

        // An empty rect is published too: it is how a window says its caret went away.
        if (std.meta.eql(caret, published_caret)) return;

        published_caret = caret;

        _ = ipc.request(self.connection.endpoint, proto.window.set_caret, &.{

            self.id,
            pack_pair(@intCast(@max(0, caret.x)), @intCast(@max(0, caret.y))),
            pack_pair(@intCast(@max(0, caret.w)), @intCast(@max(0, caret.h))),

        }, &.{}) catch {};

    }

    pub fn set_title(self: *const Window, title: []const u8) Error!void {

        const packed_title = pack_title(title);

        _ = try ipc.request(self.connection.endpoint, proto.window.set_title, &.{

            self.id,
            0,
            packed_title[0],
            packed_title[1],
            packed_title[2],

        }, &.{});

    }

    /// Swap the surface for a new size (a fullscreen client following a mode change); the old mapping is released.
    pub fn resize(self: *Window, width: u32, height: u32) Error!void {

        const reply = try ipc.request(self.connection.endpoint, proto.window.resize, &.{

            self.id,
            pack_pair(width, height),

        }, &.{});

        if (reply.handle_count < 1) return error.Invalid;

        unregister(self.id);
        release_surface(self.region, self.base);

        const replaced = try Window.from_reply(self.connection, self.id, self.flags, &reply);

        self.surface = replaced.surface;
        self.region = replaced.region;
        self.base = replaced.base;

        register(self);

    }

    pub fn destroy(self: *Window) void {

        unregister(self.id);

        _ = ipc.request(self.connection.endpoint, proto.window.destroy, &.{self.id}, &.{}) catch {};

        release_surface(self.region, self.base);

    }

};

pub fn pack_pair(high: u32, low: u32) u64 {

    return (@as(u64, high) << 32) | low;

}

pub fn unpack_high(pair: u64) u32 {

    return @intCast(pair >> 32);

}

pub fn unpack_low(pair: u64) u32 {

    return @truncate(pair);

}

/// NUL-padded title in three message words (proto.window.max_title bytes).
pub fn pack_title(title: []const u8) [3]u64 {

    var bytes = [_]u8{0} ** proto.window.max_title;
    const length = @min(title.len, bytes.len);

    @memcpy(bytes[0..length], title[0..length]);

    var words: [3]u64 = undefined;

    for (&words, 0..) |*word, index| {

        word.* = std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little);

    }

    return words;

}

pub fn unpack_title(words: [3]u64, out: *[proto.window.max_title]u8) []const u8 {

    for (words, 0..) |word, index| {

        std.mem.writeInt(u64, out[index * 8 ..][0..8], word, .little);

    }

    var length: usize = 0;

    while (length < out.len and out[length] != 0) : (length += 1) {}

    return out[0..length];

}

const testing = std.testing;

test "titles round-trip through their message words" {

    var out: [proto.window.max_title]u8 = undefined;

    const words = pack_title("GraniteOS 2");

    try testing.expectEqualStrings("GraniteOS 2", unpack_title(words, &out));

    const clipped = pack_title("a title far too long to fit in twenty-four bytes");

    try testing.expectEqual(@as(usize, proto.window.max_title), unpack_title(clipped, &out).len);

}

test "pair packing round-trips" {

    const pair = pack_pair(1280, 800);

    try testing.expectEqual(@as(u32, 1280), unpack_high(pair));
    try testing.expectEqual(@as(u32, 800), unpack_low(pair));

}
