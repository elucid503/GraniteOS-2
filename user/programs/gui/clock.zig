// Clock: an analog face for local time plus a world clock. A worker wakes the UI each second; all painting stays on the main thread.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;
const ui = lib.ui;

const path = lib.draw.path;
const raster = lib.draw.raster;
const stroke = lib.draw.stroke;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Clock",
    .description = "Local and a world clock.",
    .icon = "clock",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const tab_h: i32 = 42;
const pad: i32 = 16;
const tick_ms = 1000;

const Mode = enum {

    clock,
    world,

};

const weekday_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const weekday_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

// Daylight-saving rule families. Transitions are evaluated against the UTC date,
// so a city can read up to an hour off within the transition day itself.
const Dst = enum {

    none,
    us,
    eu,
    au,

};

// Standard-time offset in minutes from UTC; DST (when in season) adds 60.
const City = struct {

    name: []const u8,
    offset: i32,
    dst: Dst,

};

const cities = [_]City{

    .{ .name = "Los Angeles", .offset = -480, .dst = .us },
    .{ .name = "New York", .offset = -300, .dst = .us },
    .{ .name = "London", .offset = 0, .dst = .eu },
    .{ .name = "Berlin", .offset = 60, .dst = .eu },
    .{ .name = "Dubai", .offset = 240, .dst = .none },
    .{ .name = "Tokyo", .offset = 540, .dst = .none },
    .{ .name = "Sydney", .offset = 600, .dst = .au },

};

const sunday: u32 = 0;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var mode: Mode = .clock;

const tab_items = [_]ui.TabStrip.Item{

    .{ .label = "Clock" },
    .{ .label = "World" },

};

var tab_strip = ui.TabStrip{ .items = &tab_items, .height = tab_h };

var tick: u32 = 0;
var running: u32 = 1;

const worker_stack_pages = 8;
const page_size = 4096;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try lib.wm.open_main(&connection, 340, 430, "Clock");

    _ = lib.draw.round.masks_for(6);

    try start_worker();
    paint();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    lib.wm.close_main(&connection, &window);
                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    dirty = true;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left) {

                        click(event.x, event.y);
                        dirty = true;

                    }

                },

                events.kind_pointer_move => {

                    if (tab_strip.pointer_move(@intCast(window.surface.width), event.x, event.y)) dirty = true;

                    lib.cursor.set(&connection, if (event.y < tab_h) .clicker else .pointer);

                },

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) dirty = true;

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn click(x: i32, y: i32) void {

    if (tab_strip.index_at(@intCast(window.surface.width), x, y)) |index| {

        mode = if (index == 0) .clock else .world;

    }

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.window_bg);

    tab_strip.paint(surface, &font, width, if (mode == .clock) 0 else 1);

    switch (mode) {

        .clock => paint_clock(surface),
        .world => paint_world(surface),

    }

    window.present_all() catch {};

}

fn paint_clock(surface: *const gfx.Surface) void {

    const now = lib.localtime.now(lib.prefs.tz_offset_minutes);
    const secs: u32 = @intCast((lib.time.now_ms() / 1000) % 60);

    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    const face_top = tab_h + pad;
    const face_bottom = height - pad - 70;
    const diameter = @min(width - 2 * pad, face_bottom - face_top);
    const radius = @as(f32, @floatFromInt(diameter)) / 2 - 4;

    const cx = @as(f32, @floatFromInt(width)) / 2;
    const cy = @as(f32, @floatFromInt(face_top)) + @as(f32, @floatFromInt(diameter)) / 2;

    var shape = path.Path{};

    // Face ring first; ticks sit just inside its inner edge so ends look concentric.
    const ring_w: f32 = 2;
    const tick_outer = radius - ring_w * 0.5 - 0.5;

    stroke.circle_border(&shape, cx, cy, radius, ring_w);
    raster.fill(surface, &shape, ui.theme.text_dim);
    shape.reset();

    // 60 minute marks, every fifth lengthened for the hour. Separate fill keeps
    // winding simple and the short radial spines from fighting the ring hole.
    var mark: i32 = 0;

    while (mark < 60) : (mark += 1) {

        const hour_mark = @mod(mark, 5) == 0;
        const tick_inner = if (hour_mark) tick_outer - 14 else tick_outer - 7;
        const tick_w: f32 = if (hour_mark) 2.25 else 1.0;
        const deg = mark * 6;

        const outer = path.polar(cx, cy, tick_outer, deg);
        const inner = path.polar(cx, cy, tick_inner, deg);

        stroke.segment(&shape, inner.x, inner.y, outer.x, outer.y, tick_w);

    }

    raster.fill(surface, &shape, ui.theme.text_dim);
    shape.reset();

    // Hour and minute hands plus the hub, in the primary tone.

    const hour_angle: i32 = @intCast((now.hour % 12) * 30 + now.minute / 2);
    const minute_angle: i32 = @intCast(now.minute * 6);

    const hour_end = path.polar(cx, cy, radius * 0.55, hour_angle);
    const minute_end = path.polar(cx, cy, radius * 0.8, minute_angle);

    stroke.segment(&shape, cx, cy, hour_end.x, hour_end.y, 5);
    stroke.segment(&shape, cx, cy, minute_end.x, minute_end.y, 3);
    shape.add_circle(cx, cy, 4);

    raster.fill(surface, &shape, ui.theme.text);
    shape.reset();

    // Second hand accented on top.

    const second_end = path.polar(cx, cy, radius * 0.85, @intCast(secs * 6));

    stroke.segment(&shape, cx, cy, second_end.x, second_end.y, 1.5);
    raster.fill(surface, &shape, ui.theme.accent);

    // Digital time and date under the face.

    var buffer: [16]u8 = undefined;
    const digital = format_ampm(now.hour, now.minute, &buffer);
    const time_size: u32 = 26;
    const time_x = @divTrunc(width - font.text_width(digital, time_size), 2);

    font.draw(surface, time_x, height - pad - 60, time_size, digital, ui.theme.text);

    var date_buffer: [48]u8 = undefined;
    const dow = lib.localtime.weekday(now.year, now.month, now.day);
    const date = std.fmt.bufPrint(&date_buffer, "{s}, {s} {d}, {d}", .{
        weekday_long[dow],
        lib.localtime.month_name(now.month),
        now.day,
        now.year,
    }) catch "";
    const date_size: u32 = 13;
    const date_x = @divTrunc(width - font.text_width(date, date_size), 2);

    font.draw(surface, date_x, height - pad - 26, date_size, date, ui.theme.text_dim);

}

