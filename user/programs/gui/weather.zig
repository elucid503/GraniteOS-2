// Weather: Open-Meteo forecast (plain HTTP) for the metrics-reported location. A worker thread
// owns the network; the UI paints current conditions, a hoverable hourly chart, and a 7-day strip.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Weather",
    .description = "Local conditions and forecast.",
    .icon = "weather",
    .category = "Internet",
};

comptime {

    _ = lib.start;

}

const margin: i32 = 14;
const header_h: i32 = 92;
const tile_h: i32 = 54;
const day_h: i32 = 66;
const detail_h: i32 = 46;
const min_chart_h: i32 = 160;

const weather_host = "api.open-meteo.com";
const refresh_interval_ms: u64 = 60 * 1000;

const max_hours = 168;
const max_days = 7;
const hours_per_day = 24;
const response_capacity = 32768;

const day_id_base: u32 = 8;

// All numeric fields are integers: temperatures and UV in deci-units, wind in deci-km/h.

const Forecast = struct {

    ready: bool = false,
    failed: bool = false,

    city: [16]u8 = [_]u8{0} ** 16,
    city_len: usize = 0,

    temp_dc: i32 = 0,
    feels_dc: i32 = 0,
    humidity: i32 = 0,
    wind_dkmh: i32 = 0,
    wind_dir: i32 = 0,
    pressure_hpa: i32 = 0,
    precip_dmm: i32 = 0,
    code: u32 = 0,
    is_day: bool = true,
    now_minutes: i32 = 0,

    hour_count: usize = 0,
    hour_temp_dc: [max_hours]i32 = [_]i32{0} ** max_hours,
    hour_precip: [max_hours]i32 = [_]i32{0} ** max_hours,
    hour_code: [max_hours]i32 = [_]i32{0} ** max_hours,

    day_count: usize = 0,
    day_min_dc: [max_days]i32 = [_]i32{0} ** max_days,
    day_max_dc: [max_days]i32 = [_]i32{0} ** max_days,
    day_code: [max_days]i32 = [_]i32{0} ** max_days,
    day_precip: [max_days]i32 = [_]i32{0} ** max_days,
    day_wind_dkmh: [max_days]i32 = [_]i32{0} ** max_days,
    day_uv_dx: [max_days]i32 = [_]i32{0} ** max_days,
    day_sunrise_min: [max_days]i32 = [_]i32{0} ** max_days,
    day_sunset_min: [max_days]i32 = [_]i32{0} ** max_days,
    day_weekday: [max_days]i32 = [_]i32{0} ** max_days,

};

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var forecast: Forecast = .{};
var staging: Forecast = .{};

var selected_day: usize = 0;
var hover_hour: ?usize = null;
var regions = ui.HitRegions{};

var scroll: i32 = 0;
var dragging_scrollbar = false;

var tick: u32 = 0;
var running: u32 = 1;

var response: [response_capacity]u8 = undefined;

const worker_stack_pages = 16;
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
    window = try lib.wm.open_main(&connection, 560, 620, "Weather");

    _ = lib.draw.round.masks_for(6);

    paint();

    try start_worker();

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
                    clamp_scroll();
                    dirty = true;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left) {

                        if (click(event.x, event.y)) dirty = true;

                    }

                },

                events.kind_button_up => {

                    if (event.code == events.button_left) dragging_scrollbar = false;

                },

                events.kind_scroll => {

                    if (wheel(event.value)) dirty = true;

                },

                events.kind_pointer_move => {

                    if (dragging_scrollbar) {

                        if (drag_scrollbar(event.y)) dirty = true;

                    }

                    if (regions.pointer_move(event.x, event.y)) dirty = true;
                    if (track_chart_hover(event.x, event.y)) dirty = true;

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

            forecast = staging;

            if (selected_day >= @max(forecast.day_count, 1)) selected_day = 0;

            dirty = true;

        }

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

// Input.

fn click(x: i32, y: i32) bool {

    if (scrollbar_rect().contains(x, y) and max_scroll() > 0) {

        dragging_scrollbar = true;

        return drag_scrollbar(y);

    }

    const id = regions.hit(x, y);

    if (id >= day_id_base and id < day_id_base + max_days) {

        selected_day = id - day_id_base;
        hover_hour = null;

        return true;

    }

    return false;

}

fn wheel(delta: i64) bool {

    const before = scroll;

    scroll = @intCast(scroll_model().wheel(delta, 40));

    return scroll != before;

}

fn drag_scrollbar(y: i32) bool {

    const track = scrollbar_rect();
    const before = scroll;

    scroll = @intCast(scroll_model().offset_at(track.h, y - track.y));

    return scroll != before;

}

