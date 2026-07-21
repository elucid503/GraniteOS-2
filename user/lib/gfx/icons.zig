// Lucide outline icons (ISC). Path data is embedded; rasterization is lazy via the vector cache.

const std = @import("std");

// Embed a Lucide SVG by file stem (relative to this source file).
fn lucide(comptime stem: []const u8) []const u8 {

    return @embedFile("../icons/lucide/" ++ stem ++ ".svg");

}

// Named exports keep call sites stable; each is a Lucide asset.

pub const apps = lucide("layout-grid");
pub const category = lucide("tag");
pub const folder = lucide("folder");
pub const folder_plus = lucide("folder-plus");
pub const file = lucide("file");
pub const file_up = lucide("file-up");
pub const file_down = lucide("file-down");
pub const chart = lucide("trending-up");
pub const terminal = lucide("terminal");
pub const network = lucide("globe");
pub const home = lucide("house");
pub const arrow_up = lucide("arrow-up");
pub const search = lucide("search");
pub const clock = lucide("clock");
pub const calendar = lucide("calendar");
pub const bell = lucide("bell");
pub const cpu = lucide("cpu");
pub const disk = lucide("hard-drive");
pub const memory = lucide("memory-stick");
pub const calculator = lucide("calculator");
pub const timer = lucide("timer");
pub const paint = lucide("paintbrush");
pub const image = lucide("image");
pub const music = lucide("music");
pub const settings = lucide("settings");
pub const pointer = lucide("mouse-pointer-2");
pub const hand = lucide("hand");
pub const text_cursor = lucide("text-cursor");
pub const refresh_cw = lucide("refresh-cw");
pub const log_out = lucide("log-out");
pub const users = lucide("users");

// Weather (WMO codes from Open-Meteo current_weather.weathercode).

pub const weather_clear = lucide("sun");
pub const weather_clear_night = lucide("moon");
pub const weather_partly = lucide("cloud-sun");
pub const weather_partly_night = lucide("cloud-moon");
pub const weather_cloud = lucide("cloud");
pub const weather_fog = lucide("cloud-fog");
pub const weather_rain = lucide("cloud-rain");
pub const weather_snow = lucide("cloud-snow");
pub const weather_storm = lucide("cloud-lightning");
pub const weather_app = lucide("cloud-sun");

pub const wind = lucide("wind");
pub const droplet = lucide("droplet");
pub const gauge = lucide("gauge");
pub const thermometer = lucide("thermometer");
pub const umbrella = lucide("umbrella");
pub const sunrise = lucide("sunrise");
pub const sunset = lucide("sunset");
pub const uv = lucide("sun");

const Entry = struct {

    name: []const u8,
    svg: []const u8,

};

// Catalog names used by app metadata and the launcher; only these participate in by-name lookup.
const catalog = [_]Entry{

    .{ .name = "apps", .svg = apps },
    .{ .name = "folder", .svg = folder },
    .{ .name = "file", .svg = file },
    .{ .name = "chart", .svg = chart },
    .{ .name = "terminal", .svg = terminal },
    .{ .name = "network", .svg = network },
    .{ .name = "home", .svg = home },
    .{ .name = "search", .svg = search },
    .{ .name = "clock", .svg = clock },
    .{ .name = "calendar", .svg = calendar },
    .{ .name = "cpu", .svg = cpu },
    .{ .name = "disk", .svg = disk },
    .{ .name = "memory", .svg = memory },
    .{ .name = "settings", .svg = settings },
    .{ .name = "calculator", .svg = calculator },
    .{ .name = "timer", .svg = timer },
    .{ .name = "paint", .svg = paint },
    .{ .name = "image", .svg = image },
    .{ .name = "music", .svg = music },
    .{ .name = "weather", .svg = weather_app },

};

/// Resolve a catalog / desktop icon name. Unknown names fall back to the apps grid.
pub fn get(name: []const u8) []const u8 {

    for (catalog) |entry| {

        if (std.mem.eql(u8, entry.name, name)) return entry.svg;

    }

    return apps;

}

const testing = std.testing;

test "catalog names resolve to lucide assets" {

    try testing.expect(get("folder").len > 0);
    try testing.expect(std.mem.indexOf(u8, get("folder"), "viewBox") != null);
    try testing.expect(get("missing-name").ptr == apps.ptr);
    try testing.expect(get("settings").ptr == settings.ptr);

}

test "every catalog icon strokes into a 20px box without overflowing" {

    const vector = @import("../draw/vector.zig");
    const path_mod = @import("../draw/path.zig");

    for (catalog) |entry| {

        var path = path_mod.Path{};

        vector.build_stroked(&path, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, entry.svg, 0);

        try testing.expect(!path.overflowed);
        try testing.expect(path.verb_count > 0);

    }

}

test "non-catalog icons stroke without overflowing" {

    const vector = @import("../draw/vector.zig");
    const path_mod = @import("../draw/path.zig");

    const set = [_][]const u8{

        paint,
        hand,
        pointer,
        text_cursor,
        folder_plus,
        file_up,
        file_down,
        refresh_cw,
        log_out,
        users,
        weather_clear,
        weather_clear_night,
        weather_partly,
        weather_partly_night,
        weather_cloud,
        weather_fog,
        weather_rain,
        weather_snow,
        weather_storm,
        wind,
        droplet,
        gauge,
        thermometer,
        umbrella,
        sunrise,
        sunset,

    };

    for (set) |svg| {

        var path = path_mod.Path{};

        vector.build_stroked(&path, .{ .x = 0, .y = 0, .w = 24, .h = 24 }, svg, 0);

        try testing.expect(!path.overflowed);
        try testing.expect(path.verb_count > 0);

    }

}
