// Calendar: browse any month and see US federal holidays. Floating holidays (nth-weekday and last-Monday rules) are computed per year, so no table ever goes stale.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Calendar",
    .description = "Browse months and holidays.",
    .icon = "calendar",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const pad: i32 = 16;
const nav_h: i32 = 34;
const day_id_base: u32 = 100;

// Packed from the top: short weekday header, fixed day cells, only as many week rows as the month needs.
const grid_gap: i32 = 3;
const header_h: i32 = 18;
const cell_h: i32 = 36;

// Detail band only when the selection is a holiday (window height follows).
const detail_gap: i32 = 6;
const detail_h: i32 = 16;
const detail_band: i32 = detail_gap + detail_h;

const win_w: u32 = 340;

const weekday_short = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };

const sunday: u32 = 0;
const monday: u32 = 1;
const thursday: u32 = 4;

const Holiday = struct {

    day: u32,
    name: []const u8,

};

const max_holidays = 4;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

// Defaults to the current month; navigation shifts it.
var view_year: i64 = 0;
var view_month: u32 = 0;
var selected_day: u32 = 1;

var regions = ui.HitRegions{};

const Nav = enum(u32) {

    prev = 1,
    next,
    today,

};

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);

    reset_view();

    window = try connection.create_window(win_w, @intCast(content_height(false)), 0, "Calendar");

    _ = lib.draw.round.masks_for(6);

    paint();

    while (true) {

        const event = try connection.wait_event();

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                paint();

            },

            events.kind_button_down => {

                if (event.code == events.button_left) {

                    click(event.x, event.y);
                    paint();

                }

            },

            events.kind_pointer_move => {

                if (regions.pointer_move(event.x, event.y)) paint();

                update_cursor(event.x, event.y);

            },

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

}

fn reset_view() void {

    const now = lib.localtime.now(lib.prefs.tz_offset_minutes);

    view_year = now.year;
    view_month = now.month;
    selected_day = now.day;

}

fn clamp_selection() void {

    const days = lib.localtime.days_in_month(view_year, view_month);

    if (selected_day < 1) selected_day = 1;
    if (selected_day > days) selected_day = days;

}

