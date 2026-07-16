// Desktop preferences: theme palettes and a small config file on disk.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const gfx = @import("../draw/draw.zig");
const fs = @import("../fs/fs.zig");
const ipc = @import("../ipc/ipc.zig");
const proto = @import("../ipc/proto.zig");
const ui = @import("../ui/ui.zig");
const events = @import("events.zig");
const window = @import("window.zig");

const Color = gfx.Color;

pub const config_path = "/root/user/settings.cfg";
pub const open_path_file = "/root/user/.open-path";
pub const desktop_pins_path = "/root/user/desktop.pins";
pub const taskbar_pins_path = "/root/user/taskbar.pins";

pub const max_desktop_pins = 24;
pub const max_pin_path = 128;

pub const max_taskbar_pins = 16;
pub const max_pin_program = 32; // matches proto.launch.max_length

pub const ThemeId = enum(u8) {

    mono,
    ocean,
    forest,
    sunset,
    grape,

};

pub const theme_count: usize = 5;

pub const theme_names = [_][]const u8{

    "Monochrome",
    "Ocean",
    "Forest",
    "Sunset",
    "Grape",

};

pub const Chrome = struct {

    wallpaper: Color,
    title_focused: Color,
    title_blurred: Color,
    chrome: Color,
    border: Color,

};

pub var active_theme: ThemeId = .mono;
pub var tz_offset_minutes: i32 = 0;

pub const QuartzLevel = enum(u8) {

    off = 0,
    light = 1,
    medium = 2,
    dark = 3,

};

pub const quartz_level_count: usize = 4;

pub const quartz_level_names = [_][]const u8{

    "Off",
    "Light",
    "Medium",
    "Dark",

};

pub var quartz_level: QuartzLevel = .medium;

/// Display unit for weather temperatures (stored in Celsius from the API).
pub const TempUnit = enum(u8) {

    celsius = 0,
    fahrenheit = 1,

};

pub var temp_unit: TempUnit = .celsius;

var loaded_generation: u64 = 0;

const Palette = struct {

    window_bg: Color,
    surface: Color,
    surface_alt: Color,
    border: Color,
    hover: Color,
    active: Color,
    accent: Color,
    accent_dim: Color,
    text: Color,
    text_dim: Color,
    text_faint: Color,
    good: Color,
    warn: Color,
    wallpaper: Color,

};

