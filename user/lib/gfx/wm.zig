// Window-manager client for taskbar chrome: screen info, window list, focus, and launch helpers.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const app_catalog = @import("../boot/app_catalog.zig");
const bundle_mod = @import("../boot/bundle.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const stream = @import("../io/stream.zig");
const sys = @import("../syscall/sys.zig");

const desktop_mod = @import("desktop.zig");
const icons = @import("icons.zig");
const prefs = @import("prefs.zig");
const window = @import("window.zig");

const Error = sys.Error;
const Handle = cap.Handle;
const WindowInfo = proto.window.WindowInfo;

pub const Screen = struct {

    width: u32,
    height: u32,

};

pub const App = struct {

    program: []const u8,
    title: []const u8,
    description: []const u8,
    icon: []const u8,
    category: []const u8,

};

pub const List = struct {

    connection: *window.Connection,
    info_region: Handle,
    info: [*]WindowInfo,
    list_ready: Handle = 0,
    attached: bool = false,
    subscribed: bool = false,

    pub fn init(connection: *window.Connection, authority: Handle) Error!List {

        const info_region = try sys.create(.region, proto.window.max_windows * @sizeOf(WindowInfo), authority);
        const base = try sys.map(cap.self_space, info_region, 0, sys.read | sys.write);

        return .{

            .connection = connection,
            .info_region = info_region,
            .info = @ptrFromInt(base),

        };

    }

    pub fn subscribe(self: *List) Error!void {

        if (self.subscribed) return;

        const notify = try sys.create(.notification, 0, 0);

        _ = try ipc.request(self.connection.endpoint, proto.window.subscribe_list, &.{}, &.{

            .{ .handle = self.info_region, .move = false },
            .{ .handle = notify, .move = false },

        });

        self.list_ready = notify;
        self.subscribed = true;
        // Subscribe maps compositor-side only; next list still attaches the session buffer.

    }

    pub fn refresh(self: *List, out: []WindowInfo) usize {

        const handles = [_]ipc.HandleSlot{.{ .handle = self.info_region, .move = false }};
        const attach: []const ipc.HandleSlot = if (self.attached) &.{} else &handles;

        const reply = ipc.request(self.connection.endpoint, proto.window.list, &.{}, attach) catch {

            // Session mapping can be missing after subscribe-only setup; retry once with the handle.
            if (!self.attached) return 0;

            self.attached = false;

            const retry = ipc.request(self.connection.endpoint, proto.window.list, &.{}, &handles) catch return 0;

            self.attached = true;

            return copy_info(self, out, retry.data[1]);

        };

        self.attached = true;

        return copy_info(self, out, reply.data[1]);

    }

    fn copy_info(self: *const List, out: []WindowInfo, raw_count: u64) usize {

        const count = @min(@as(usize, @intCast(raw_count)), out.len, proto.window.max_windows);

        for (0..count) |index| {

            out[index] = self.info[index];

        }

        return count;

    }

};

pub fn screen_info(connection: *window.Connection) Error!Screen {

    const reply = try ipc.request(connection.endpoint, proto.window.screen_info, &.{}, &.{});

    return .{

        .width = window.unpack_high(reply.data[1]),
        .height = window.unpack_low(reply.data[1]),

    };

}

pub fn activate(connection: *window.Connection, id: u32) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.activate, &.{id}, &.{});

}

pub fn move_window(connection: *window.Connection, id: u64, x: i32, y: i32) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.move, &.{

        id,
        window.pack_pair(@intCast(@max(0, x)), @intCast(@max(0, y))),

    }, &.{});

}

/// Place a transient surface at content-local coordinates of another window owned by this client.
pub fn place_relative(connection: *window.Connection, id: u64, anchor: u64, x: i32, y: i32) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.place_relative, &.{

        id,
        anchor,
        window.pack_pair(@intCast(@max(0, x)), @intCast(@max(0, y))),

    }, &.{});

}

pub fn minimize(connection: *window.Connection, id: u64) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.minimize, &.{id}, &.{});

}

pub fn restore(connection: *window.Connection, id: u64) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.restore, &.{id}, &.{});

}

