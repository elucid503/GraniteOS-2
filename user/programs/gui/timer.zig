// Timer: stopwatch and countdown. A small worker wakes the UI while a clock is running; all painting stays on the main thread.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Timer",
    .description = "Run a stopwatch or timer.",
    .icon = "timer",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const tab_h: i32 = 42;
const pad: i32 = 16;
const btn_h: i32 = 40;
const clock_font_px: u32 = 28;
const tick_ms = 100;

const Mode = enum {

    stopwatch,
    countdown,

};

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var mode: Mode = .stopwatch;

var sw_elapsed_ms: u64 = 0;
var sw_running = false;
var sw_anchor_ms: u64 = 0;

var cd_remaining_ms: u64 = 5 * 60 * 1000;
var cd_duration_ms: u64 = 5 * 60 * 1000;
var cd_running = false;
var cd_anchor_ms: u64 = 0;
var cd_finished = false;

const tab_items = [_]ui.TabStrip.Item{

    .{ .label = "Stopwatch" },
    .{ .label = "Countdown" },

};

var tab_strip = ui.TabStrip{ .items = &tab_items, .height = tab_h };
var regions = ui.HitRegions{};

var tick: u32 = 0;
var running: u32 = 1;

const worker_stack_pages = 8;
const page_size = 4096;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try connection.create_window(340, 280, 0, "Timer");

    _ = lib.draw.round.masks_for(6);

    try start_worker();
    paint();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    window.destroy();
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
                    if (regions.pointer_move(event.x, event.y)) dirty = true;

                    update_cursor(event.x, event.y);

                },

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) {

            if (sw_running or cd_running) {

                advance_clocks();
                dirty = true;

            }

        }

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn update_cursor(x: i32, y: i32) void {

    if (y < tab_h or hit_control(x, y) != null) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn advance_clocks() void {

    const now = lib.time.now_ms();

    if (sw_running) sw_elapsed_ms = now -% sw_anchor_ms;

    if (cd_running) {

        if (now >= cd_anchor_ms + cd_remaining_ms) {

            cd_remaining_ms = 0;
            cd_running = false;
            cd_finished = true;
            lib.notify.post("Timer", "Your countdown is complete.");

        }

    }

}

fn click(x: i32, y: i32) void {

    if (tab_strip.index_at(@intCast(window.surface.width), x, y)) |index| {

        mode = if (index == 0) .stopwatch else .countdown;
        return;

    }

    const control = hit_control(x, y) orelse return;

    switch (mode) {

        .stopwatch => switch (control) {

            .primary => toggle_stopwatch(),
            .secondary => reset_stopwatch(),
            .adjust_minus, .adjust_plus => {},

        },

        .countdown => switch (control) {

            .primary => toggle_countdown(),
            .secondary => reset_countdown(),
            .adjust_minus => adjust_countdown(-60_000),
            .adjust_plus => adjust_countdown(60_000),

        },

    }

}

const Control = enum(u32) {

    primary = 1,
    secondary,
    adjust_minus,
    adjust_plus,

};

fn hit_control(x: i32, y: i32) ?Control {

    const id = regions.hit(x, y);

    if (id == 0) return null;

    return @enumFromInt(id);

}

fn toggle_stopwatch() void {

    const now = lib.time.now_ms();

    if (sw_running) {

        sw_elapsed_ms = now -% sw_anchor_ms;
        sw_running = false;

    } else {

        sw_anchor_ms = now -% sw_elapsed_ms;
        sw_running = true;

    }

}

fn reset_stopwatch() void {

    sw_running = false;
    sw_elapsed_ms = 0;

}

fn toggle_countdown() void {

    if (cd_finished or cd_remaining_ms == 0) {

        reset_countdown();
        return;

    }

    const now = lib.time.now_ms();

    if (cd_running) {

        if (now >= cd_anchor_ms) {

            const spent = now - cd_anchor_ms;

            cd_remaining_ms = if (spent >= cd_remaining_ms) 0 else cd_remaining_ms - spent;

        }

        cd_running = false;

    } else {

        cd_anchor_ms = now;
        cd_running = true;
        cd_finished = false;

    }

}

fn reset_countdown() void {

    cd_running = false;
    cd_finished = false;
    cd_remaining_ms = cd_duration_ms;

}

fn adjust_countdown(delta: i64) void {

    if (cd_running) return;

    var next: i64 = @intCast(cd_duration_ms);

    next += delta;
    if (next < 60_000) next = 60_000;
    if (next > 99 * 60_000) next = 99 * 60_000;

    cd_duration_ms = @intCast(next);
    cd_remaining_ms = cd_duration_ms;
    cd_finished = false;

}

fn live_stopwatch_ms() u64 {

    if (!sw_running) return sw_elapsed_ms;

    return lib.time.now_ms() -% sw_anchor_ms;

}

fn live_countdown_ms() u64 {

    if (!cd_running) return cd_remaining_ms;

    const now = lib.time.now_ms();

    if (now >= cd_anchor_ms + cd_remaining_ms) return 0;

    return (cd_anchor_ms + cd_remaining_ms) - now;

}

fn primary_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const y = height - pad - btn_h;
    const w = @divTrunc(width - 3 * pad, 2);

    return .{ .x = pad, .y = y, .w = w, .h = btn_h };

}

