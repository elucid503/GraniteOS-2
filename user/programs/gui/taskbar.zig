// Taskbar: the desktop's persistent panel.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const proto = lib.proto;
const quartz = lib.quartz;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;
const WindowInfo = proto.window.WindowInfo;

comptime {

    _ = lib.start;

}

fn bar_height() i32 {

    return 40;

}

// Must match the compositor's `manager.panel_margin` (user/servers/display/manager.zig)
fn dock_margin() i32 {

    return 10;

}

// Must match the compositor's `render.corner_radius` (user/servers/display/render.zig)
fn dock_radius() i32 {

    return 8;

}

fn launcher_width() i32 {

    return 44;

}

fn clock_width() i32 {

    return 100;

}

fn calendar_width() u32 {

    return 292;

}

fn calendar_cell() i32 {

    return 34;

}

fn calendar_pad() i32 {

    return 10;

}

fn calendar_header_height() i32 {

    return 32;

}

fn calendar_weekday_height() i32 {

    return 20;

}

fn popup_gap() i32 {

    return 8;

}

fn weather_height() u32 {

    return 76;

}

/// Week rows needed for the current local month (4..=6).
fn calendar_week_rows() i32 {

    const local = lib.localtime.now(lib.prefs.tz_offset_minutes);
    const first = lib.localtime.weekday(local.year, local.month, 1);
    const days = lib.localtime.days_in_month(local.year, local.month);
    const slots = first + days;

    return @intCast((slots + 6) / 7);

}

fn calendar_height() u32 {

    // Month title, weekday labels, only as many week rows as the month needs, outer pad.
    return @intCast(calendar_pad() + calendar_header_height() + calendar_weekday_height() + calendar_cell() * calendar_week_rows() + calendar_pad());

}

fn window_button_max() i32 {

    return 184;

}

fn window_button_min() i32 {

    return 36;

}

const window_button_icon: i32 = 18;

fn button_gap() i32 {

    return 4;

}

fn menu_width() u32 {

    return @intCast(category_col_width() + 280);

}

fn category_col_width() i32 {

    return 190;

}

fn row_height() i32 {

    return 56;

}

fn search_height() i32 {

    return 46;

}

const max_apps = 32;
const max_categories = 12;
const max_menu_rows = 10;

var font: lib.draw.text.Face = undefined;
var bundle: lib.bundle.Bundle = undefined;

var connection: lib.window.Connection = undefined;
var window_list: lib.wm.List = undefined;
var bar: lib.window.Window = undefined;

var menu: ?lib.window.Window = null;
var menu_open = false;
var menu_row_limit: usize = max_menu_rows;

var pin_menu: ?lib.window.Window = null;
var pin_menu_open = false;
var pin_menu_widget = ui.Menu{};
var pin_menu_program: [lib.prefs.max_pin_program]u8 = undefined;
var pin_menu_program_len: usize = 0;
var pin_menu_pinned = false;

var calendar: ?lib.window.Window = null;
var weather_popup: ?lib.window.Window = null;
var calendar_open = false;

const WeatherState = struct {

    ready: bool = false,
    failed: bool = false,
    temperature_c: f64 = 0,
    code: u32 = 0,
    city: [proto.metrics.max_city]u8 = .{0} ** proto.metrics.max_city,
    city_len: usize = 0,

};

var weather: WeatherState = .{};
var weather_staging: WeatherState = .{};

const pin_action_row = [_]ui.Menu.Row{.{ .item = "Pin to Taskbar" }};
const unpin_action_row = [_]ui.Menu.Row{.{ .item = "Unpin from Taskbar" }};

var windows: [proto.window.max_windows]WindowInfo = undefined;
var window_count: usize = 0;

var apps: [max_apps]lib.wm.App = undefined;
var app_count: usize = 0;

// One taskbar indicator per open window, plus one per pinned app that is not currently running.
const TaskbarItem = struct {

    is_window: bool,
    window_index: usize = 0,
    app_index: usize = 0,
    has_app: bool = false,
    pinned: bool = false,

};

const max_taskbar_items = proto.window.max_windows + lib.prefs.max_taskbar_pins;

var items: [max_taskbar_items]TaskbarItem = undefined;
var item_count: usize = 0;

var pinned_programs: [lib.prefs.max_taskbar_pins]lib.prefs.TaskbarPin = undefined;
var pinned_count: usize = 0;

// Categories are derived from the apps' `category` metadata; the menu lists them and flies the active category's apps out to the side. Searching bypasses the grouping and matches across every app.
var categories: [max_categories][]const u8 = undefined;
var category_count: usize = 0;
var active_category: usize = 0;

var launch_endpoint: cap.Handle = 0;

var keyboard = lib.keymap.Keyboard{};
var search_storage: [48]u8 = undefined;
var search = ui.EditBuffer{ .bytes = &search_storage };

// Hit regions per window, rebuilt on paint; a move only repaints when the hovered id actually changes.

var bar_regions = ui.HitRegions{};
var menu_regions = ui.HitRegions{};

const launcher_id: u32 = 1;
const clock_id: u32 = 2;
const overflow_id: u32 = 99;
const window_id_base: u32 = 100;
const category_id_base: u32 = 1000;
const browse_id_base: u32 = 2000;
const search_id_base: u32 = 3000;

// Open-Meteo forecast API (plain HTTP, no key) for the weather card above the calendar.
const weather_host = "api.open-meteo.com";

var ready: cap.Handle = 0;

// Separates wake bits so the clock tick does not re-list every window over IPC.
var clock_tick: u32 = 0;
var list_tick: u32 = 0;
var weather_tick: u32 = 0;
var weather_pending: u32 = 0;
var prefs_backstop_ticks: u8 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window_list = try lib.wm.List.init(&connection, cap.memory);
    try window_list.subscribe();

    bar = try connection.create_window(0, @intCast(bar_height()), proto.window.flag_panel | proto.window.flag_quartz, "taskbar");

    app_count = lib.wm.load_apps(&bundle, apps[0..]);
    build_categories();
    launch_endpoint = lib.stream.lookup_endpoint("launch") catch 0;

    reload_pins();
    refresh_windows();
    paint_bar();

    try start_ticker();
    try start_list_watcher();
    try start_weather_worker();

    // Prefetch weather and warm the popup surfaces so the first clock click is immediate.
    ensure_weather_popup() catch {};
    ensure_calendar() catch {};
    request_weather_refresh();

    while (true) {

        while (connection.poll_event()) |event| {

            handle(event);

        }

        const list_due = @atomicRmw(u32, &list_tick, .Xchg, 0, .acquire) != 0;
        const clock_due = @atomicRmw(u32, &clock_tick, .Xchg, 0, .acquire) != 0;
        const weather_due = @atomicLoad(u32, &weather_tick, .acquire) != 0;

        if (list_due) refresh_windows();

        if (list_due) {

            paint_bar();

        } else if (clock_due) {

            prefs_backstop_ticks +|= 1;

            if (prefs_backstop_ticks >= 5) {

                prefs_backstop_ticks = 0;

                // Backstop prefs events that were dropped from a full input ring.
                if (lib.prefs.refresh_if_changed()) {

                    repaint_prefs();

                } else {

                    paint_clock_only();

                }

            } else {

                paint_clock_only();

            }

        }

        if (weather_due) {

            const update = weather_staging;

            @atomicStore(u32, &weather_tick, 0, .release);

            if (update.ready or !weather.ready) weather = update;
            if (calendar_open) paint_calendar();

        }

        _ = sys.wait(ready) catch {};

    }

}

fn refresh_windows() void {

    window_count = window_list.refresh(windows[0..]);
    rebuild_items();

}

fn reload_pins() void {

    pinned_count = lib.prefs.load_taskbar_pins(pinned_programs[0..]);

}