fn clamp_scroll() void {

    scroll = std.math.clamp(scroll, 0, max_scroll());

}

fn track_chart_hover(x: i32, y: i32) bool {

    const before = hover_hour;
    const inner = chart_rect().inset(2);
    const count = selected_hour_count();

    hover_hour = null;

    if (forecast.ready and count > 1 and inner.contains(x, y)) {

        const index: usize = @intCast(@divTrunc((x - inner.x) * @as(i32, @intCast(count - 1)) + @divTrunc(inner.w, 2), @max(1, inner.w)));

        hover_hour = @min(index, count - 1);

    }

    return before != hover_hour;

}

fn update_cursor(x: i32, y: i32) void {

    if (regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

// Layout: fixed-height sections stacked under a pixel scroll offset; the chart absorbs spare height.

fn content_width() i32 {

    return @as(i32, @intCast(window.surface.width)) - margin * 2;

}

fn header_y() i32 {

    return margin - scroll;

}

fn tiles_y() i32 {

    return header_y() + header_h;

}

fn days_y() i32 {

    return tiles_y() + tile_h + 12;

}

fn details_y() i32 {

    return days_y() + day_h + 10;

}

fn fixed_top_height() i32 {

    return margin + header_h + tile_h + 12 + day_h + 10 + detail_h + 10;

}

fn chart_height() i32 {

    return @max(min_chart_h, @as(i32, @intCast(window.surface.height)) - fixed_top_height() - margin);

}

fn chart_rect() Rect {

    return .{ .x = margin, .y = details_y() + detail_h + 10, .w = content_width(), .h = chart_height() };

}

fn content_height() i32 {

    return fixed_top_height() + chart_height() + margin;

}

fn max_scroll() i32 {

    return @max(0, content_height() - @as(i32, @intCast(window.surface.height)));

}

fn scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(scroll),
        .content = @intCast(content_height()),
        .viewport = @intCast(window.surface.height),

    };

}

fn scrollbar_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{ .x = width - ui.scrollbar_width - 2, .y = 2, .w = ui.scrollbar_width, .h = height - 4 };

}

fn day_chip_rect(index: usize) Rect {

    const count: i32 = @intCast(@max(forecast.day_count, 1));
    const total = content_width();
    const gap: i32 = 6;
    const width = @divTrunc(total - gap * (count - 1), count);
    const x = margin + @as(i32, @intCast(index)) * (width + gap);

    return .{ .x = x, .y = days_y(), .w = width, .h = day_h };

}

fn selected_hour_count() usize {

    const start = selected_day * hours_per_day;

    if (start >= forecast.hour_count) return 0;

    return @min(hours_per_day, forecast.hour_count - start);

}

// Painting.

fn paint() void {

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);

    regions.reset();

    if (forecast.ready) {

        paint_header(surface);
        paint_tiles(surface);
        paint_days(surface);
        paint_day_details(surface);
        paint_chart(surface);

        if (max_scroll() > 0) ui.scrollbar(surface, scrollbar_rect(), scroll_model());

    } else {

        const message: []const u8 = if (forecast.failed) "Weather unavailable. Retrying every minute..." else "Loading weather...";

        text_center(surface, .{ .x = margin, .y = margin, .w = content_width(), .h = header_h }, 14, message, ui.theme.text_dim);

    }

    window.present_all() catch {};

}

fn paint_header(surface: *const gfx.Surface) void {

    const top = header_y();
    const icon_size: i32 = 46;
    const icon_rect = Rect{ .x = margin + 2, .y = top + 8, .w = icon_size, .h = icon_size };

    lib.draw.vector.icon_in(surface, icon_rect, condition_icon(forecast.code, forecast.is_day), ui.theme.text);

    var buffer: [24]u8 = undefined;
    const big = big_temp_text(&buffer, forecast.temp_dc);
    const temp_x = icon_rect.x + icon_size + 14;

    font.draw(surface, temp_x, top + 6, 34, big, ui.theme.text);

    var feels_buffer: [48]u8 = undefined;
    const feels = std.fmt.bufPrint(&feels_buffer, "{s}  ·  Feels like {d} {s}", .{

        condition_text(forecast.code),
        round_deci(display_deci(forecast.feels_dc)),
        unit_label(),

    }) catch "";

    font.draw(surface, temp_x, top + 52, 13, feels, ui.theme.text_dim);

    const city = forecast.city[0..forecast.city_len];
    const place = if (city.len == 0) "Local weather" else city;
    const width: i32 = @intCast(window.surface.width);
    const place_w = font.text_width(place, 15);

    font.draw(surface, width - margin - place_w, top + 8, 15, place, ui.theme.text);

    var clock_buffer: [24]u8 = undefined;
    var stamp_buffer: [16]u8 = undefined;
    const clock = std.fmt.bufPrint(&clock_buffer, "as of {s}", .{clock_text(&stamp_buffer, forecast.now_minutes)}) catch "";
    const clock_w = font.text_width(clock, 12);

    font.draw(surface, width - margin - clock_w, top + 32, 12, clock, ui.theme.text_faint);

}