const palettes = [_]Palette{

    .{

        .window_bg = gfx.rgb(30, 30, 30),
        .surface = gfx.rgb(38, 38, 38),
        .surface_alt = gfx.rgb(46, 46, 46),
        .border = gfx.rgb(58, 58, 58),
        .hover = gfx.rgb(52, 52, 52),
        .active = gfx.rgb(70, 70, 70),
        .accent = gfx.rgb(200, 200, 200),
        .accent_dim = gfx.rgb(100, 100, 100),
        .text = gfx.rgb(230, 230, 230),
        .text_dim = gfx.rgb(160, 160, 160),
        .text_faint = gfx.rgb(110, 110, 110),
        .good = gfx.rgb(190, 190, 190),
        .warn = gfx.rgb(140, 140, 140),
        .wallpaper = gfx.rgb(22, 22, 22),

    },

    .{

        .window_bg = gfx.rgb(18, 28, 42),
        .surface = gfx.rgb(24, 36, 54),
        .surface_alt = gfx.rgb(30, 44, 64),
        .border = gfx.rgb(48, 72, 98),
        .hover = gfx.rgb(34, 52, 76),
        .active = gfx.rgb(52, 88, 120),
        .accent = gfx.rgb(120, 190, 255),
        .accent_dim = gfx.rgb(60, 110, 170),
        .text = gfx.rgb(220, 235, 255),
        .text_dim = gfx.rgb(150, 180, 210),
        .text_faint = gfx.rgb(100, 130, 160),
        .good = gfx.rgb(100, 200, 180),
        .warn = gfx.rgb(220, 170, 90),
        .wallpaper = gfx.rgb(14, 22, 34),

    },

    .{

        .window_bg = gfx.rgb(18, 32, 22),
        .surface = gfx.rgb(24, 40, 28),
        .surface_alt = gfx.rgb(30, 48, 34),
        .border = gfx.rgb(48, 78, 54),
        .hover = gfx.rgb(34, 56, 40),
        .active = gfx.rgb(52, 90, 60),
        .accent = gfx.rgb(120, 220, 140),
        .accent_dim = gfx.rgb(70, 140, 90),
        .text = gfx.rgb(220, 245, 225),
        .text_dim = gfx.rgb(150, 190, 160),
        .text_faint = gfx.rgb(100, 140, 110),
        .good = gfx.rgb(140, 230, 160),
        .warn = gfx.rgb(200, 180, 90),
        .wallpaper = gfx.rgb(12, 24, 16),

    },

    .{

        .window_bg = gfx.rgb(38, 24, 18),
        .surface = gfx.rgb(48, 30, 22),
        .surface_alt = gfx.rgb(58, 36, 26),
        .border = gfx.rgb(90, 58, 42),
        .hover = gfx.rgb(68, 42, 30),
        .active = gfx.rgb(110, 68, 48),
        .accent = gfx.rgb(255, 170, 100),
        .accent_dim = gfx.rgb(180, 110, 60),
        .text = gfx.rgb(255, 235, 220),
        .text_dim = gfx.rgb(210, 170, 140),
        .text_faint = gfx.rgb(160, 120, 90),
        .good = gfx.rgb(200, 220, 120),
        .warn = gfx.rgb(255, 140, 90),
        .wallpaper = gfx.rgb(28, 16, 12),

    },

    .{

        .window_bg = gfx.rgb(28, 20, 38),
        .surface = gfx.rgb(36, 26, 48),
        .surface_alt = gfx.rgb(44, 32, 58),
        .border = gfx.rgb(72, 54, 96),
        .hover = gfx.rgb(50, 36, 68),
        .active = gfx.rgb(80, 58, 110),
        .accent = gfx.rgb(190, 140, 255),
        .accent_dim = gfx.rgb(120, 80, 180),
        .text = gfx.rgb(240, 230, 255),
        .text_dim = gfx.rgb(180, 160, 210),
        .text_faint = gfx.rgb(130, 110, 160),
        .good = gfx.rgb(160, 220, 180),
        .warn = gfx.rgb(230, 160, 200),
        .wallpaper = gfx.rgb(20, 14, 30),

    },

};

pub fn wallpaper() Color {

    return palettes[@intFromEnum(active_theme)].wallpaper;

}

/// On-disk / source path for the single wallpaper set (one PNG per theme).
pub const wallpaper_dir = "/root/user/images/wallpaper/default";

/// File stem for the active theme's wallpaper PNG (matches files under wallpaper_dir).
pub fn wallpaper_file_stem(id: ThemeId) []const u8 {

    return switch (id) {

        .mono => "monochrome",
        .ocean => "ocean",
        .forest => "forest",
        .sunset => "sunset",
        .grape => "grape",

    };

}

/// Module-bundle name for the theme wallpaper (`wp-<stem>`).
pub fn wallpaper_bundle_name(id: ThemeId) []const u8 {

    return switch (id) {

        .mono => "wp-monochrome",
        .ocean => "wp-ocean",
        .forest => "wp-forest",
        .sunset => "wp-sunset",
        .grape => "wp-grape",

    };

}

pub fn chrome() Chrome {

    const palette = palettes[@intFromEnum(active_theme)];

    return .{

        .wallpaper = palette.wallpaper,
        .title_focused = palette.surface_alt,
        .title_blurred = palette.surface,
        .chrome = palette.text,
        .border = palette.border,

    };

}

pub fn apply_theme(id: ThemeId) void {

    active_theme = id;

    const palette = palettes[@intFromEnum(id)];

    ui.theme.window_bg = palette.window_bg;
    ui.theme.surface = palette.surface;
    ui.theme.surface_alt = palette.surface_alt;
    ui.theme.border = palette.border;
    ui.theme.hover = palette.hover;
    ui.theme.active = palette.active;
    ui.theme.accent = palette.accent;
    ui.theme.accent_dim = palette.accent_dim;
    ui.theme.text = palette.text;
    ui.theme.text_dim = palette.text_dim;
    ui.theme.text_faint = palette.text_faint;
    ui.theme.good = palette.good;
    ui.theme.warn = palette.warn;
    ui.theme.wallpaper = palette.wallpaper;

}