fn is_pinned_program(program: []const u8) bool {

    for (pinned_programs[0..pinned_count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), program)) return true;

    }

    return false;

}

fn app_index_for_title(title: []const u8) ?usize {

    for (apps[0..app_count], 0..) |app, index| {

        if (std.mem.eql(u8, app.title, title)) return index;

    }

    return null;

}

fn app_index_for_program(program: []const u8) ?usize {

    for (apps[0..app_count], 0..) |app, index| {

        if (std.mem.eql(u8, app.program, program)) return index;

    }

    return null;

}

/// Merge open windows with pinned idle apps into one indicator list.
fn rebuild_items() void {

    item_count = 0;

    for (windows[0..window_count], 0..) |info, window_index| {

        if (item_count >= items.len) break;

        const title = info.title[0..@min(@as(usize, @intCast(info.title_len)), proto.window.max_title)];
        const app_index = app_index_for_title(title);
        const pinned = if (app_index) |index| is_pinned_program(apps[index].program) else false;

        items[item_count] = .{

            .is_window = true,
            .window_index = window_index,
            .app_index = app_index orelse 0,
            .has_app = app_index != null,
            .pinned = pinned,

        };

        item_count += 1;

    }

    for (pinned_programs[0..pinned_count]) |pin| {

        if (item_count >= items.len) break;

        var already_open = false;

        for (items[0..item_count]) |existing| {

            if (!existing.is_window or !existing.has_app) continue;
            if (std.mem.eql(u8, apps[existing.app_index].program, pin.slice())) {

                already_open = true;
                break;

            }

        }

        if (already_open) continue;

        const app_index = app_index_for_program(pin.slice()) orelse continue;

        items[item_count] = .{

            .is_window = false,
            .app_index = app_index,
            .has_app = true,
            .pinned = true,

        };

        item_count += 1;

    }

}

// Event handling

fn handle(event: events.Event) void {

    if (lib.prefs.apply_event(event)) {

        prefs_backstop_ticks = 0;
        repaint_prefs();
        return;

    }

    if (pin_menu) |pin_menu_window| {

        if (event.window == pin_menu_window.id) return handle_pin_menu(event);

    }

    if (weather_popup) |weather_window| {

        if (event.window == weather_window.id) return handle_weather_popup(event);

    }

    if (calendar) |calendar_window| {

        if (event.window == calendar_window.id) return handle_calendar(event);

    }

    if (menu) |menu_window| {

        if (event.window == menu_window.id) return handle_menu(event);

    }

    if (event.window == bar.id) handle_bar(event);

}

fn update_bar_cursor(x: i32, y: i32) void {

    const id = bar_regions.hit(x, y);

    if (id != 0 and id != overflow_id) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn update_calendar_cursor(_: i32, _: i32) void {

    lib.cursor.set(&connection, .pointer);

}

fn update_menu_cursor(x: i32, y: i32) void {

    if (y < search_height()) lib.cursor.set(&connection, .selector)
    else if (menu_regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

/// Redraw every taskbar surface for the current preferences.
fn repaint_prefs() void {

    reload_pins();
    rebuild_items();
    paint_bar();

    refresh_quartz_popups();

}

/// Refresh minimized popup surfaces so restoring one cannot show stale material.
fn refresh_quartz_popups() void {

    if (menu != null) {

        paint_menu_content();
        if (menu_open) if (menu) |window| window.present_all() catch {};

    }

    if (pin_menu != null) {

        paint_pin_menu_content();
        if (pin_menu_open) if (pin_menu) |window| window.present_all() catch {};

    }

    if (weather_popup != null) {

        paint_weather_content();
        if (calendar_open) if (weather_popup) |window| window.present_all() catch {};

    }

    if (calendar != null) {

        paint_calendar_content();
        if (calendar_open) if (calendar) |window| window.present_all() catch {};

    }

}

fn clock_hover_rect(clock_rect: Rect) Rect {

    const hover_w: i32 = 76;

    return .{

        .x = clock_rect.x + @divTrunc(clock_rect.w - hover_w, 2),
        .y = 4,
        .w = hover_w,
        .h = bar_height() - 8,

    };

}

fn handle_bar(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => {

            const id = bar_regions.hit(event.x, event.y);

            if (event.code == events.button_left) {

                close_pin_menu();

                if (id == launcher_id) {

                    close_calendar();
                    toggle_menu();
                    return;

                }

                if (id == clock_id) {

                    toggle_calendar();
                    return;

                }

                close_calendar();

                if (id >= window_id_base) activate_item(id - window_id_base);

                return;

            }

            if (event.code == events.button_right) {

                if (id >= window_id_base) open_pin_menu(id - window_id_base, event.x);

            }

        },

        events.kind_pointer_move => {

            const previous = bar_regions.hovered_id();

            if (bar_regions.pointer_move(event.x, event.y)) {

                const current = bar_regions.hovered_id();
                const changed = hover_damage(&bar_regions, previous, current);

                if (!changed.is_empty()) paint_bar_damage(changed) else paint_bar();

            }

            update_bar_cursor(event.x, event.y);

        },

        events.kind_window_resize => {

            bar.resize(@intCast(event.x), @intCast(bar_height())) catch {};

            if (lib.wm.screen_info(&connection)) |screen| {

                menu_row_limit = menu_rows_for_screen(screen.height);

                if (menu_open) {

                    sync_menu_size(true);

                    if (menu) |menu_window| {

                        lib.wm.move_window(&connection, menu_window.id, dock_margin(), menu_y(screen.height, menu_window.surface.height)) catch {};

                    }

                }

            } else |_| {}

            close_pin_menu();
            close_calendar();

            refresh_windows();
            paint_bar();

            if (menu_open) paint_menu();

        },

        else => {},

    }

}

fn handle_menu(event: events.Event) void {

    switch (event.kind) {

        events.kind_key_down => menu_key(event.code),

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

        events.kind_button_down => {

            if (event.code == events.button_left) menu_click(event.x, event.y);

        },

        events.kind_pointer_move => {

            var need = false;
            var category_changed = false;
            const previous = menu_regions.hovered_id();

            // Hovering a category flies its apps out to the side, so the active group tracks the pointer.
            if (!searching() and event.x < category_col_width()) {

                if (category_at(event.y)) |index| {

                    if (index != active_category) {

                        active_category = index;
                        need = true;
                        category_changed = true;

                    }

                }

            }

            if (menu_regions.pointer_move(event.x, event.y)) need = true;

            if (need) {

                const current = menu_regions.hovered_id();
                const changed = hover_damage(&menu_regions, previous, current);

                if (!category_changed and !changed.is_empty()) paint_menu_damage(changed) else paint_menu();

            }

            update_menu_cursor(event.x, event.y);

        },

        events.kind_window_blur => close_menu(),

        else => {},

    }

}

fn activate_item(index: usize) void {

    if (index >= item_count) return;

    const item = items[index];

    if (item.is_window) {

        activate_window(item.window_index);

    } else if (item.has_app) {

        launch(apps[item.app_index].program);

    }

}

fn activate_window(index: usize) void {

    if (index >= window_count) return;

    const entry = windows[index];

    if (entry.minimized != 0) {

        lib.wm.restore(&connection, entry.id) catch {};

    } else if (entry.focused != 0) {

        // Clicking the focused window's taskbar button minimizes it (classic toggle).
        lib.wm.minimize(&connection, entry.id) catch {};

    } else {

        lib.wm.activate(&connection, entry.id) catch {};

    }

}

fn menu_key(code: u16) void {

    if (keyboard.modifier(events.kind_key_down, code)) return;

    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len == 0) return;

    if (bytes.len == 1) {

        switch (bytes[0]) {

            '\r' => return launch_first(),
            0x1b => return close_menu(),

            else => {},

        }

    }

    // Printable bytes, Backspace/Delete, and the arrow escapes all flow through the shared edit buffer.

    if (search.feed(bytes, keyboard.shift)) paint_menu();

}

fn menu_click(x: i32, y: i32) void {

    const width: i32 = if (menu) |m| @intCast(m.surface.width) else 0;
    const text_rect = search_text_rect(width);

    if (text_rect.contains(x, y)) {

        const index = ui.field_click_index(&font, search.slice(), 13, search.cursor, text_rect.w, x - text_rect.x);

        _ = search.set_cursor(index, keyboard.shift);
        paint_menu();

        return;

    }

    const id = menu_regions.hit(x, y);

    if (id == 0) return;

    if (id >= search_id_base) {

        if (search_app(id - search_id_base)) |app| {

            launch(app.program);
            close_menu();

        }

        return;

    }

    if (id >= browse_id_base) {

        if (category_app(active_category, id - browse_id_base)) |app| {

            launch(app.program);
            close_menu();

        }

        return;

    }

    const index = id - category_id_base;

    if (index != active_category) {

        active_category = index;
        paint_menu();

    }

}

fn searching() bool {

    return search.slice().len != 0;

}

fn app_category(app: lib.wm.App) []const u8 {

    return if (app.category.len == 0) "Other" else app.category;

}

// Collect the distinct category names in alphabetical order so grouping is stable across launches.
fn build_categories() void {

    category_count = 0;

    for (apps[0..app_count]) |app| {

        const name = app_category(app);
        var seen = false;

        for (categories[0..category_count]) |existing| {

            if (std.mem.eql(u8, existing, name)) {

                seen = true;
                break;

            }

        }

        if (!seen and category_count < max_categories) {

            categories[category_count] = name;
            category_count += 1;

        }

    }

    var i: usize = 0;

    while (i < category_count) : (i += 1) {

        var j = i + 1;

        while (j < category_count) : (j += 1) {

            if (std.mem.order(u8, categories[j], categories[i]) == .lt) {

                const tmp = categories[i];
                categories[i] = categories[j];
                categories[j] = tmp;

            }

        }

    }

    if (active_category >= category_count) active_category = 0;

}

fn category_size(index: usize) usize {

    if (index >= category_count) return 0;

    const name = categories[index];
    var count: usize = 0;

    for (apps[0..app_count]) |app| {

        if (std.mem.eql(u8, app_category(app), name)) count += 1;

    }

    return count;

}

fn category_app(index: usize, nth: usize) ?lib.wm.App {

    if (index >= category_count) return null;

    const name = categories[index];
    var k: usize = 0;

    for (apps[0..app_count]) |app| {

        if (!std.mem.eql(u8, app_category(app), name)) continue;

        if (k == nth) return app;

        k += 1;

    }

    return null;

}

fn match_count() usize {

    var count: usize = 0;

    for (apps[0..app_count]) |app| {

        if (matches(app)) count += 1;

    }

    return count;

}

fn search_app(nth: usize) ?lib.wm.App {

    var k: usize = 0;

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

        if (k == nth) return app;

        k += 1;

    }

    return null;

}