/// Current-condition stats only (instantaneous). Day-level facts live in the details row.
fn paint_tiles(surface: *const gfx.Surface) void {

    const panel = Rect{ .x = margin, .y = tiles_y(), .w = content_width(), .h = tile_h };

    ui.fill_round_rect(surface, panel, 6, ui.theme.surface);
    ui.stroke_round_rect(surface, panel, 6, 1, ui.theme.border);

    var value: [32]u8 = undefined;

    const humidity = std.fmt.bufPrint(&value, "{d}%", .{forecast.humidity}) catch "-";

    paint_stat(surface, panel, 0, 4, lib.icons.droplet, "Humidity", humidity, "");

    const wind = std.fmt.bufPrint(&value, "{d} km/h", .{round_deci(forecast.wind_dkmh)}) catch "-";

    paint_stat(surface, panel, 1, 4, lib.icons.wind, "Wind", wind, compass_point(forecast.wind_dir));

    const pressure = std.fmt.bufPrint(&value, "{d} hPa", .{forecast.pressure_hpa}) catch "-";

    paint_stat(surface, panel, 2, 4, lib.icons.gauge, "Pressure", pressure, "");

    const precip = std.fmt.bufPrint(&value, "{d}.{d} mm", .{ @divTrunc(forecast.precip_dmm, 10), @mod(@max(0, forecast.precip_dmm), 10) }) catch "-";

    paint_stat(surface, panel, 3, 4, lib.icons.umbrella, "Precipitation", precip, "");

}

fn paint_stat(surface: *const gfx.Surface, panel: Rect, column: i32, columns: i32, icon: []const u8, label: []const u8, value: []const u8, detail: []const u8) void {

    const width = @divTrunc(panel.w, columns);
    const rect = Rect{

        .x = panel.x + column * width,
        .y = panel.y,

        .w = width,
        .h = tile_h,

    };

    const icon_side: i32 = 20;

    lib.draw.vector.icon_in(surface, .{ .x = rect.x + 12, .y = rect.y + @divTrunc(tile_h - icon_side, 2), .w = icon_side, .h = icon_side }, icon, ui.theme.text_dim);

    const text_x = rect.x + 12 + icon_side + 8;
    const clipped = surface.clipped(rect.inset(1));

    font.draw(&clipped, text_x, rect.y + 9, 11, label, ui.theme.text_faint);
    font.draw(&clipped, text_x, rect.y + 26, 14, value, ui.theme.text);

    if (detail.len > 0) {

        const value_w = font.text_width(value, 14);

        font.draw(&clipped, text_x + value_w + 6, rect.y + 28, 11, detail, ui.theme.text_dim);

    }

}

fn paint_days(surface: *const gfx.Surface) void {

    var index: usize = 0;

    while (index < forecast.day_count) : (index += 1) {

        const rect = day_chip_rect(index);
        const id = day_id_base + @as(u32, @intCast(index));

        regions.add(id, rect);

        const selected = index == selected_day;
        const fill = if (selected) ui.theme.accent_dim else if (regions.hovered(id)) ui.theme.hover else ui.theme.surface;

        ui.fill_round_rect(surface, rect, 6, fill);
        ui.stroke_round_rect(surface, rect, 6, 1, if (selected) ui.theme.accent else ui.theme.border);

        const label = if (index == 0) "Today" else weekday_name(forecast.day_weekday[index]);

        text_center(surface, .{ .x = rect.x, .y = rect.y + 4, .w = rect.w, .h = 14 }, 11, label, if (selected) ui.theme.text else ui.theme.text_dim);

        const icon_side: i32 = 20;

        lib.draw.vector.icon_in(surface, .{ .x = rect.x + @divTrunc(rect.w - icon_side, 2), .y = rect.y + 20, .w = icon_side, .h = icon_side }, condition_icon(@intCast(@max(0, forecast.day_code[index])), true), ui.theme.text);

        var buffer: [16]u8 = undefined;
        const span = std.fmt.bufPrint(&buffer, "{d} / {d}", .{

            round_deci(display_deci(forecast.day_max_dc[index])),
            round_deci(display_deci(forecast.day_min_dc[index])),

        }) catch "-";

        text_center(surface, .{ .x = rect.x, .y = rect.y + rect.h - 18, .w = rect.w, .h = 14 }, 11, span, ui.theme.text_dim);

    }

}