// "H:MM AM" / "H:MM PM" from a 24-hour clock.
fn format_ampm(hour: u32, minute: u32, buffer: []u8) []const u8 {

    const suffix = if (hour < 12) "AM" else "PM";

    var twelve = hour % 12;

    if (twelve == 0) twelve = 12;

    return std.fmt.bufPrint(buffer, "{d}:{d:0>2} {s}", .{ twelve, minute, suffix }) catch "--:--";

}

// The day-of-month of the nth (1-based) `target` weekday in the month.
fn nth_weekday(year: i64, month: u32, target: u32, n: u32) u32 {

    const first = lib.localtime.weekday(year, month, 1);
    const offset = (target + 7 - first) % 7;

    return 1 + offset + (n - 1) * 7;

}

// The day-of-month of the last `target` weekday in the month.
fn last_weekday(year: i64, month: u32, target: u32) u32 {

    const days = lib.localtime.days_in_month(year, month);
    const last = lib.localtime.weekday(year, month, days);
    const back = (last + 7 - target) % 7;

    return days - back;

}

// (month, day) at or after (sm, sd).
fn on_or_after(month: u32, day: u32, sm: u32, sd: u32) bool {

    return month > sm or (month == sm and day >= sd);

}

// (month, day) strictly before (em, ed).
fn before(month: u32, day: u32, em: u32, ed: u32) bool {

    return month < em or (month == em and day < ed);

}

// Whether `rule` is in daylight-saving season right now, judged by the UTC date.
fn dst_active(rule: Dst) bool {

    if (rule == .none) return false;

    const utc = lib.localtime.now(0);
    const y = utc.year;
    const m = utc.month;
    const d = utc.day;

    return switch (rule) {

        .none => false,

        // Second Sunday of March through the first Sunday of November.
        .us => on_or_after(m, d, 3, nth_weekday(y, 3, sunday, 2)) and before(m, d, 11, nth_weekday(y, 11, sunday, 1)),

        // Last Sunday of March through the last Sunday of October.
        .eu => on_or_after(m, d, 3, last_weekday(y, 3, sunday)) and before(m, d, 10, last_weekday(y, 10, sunday)),

        // Southern hemisphere: first Sunday of October through the first Sunday of April.
        .au => on_or_after(m, d, 10, nth_weekday(y, 10, sunday, 1)) or before(m, d, 4, nth_weekday(y, 4, sunday, 1)),

    };

}

fn paint_world(surface: *const gfx.Surface) void {

    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    // Local first, then each city; the row height fills the available space.

    const count: i32 = 1 + cities.len;
    const top = tab_h + pad;
    const row_h = @divTrunc(height - top - pad, count);

    paint_row(surface, top, row_h, width, "Local", lib.prefs.tz_offset_minutes, true);

    for (cities, 0..) |city, index| {

        const y = top + (@as(i32, @intCast(index)) + 1) * row_h;
        const offset = city.offset + if (dst_active(city.dst)) @as(i32, 60) else 0;

        paint_row(surface, y, row_h, width, city.name, offset, false);

    }

}

fn paint_row(surface: *const gfx.Surface, y: i32, row_h: i32, width: i32, name: []const u8, offset: i32, accent: bool) void {

    const time = lib.localtime.now(offset);
    const dow = lib.localtime.weekday(time.year, time.month, time.day);

    const name_y = y + @divTrunc(row_h - font.line_height(15), 2);

    font.draw(surface, pad, name_y, 15, name, if (accent) ui.theme.text else ui.theme.text_dim);

    var buffer: [16]u8 = undefined;
    const clock = format_ampm(time.hour, time.minute, &buffer);
    const time_size: u32 = 18;
    const time_x = width - pad - font.text_width(clock, time_size);

    font.draw(surface, time_x, y + @divTrunc(row_h - font.line_height(time_size), 2) - 6, time_size, clock, if (accent) ui.theme.accent else ui.theme.text);

    const day_x = width - pad - font.text_width(weekday_short[dow], 11);

    font.draw(surface, day_x, y + @divTrunc(row_h, 2) + 6, 11, weekday_short[dow], ui.theme.text_faint);

    // Hairline separator below each row except the last.
    surface.fill_rect(.{ .x = pad, .y = y + row_h - 1, .w = width - 2 * pad, .h = 1 }, ui.theme.surface_alt);

}

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

// Wakes the main loop once a second so both tabs stay current.
fn worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        lib.time.sleep_ms(tick_ms);

        if (@atomicLoad(u32, &running, .acquire) == 0) break;

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, lib.proto.window.ring_bit) catch {};

    }

    while (true) lib.time.sleep_ms(1000);

}