fn row_at(y: i32) ?usize {

    if (y < search_height()) return null;

    const row = @divTrunc(y - search_height(), row_height());

    if (row < 0) return null;

    return @intCast(row);

}

fn category_at(y: i32) ?usize {

    const row = row_at(y) orelse return null;

    return if (row < category_count) row else null;

}

fn launch_first() void {

    for (apps[0..app_count]) |app| {

        if (matches(app)) {

            launch(app.program);
            close_menu();
            return;

        }

    }

}

fn toggle_menu() void {

    if (menu_open) {

        close_menu();

    } else {

        open_menu();

    }

}

// Browse height tracks tallest category column so hover does not resize the menu.
fn browse_rows() usize {

    var rows = category_count;
    var i: usize = 0;

    while (i < category_count) : (i += 1) {

        rows = @max(rows, category_size(i));

    }

    return rows;

}

fn view_rows() usize {

    const rows = if (searching()) match_count() else browse_rows();

    return @min(rows, menu_row_limit);

}

fn menu_rows_for_screen(screen_height: u32) usize {

    const reserved: i64 = bar_height() + dock_margin() + search_height() + 28;
    const row: i64 = row_height();
    const available = @as(i64, screen_height) - reserved;

    if (available <= row) return 1;

    return @min(max_menu_rows, @as(usize, @intCast(@divTrunc(available, row))));

}

fn menu_height() u32 {

    const rows: i32 = @intCast(@max(view_rows(), 1));

    return @intCast(search_height() + rows * row_height() + 8);

}

fn menu_y(screen_height: u32, height: u32) i32 {

    return @as(i32, @intCast(screen_height)) - bar_height() - dock_margin() - @as(i32, @intCast(height)) - 10;

}

fn sync_menu_size(allow_shrink: bool) void {

    if (menu) |*menu_window| {

        const height = menu_height();

        if (menu_window.surface.height == height) return;
        if (!allow_shrink and menu_window.surface.height > height) return;

        menu_window.resize(menu_width(), height) catch return;

        if (lib.wm.screen_info(&connection)) |screen| {

            lib.wm.move_window(&connection, menu_window.id, dock_margin(), menu_y(screen.height, menu_window.surface.height)) catch {};

        } else |_| {}

    }

}

fn ensure_menu() !void {

    if (menu != null) return;

    const screen = try lib.wm.screen_info(&connection);

    menu_row_limit = menu_rows_for_screen(screen.height);

    const height = menu_height();
    var menu_window = try connection.create_window(menu_width(), height, proto.window.flag_undecorated | proto.window.flag_quartz, "menu");

    menu_window.surface.fill(ui.theme.window_bg);

    try lib.wm.minimize(&connection, menu_window.id);

    try lib.wm.move_window(&connection, menu_window.id, dock_margin(), menu_y(screen.height, menu_window.surface.height));

    menu = menu_window;

}

fn open_menu() void {

    close_pin_menu();
    close_calendar();

    // Covers a prefs_changed dropped while closed, so the menu opens with the current material.
    _ = lib.prefs.refresh_if_changed();

    ensure_menu() catch return;

    search.clear();
    active_category = 0;

    _ = menu_regions.leave();

    // Reopen at the browse size after a prior search expanded the backing surface.
    sync_menu_size(true);

    const menu_window = menu orelse return;

    if (lib.wm.screen_info(&connection)) |screen| {

        lib.wm.move_window(&connection, menu_window.id, dock_margin(), menu_y(screen.height, menu_window.surface.height)) catch {};

    } else |_| {}

    menu_open = true;

    paint_menu_content();

    gfx.fence();
    lib.wm.restore(&connection, menu_window.id) catch {};
    menu_window.present_all() catch {};

    paint_bar();

}

fn close_menu() void {

    if (!menu_open) return;

    if (menu) |menu_window| lib.wm.minimize(&connection, menu_window.id) catch {};

    menu_open = false;

    paint_bar();

}

// The pin action row is always exactly one row tall...
fn pin_menu_width() u32 {

    return @intCast(pin_menu_widget.width);

}

fn pin_menu_height() u32 {

    return @intCast(pin_menu_widget.row_height + pin_menu_widget.inset * 2);

}

fn ensure_pin_menu() !void {

    if (pin_menu != null) return;

    var window = try connection.create_window(pin_menu_width(), pin_menu_height(), proto.window.flag_undecorated | proto.window.flag_quartz, "pin-menu");

    window.surface.fill(ui.theme.surface);

    try lib.wm.minimize(&connection, window.id);

    pin_menu = window;

}