fn paint_chart(surface: *const gfx.Surface) void {

    const rect = chart_rect();
    const count = selected_hour_count();
    const start = selected_day * hours_per_day;

    if (count < 2) {

        ui.fill_round_rect(surface, rect, 6, ui.theme.surface);
        text_center(surface, rect, 12, "No hourly data.", ui.theme.text_faint);

        return;

    }

    const temps = forecast.hour_temp_dc[start .. start + count];

    var low = temps[0];
    var high = temps[0];

    for (temps) |sample| {

        low = @min(low, sample);
        high = @max(high, sample);

    }

    // Normalize to u32 with headroom so the curve never rides the frame edges.
    const pad_dc: i32 = 15;
    var samples: [hours_per_day]u32 = undefined;

    for (temps, 0..) |sample, i| {

        samples[i] = @intCast(sample - low + pad_dc);

    }

    ui.chart.line(surface, rect, samples[0..count], @intCast(high - low + pad_dc * 2), ui.theme.accent);

    const inner = rect.inset(2);

    paint_precipitation_bars(surface, inner, start, count);
    paint_hour_icons(surface, inner, start, count);
    paint_now_marker(surface, inner, count);
    paint_hover_readout(surface, rect, inner, start, count);
    paint_range_labels(surface, inner, low, high);

}

/// Per-day forecast facts for the selected day (above the hourly chart).
/// Omits conditions (day chip icon + header) and current-only stats (tiles).
fn paint_day_details(surface: *const gfx.Surface) void {

    if (selected_day >= forecast.day_count) return;

    const day = selected_day;

    var rain: [16]u8 = undefined;
    var uv_value: [16]u8 = undefined;
    var wind: [16]u8 = undefined;
    var rise: [16]u8 = undefined;
    var set: [16]u8 = undefined;

    const cells = [_]struct { label: []const u8, value: []const u8 }{

        .{ .label = "Rain", .value = std.fmt.bufPrint(&rain, "{d}%", .{forecast.day_precip[day]}) catch "-" },

        .{ .label = "UV index", .value = std.fmt.bufPrint(&uv_value, "{d}.{d}", .{

            @divTrunc(forecast.day_uv_dx[day], 10),
            @mod(@max(0, forecast.day_uv_dx[day]), 10),

        }) catch "-" },

        .{ .label = "Max wind", .value = std.fmt.bufPrint(&wind, "{d} km/h", .{round_deci(forecast.day_wind_dkmh[day])}) catch "-" },
        .{ .label = "Sunrise", .value = clock_text(&rise, forecast.day_sunrise_min[day]) },
        .{ .label = "Sunset", .value = clock_text(&set, forecast.day_sunset_min[day]) },

    };

    const total = content_width();
    const gap: i32 = 6;
    const count: i32 = @intCast(cells.len);
    const width = @divTrunc(total - gap * (count - 1), count);

    for (cells, 0..) |cell, index| {

        const rect = Rect{

            .x = margin + @as(i32, @intCast(index)) * (width + gap),
            .y = details_y(),

            .w = width,
            .h = detail_h,

        };

        const clipped = surface.clipped(rect);

        font.draw(&clipped, rect.x + 2, rect.y + 8, 10, cell.label, ui.theme.text_faint);
        font.draw(&clipped, rect.x + 2, rect.y + 23, 13, cell.value, ui.theme.text);

    }

}

fn hour_x(inner: Rect, index: usize, count: usize) i32 {

    return inner.x + @as(i32, @intCast(@divTrunc(@as(i64, @intCast(index)) * inner.w, @as(i64, @intCast(count - 1)))));

}

fn paint_precipitation_bars(surface: *const gfx.Surface, inner: Rect, start: usize, count: usize) void {

    const max_bar = @divTrunc(inner.h, 4);

    for (0..count) |index| {

        const probability = std.math.clamp(forecast.hour_precip[start + index], 0, 100);

        if (probability == 0) continue;

        const bar = @max(1, @divTrunc(max_bar * probability, 100));
        const x = hour_x(inner, index, count);

        surface.fill_rect(.{ .x = x - 1, .y = inner.y + inner.h - bar, .w = 2, .h = bar }, ui.theme.accent_dim);

    }

}

/// Condition icons every three hours along the top of the chart, day/night-aware per hour.
fn paint_hour_icons(surface: *const gfx.Surface, inner: Rect, start: usize, count: usize) void {

    const icon_side: i32 = 14;
    const rise = if (selected_day < forecast.day_count) forecast.day_sunrise_min[selected_day] else 6 * 60;
    const set = if (selected_day < forecast.day_count) forecast.day_sunset_min[selected_day] else 20 * 60;

    var index: usize = 2;

    while (index < count) : (index += 3) {

        const minute = @as(i32, @intCast(index)) * 60;
        const day = minute >= rise and minute < set;
        const code: u32 = @intCast(@max(0, forecast.hour_code[start + index]));
        const x = std.math.clamp(hour_x(inner, index, count) - @divTrunc(icon_side, 2), inner.x, inner.x + inner.w - icon_side);

        lib.draw.vector.icon_in(surface, .{ .x = x, .y = inner.y + 6, .w = icon_side, .h = icon_side }, condition_icon(code, day), ui.theme.text_dim);

    }

}