/// Tell the compositor where a window's taskbar indicator sits, so minimize can jump toward it.
pub fn minimize_hint(connection: *window.Connection, id: u64, local_x: i32) Error!void {

    _ = try ipc.request(connection.endpoint, proto.window.minimize_hint, &.{

        id,
        @intCast(@max(0, local_x)),

    }, &.{});

}

pub fn activate_title(connection: *window.Connection, title: []const u8) Error!void {

    const title_words = window.pack_title(title);

    _ = try ipc.request(connection.endpoint, proto.window.activate_title, &.{ title_words[0], title_words[1], title_words[2] }, &.{});

}

pub fn close_title(connection: *window.Connection, title: []const u8) Error!void {

    const title_words = window.pack_title(title);

    _ = try ipc.request(connection.endpoint, proto.window.close_title, &.{ title_words[0], title_words[1], title_words[2] }, &.{});

}

pub fn load_apps(bundle: *const bundle_mod.Bundle, out: []App) usize {

    const bytes = bundle.find("app-catalog") orelse return 0;
    const catalog = app_catalog.Catalog.open(bytes) catch return 0;

    var written: usize = 0;
    var index: usize = 0;

    while (index < catalog.desktop_count and written < out.len) : (index += 1) {

        const entry = catalog.desktop(index) orelse continue;

        out[written] = .{

            .program = entry.program,
            .title = entry.title,
            .description = entry.description,
            .icon = icon_by_name(entry.icon),
            .category = entry.category,

        };

        written += 1;

    }

    return written;

}

pub fn open_catalog(bundle: *const bundle_mod.Bundle) ?app_catalog.Catalog {

    const bytes = bundle.find("app-catalog") orelse return null;

    return app_catalog.Catalog.open(bytes) catch null;

}

pub fn icon_by_name(name: []const u8) []const u8 {

    if (std.mem.eql(u8, name, "folder")) return icons.folder;
    if (std.mem.eql(u8, name, "file")) return icons.file;
    if (std.mem.eql(u8, name, "chart")) return icons.chart;
    if (std.mem.eql(u8, name, "terminal")) return icons.terminal;
    if (std.mem.eql(u8, name, "network")) return icons.network;
    if (std.mem.eql(u8, name, "home")) return icons.home;
    if (std.mem.eql(u8, name, "search")) return icons.search;
    if (std.mem.eql(u8, name, "clock")) return icons.clock;
    if (std.mem.eql(u8, name, "cpu")) return icons.cpu;
    if (std.mem.eql(u8, name, "disk")) return icons.disk;
    if (std.mem.eql(u8, name, "memory")) return icons.memory;
    if (std.mem.eql(u8, name, "settings")) return icons.apps;
    if (std.mem.eql(u8, name, "calculator")) return icons.calculator;
    if (std.mem.eql(u8, name, "timer")) return icons.timer;
    if (std.mem.eql(u8, name, "paint")) return icons.paint;
    if (std.mem.eql(u8, name, "image")) return icons.image;
    if (std.mem.eql(u8, name, "music")) return icons.music;
    if (std.mem.eql(u8, name, "weather")) return icons.weather_app;
    return icons.apps;

}

/// Ask the launcher server to start a bundled desktop program by name.
pub fn launch(program: []const u8) void {

    const endpoint = stream.lookup_endpoint("launch") catch return;

    var words = [_]u64{ program.len, 0, 0, 0, 0 };
    var packed_name = [_]u8{0} ** proto.launch.max_length;

    const length = @min(program.len, packed_name.len);
    @memcpy(packed_name[0..length], program[0..length]);

    for (0..4) |index| {

        words[index + 1] = std.mem.readInt(u64, packed_name[index * 8 ..][0..8], .little);

    }

    _ = ipc.request(endpoint, proto.launch.spawn, &words, &.{}) catch {};

}

/// Stage a file path for the next program launch, then spawn it (used by the file manager to open Notepad).
pub fn launch_with_path(program: []const u8, path: []const u8) void {

    prefs.write_open_path(path);
    launch(program);

}

/// Convenience for GUI programs: open the bundle, connect to the compositor, and return both.
pub fn boot(authority: Handle) Error!struct { bundle: bundle_mod.Bundle, connection: window.Connection } {

    const bundle = try desktop_mod.open_bundle();

    return .{

        .bundle = bundle,
        .connection = try desktop_mod.connect(authority),

    };

}