/// Opens the "Pin to Taskbar" / "Unpin from Taskbar" popup.
fn open_pin_menu(index: usize, local_x: i32) void {

    if (index >= item_count) return;

    const item = items[index];

    if (!item.has_app) return;

    close_menu();
    close_calendar();

    // Covers a prefs_changed dropped while closed, so the popup opens with the current material.
    _ = lib.prefs.refresh_if_changed();

    ensure_pin_menu() catch return;

    const program = apps[item.app_index].program;

    pin_menu_program_len = @min(program.len, pin_menu_program.len);
    @memcpy(pin_menu_program[0..pin_menu_program_len], program[0..pin_menu_program_len]);
    pin_menu_pinned = item.pinned;

    const rows: []const ui.Menu.Row = if (pin_menu_pinned) unpin_action_row[0..] else pin_action_row[0..];
    const window = pin_menu orelse return;

    pin_menu_widget.open_at(rows, 0, 0, @intCast(pin_menu_width()), @intCast(pin_menu_height()));

    if (lib.wm.screen_info(&connection)) |screen| {

        const max_x = @as(i32, @intCast(screen.width)) - @as(i32, @intCast(pin_menu_width()));
        const screen_x = std.math.clamp(dock_margin() + local_x, 0, @max(0, max_x));
        const popup_y = @as(i32, @intCast(screen.height)) - bar_height() - dock_margin() - @as(i32, @intCast(pin_menu_height())) - 10;

        lib.wm.move_window(&connection, window.id, screen_x, popup_y) catch {};

    } else |_| {}

    pin_menu_open = true;

    paint_pin_menu_content();

    gfx.fence();
    lib.wm.restore(&connection, window.id) catch {};
    window.present_all() catch {};

}

fn close_pin_menu() void {

    if (!pin_menu_open) return;

    if (pin_menu) |window| lib.wm.minimize(&connection, window.id) catch {};

    pin_menu_open = false;

}

fn paint_pin_menu_content() void {

    const window = pin_menu orelse return;
    const surface = &window.surface;

    if (lib.prefs.quartz_level == .off) {

        surface.fill(ui.theme.surface);
        pin_menu_widget.paint(surface, &font);

        return;

    }

    panel(surface, surface.bounds(), ui.theme.surface);
    pin_menu_widget.paint_content(surface, &font);

}

fn paint_pin_menu() void {

    paint_pin_menu_content();

    if (pin_menu) |window| window.present_all() catch {};

}

fn handle_pin_menu(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => {

            if (event.code == events.button_left) pin_menu_click(event.x, event.y);

        },

        events.kind_pointer_move => {

            if (pin_menu_widget.pointer_move(event.x, event.y)) paint_pin_menu();

        },

        events.kind_key_down => {

            if (keyboard.modifier(events.kind_key_down, event.code)) return;

            var buffer: [3]u8 = undefined;
            const bytes = keyboard.bytes(event.code, &buffer);

            if (bytes.len == 1 and bytes[0] == 0x1b) close_pin_menu();

        },

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

        events.kind_window_blur => close_pin_menu(),

        else => {},

    }

}

fn pin_menu_click(x: i32, y: i32) void {

    if (pin_menu_widget.hit(x, y) == null) {

        close_pin_menu();
        return;

    }

    const program = pin_menu_program[0..pin_menu_program_len];
    const previous_count = pinned_count;
    var previous = [_]lib.prefs.TaskbarPin{.{}} ** lib.prefs.max_taskbar_pins;

    @memcpy(previous[0..previous_count], pinned_programs[0..previous_count]);

    if (pin_menu_pinned) {

        untrack_pinned_program(program);

    } else {

        track_pinned_program(program);

    }

    if (!lib.prefs.save_taskbar_pins(pinned_programs[0..pinned_count])) {

        pinned_programs = previous;
        pinned_count = previous_count;

    }

    close_pin_menu();

    rebuild_items();
    paint_bar();

}

// Clock popups: separate weather card + calendar card (two windows).

fn toggle_calendar() void {

    if (calendar_open) {

        close_calendar();

    } else {

        open_calendar();

    }

}

fn ensure_weather_popup() !void {

    if (weather_popup) |*window| {

        window.resize(calendar_width(), weather_height()) catch {};
        return;

    }

    var window = try connection.create_window(calendar_width(), weather_height(), proto.window.flag_undecorated | proto.window.flag_quartz, "weather");

    window.surface.fill(ui.theme.surface);

    try lib.wm.minimize(&connection, window.id);

    weather_popup = window;

}

fn ensure_calendar() !void {

    if (calendar) |*window| {

        window.resize(calendar_width(), calendar_height()) catch {};
        return;

    }

    var window = try connection.create_window(calendar_width(), calendar_height(), proto.window.flag_undecorated | proto.window.flag_quartz, "calendar");

    window.surface.fill(ui.theme.surface);

    try lib.wm.minimize(&connection, window.id);

    calendar = window;

}

fn open_calendar() void {

    close_menu();
    close_pin_menu();

    // Prefer latest temp unit before painting (covers missed prefs_changed while closed).
    _ = lib.prefs.refresh_if_changed();

    ensure_weather_popup() catch return;
    ensure_calendar() catch return;

    const weather_window = weather_popup orelse return;
    const calendar_window = calendar orelse return;

    if (lib.wm.screen_info(&connection)) |screen| {

        const popup_x = @as(i32, @intCast(screen.width)) - @as(i32, @intCast(calendar_width())) - dock_margin();
        const calendar_y = @as(i32, @intCast(screen.height)) - bar_height() - dock_margin() - @as(i32, @intCast(calendar_height())) - 10;
        const weather_y = calendar_y - popup_gap() - @as(i32, @intCast(weather_height()));

        lib.wm.move_window(&connection, weather_window.id, @max(0, popup_x), @max(0, weather_y)) catch {};
        lib.wm.move_window(&connection, calendar_window.id, @max(0, popup_x), @max(0, calendar_y)) catch {};

    } else |_| {}

    calendar_open = true;

    // Paint cached/loading weather immediately; HTTP runs on the weather worker.
    paint_weather_content();
    paint_calendar_content();

    gfx.fence();
    lib.wm.restore(&connection, weather_window.id) catch {};
    weather_window.present_all() catch {};
    lib.wm.restore(&connection, calendar_window.id) catch {};
    calendar_window.present_all() catch {};

    paint_bar();
    request_weather_refresh();

}

fn close_calendar() void {

    if (!calendar_open) return;

    if (weather_popup) |window| lib.wm.minimize(&connection, window.id) catch {};
    if (calendar) |window| lib.wm.minimize(&connection, window.id) catch {};

    calendar_open = false;

    paint_bar();

}

fn handle_weather_popup(event: events.Event) void {

    switch (event.kind) {

        events.kind_pointer_move => update_calendar_cursor(event.x, event.y),

        events.kind_key_down => {

            if (keyboard.modifier(events.kind_key_down, event.code)) return;

            var buffer: [3]u8 = undefined;
            const bytes = keyboard.bytes(event.code, &buffer);

            if (bytes.len == 1 and bytes[0] == 0x1b) close_calendar();

        },

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

        // Weather is display-only; ignore blur so focus can sit on the calendar card below.
        else => {},

    }

}

fn handle_calendar(event: events.Event) void {

    switch (event.kind) {

        events.kind_pointer_move => update_calendar_cursor(event.x, event.y),

        events.kind_key_down => {

            if (keyboard.modifier(events.kind_key_down, event.code)) return;

            var buffer: [3]u8 = undefined;
            const bytes = keyboard.bytes(event.code, &buffer);

            if (bytes.len == 1 and bytes[0] == 0x1b) close_calendar();

        },

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

        events.kind_window_blur => close_calendar(),

        else => {},

    }

}