fn paint_now_marker(surface: *const gfx.Surface, inner: Rect, count: usize) void {

    if (selected_day != 0) return;

    const hour: usize = @intCast(std.math.clamp(@divTrunc(forecast.now_minutes, 60), 0, @as(i32, @intCast(count - 1))));
    const x = hour_x(inner, hour, count);

    surface.fill_rect(.{ .x = x, .y = inner.y, .w = 1, .h = inner.h }, ui.theme.text_faint);

}

fn paint_hover_readout(surface: *const gfx.Surface, rect: Rect, inner: Rect, start: usize, count: usize) void {

    const hour = hover_hour orelse return;

    if (hour >= count) return;

    const x = hour_x(inner, hour, count);

    surface.fill_rect(.{ .x = x, .y = inner.y, .w = 1, .h = inner.h }, ui.theme.accent);

    var stamp: [16]u8 = undefined;
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}  {d} {s}  ·  {d}%  ·  {s}", .{

        clock_text(&stamp, @as(i32, @intCast(hour)) * 60),
        round_deci(display_deci(forecast.hour_temp_dc[start + hour])),
        unit_label(),

        std.math.clamp(forecast.hour_precip[start + hour], 0, 100),
        condition_text(@intCast(@max(0, forecast.hour_code[start + hour]))),

    }) catch "";

    const text_w = font.text_width(text, 12);
    const box_h: i32 = 18;
    const box = Rect{ .x = rect.x + @divTrunc(rect.w - text_w, 2) - 8, .y = rect.y + rect.h - box_h + 1, .w = text_w + 16, .h = box_h };

    ui.fill_round_rect(surface, box, 5, ui.theme.surface_alt);
    text_center(surface, box, 12, text, ui.theme.text);

}

fn paint_range_labels(surface: *const gfx.Surface, inner: Rect, low: i32, high: i32) void {

    var buffer: [16]u8 = undefined;

    const top = std.fmt.bufPrint(&buffer, "{d}", .{round_deci(display_deci(high))}) catch "";

    font.draw(surface, inner.x + 5, inner.y + 4, 10, top, ui.theme.text_faint);

    var low_buffer: [16]u8 = undefined;
    const bottom = std.fmt.bufPrint(&low_buffer, "{d}", .{round_deci(display_deci(low))}) catch "";

    font.draw(surface, inner.x + 5, inner.y + inner.h - 14, 10, bottom, ui.theme.text_faint);

}

// Text helpers.