/// Reload settings from disk when the on-disk generation changes.
pub fn refresh_if_changed() bool {

    var client = fs.Client.connect(cap.memory) catch return false;
    defer client.close();

    const file = client.open_path(config_path, 0) catch return false;
    defer client.close_file(file) catch {};

    var buffer: [256]u8 = undefined;
    const read = client.read(file, 0, &buffer) catch return false;

    const generation = config_generation(buffer[0..read]);

    if (generation != 0 and generation == loaded_generation) return false;

    parse_config(buffer[0..read]);
    loaded_generation = generation;

    return true;

}

/// Always re-reads and re-parses settings.cfg (ignores the generation short-circuit).
pub fn force_reload() bool {

    var client = fs.Client.connect(cap.memory) catch return false;
    defer client.close();

    const file = client.open_path(config_path, 0) catch return false;
    defer client.close_file(file) catch {};

    var buffer: [256]u8 = undefined;
    const read = client.read(file, 0, &buffer) catch return false;

    parse_config(buffer[0..read]);
    loaded_generation = config_generation(buffer[0..read]);

    return true;

}

/// Reload from disk when the on-disk generation changes; keeps the current theme when missing.
pub fn refresh() void {

    _ = refresh_if_changed();

}

pub fn save() void {

    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    var buffer: [160]u8 = undefined;
    const stamp = loaded_generation +% 1;
    const text = std.fmt.bufPrint(&buffer, "theme={d}\ntz={d}\ntemp={d}\nquartz={d}\nstamp={d}\n", .{

        @intFromEnum(active_theme),
        tz_offset_minutes,
        @intFromEnum(temp_unit),
        @intFromEnum(quartz_level),
        stamp,

    }) catch return;

    if (client.open_path(config_path, 0)) |file| {

        defer client.close_file(file) catch {};

        if ((client.write(file, 0, text) catch 0) > 0) loaded_generation = stamp;

        return;

    } else |_| {}

    client.create(config_path, proto.filesystem.kind_file) catch return;

    const file = client.open_path(config_path, 0) catch return;
    defer client.close_file(file) catch {};

    if ((client.write(file, 0, text) catch 0) > 0) loaded_generation = stamp;

}

/// Ask the compositor to broadcast prefs_changed to every connected GUI client.
pub fn broadcast_change(connection: *window.Connection) void {

    _ = ipc.request(connection.endpoint, proto.window.notify_prefs, &.{}, &.{}) catch {};

}

/// Pack the live preferences into the prefs_changed record the compositor broadcasts
pub fn changed_event() events.Event {

    const bits: u64 =
        @as(u64, @intFromEnum(active_theme)) |
        (@as(u64, @intFromEnum(quartz_level)) << 8) |
        (@as(u64, @intFromEnum(temp_unit)) << 16);

    return .{

        .kind = events.kind_prefs_changed,
        .code = 0,
        .window = 0,

        .x = tz_offset_minutes,
        .y = 0,

        .value = @bitCast(bits),

    };

}

/// The single client-side entry point for a prefs update
pub fn apply_event(event: events.Event) bool {

    if (event.kind != events.kind_prefs_changed) return false;

    const bits: u64 = @bitCast(event.value);
    const theme_value: u8 = @truncate(bits & 0xff);
    const quartz_value: u8 = @truncate((bits >> 8) & 0xff);
    const temp_value: u8 = @truncate((bits >> 16) & 0xff);

    if (theme_value < theme_count) apply_theme(@enumFromInt(theme_value));
    if (quartz_value < quartz_level_count) quartz_level = @enumFromInt(quartz_value);
    if (temp_value <= @intFromEnum(TempUnit.fahrenheit)) temp_unit = @enumFromInt(temp_value);

    tz_offset_minutes = event.x;

    return true;

}