fn paint_calendar() void {

    paint_weather_content();
    paint_calendar_content();

    if (weather_popup) |window| window.present_all() catch {};
    if (calendar) |window| window.present_all() catch {};

}

fn paint_weather_content() void {

    const window = weather_popup orelse return;
    const surface = &window.surface;

    panel(surface, surface.bounds(), ui.theme.surface);

    const pad = calendar_pad();
    const rect = Rect{

        .x = pad,
        .y = pad,
        .w = @as(i32, @intCast(surface.width)) - pad * 2,
        .h = @as(i32, @intCast(surface.height)) - pad * 2,

    };

    if (weather.ready) {

        const city = weather.city[0..weather.city_len];
        const place = if (city.len == 0) "Local weather" else city;

        var temp_buffer: [24]u8 = undefined;
        const temp_text = format_temperature(&temp_buffer, weather.temperature_c) catch "-";
        const condition = weather_condition(weather.code);
        const icon = weather_icon(weather.code);
        const icon_size: i32 = 32;
        const icon_rect = Rect{

            .x = rect.x + rect.w - icon_size - 2,
            .y = rect.y + @divTrunc(rect.h - icon_size, 2),
            .w = icon_size,
            .h = icon_size,

        };

        draw_text(surface, rect.x + 4, rect.y + 2, 13, place, ui.theme.text_dim);
        draw_text(surface, rect.x + 4, rect.y + 24, 20, temp_text, ui.theme.text);

        const temp_w = font.text_width(temp_text, 20);

        draw_text(surface, rect.x + 4 + temp_w + 10, rect.y + 30, 13, condition, ui.theme.text_dim);
        lib.draw.vector.icon_in(surface, icon_rect, icon, ui.theme.text);

        return;

    }

    if (weather.failed) {

        draw_text(surface, rect.x + 4, rect.y + 20, 13, "Weather unavailable", ui.theme.text_dim);
        return;

    }

    draw_text(surface, rect.x + 4, rect.y + 20, 13, "Loading weather...", ui.theme.text_dim);

}

fn format_temperature(buffer: []u8, celsius: f64) ![]const u8 {

    if (lib.prefs.temp_unit == .fahrenheit) {

        const fahrenheit = celsius * 9.0 / 5.0 + 32.0;

        return std.fmt.bufPrint(buffer, "{d:.0} F", .{fahrenheit});

    }

    return std.fmt.bufPrint(buffer, "{d:.0} C", .{celsius});

}

fn paint_calendar_content() void {

    const window = calendar orelse return;
    const surface = &window.surface;
    const pad = calendar_pad();

    panel(surface, surface.bounds(), ui.theme.surface);

    const grid_rect = Rect{

        .x = pad,
        .y = pad,
        .w = @as(i32, @intCast(surface.width)) - pad * 2,
        .h = @as(i32, @intCast(surface.height)) - pad * 2,

    };

    paint_month_grid(surface, grid_rect);

}

fn paint_month_grid(surface: *const gfx.Surface, rect: Rect) void {

    const local = lib.localtime.now(lib.prefs.tz_offset_minutes);
    const year = local.year;
    const month = local.month;
    const today = local.day;

    var title_buffer: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buffer, "{s} {d}", .{ lib.localtime.month_name(month), year }) catch "Calendar";

    const title_y = rect.y + @divTrunc(calendar_header_height() - font.line_height(15), 2);

    draw_text(surface, rect.x + 4, title_y, 15, title, ui.theme.text);

    const weekday_names = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
    const cell_w = @divTrunc(rect.w, 7);
    const labels_y = rect.y + calendar_header_height();

    for (weekday_names, 0..) |name, index| {

        const cell = Rect{

            .x = rect.x + @as(i32, @intCast(index)) * cell_w,
            .y = labels_y,
            .w = cell_w,
            .h = calendar_weekday_height(),

        };

        text_center(surface, cell, 11, name, ui.theme.text_faint);

    }

    const first_weekday = lib.localtime.weekday(year, month, 1);
    const month_days = lib.localtime.days_in_month(year, month);
    const grid_y = labels_y + calendar_weekday_height();
    const cell_h = calendar_cell();

    var day: u32 = 1;

    while (day <= month_days) : (day += 1) {

        const slot = first_weekday + day - 1;
        const col: i32 = @intCast(slot % 7);
        const row: i32 = @intCast(slot / 7);

        const cell = Rect{

            .x = rect.x + col * cell_w,
            .y = grid_y + row * cell_h,
            .w = cell_w,
            .h = cell_h,

        };

        var day_buffer: [4]u8 = undefined;
        const day_text = std.fmt.bufPrint(&day_buffer, "{d}", .{day}) catch continue;

        if (day == today) {

            const mark_size: i32 = 24;
            const mark = Rect{

                .x = cell.x + @divTrunc(cell.w - mark_size, 2),
                .y = cell.y + @divTrunc(cell.h - mark_size, 2),
                .w = mark_size,
                .h = mark_size,

            };

            ui.fill_round_rect(surface, mark, mark_size, ui.theme.accent_dim);
            text_center(surface, cell, 13, day_text, ui.theme.text);

        } else {

            text_center(surface, cell, 13, day_text, ui.theme.text);

        }

    }

}

/// Ask the weather worker to refresh; no-op if a fetch is already in flight.
fn request_weather_refresh() void {

    if (@atomicRmw(u32, &weather_pending, .Xchg, 1, .acq_rel) != 0) return;

    sys.notify(ready, proto.window.ring_bit) catch {};

}

/// Metrics location must succeed before the Open-Meteo call runs.
fn refresh_weather() void {

    var next: WeatherState = .{};

    const location = metrics_location() catch {

        next.failed = true;
        weather_staging = next;

        return;

    };

    const city_len = @min(location.city_len, next.city.len);

    @memcpy(next.city[0..city_len], location.city[0..city_len]);
    next.city_len = city_len;

    fetch_weather_into(&next, location.lat, location.lon) catch {

        next.failed = true;
        weather_staging = next;

        return;

    };

    weather_staging = next;

}

const MetricsLocation = struct {

    lat: f64,
    lon: f64,
    city: [proto.metrics.max_city]u8,
    city_len: usize,

};

fn metrics_location() !MetricsLocation {

    const endpoint = try lib.stream.lookup_endpoint("metrics");
    const reply = try ipc.request(endpoint, proto.metrics.get_location, &.{}, &.{});

    if (reply.data[1] != proto.metrics.status_ready) return error.Unavailable;

    var city = [_]u8{0} ** proto.metrics.max_city;

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

fn fetch_weather_into(out: *WeatherState, lat: f64, lon: f64) !void {

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/v1/forecast?latitude={d:.4}&longitude={d:.4}&current_weather=true", .{ lat, lon });

    var socket = try lib.net.Socket.connect_host(cap.memory, weather_host, 80);
    defer socket.close();

    var request_buffer: [256]u8 = undefined;
    const http_request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, weather_host });

    try socket.send_all(http_request);

    var response: [4096]u8 = undefined;
    var length: usize = 0;

    while (length < response.len) {

        const read = socket.recv(response[length..]) catch break;

        if (read == 0) break;

        length += read;

    }

    try parse_weather_response(out, response[0..length]);

}

fn parse_weather_response(out: *WeatherState, bytes: []const u8) !void {

    const body_start = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.Invalid;
    const body = bytes[body_start + 4 ..];

    // Open-Meteo emits unit strings under current_weather_units first (same key names).
    // Scope parsing to the current_weather object so temperature/weathercode are numeric.
    const marker = "\"current_weather\":{";
    const at = std.mem.indexOf(u8, body, marker) orelse return error.Invalid;
    const section = body[at + marker.len - 1 ..];

    const temperature = json_float_near(section, "\"temperature\":") orelse return error.Invalid;
    const code = json_int_near(section, "\"weathercode\":") orelse
        json_int_near(section, "\"weather_code\":") orelse
        return error.Invalid;

    out.temperature_c = temperature;
    out.code = @intCast(@max(code, 0));
    out.ready = true;
    out.failed = false;

}