fn text_in(surface: *const gfx.Surface, rect: Rect, size: u32, value: []const u8, color: gfx.Color) void {

    const clipped = surface.clipped(rect);
    const visible = ui.truncate(&font, value, size, rect.w);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(&clipped, rect.x, y, size, visible, color);

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, value: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, value, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

// Formatting.

fn display_deci(dc: i32) i32 {

    if (lib.prefs.temp_unit == .fahrenheit) return @divTrunc(dc * 9, 5) + 320;

    return dc;

}

fn round_deci(deci: i32) i32 {

    if (deci >= 0) return @divTrunc(deci + 5, 10);

    return @divTrunc(deci - 5, 10);

}

fn unit_label() []const u8 {

    return if (lib.prefs.temp_unit == .fahrenheit) "F" else "C";

}

fn big_temp_text(buffer: []u8, dc: i32) []const u8 {

    return std.fmt.bufPrint(buffer, "{d} {s}", .{ round_deci(display_deci(dc)), unit_label() }) catch "-";

}

/// Minutes since local midnight -> "10:47 PM". Width specifiers stay on unsigned values: with a
/// width, std.fmt prints an explicit sign for signed integers.
fn clock_text(buffer: []u8, minutes: i32) []const u8 {

    const total: u32 = @intCast(@mod(minutes, 24 * 60));
    const hour = total / 60;
    const in_twelve = if (hour % 12 == 0) 12 else hour % 12;
    const suffix: []const u8 = if (hour < 12) "AM" else "PM";

    return std.fmt.bufPrint(buffer, "{d}:{d:0>2} {s}", .{ in_twelve, total % 60, suffix }) catch "-";

}

fn compass_point(degrees: i32) []const u8 {

    const points = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
    const index: usize = @intCast(@mod(@divTrunc(degrees + 22, 45), 8));

    return points[index];

}

fn weekday_name(day: i32) []const u8 {

    const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

    return names[@intCast(@mod(day, 7))];

}

fn weekday_full(day: i32) []const u8 {

    const names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

    return names[@intCast(@mod(day, 7))];

}

fn condition_text(code: u32) []const u8 {

    return switch (code) {

        0 => "Clear",
        1, 2 => "Partly cloudy",
        3 => "Overcast",
        45, 48 => "Fog",
        51, 53, 55, 56, 57 => "Drizzle",
        61, 63, 65, 66, 67 => "Rain",
        71, 73, 75, 77 => "Snow",
        80, 81, 82 => "Showers",
        85, 86 => "Snow showers",
        95, 96, 99 => "Thunderstorm",
        else => "Weather",

    };

}

fn condition_icon(code: u32, day: bool) []const u8 {

    return switch (code) {

        0 => if (day) lib.icons.weather_clear else lib.icons.weather_clear_night,
        1, 2 => if (day) lib.icons.weather_partly else lib.icons.weather_partly_night,
        3 => lib.icons.weather_cloud,
        45, 48 => lib.icons.weather_fog,
        51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82 => lib.icons.weather_rain,
        71, 73, 75, 77, 85, 86 => lib.icons.weather_snow,
        95, 96, 99 => lib.icons.weather_storm,
        else => lib.icons.weather_cloud,

    };

}

// Worker: location + HTTP fetch + parse, staged for the UI thread.

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        refresh_forecast();

        @atomicStore(u32, &tick, 1, .release);
        sys.notify(ready, lib.proto.window.ring_bit) catch {};

        var waited: u64 = 0;

        while (waited < refresh_interval_ms and @atomicLoad(u32, &running, .acquire) != 0) {

            lib.time.sleep_ms(500);
            waited += 500;

        }

    }

    lib.start.exit();

}

fn refresh_forecast() void {

    var next: Forecast = .{};

    const location = metrics_location() catch {

        next.failed = true;
        staging = next;

        return;

    };

    const city_len = @min(location.city_len, next.city.len);

    @memcpy(next.city[0..city_len], location.city[0..city_len]);
    next.city_len = city_len;

    fetch_forecast(&next, location.lat, location.lon) catch {

        next.failed = true;
        staging = next;

        return;

    };

    staging = next;

}

const MetricsLocation = struct {

    lat: f64,
    lon: f64,
    city: [lib.proto.metrics.max_city]u8,
    city_len: usize,

};

fn metrics_location() !MetricsLocation {

    const endpoint = try lib.stream.lookup_endpoint("metrics");
    const reply = try ipc.request(endpoint, lib.proto.metrics.get_location, &.{}, &.{});

    if (reply.data[1] != lib.proto.metrics.status_ready) return error.Unavailable;

    var city = [_]u8{0} ** lib.proto.metrics.max_city;

    std.mem.writeInt(u64, city[0..8], reply.data[4], .little);
    std.mem.writeInt(u64, city[8..16], reply.data[5], .little);

    var city_len: usize = 0;

    while (city_len < city.len and city[city_len] != 0) : (city_len += 1) {}

    return .{

        .lat = @bitCast(reply.data[2]),
        .lon = @bitCast(reply.data[3]),
        .city = city,
        .city_len = city_len,

    };

}

fn fetch_forecast(out: *Forecast, lat: f64, lon: f64) !void {

    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/v1/forecast?latitude={d:.4}&longitude={d:.4}&timezone=auto&forecast_days=7" ++
        "&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,surface_pressure,wind_speed_10m,wind_direction_10m,is_day" ++
        "&hourly=temperature_2m,precipitation_probability,weather_code" ++
        "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,wind_speed_10m_max,uv_index_max,sunrise,sunset", .{ lat, lon });

    var socket = try lib.net.Socket.connect_host(cap.memory, weather_host, 80);
    defer socket.close();

    var request_buffer: [640]u8 = undefined;
    const http_request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, weather_host });

    try socket.send_all(http_request);

    var length: usize = 0;

    while (length < response.len) {

        const read = socket.recv(response[length..]) catch break;

        if (read == 0) break;

        length += read;

    }

    try parse_forecast(out, response[0..length]);

}

// Parsing: key scans over the three response sections, everything stored as scaled integers.