fn secondary_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const y = height - pad - btn_h;
    const w = @divTrunc(width - 3 * pad, 2);

    return .{ .x = pad * 2 + w, .y = y, .w = w, .h = btn_h };

}

fn minus_rect() Rect {

    const mid_y = tab_h + @divTrunc(@as(i32, @intCast(window.surface.height)) - tab_h - btn_h - pad * 2, 2);

    return .{ .x = pad, .y = mid_y - 18, .w = 40, .h = 36 };

}

fn plus_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const mid_y = tab_h + @divTrunc(@as(i32, @intCast(window.surface.height)) - tab_h - btn_h - pad * 2, 2);

    return .{ .x = width - pad - 40, .y = mid_y - 18, .w = 40, .h = 36 };

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill(ui.theme.window_bg);

    regions.reset();
    tab_strip.paint(surface, &font, width, if (mode == .stopwatch) 0 else 1);

    const ms = switch (mode) {

        .stopwatch => live_stopwatch_ms(),
        .countdown => live_countdown_ms(),

    };

    var buffer: [16]u8 = undefined;
    const clock = format_ms(ms, &buffer);

    const clock_w = font.text_width(clock, clock_font_px);
    const clock_x = @divTrunc(width - clock_w, 2);
    const clock_y = tab_h + @divTrunc(height - tab_h - btn_h - pad * 2 - font.line_height(clock_font_px), 2);
    const color = if (mode == .countdown and cd_finished) ui.theme.warn else ui.theme.text;

    font.draw(surface, clock_x, clock_y, clock_font_px, clock, color);

    if (mode == .countdown and !cd_running) {

        paint_control(surface, .adjust_minus, minus_rect(), "-1m", .{ .size = 12, .idle = ui.theme.surface });
        paint_control(surface, .adjust_plus, plus_rect(), "+1m", .{ .size = 12, .idle = ui.theme.surface });

    }

    const primary_label: []const u8 = switch (mode) {

        .stopwatch => if (sw_running) "Pause" else "Start",
        .countdown => if (cd_running) "Pause" else if (cd_finished or cd_remaining_ms == 0) "Restart" else "Start",

    };

    paint_control(surface, .primary, primary_rect(), primary_label, .{ .size = 14 });
    paint_control(surface, .secondary, secondary_rect(), "Reset", .{ .size = 14 });

    window.present_all() catch {};

}

// Draw one control through the shared widget and register its hit region under the Control's id.

fn paint_control(surface: *const gfx.Surface, control: Control, rect: Rect, label: []const u8, style: ui.ButtonStyle) void {

    const id: u32 = @intFromEnum(control);

    regions.add(id, rect);

    ui.widgets.button(surface, &font, rect, label, .{

        .hovered = regions.hovered(id),
        .accent = control == .primary,

    }, style);

}

fn format_ms(ms: u64, buffer: []u8) []const u8 {

    const total_cs = ms / 10;
    const centiseconds = total_cs % 100;
    const total_seconds = ms / 1000;
    const seconds = total_seconds % 60;
    const minutes = (total_seconds / 60) % 100;

    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}.{d:0>2}", .{ minutes, seconds, centiseconds }) catch "00:00.00";

}

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

// Only wakes the main loop while a clock is running. Never paints or tears down the process.
fn worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        lib.time.sleep_ms(tick_ms);

        if (@atomicLoad(u32, &running, .acquire) == 0) break;

        // Main thread owns start/stop; this is a soft hint so idle Timer apps stay quiet.
        if (!sw_running and !cd_running) continue;

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, lib.proto.window.ring_bit) catch {};

    }

    while (true) lib.time.sleep_ms(1000);

}