fn json_float_near(body: []const u8, key: []const u8) ?f64 {

    const token = json_number_token(body, key) orelse return null;

    return std.fmt.parseFloat(f64, token) catch null;

}

fn json_int_near(body: []const u8, key: []const u8) ?i64 {

    const token = json_number_token(body, key) orelse return null;

    return std.fmt.parseInt(i64, token, 10) catch null;

}

fn json_number_token(body: []const u8, key: []const u8) ?[]const u8 {

    const at = std.mem.indexOf(u8, body, key) orelse return null;
    var rest = body[at + key.len ..];

    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];

    var end: usize = 0;

    while (end < rest.len) : (end += 1) {

        const c = rest[end];

        if (c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' or (c >= '0' and c <= '9')) continue;

        break;

    }

    if (end == 0) return null;

    return rest[0..end];

}

fn weather_condition(code: u32) []const u8 {

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

/// Rough day window (local): 06:00 inclusive … 20:00 exclusive. No sunrise/sunset model yet.
fn weather_is_daytime() bool {

    const local = lib.localtime.now(lib.prefs.tz_offset_minutes);

    return local.hour >= 6 and local.hour < 20;

}

fn weather_icon(code: u32) []const u8 {

    const day = weather_is_daytime();

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

fn track_pinned_program(program: []const u8) void {

    for (pinned_programs[0..pinned_count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), program)) return;

    }

    if (pinned_count >= pinned_programs.len) return;

    var entry: lib.prefs.TaskbarPin = .{};
    const length = @min(program.len, entry.program.len);

    @memcpy(entry.program[0..length], program[0..length]);
    entry.length = @intCast(length);

    pinned_programs[pinned_count] = entry;
    pinned_count += 1;

}

fn untrack_pinned_program(program: []const u8) void {

    var write_index: usize = 0;

    for (pinned_programs[0..pinned_count]) |pin| {

        if (std.mem.eql(u8, pin.slice(), program)) continue;

        pinned_programs[write_index] = pin;
        write_index += 1;

    }

    pinned_count = write_index;

}

fn launch(program: []const u8) void {

    if (launch_endpoint == 0) {

        launch_endpoint = lib.stream.lookup_endpoint("launch") catch return;

    }

    var words = [_]u64{ program.len, 0, 0, 0, 0 };
    var packed_name = [_]u8{0} ** proto.launch.max_length;

    const length = @min(program.len, packed_name.len);
    @memcpy(packed_name[0..length], program[0..length]);

    for (0..4) |index| {

        words[index + 1] = std.mem.readInt(u64, packed_name[index * 8 ..][0..8], .little);

    }

    _ = ipc.request(launch_endpoint, proto.launch.spawn, &words, &.{}) catch {};

}

// Rendering

const ButtonLayout = struct {

    start: i32,
    width: i32,
    visible: usize,
    overflow: bool,
    overflow_x: i32,

};

fn button_layout() ButtonLayout {

    const start = launcher_width() + button_gap();
    const end = @as(i32, @intCast(bar.surface.width)) - clock_width() - button_gap();
    const available = end - start;

    if (item_count == 0 or available <= 0) {

        return .{ .start = start, .width = 0, .visible = 0, .overflow = false, .overflow_x = start };

    }

    // Fit as many buttons as possible at a usable width; shrink first, then overflow.
    var count = item_count;
    var width = @divTrunc(available - button_gap() * @as(i32, @intCast(count)), @as(i32, @intCast(count)));

    if (width > window_button_max()) width = window_button_max();

    if (width < window_button_min()) {

        const slot = window_button_min() + button_gap();
        const fit: usize = @intCast(@max(0, @divTrunc(available, slot)));

        count = @min(item_count, @max(@as(usize, 1), fit));
        width = window_button_min();

        if (count < item_count and count > 0) {

            // Reserve one slot for the overflow indicator.
            count = @max(@as(usize, 1), count - 1);

        }

    }

    const overflow = count < item_count;
    const overflow_x = start + @as(i32, @intCast(count)) * (width + button_gap());

    return .{

        .start = start,
        .width = @max(0, width),
        .visible = count,
        .overflow = overflow,
        .overflow_x = overflow_x,

    };

}

fn paint_bar() void {

    const surface = &bar.surface;

    paint_bar_content(surface);

    bar.present_all() catch {};

}

fn paint_bar_damage(damage: Rect) void {

    const target = damage.intersect(bar.surface.bounds());

    if (target.is_empty()) return;

    const clipped = bar.surface.clipped(target);

    paint_bar_content(&clipped);
    bar.present(target) catch {};

}

fn paint_bar_content(surface: *const gfx.Surface) void {

    const width: i32 = @intCast(surface.width);

    panel(surface, surface.bounds(), ui.theme.surface_alt);

    bar_regions.reset();

    // Launcher button.

    const icon_size: i32 = 22;
    const hover_h: i32 = 32;
    const launcher_hover = Rect{

        .x = 4,
        .y = @divTrunc(bar_height() - hover_h, 2),
        .w = launcher_width() - 8,
        .h = hover_h,

    };

    bar_regions.add(launcher_id, .{ .x = 0, .y = 0, .w = launcher_width(), .h = bar_height() });

    const launcher_hovered = bar_regions.hovered(launcher_id);

    if (menu_open) {

        ui.fill_round_rect(surface, launcher_hover, 5, ui.theme.accent_dim);

    } else if (launcher_hovered) {

        ui.fill_round_rect(surface, launcher_hover, 5, ui.theme.hover);

    }

    const icon_x = @divTrunc(launcher_width() - icon_size, 2);
    const icon_y = @divTrunc(bar_height() - icon_size, 2);

    lib.draw.vector.icon_in(surface, .{ .x = icon_x, .y = icon_y, .w = icon_size, .h = icon_size }, lib.icons.apps, ui.theme.text);

    // Window buttons.

    const layout = button_layout();
    var index: usize = 0;

    while (index < layout.visible and layout.width > 0) : (index += 1) {

        const x = layout.start + @as(i32, @intCast(index)) * (layout.width + button_gap());
        const rect = Rect{ .x = x, .y = 5, .w = layout.width, .h = bar_height() - 10 };
        const id = window_id_base + @as(u32, @intCast(index));

        bar_regions.add(id, .{ .x = x, .y = 0, .w = layout.width, .h = bar_height() });

        const item = items[index];
        const info_entry: ?WindowInfo = if (item.is_window) windows[item.window_index] else null;
        const focused = if (info_entry) |entry| entry.focused != 0 else false;
        const minimized = if (info_entry) |entry| entry.minimized != 0 else false;
        const hovered = bar_regions.hovered(id);

        const fill = if (minimized) ui.theme.surface else if (focused) ui.theme.accent_dim else if (hovered) ui.theme.hover else ui.theme.surface_alt;

        ui.fill_round_rect(surface, rect, 5, fill);

        const title: []const u8 = if (info_entry) |entry|
            entry.title[0..@min(@as(usize, @intCast(entry.title_len)), proto.window.max_title)]
        else if (item.has_app) apps[item.app_index].title else "";

        // A pinned-but-not-running app has no window to dim/highlight, so its label reads as idle.
        const label_color = if (minimized or !item.is_window) ui.theme.text_dim else ui.theme.text;
        const icon: []const u8 = if (item.has_app) apps[item.app_index].icon else lib.icons.apps;

        if (layout.width >= 72) {

            const button_icon_x = rect.x + 8;
            const button_icon_y = rect.y + @divTrunc(rect.h - window_button_icon, 2);
            const icon_rect = Rect{ .x = button_icon_x, .y = button_icon_y, .w = window_button_icon, .h = window_button_icon };

            lib.draw.vector.icon_in(surface, icon_rect, icon, label_color);
            if (item.pinned) draw_pin_dot(surface, icon_rect, fill);

            const text_x = button_icon_x + window_button_icon + 6;
            const text_rect = Rect{ .x = text_x, .y = rect.y, .w = rect.x + rect.w - text_x - 8, .h = rect.h };

            text_in(surface, text_rect, 0, 13, title, label_color);

        } else {

            // Narrow buttons: icon only, centered.
            const button_icon_x = rect.x + @divTrunc(rect.w - window_button_icon, 2);
            const button_icon_y = rect.y + @divTrunc(rect.h - window_button_icon, 2);
            const icon_rect = Rect{ .x = button_icon_x, .y = button_icon_y, .w = window_button_icon, .h = window_button_icon };

            lib.draw.vector.icon_in(surface, icon_rect, icon, label_color);
            if (item.pinned) draw_pin_dot(surface, icon_rect, fill);

        }

    }

    if (layout.overflow and layout.width > 0) {

        const rect = Rect{ .x = layout.overflow_x, .y = 5, .w = layout.width, .h = bar_height() - 10 };

        bar_regions.add(overflow_id, .{ .x = layout.overflow_x, .y = 0, .w = layout.width, .h = bar_height() });
        const remaining = item_count - layout.visible;
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "+{d}", .{remaining}) catch "+";

        ui.fill_round_rect(surface, rect, 5, ui.theme.surface);
        text_center(surface, rect, 12, label, ui.theme.text_dim);

    }

    const clock_rect = Rect{ .x = width - clock_width(), .y = 0, .w = clock_width(), .h = bar_height() };

    bar_regions.add(clock_id, clock_hover_rect(clock_rect));
    paint_clock(surface, width);

}