fn parse_forecast(out: *Forecast, bytes: []const u8) !void {

    const body_start = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.Invalid;
    const body = bytes[body_start + 4 ..];

    const current = section_after(body, "\"current\":{") orelse return error.Invalid;

    out.temp_dc = value_scaled(current, "\"temperature_2m\":", 10) orelse return error.Invalid;
    out.feels_dc = value_scaled(current, "\"apparent_temperature\":", 10) orelse out.temp_dc;
    out.humidity = value_scaled(current, "\"relative_humidity_2m\":", 1) orelse 0;
    out.precip_dmm = value_scaled(current, "\"precipitation\":", 10) orelse 0;
    out.code = @intCast(@max(0, value_scaled(current, "\"weather_code\":", 1) orelse 0));
    out.pressure_hpa = value_scaled(current, "\"surface_pressure\":", 1) orelse 0;
    out.wind_dkmh = value_scaled(current, "\"wind_speed_10m\":", 10) orelse 0;
    out.wind_dir = value_scaled(current, "\"wind_direction_10m\":", 1) orelse 0;
    out.is_day = (value_scaled(current, "\"is_day\":", 1) orelse 1) != 0;
    out.now_minutes = value_hhmm(current, "\"time\":") orelse 0;

    const hourly = section_after(body, "\"hourly\":{") orelse return error.Invalid;

    const temps = array_scaled(hourly, "\"temperature_2m\":", out.hour_temp_dc[0..], 10);
    const rain = array_scaled(hourly, "\"precipitation_probability\":", out.hour_precip[0..], 1);
    const codes = array_scaled(hourly, "\"weather_code\":", out.hour_code[0..], 1);

    out.hour_count = @min(temps, @min(rain, codes));

    const daily = section_after(body, "\"daily\":{") orelse return error.Invalid;

    const highs = array_scaled(daily, "\"temperature_2m_max\":", out.day_max_dc[0..], 10);
    const lows = array_scaled(daily, "\"temperature_2m_min\":", out.day_min_dc[0..], 10);
    const day_codes = array_scaled(daily, "\"weather_code\":", out.day_code[0..], 1);

    _ = array_scaled(daily, "\"precipitation_probability_max\":", out.day_precip[0..], 1);
    _ = array_scaled(daily, "\"wind_speed_10m_max\":", out.day_wind_dkmh[0..], 10);
    _ = array_scaled(daily, "\"uv_index_max\":", out.day_uv_dx[0..], 10);
    _ = array_hhmm(daily, "\"sunrise\":", out.day_sunrise_min[0..]);
    _ = array_hhmm(daily, "\"sunset\":", out.day_sunset_min[0..]);
    _ = array_weekdays(daily, "\"time\":", out.day_weekday[0..]);

    out.day_count = @min(highs, @min(lows, day_codes));

    if (out.hour_count == 0 or out.day_count == 0) return error.Invalid;

    out.ready = true;

}

fn section_after(body: []const u8, marker: []const u8) ?[]const u8 {

    const at = std.mem.indexOf(u8, body, marker) orelse return null;

    return body[at + marker.len ..];

}

fn is_number_byte(byte: u8) bool {

    return byte == '-' or byte == '+' or byte == '.' or byte == 'e' or byte == 'E' or (byte >= '0' and byte <= '9');

}

fn scaled_from_token(token: []const u8, scale: i32) ?i32 {

    const value = std.fmt.parseFloat(f64, token) catch return null;

    return @intFromFloat(@round(value * @as(f64, @floatFromInt(scale))));

}

fn value_scaled(text: []const u8, key: []const u8, scale: i32) ?i32 {

    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = text[at + key.len ..];

    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];

    var end: usize = 0;

    while (end < rest.len and is_number_byte(rest[end])) : (end += 1) {}

    if (end == 0) return null;

    return scaled_from_token(rest[0..end], scale);

}

/// "key":"2026-07-18T14:30" (or a bare quoted time) -> minutes since local midnight.
fn value_hhmm(text: []const u8, key: []const u8) ?i32 {

    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const open = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return null;

    return hhmm_from_stamp(rest[open + 1 .. close]);

}

fn hhmm_from_stamp(stamp: []const u8) ?i32 {

    const t = std.mem.indexOfScalar(u8, stamp, 'T') orelse return null;

    if (stamp.len < t + 6) return null;

    const hour = std.fmt.parseInt(i32, stamp[t + 1 .. t + 3], 10) catch return null;
    const minute = std.fmt.parseInt(i32, stamp[t + 4 .. t + 6], 10) catch return null;

    return hour * 60 + minute;

}

fn array_scaled(text: []const u8, key: []const u8, out: []i32, scale: i32) usize {

    var rest = array_body(text, key) orelse return 0;
    var count: usize = 0;

    while (rest.len > 0 and count < out.len) {

        const byte = rest[0];

        if (byte == ']') break;

        if (is_number_byte(byte)) {

            var end: usize = 0;

            while (end < rest.len and is_number_byte(rest[end])) : (end += 1) {}

            out[count] = scaled_from_token(rest[0..end], scale) orelse 0;
            count += 1;
            rest = rest[end..];

            continue;

        }

        if (byte == 'n') {

            // Open-Meteo emits null for missing samples; zero keeps indexes aligned.
            out[count] = 0;
            count += 1;
            rest = rest[@min(rest.len, 4)..];

            continue;

        }

        rest = rest[1..];

    }

    return count;

}