pub fn write_open_path(path: []const u8) void {

    var client = fs.Client.connect(cap.memory) catch return;
    defer client.close();

    _ = client.delete(open_path_file) catch {};
    _ = client.create(open_path_file, @import("../ipc/proto.zig").filesystem.kind_file) catch return;

    const file = client.open_path(open_path_file, 0) catch return;
    defer client.close_file(file) catch {};

    _ = client.write(file, 0, path) catch {};

}

pub fn take_open_path(out: []u8) ?[]const u8 {

    var client = fs.Client.connect(cap.memory) catch return null;
    defer client.close();

    const file = client.open_path(open_path_file, 0) catch return null;
    defer client.close_file(file) catch {};

    const read = client.read(file, 0, out) catch return null;

    _ = client.delete(open_path_file) catch {};

    if (read == 0) return null;

    return out[0..read];

}

pub const DesktopPin = struct {

    path: [max_pin_path]u8 = [_]u8{0} ** max_pin_path,
    length: u8 = 0,

    pub fn slice(self: *const DesktopPin) []const u8 {

        return self.path[0..self.length];

    }

};

/// Load desktop shortcut paths (one absolute path per line) into `out`; returns the count.
pub fn load_desktop_pins(out: []DesktopPin) usize {

    var client = fs.Client.connect(cap.memory) catch return 0;
    defer client.close();

    const file = client.open_path(desktop_pins_path, 0) catch return 0;
    defer client.close_file(file) catch {};

    var buffer: [max_desktop_pins * (max_pin_path + 1)]u8 = undefined;
    const read = client.read(file, 0, &buffer) catch return 0;

    var written: usize = 0;
    var start: usize = 0;
    var index: usize = 0;

    while (index <= read and written < out.len) : (index += 1) {

        const at_end = index == read;
        const sep = if (at_end) true else buffer[index] == '\n' or buffer[index] == '\r';

        if (!sep) continue;

        const line = buffer[start..index];
        start = index + 1;

        if (line.len == 0 or line[0] != '/') continue;

        const length = @min(line.len, max_pin_path);

        out[written] = .{};
        @memcpy(out[written].path[0..length], line[0..length]);
        out[written].length = @intCast(length);
        written += 1;

    }

    return written;

}

/// Append `path` to the desktop pin list when it is not already present.
pub fn add_desktop_pin(path: []const u8) bool {

    if (path.len == 0 or path[0] != '/') return false;

    var pins: [max_desktop_pins]DesktopPin = undefined;
    const count = load_desktop_pins(pins[0..]);

    for (pins[0..count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), path)) return true;

    }

    if (count >= max_desktop_pins) return false;

    pins[count] = .{};
    const length = @min(path.len, max_pin_path);
    @memcpy(pins[count].path[0..length], path[0..length]);
    pins[count].length = @intCast(length);

    return save_desktop_pins(pins[0 .. count + 1]);

}

/// Remove `path` from the desktop pin list.
pub fn remove_desktop_pin(path: []const u8) bool {

    var pins: [max_desktop_pins]DesktopPin = undefined;
    const count = load_desktop_pins(pins[0..]);
    var written: usize = 0;
    var changed = false;

    for (pins[0..count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), path)) {

            changed = true;
            continue;

        }

        pins[written] = pin;
        written += 1;

    }

    if (!changed) return false;

    return save_desktop_pins(pins[0..written]);

}

fn save_desktop_pins(pins: []const DesktopPin) bool {

    var client = fs.Client.connect(cap.memory) catch return false;
    defer client.close();

    var buffer: [max_desktop_pins * (max_pin_path + 1)]u8 = undefined;
    var length: usize = 0;

    for (pins) |pin| {

        const slice = pin.slice();

        if (length + slice.len + 1 > buffer.len) break;

        @memcpy(buffer[length .. length + slice.len], slice);
        length += slice.len;
        buffer[length] = '\n';
        length += 1;

    }

    _ = client.delete(desktop_pins_path) catch {};
    client.create(desktop_pins_path, proto.filesystem.kind_file) catch return false;

    const file = client.open_path(desktop_pins_path, 0) catch return false;
    defer client.close_file(file) catch {};

    return (client.write(file, 0, buffer[0..length]) catch 0) == length;

}