fn paint_clock(surface: *const gfx.Surface, width: i32) void {

    const rect = Rect{ .x = width - clock_width(), .y = 0, .w = clock_width(), .h = bar_height() };
    const hover = clock_hover_rect(rect);

    if (calendar_open) {

        ui.fill_round_rect(surface, hover, 5, ui.theme.accent_dim);

    } else if (bar_regions.hovered(clock_id)) {

        ui.fill_round_rect(surface, hover, 5, ui.theme.hover);

    }

    const local = lib.localtime.now(lib.prefs.tz_offset_minutes);

    const hour12 = if (local.hour % 12 == 0) 12 else local.hour % 12;
    const am_pm: []const u8 = if (local.hour < 12) "AM" else "PM";

    var time_buffer: [16]u8 = undefined;
    var date_buffer: [16]u8 = undefined;

    const time_text = std.fmt.bufPrint(&time_buffer, "{d}:{d:0>2} {s}", .{ hour12, local.minute, am_pm }) catch return;
    const date_text = std.fmt.bufPrint(&date_buffer, "{d}/{d}/{d}", .{ local.month, local.day, local.year }) catch return;

    const time_size: u32 = 13;
    const date_size: u32 = 10;
    const line_gap: i32 = 1;

    const time_h = font.line_height(time_size);
    const date_h = font.line_height(date_size);
    const top = rect.y + @divTrunc(rect.h - (time_h + line_gap + date_h), 2);

    text_center(surface, .{ .x = rect.x, .y = top, .w = rect.w, .h = time_h }, time_size, time_text, ui.theme.text);
    text_center(surface, .{ .x = rect.x, .y = top + time_h + line_gap, .w = rect.w, .h = date_h }, date_size, date_text, ui.theme.text_dim);

}

fn paint_clock_only() void {

    const surface = &bar.surface;
    const width: i32 = @intCast(surface.width);
    const rect = Rect{ .x = width - clock_width(), .y = 0, .w = clock_width(), .h = bar_height() };

    if (lib.prefs.quartz_level == .off) {

        surface.fill_rect(rect, ui.theme.surface_alt);

    } else {

        const clipped = surface.clipped(rect);

        panel(&clipped, surface.bounds(), ui.theme.surface_alt);

    }

    paint_clock(surface, width);

    bar.present(rect) catch {};

}

fn paint_menu() void {

    // Grow at most once for broad results; filtering must not churn Quartz surfaces.
    sync_menu_size(false);
    paint_menu_content();

    if (menu) |menu_window| menu_window.present_all() catch {};

}

fn paint_menu_content() void {

    const menu_window = menu orelse return;
    paint_menu_surface(&menu_window.surface);

}

fn paint_menu_damage(damage: Rect) void {

    const menu_window = menu orelse return;
    const target = damage.intersect(menu_window.surface.bounds());

    if (target.is_empty()) return;

    const clipped = menu_window.surface.clipped(target);

    paint_menu_surface(&clipped);
    menu_window.present(target) catch {};

}

fn paint_menu_surface(surface: *const gfx.Surface) void {

    const width: i32 = @intCast(surface.width);

    panel(surface, surface.bounds(), ui.theme.window_bg);

    menu_regions.reset();

    paint_search_box(surface, width);

    if (searching()) {

        paint_search_results(surface, width);

    } else {

        paint_categories(surface);
        paint_category_apps(surface, width);

    }

}

fn search_box_rect(width: i32) Rect {

    return .{ .x = 8, .y = 8, .w = width - 16, .h = search_height() - 12 };

}

/// Search text rect past the icon; shared by paint and click-to-position.
fn search_text_rect(width: i32) Rect {

    const search_rect = search_box_rect(width);
    const icon_size: i32 = 20;
    const text_x = search_rect.x + 8 + icon_size + 8;

    return .{ .x = text_x, .y = search_rect.y, .w = width - 8 - text_x, .h = search_rect.h };

}

fn paint_search_box(surface: *const gfx.Surface, width: i32) void {

    const search_rect = search_box_rect(width);

    ui.paint_field_chrome(surface, search_rect, true);

    const icon_size: i32 = 20;
    const icon_x = search_rect.x + 8;
    const icon_y = search_rect.y + @divTrunc(search_rect.h - icon_size, 2);

    lib.draw.vector.icon_in(surface, .{ .x = icon_x, .y = icon_y, .w = icon_size, .h = icon_size }, lib.icons.search, ui.theme.text_dim);

    ui.paint_field_content(surface, &font, search_text_rect(width), &search, "Search applications", true, 13);

}

fn paint_categories(surface: *const gfx.Surface) void {

    const col_w = category_col_width();

    // Divider between the category column and the app flyout.
    surface.fill_rect(.{ .x = col_w, .y = search_height(), .w = 1, .h = @as(i32, @intCast(surface.height)) - search_height() }, ui.theme.border);

    for (categories[0..category_count], 0..) |name, index| {

        const top = search_height() + @as(i32, @intCast(index)) * row_height();
        const rect = Rect{ .x = 6, .y = top + 3, .w = col_w - 12, .h = row_height() - 6 };
        const id = category_id_base + @as(u32, @intCast(index));

        menu_regions.add(id, .{ .x = 0, .y = rect.y, .w = col_w, .h = rect.h });

        const hovered = menu_regions.hovered(id);
        const is_active = index == active_category;

        if (is_active) {

            ui.fill_round_rect(surface, rect, 6, ui.theme.accent_dim);

        } else if (hovered) {

            row_hover(surface, rect);

        }

        lib.draw.vector.icon_in(surface, .{ .x = rect.x + 10, .y = rect.y + @divTrunc(rect.h - 22, 2), .w = 22, .h = 22 }, lib.icons.category, ui.theme.accent);

        text_in(surface, .{ .x = rect.x + 40, .y = rect.y, .w = rect.w - 56, .h = rect.h }, 0, 14, name, ui.theme.text);

        // Chevron marking that the category opens its apps to the side.
        draw_chevron(surface, rect.x + rect.w - 20, rect.y + @divTrunc(rect.h, 2), ui.theme.text_dim);

    }

}