fn array_hhmm(text: []const u8, key: []const u8, out: []i32) usize {

    var rest = array_body(text, key) orelse return 0;
    var count: usize = 0;

    while (count < out.len) {

        const open = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse break;
        const closer = std.mem.indexOfScalar(u8, rest[0..open], ']');

        if (closer != null) break;

        out[count] = hhmm_from_stamp(rest[open + 1 .. close]) orelse 0;
        count += 1;
        rest = rest[close + 1 ..];

    }

    return count;

}

fn array_weekdays(text: []const u8, key: []const u8, out: []i32) usize {

    var rest = array_body(text, key) orelse return 0;
    var count: usize = 0;

    while (count < out.len) {

        const open = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse break;
        const closer = std.mem.indexOfScalar(u8, rest[0..open], ']');

        if (closer != null) break;

        out[count] = weekday_of(rest[open + 1 .. close]) orelse 0;
        count += 1;
        rest = rest[close + 1 ..];

    }

    return count;

}

fn array_body(text: []const u8, key: []const u8) ?[]const u8 {

    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const open = std.mem.indexOfScalar(u8, rest, '[') orelse return null;

    return rest[open + 1 ..];

}

/// Sakamoto's algorithm over an ISO "YYYY-MM-DD" date: 0 = Sunday.
fn weekday_of(date: []const u8) ?i32 {

    if (date.len < 10) return null;

    var year = std.fmt.parseInt(i32, date[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i32, date[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i32, date[8..10], 10) catch return null;

    if (month < 1 or month > 12) return null;

    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };

    if (month < 3) year -= 1;

    return @mod(year + @divTrunc(year, 4) - @divTrunc(year, 100) + @divTrunc(year, 400) + offsets[@intCast(month - 1)] + day, 7);

}

const testing = std.testing;

test "forecast response parses into scaled integers" {

    const payload = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" ++
        "{\"current_units\":{\"temperature_2m\":\"C\"}," ++
        "\"current\":{\"time\":\"2026-07-18T14:30\",\"temperature_2m\":21.4,\"relative_humidity_2m\":63,\"apparent_temperature\":20.1," ++
        "\"precipitation\":0.2,\"weather_code\":61,\"surface_pressure\":1013.2,\"wind_speed_10m\":12.6,\"wind_direction_10m\":225,\"is_day\":1}," ++
        "\"hourly\":{\"time\":[\"2026-07-18T00:00\",\"2026-07-18T01:00\"],\"temperature_2m\":[18.5,-0.5],\"precipitation_probability\":[10,null],\"weather_code\":[2,3]}," ++
        "\"daily\":{\"time\":[\"2026-07-18\",\"2026-07-19\"],\"temperature_2m_max\":[24.0,22.5],\"temperature_2m_min\":[16.1,15.0],\"weather_code\":[61,3]," ++
        "\"precipitation_probability_max\":[40,20],\"wind_speed_10m_max\":[18.4,12.0],\"uv_index_max\":[6.25,5.0]," ++
        "\"sunrise\":[\"2026-07-18T05:43\",\"2026-07-19T05:44\"],\"sunset\":[\"2026-07-18T21:12\",\"2026-07-19T21:11\"]}}";

    var out: Forecast = .{};

    try parse_forecast(&out, payload);

    try testing.expect(out.ready);
    try testing.expectEqual(@as(i32, 214), out.temp_dc);
    try testing.expectEqual(@as(i32, 63), out.humidity);
    try testing.expectEqual(@as(i32, 126), out.wind_dkmh);
    try testing.expectEqual(@as(i32, 14 * 60 + 30), out.now_minutes);

    try testing.expectEqual(@as(usize, 2), out.hour_count);
    try testing.expectEqual(@as(i32, 185), out.hour_temp_dc[0]);
    try testing.expectEqual(@as(i32, -5), out.hour_temp_dc[1]);
    try testing.expectEqual(@as(i32, 0), out.hour_precip[1]);

    try testing.expectEqual(@as(usize, 2), out.day_count);
    try testing.expectEqual(@as(i32, 63), out.day_uv_dx[0]);
    try testing.expectEqual(@as(i32, 5 * 60 + 43), out.day_sunrise_min[0]);

    // 2026-07-18 is a Saturday.
    try testing.expectEqual(@as(i32, 6), out.day_weekday[0]);

}