pub const TaskbarPin = struct {

    program: [max_pin_program]u8 = [_]u8{0} ** max_pin_program,
    length: u8 = 0,

    pub fn slice(self: *const TaskbarPin) []const u8 {

        return self.program[0..self.length];

    }

};

/// Load pinned taskbar program names (one per line) into `out`; returns the count.
pub fn load_taskbar_pins(out: []TaskbarPin) usize {

    var client = fs.Client.connect(cap.memory) catch return 0;
    defer client.close();

    const file = client.open_path(taskbar_pins_path, 0) catch return 0;
    defer client.close_file(file) catch {};

    var buffer: [max_taskbar_pins * (max_pin_program + 1)]u8 = undefined;
    const read = client.read(file, 0, &buffer) catch return 0;

    var written: usize = 0;
    var start: usize = 0;
    var index: usize = 0;

    while (index <= read and written < out.len) : (index += 1) {

        const at_end = index == read;
        const sep = if (at_end) true else buffer[index] == '\n' or buffer[index] == '\r';

        if (!sep) continue;

        const line = buffer[start..index];
        start = index + 1;

        if (line.len == 0) continue;

        const length = @min(line.len, max_pin_program);

        out[written] = .{};
        @memcpy(out[written].program[0..length], line[0..length]);
        out[written].length = @intCast(length);
        written += 1;

    }

    return written;

}

pub fn is_taskbar_pinned(program: []const u8) bool {

    var pins: [max_taskbar_pins]TaskbarPin = undefined;
    const count = load_taskbar_pins(pins[0..]);

    for (pins[0..count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), program)) return true;

    }

    return false;

}

/// Overwrites the on-disk taskbar pin list with exactly `pins`. Good for avoiding duplicates and keeping the order of pins consistent with the taskbar.
pub fn save_taskbar_pins(pins: []const TaskbarPin) bool {

    var client = fs.Client.connect(cap.memory) catch return false;
    defer client.close();

    var buffer: [max_taskbar_pins * (max_pin_program + 1)]u8 = undefined;
    var length: usize = 0;

    for (pins) |pin| {

        const slice = pin.slice();

        if (length + slice.len + 1 > buffer.len) break;

        @memcpy(buffer[length .. length + slice.len], slice);
        length += slice.len;
        buffer[length] = '\n';
        length += 1;

    }

    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = client.open_path(taskbar_pins_path, flags) catch return false;
    defer client.close_file(file) catch {};

    return (client.write(file, 0, buffer[0..length]) catch 0) == length;

}

fn config_generation(text: []const u8) u64 {

    var lines = std.mem.tokenizeScalar(u8, text, '\n');

    while (lines.next()) |line| {

        if (std.mem.startsWith(u8, line, "stamp=")) {

            return std.fmt.parseInt(u64, line[6..], 10) catch 0;

        }

    }

    var hash: u64 = 0;

    for (text) |byte| hash = hash *% 33 +% byte;

    return if (hash == 0) 1 else hash;

}

fn parse_config(text: []const u8) void {

    var lines = std.mem.tokenizeScalar(u8, text, '\n');

    while (lines.next()) |line| {

        if (std.mem.startsWith(u8, line, "theme=")) {

            const value = std.fmt.parseInt(u8, line[6..], 10) catch continue;

            if (value < theme_count) apply_theme(@enumFromInt(value));

        } else if (std.mem.startsWith(u8, line, "tz=")) {

            tz_offset_minutes = std.fmt.parseInt(i32, line[3..], 10) catch tz_offset_minutes;

        } else if (std.mem.startsWith(u8, line, "temp=")) {

            const value = std.fmt.parseInt(u8, line[5..], 10) catch continue;

            if (value <= @intFromEnum(TempUnit.fahrenheit)) temp_unit = @enumFromInt(value);

        } else if (std.mem.startsWith(u8, line, "quartz=")) {

            const value = std.fmt.parseInt(u8, line[7..], 10) catch continue;

            if (value < quartz_level_count) quartz_level = @enumFromInt(value);

        }

    }

}