fn paint_category_apps(surface: *const gfx.Surface, width: i32) void {

    const left = category_col_width();
    const count = category_size(active_category);

    if (count == 0) {

        draw_text(surface, left + 16, search_height() + 14, 13, "No applications", ui.theme.text_dim);
        return;

    }

    var index: usize = 0;

    while (index < count) : (index += 1) {

        const app = category_app(active_category, index) orelse break;
        const top = search_height() + @as(i32, @intCast(index)) * row_height();
        const rect = Rect{ .x = left + 6, .y = top + 3, .w = width - left - 12, .h = row_height() - 6 };
        const id = browse_id_base + @as(u32, @intCast(index));

        menu_regions.add(id, .{ .x = left, .y = rect.y, .w = width - left, .h = rect.h });

        paint_app_row(surface, rect, app, menu_regions.hovered(id));

    }

}

fn paint_search_results(surface: *const gfx.Surface, width: i32) void {

    var y = search_height();
    var any = false;
    var nth: u32 = 0;
    const visible_rows = view_rows();

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;
        if (@as(usize, nth) >= visible_rows) break;

        any = true;

        const rect = Rect{ .x = 6, .y = y + 3, .w = width - 12, .h = row_height() - 6 };
        const id = search_id_base + nth;

        menu_regions.add(id, .{ .x = 0, .y = rect.y, .w = width, .h = rect.h });

        paint_app_row(surface, rect, app, menu_regions.hovered(id));

        y += row_height();
        nth += 1;

    }

    if (!any) {

        draw_text(surface, 20, search_height() + 12, 13, "No matching applications", ui.theme.text_dim);

    }

}

fn paint_app_row(surface: *const gfx.Surface, rect: Rect, app: lib.wm.App, hovered: bool) void {

    if (hovered) row_hover(surface, rect);

    lib.draw.vector.icon_in(surface, .{ .x = rect.x + 10, .y = rect.y + @divTrunc(rect.h - 26, 2), .w = 26, .h = 26 }, app.icon, ui.theme.accent);

    draw_text(surface, rect.x + 48, rect.y + 7, 15, app.title, ui.theme.text);
    draw_text(surface, rect.x + 48, rect.y + 28, 12, app.description, ui.theme.text_dim);

}

/// A small dot inset into an icon's bottom-right corner marking a pinned app.
fn draw_pin_dot(surface: *const gfx.Surface, icon_rect: Rect, halo_color: gfx.Color) void {

    const outer: i32 = 8;
    const inner: i32 = 5;

    const cx = icon_rect.x + icon_rect.w - @divTrunc(inner, 2) - 1;
    const cy = icon_rect.y + icon_rect.h - @divTrunc(inner, 2) - 1;

    const outer_rect = Rect{ .x = cx - @divTrunc(outer, 2), .y = cy - @divTrunc(outer, 2), .w = outer, .h = outer };
    const inner_rect = Rect{ .x = cx - @divTrunc(inner, 2), .y = cy - @divTrunc(inner, 2), .w = inner, .h = inner };

    ui.fill_round_rect(surface, outer_rect, outer, halo_color);
    ui.fill_round_rect(surface, inner_rect, inner, ui.theme.accent);

}

// Small right-pointing chevron drawn from pixels so it needs no font glyph.
fn draw_chevron(surface: *const gfx.Surface, cx: i32, cy: i32, color: gfx.Color) void {

    var i: i32 = 0;

    while (i < 4) : (i += 1) {

        surface.fill_rect(.{ .x = cx - 1 + i, .y = cy - 4 + i, .w = 1, .h = 2 }, color);
        surface.fill_rect(.{ .x = cx - 1 + i, .y = cy + 3 - i, .w = 1, .h = 2 }, color);

    }

}

fn matches(app: lib.wm.App) bool {

    const query = search.slice();

    if (query.len == 0) return true;

    return contains_ignore_case(app.title, query) or contains_ignore_case(app.program, query);

}

fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {

    if (needle.len > haystack.len) return false;

    var start: usize = 0;

    while (start + needle.len <= haystack.len) : (start += 1) {

        var index: usize = 0;

        while (index < needle.len and lower(haystack[start + index]) == lower(needle[index])) : (index += 1) {}

        if (index == needle.len) return true;

    }

    return false;

}

fn lower(byte: u8) u8 {

    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;

}

fn draw_text(surface: *const gfx.Surface, x: i32, y: i32, size: u32, content: []const u8, color: gfx.Color) void {

    font.draw(surface, x, y, size, content, color);

}

fn text_in(surface: *const gfx.Surface, rect: Rect, inset: i32, size: u32, content: []const u8, color: gfx.Color) void {

    const inner = rect.inset(inset);
    const clipped = surface.clipped(inner);
    const visible = ui.truncate(&font, content, size, inner.w);
    const y = inner.y + @divTrunc(inner.h - font.line_height(size), 2);

    font.draw(&clipped, inner.x, y, size, visible, color);

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, content: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, content, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

fn panel(surface: *const gfx.Surface, rect: Rect, color: gfx.Color) void {

    if (lib.prefs.quartz_level == .off) {

        // Fill directly
        lib.draw.round.fill_round_rect(surface, rect, dock_radius(), color);
        ui.stroke_round_rect(surface, rect, dock_radius(), 1, ui.theme.border);

        return;

    }

    var appearance = quartz.style(switch (lib.prefs.quartz_level) {

        .off => unreachable,
        .light => .clear,
        .medium => .regular,
        .dark => .prominent,

    }, color, ui.theme.accent);

    appearance.radius = dock_radius();

    quartz.clear(surface);
    quartz.panel(surface, rect, appearance);

}

fn hover_damage(regions: *const ui.HitRegions, previous: u32, current: u32) Rect {

    const before = if (previous != 0) regions.rect_of(previous) orelse Rect.empty else Rect.empty;
    const after = if (current != 0) regions.rect_of(current) orelse Rect.empty else Rect.empty;

    if (before.is_empty()) return after;
    if (after.is_empty()) return before;

    return before.cover(after);

}

fn row_hover(surface: *const gfx.Surface, rect: Rect) void {

    ui.fill_round_rect(surface, rect, 6, ui.theme.hover);

}

// A worker thread wakes the main loop on second boundaries to refresh the clock.

const ticker_stack_pages = 8;
const page_size = 4096;

fn start_ticker() !void {

    const stack = try sys.create(.region, ticker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&ticker), base + ticker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn start_list_watcher() !void {

    const stack = try sys.create(.region, ticker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&list_watcher), base + ticker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn start_weather_worker() !void {

    const stack = try sys.create(.region, ticker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&weather_worker), base + ticker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn ticker() callconv(.c) noreturn {

    while (true) {

        const remainder = lib.time.now_ms() % 1000;

        lib.time.sleep_ms(if (remainder == 0) 1000 else 1000 - remainder);

        @atomicStore(u32, &clock_tick, 1, .release);

        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}

fn list_watcher() callconv(.c) noreturn {

    while (true) {

        _ = sys.wait(window_list.list_ready) catch continue;

        @atomicStore(u32, &list_tick, 1, .release);

        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}

fn weather_worker() callconv(.c) noreturn {

    while (true) {

        lib.time.sleep_ms(50);

        if (@atomicLoad(u32, &weather_tick, .acquire) != 0) continue;
        if (@atomicRmw(u32, &weather_pending, .Xchg, 0, .acquire) == 0) continue;

        refresh_weather();

        @atomicStore(u32, &weather_tick, 1, .release);
        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}