fn update_cursor(x: i32, y: i32) void {

    if (regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn click(x: i32, y: i32) void {

    const id = regions.hit(x, y);

    if (id >= day_id_base and id < day_id_base + 32) {

        selected_day = id - day_id_base;
        return;

    }

    switch (id) {

        @intFromEnum(Nav.prev) => shift_month(-1),
        @intFromEnum(Nav.next) => shift_month(1),
        @intFromEnum(Nav.today) => reset_view(),

        else => {},

    }

}

fn shift_month(delta: i32) void {

    var m: i32 = @as(i32, @intCast(view_month)) + delta;

    if (m < 1) {

        m = 12;
        view_year -= 1;

    } else if (m > 12) {

        m = 1;
        view_year += 1;

    }

    view_month = @intCast(m);
    clamp_selection();

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

// US federal holidays that fall in the viewed month, in date order.
fn holidays_in_month(year: i64, month: u32, out: *[max_holidays]Holiday) usize {

    var count: usize = 0;

    const add = struct {

        fn call(list: *[max_holidays]Holiday, at: *usize, day: u32, name: []const u8) void {

            if (at.* >= max_holidays) return;

            list[at.*] = .{ .day = day, .name = name };
            at.* += 1;

        }

    }.call;

    switch (month) {

        1 => {

            add(out, &count, 1, "New Year's Day");
            add(out, &count, nth_weekday(year, 1, monday, 3), "MLK Jr. Day");

        },

        2 => add(out, &count, nth_weekday(year, 2, monday, 3), "Presidents' Day"),

        5 => add(out, &count, last_weekday(year, 5, monday), "Memorial Day"),

        6 => add(out, &count, 19, "Juneteenth"),

        7 => add(out, &count, 4, "Independence Day"),

        9 => add(out, &count, nth_weekday(year, 9, monday, 1), "Labor Day"),

        10 => add(out, &count, nth_weekday(year, 10, monday, 2), "Columbus Day"),

        11 => {

            add(out, &count, 11, "Veterans Day");
            add(out, &count, nth_weekday(year, 11, thursday, 4), "Thanksgiving");

        },

        12 => add(out, &count, 25, "Christmas Day"),

        else => {},

    }

    return count;

}

fn holiday_name(day: u32, holidays: []const Holiday) ?[]const u8 {

    for (holidays) |holiday| {

        if (holiday.day == day) return holiday.name;

    }

    return null;

}

fn fill_dot(surface: *const gfx.Surface, cx: i32, cy: i32, radius: i32, color: gfx.Color) void {

    const d = radius * 2;

    ui.fill_round_rect(surface, .{ .x = cx - radius, .y = cy - radius, .w = d, .h = d }, radius, color);

}

// Week rows needed for the viewed month (4–6).
fn week_rows() i32 {

    const first = lib.localtime.weekday(view_year, view_month, 1);
    const days = lib.localtime.days_in_month(view_year, view_month);

    return @intCast((first + days + 6) / 7);

}

fn grid_height(rows: i32) i32 {

    return header_h + grid_gap + rows * cell_h + (rows - 1) * grid_gap;

}

fn content_height(has_detail: bool) i32 {

    const band: i32 = if (has_detail) detail_band else 0;

    return pad + nav_h + 10 + grid_height(week_rows()) + band + pad;

}

fn day_cell(grid_top: i32, grid_w: i32, col: i32, week: i32) Rect {

    const cell_w = @divTrunc(grid_w - grid_gap * 6, 7);

    return .{

        .x = pad + col * (cell_w + grid_gap),
        .y = grid_top + header_h + grid_gap + week * (cell_h + grid_gap),
        .w = cell_w,
        .h = cell_h,

    };

}

fn fit_window(has_detail: bool) void {

    const want: u32 = @intCast(content_height(has_detail));

    if (window.surface.height == want and window.surface.width == win_w) return;

    window.resize(win_w, want) catch {};

}

fn paint() void {

    var holidays: [max_holidays]Holiday = undefined;
    const holiday_count = holidays_in_month(view_year, view_month, &holidays);
    const selected_holiday = holiday_name(selected_day, holidays[0..holiday_count]);

    fit_window(selected_holiday != null);

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.window_bg);

    regions.reset();

    const now = lib.localtime.now(lib.prefs.tz_offset_minutes);
    const is_current = now.year == view_year and now.month == view_month;

    // Navigation row: prev, month/year title, Today reset, next.

    const nav_y = pad;
    const arrow_w: i32 = 34;

    const prev_rect = Rect{ .x = pad, .y = nav_y, .w = arrow_w, .h = nav_h };
    const next_rect = Rect{ .x = width - pad - arrow_w, .y = nav_y, .w = arrow_w, .h = nav_h };
    const today_rect = Rect{ .x = width - pad - arrow_w - 8 - 58, .y = nav_y, .w = 58, .h = nav_h };

    regions.add(@intFromEnum(Nav.prev), prev_rect);
    regions.add(@intFromEnum(Nav.next), next_rect);
    regions.add(@intFromEnum(Nav.today), today_rect);

    ui.widgets.button(surface, &font, prev_rect, "<", .{ .hovered = regions.hovered(@intFromEnum(Nav.prev)) }, .{ .size = 16 });
    ui.widgets.button(surface, &font, next_rect, ">", .{ .hovered = regions.hovered(@intFromEnum(Nav.next)) }, .{ .size = 16 });
    ui.widgets.button(surface, &font, today_rect, "Today", .{ .hovered = regions.hovered(@intFromEnum(Nav.today)) }, .{ .size = 13 });

    var title_buffer: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buffer, "{s} {d}", .{ lib.localtime.month_name(view_month), view_year }) catch "";

    font.draw(surface, pad + arrow_w + 8, nav_y + @divTrunc(nav_h - font.line_height(15), 2), 15, title, ui.theme.text);

    const grid_top = nav_y + nav_h + 10;
    const grid_w = width - 2 * pad;
    const cell_w = @divTrunc(grid_w - grid_gap * 6, 7);
    const rows = week_rows();
    const gh = grid_height(rows);

    var col: i32 = 0;

    while (col < 7) : (col += 1) {

        const rect = Rect{ .x = pad + col * (cell_w + grid_gap), .y = grid_top, .w = cell_w, .h = header_h };

        ui.widgets.label_in(surface, &font, rect, weekday_short[@intCast(col)], 12, ui.theme.text_faint);

    }

    const first_weekday = lib.localtime.weekday(view_year, view_month, 1);
    const days = lib.localtime.days_in_month(view_year, view_month);
    const day_size: u32 = 13;
    const day_line = font.line_height(day_size);

    var day: u32 = 1;

    while (day <= days) : (day += 1) {

        const slot = first_weekday + day - 1;
        const cell = day_cell(grid_top, grid_w, @intCast(slot % 7), @intCast(slot / 7));
        const id = day_id_base + day;

        regions.add(id, cell);

        const is_today = is_current and day == now.day;
        const is_selected = day == selected_day;
        const is_holiday = holiday_name(day, holidays[0..holiday_count]) != null;
        const is_hovered = regions.hovered(id);

        if (is_selected) {

            ui.fill_round_rect(surface, cell, 6, ui.theme.accent_dim);

        } else if (is_hovered) {

            ui.fill_round_rect(surface, cell, 6, ui.theme.hover);

        } else if (is_today) {

            ui.fill_round_rect(surface, cell, 6, ui.theme.surface_alt);

        }

        const color = if (is_selected) ui.theme.text else if (is_holiday or is_today) ui.theme.accent else ui.theme.text_dim;

        var buffer: [3]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{day}) catch "";
        const text_x = cell.x + @divTrunc(cell.w - font.text_width(text, day_size), 2);

        // Holiday days sit the number higher so the indicator has clear air above it.
        const text_y = if (is_holiday) cell.y + 5 else cell.y + @divTrunc(cell.h - day_line, 2);

        font.draw(surface, text_x, text_y, day_size, text, color);

        if (is_holiday) fill_dot(surface, cell.x + @divTrunc(cell.w, 2), cell.y + cell.h - 7, 2, ui.theme.accent);

    }

    if (selected_holiday) |name| {

        const y = grid_top + gh + detail_gap;
        const text_y = y + @divTrunc(detail_h - font.line_height(13), 2);

        fill_dot(surface, pad + 3, y + @divTrunc(detail_h, 2), 3, ui.theme.accent);
        font.draw(surface, pad + 12, text_y, 13, name, ui.theme.text_dim);

    }

    window.present_all() catch {};

}
