// Taskbar: the desktop's persistent panel.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const proto = lib.proto;
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

fn launcher_width() i32 {

    return 44;

}

fn clock_width() i32 {

    return 92;

}

fn window_button_max() i32 {

    return 184;

}

fn window_button_min() i32 {

    return 36;

}

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

var font: lib.draw.text.Face = undefined;
var bundle: lib.bundle.Bundle = undefined;

var connection: lib.window.Connection = undefined;
var window_list: lib.wm.List = undefined;
var bar: lib.window.Window = undefined;

var menu: ?lib.window.Window = null;
var menu_open = false;

var windows: [proto.window.max_windows]WindowInfo = undefined;
var window_count: usize = 0;

var apps: [max_apps]lib.wm.App = undefined;
var app_count: usize = 0;

// Categories are derived from the apps' `category` metadata; the menu lists them and flies the active category's apps out to the side. Searching bypasses the grouping and matches across every app.
var categories: [max_categories][]const u8 = undefined;
var category_count: usize = 0;
var active_category: usize = 0;

var launch_endpoint: cap.Handle = 0;

var keyboard = lib.keymap.Keyboard{};
var search_storage: [48]u8 = undefined;
var search = ui.EditBuffer{ .bytes = &search_storage };

var bar_ptr_x: i32 = -1;
var menu_ptr_x: i32 = -1;
var menu_ptr_y: i32 = -1;

// Which element the pointer last hovered, so a move only repaints when the highlight would actually change.
var last_bar_hover: i32 = -3;
var last_menu_hover: i32 = -3;

var ready: cap.Handle = 0;
// Separate wake bits so the clock tick does not re-list every window over IPC.
var clock_tick: u32 = 0;
var list_tick: u32 = 0;

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

    bar = try connection.create_window(0, @intCast(bar_height()), proto.window.flag_panel, "taskbar");

    app_count = lib.wm.load_apps(&bundle, apps[0..]);
    build_categories();
    launch_endpoint = lib.stream.lookup_endpoint("launch") catch 0;

    refresh_windows();
    paint_bar();

    try start_ticker();
    try start_list_watcher();

    while (true) {

        _ = sys.wait(ready) catch {};

        while (connection.poll_event()) |event| {

            handle(event);

        }

        const list_due = @atomicRmw(u32, &list_tick, .Xchg, 0, .acquire) != 0;
        const clock_due = @atomicRmw(u32, &clock_tick, .Xchg, 0, .acquire) != 0;

        if (list_due) refresh_windows();

        if (list_due or clock_due) paint_bar();

    }

}

fn refresh_windows() void {

    window_count = window_list.refresh(windows[0..]);

}

// Event handling

fn handle(event: events.Event) void {

    if (event.kind == events.kind_prefs_changed) {

        apply_prefs_changed();
        return;

    }

    if (menu) |menu_window| {

        if (event.window == menu_window.id) return handle_menu(event);

    }

    if (event.window == bar.id) handle_bar(event);

}

fn update_bar_cursor(x: i32) void {

    if (x < launcher_width() or bar_hover_token(x) >= 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn update_menu_cursor(x: i32, y: i32) void {

    if (y < search_height()) lib.cursor.set(&connection, .selector)
    else if (menu_hover_token(x, y) >= 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn apply_prefs_changed() void {

    lib.prefs.refresh();

    bar.resize(bar.surface.width, @intCast(bar_height())) catch {};

    if (menu) |*menu_window| {

        menu_window.resize(menu_width(), menu_height()) catch {};

        if (lib.wm.screen_info(&connection)) |screen| {

            lib.wm.move_window(&connection, menu_window.id, 0, menu_y(screen.height)) catch {};

        } else |_| {}

    }

    paint_bar();

    if (menu_open) paint_menu();

}

fn handle_bar(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => {

            if (event.code != events.button_left) return;

            if (event.x < launcher_width()) {

                toggle_menu();
                return;

            }

            activate_at(event.x);

        },

        events.kind_pointer_move => {

            bar_ptr_x = event.x;

            const token = bar_hover_token(event.x);

            if (token != last_bar_hover) {

                last_bar_hover = token;
                paint_bar();

            }

            update_bar_cursor(event.x);

        },

        events.kind_window_resize => {

            bar.resize(@intCast(event.x), @intCast(bar_height())) catch {};

            if (menu_open) {

                if (lib.wm.screen_info(&connection)) |screen| {

                    if (menu) |menu_window| lib.wm.move_window(&connection, menu_window.id, 0, menu_y(screen.height)) catch {};

                } else |_| {}

            }

            refresh_windows();
            paint_bar();

            if (menu_open) paint_menu();

        },

        else => {},

    }

}

fn bar_hover_token(x: i32) i32 {

    if (x < launcher_width()) return -2;

    const layout = button_layout();

    if (layout.width <= 0 or x < layout.start) return -1;

    var index: usize = 0;

    while (index < layout.visible) : (index += 1) {

        const left = layout.start + @as(i32, @intCast(index)) * (layout.width + button_gap());

        if (x >= left and x < left + layout.width) return @intCast(index);

    }

    if (layout.overflow and x >= layout.overflow_x and x < layout.overflow_x + layout.width) return -4;

    return -1;

}

fn handle_menu(event: events.Event) void {

    switch (event.kind) {

        events.kind_key_down => menu_key(event.code),

        events.kind_button_down => {

            if (event.code == events.button_left) menu_click(event.x, event.y);

        },

        events.kind_pointer_move => {

            menu_ptr_x = event.x;
            menu_ptr_y = event.y;

            var need = false;

            // Hovering a category flies its apps out to the side, so the active group tracks the pointer.
            if (!searching() and event.x < category_col_width()) {

                if (category_at(event.y)) |index| {

                    if (index != active_category) {

                        active_category = index;
                        need = true;

                    }

                }

            }

            const token = menu_hover_token(event.x, event.y);

            if (token != last_menu_hover) {

                last_menu_hover = token;
                need = true;

            }

            if (need) paint_menu();

            update_menu_cursor(event.x, event.y);

        },

        events.kind_window_blur => close_menu(),

        else => {},

    }

}

fn activate_at(x: i32) void {

    if (window_count == 0) return;

    const layout = button_layout();

    if (layout.width <= 0) return;

    if (x < layout.start) return;

    const stride = layout.width + button_gap();
    const index: usize = @intCast(@divTrunc(x - layout.start, stride));

    if (index >= layout.visible) return;

    const left = layout.start + @as(i32, @intCast(index)) * stride;

    if (x >= left + layout.width) return;

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

    if (search.feed(bytes)) paint_menu();

}

fn menu_click(x: i32, y: i32) void {

    if (y < search_height()) return;

    if (searching()) {

        if (search_app_at(y)) |app| {

            launch(app.program);
            close_menu();

        }

        return;

    }

    if (x < category_col_width()) {

        if (category_at(y)) |index| {

            if (index != active_category) {

                active_category = index;
                paint_menu();

            }

        }

        return;

    }

    if (browse_app_at(y)) |app| {

        launch(app.program);
        close_menu();

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

fn browse_app_at(y: i32) ?lib.wm.App {

    const row = row_at(y) orelse return null;

    return category_app(active_category, row);

}

fn search_app_at(y: i32) ?lib.wm.App {

    const row = row_at(y) orelse return null;

    return search_app(row);

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

// Browse view is sized to the tallest column so hovering between categories never resizes the window;
// only the browse/search transition (and a changing result count) moves it.
fn browse_rows() usize {

    var rows = category_count;
    var i: usize = 0;

    while (i < category_count) : (i += 1) {

        rows = @max(rows, category_size(i));

    }

    return rows;

}

fn view_rows() usize {

    return if (searching()) match_count() else browse_rows();

}

fn menu_height() u32 {

    const rows: i32 = @intCast(@max(view_rows(), 1));

    return @intCast(search_height() + rows * row_height() + 8);

}

fn sync_menu_size() void {

    if (menu) |*menu_window| {

        const height = menu_height();

        if (menu_window.surface.height == height) return;

        menu_window.resize(menu_width(), height) catch {};

        if (lib.wm.screen_info(&connection)) |screen| {

            lib.wm.move_window(&connection, menu_window.id, 0, menu_y(screen.height)) catch {};

        } else |_| {}

    }

}

fn menu_y(screen_height: u32) i32 {

    return @as(i32, @intCast(screen_height)) - bar_height() - @as(i32, @intCast(menu_height())) - 10;

}

fn ensure_menu() !void {

    if (menu != null) return;

    const height = menu_height();

    var menu_window = try connection.create_window(menu_width(), height, proto.window.flag_undecorated, "menu");

    menu_window.surface.fill(ui.theme.window_bg);

    try lib.wm.minimize(&connection, menu_window.id);

    const screen = try lib.wm.screen_info(&connection);

    try lib.wm.move_window(&connection, menu_window.id, 0, menu_y(screen.height));

    menu = menu_window;

}

fn open_menu() void {

    ensure_menu() catch return;

    search.clear();
    active_category = 0;
    menu_ptr_x = -1;
    menu_ptr_y = -1;
    last_menu_hover = -3;

    // Reopen at the browse size; a prior session may have left the window expanded for search results.
    sync_menu_size();

    const menu_window = menu orelse return;

    if (lib.wm.screen_info(&connection)) |screen| {

        lib.wm.move_window(&connection, menu_window.id, 10, menu_y(screen.height)) catch {};

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

// A stable token per hovered element so a pointer move only repaints when the highlight actually changes.
fn menu_hover_token(x: i32, y: i32) i32 {

    const row = row_at(y) orelse return -1;
    const index: i32 = @intCast(row);

    if (searching()) {

        return if (row < match_count()) 3000 + index else -2;

    }

    if (x < category_col_width()) {

        return if (row < category_count) 1000 + index else -2;

    }

    return if (row < category_size(active_category)) 2000 + index else -2;

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

    if (window_count == 0 or available <= 0) {

        return .{ .start = start, .width = 0, .visible = 0, .overflow = false, .overflow_x = start };

    }

    // Fit as many buttons as possible at a usable width; shrink first, then overflow.
    var count = window_count;
    var width = @divTrunc(available - button_gap() * @as(i32, @intCast(count)), @as(i32, @intCast(count)));

    if (width > window_button_max()) width = window_button_max();

    if (width < window_button_min()) {

        const slot = window_button_min() + button_gap();
        const fit: usize = @intCast(@max(0, @divTrunc(available, slot)));

        count = @min(window_count, @max(@as(usize, 1), fit));
        width = window_button_min();

        if (count < window_count and count > 0) {

            // Reserve one slot for the overflow indicator.
            count = @max(@as(usize, 1), count - 1);

        }

    }

    const overflow = count < window_count;
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
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = 1 }, ui.theme.border);

    // Launcher button.

    const icon_size: i32 = 22;
    const hover_h: i32 = 32;
    const launcher_hover = Rect{

        .x = 4,
        .y = @divTrunc(bar_height() - hover_h, 2),
        .w = launcher_width() - 8,
        .h = hover_h,

    };

    const launcher_hovered = bar_ptr_x >= 0 and bar_ptr_x < launcher_width();

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

        const info_entry = windows[index];
        const focused = info_entry.focused != 0;
        const minimized = info_entry.minimized != 0;
        const hovered = bar_ptr_x >= rect.x and bar_ptr_x < rect.x + rect.w;

        const fill = if (minimized) ui.theme.surface else if (focused) ui.theme.accent_dim else if (hovered) ui.theme.hover else ui.theme.surface_alt;

        ui.fill_round_rect(surface, rect, 5, fill);

        const title = info_entry.title[0..@min(@as(usize, @intCast(info_entry.title_len)), proto.window.max_title)];
        const label_color = if (minimized) ui.theme.text_dim else ui.theme.text;

        if (layout.width >= 72) {

            text_in(surface, rect, 10, 13, title, label_color);

        } else {

            // Narrow buttons: first letter (or glyph) only.
            const monogram = if (title.len > 0) title[0..1] else "?";

            text_center(surface, rect, 13, monogram, label_color);

        }

    }

    if (layout.overflow and layout.width > 0) {

        const rect = Rect{ .x = layout.overflow_x, .y = 5, .w = layout.width, .h = bar_height() - 10 };
        const remaining = window_count - layout.visible;
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "+{d}", .{remaining}) catch "+";

        ui.fill_round_rect(surface, rect, 5, ui.theme.surface);
        text_center(surface, rect, 12, label, ui.theme.text_dim);

    }

    paint_clock(surface, width);

    bar.present_all() catch {};

}

fn paint_clock(surface: *const gfx.Surface, width: i32) void {

    const seconds = lib.time.now_ms() / 1000;
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    const secs = seconds % 60;

    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs }) catch return;

    const rect = Rect{ .x = width - clock_width(), .y = 0, .w = clock_width(), .h = bar_height() };

    text_center(surface, rect, 14, text, ui.theme.text_dim);

}

fn paint_menu() void {

    sync_menu_size();
    paint_menu_content();

    if (menu) |menu_window| menu_window.present_all() catch {};

}

fn paint_menu_content() void {

    const menu_window = menu orelse return;
    const surface = &menu_window.surface;
    const width: i32 = @intCast(surface.width);

    panel(surface, surface.bounds(), ui.theme.window_bg);

    paint_search_box(surface, width);

    if (searching()) {

        paint_search_results(surface, width);

    } else {

        paint_categories(surface);
        paint_category_apps(surface, width);

    }

}

fn paint_search_box(surface: *const gfx.Surface, width: i32) void {

    const search_rect = Rect{ .x = 8, .y = 8, .w = width - 16, .h = search_height() - 12 };

    ui.fill_round_rect(surface, search_rect, 5, ui.theme.surface);

    const icon_size: i32 = 20;
    const icon_x = search_rect.x + 8;
    const icon_y = search_rect.y + @divTrunc(search_rect.h - icon_size, 2);

    lib.draw.vector.icon_in(surface, .{ .x = icon_x, .y = icon_y, .w = icon_size, .h = icon_size }, lib.icons.search, ui.theme.text_dim);

    const text_x = icon_x + icon_size + 8;
    const text_w = width - text_x - 8;
    const query = search.slice();

    if (query.len == 0) {

        text_in(surface, .{ .x = text_x, .y = search_rect.y, .w = text_w, .h = search_rect.h }, 0, 13, "Search applications", ui.theme.text_faint);

    } else {

        text_in(surface, .{ .x = text_x, .y = search_rect.y, .w = text_w, .h = search_rect.h }, 0, 13, query, ui.theme.text);

    }

    // Caret at the edit cursor, clamped to the box.

    const before = query[0..@min(search.cursor, query.len)];
    const caret_x = @min(text_x + font.text_width(before, 13), text_x + text_w);
    const caret_h = @min(search_rect.h - 8, font.line_height(13));
    const caret_y = search_rect.y + @divTrunc(search_rect.h - caret_h, 2);

    surface.fill_rect(.{ .x = caret_x, .y = caret_y, .w = 1, .h = caret_h }, ui.theme.text);

}

fn paint_categories(surface: *const gfx.Surface) void {

    const col_w = category_col_width();

    // Divider between the category column and the app flyout.
    surface.fill_rect(.{ .x = col_w, .y = search_height(), .w = 1, .h = @as(i32, @intCast(surface.height)) - search_height() }, ui.theme.border);

    for (categories[0..category_count], 0..) |name, index| {

        const top = search_height() + @as(i32, @intCast(index)) * row_height();
        const rect = Rect{ .x = 6, .y = top + 3, .w = col_w - 12, .h = row_height() - 6 };
        const hovered = menu_ptr_x >= 0 and menu_ptr_x < col_w and menu_ptr_y >= rect.y and menu_ptr_y < rect.y + rect.h;
        const is_active = index == active_category;

        if (is_active) {

            ui.fill_round_rect(surface, rect, 6, ui.theme.accent_dim);

        } else if (hovered) {

            row_hover(surface, rect);

        }

        lib.draw.vector.icon_in(surface, .{ .x = rect.x + 10, .y = rect.y + @divTrunc(rect.h - 22, 2), .w = 22, .h = 22 }, lib.icons.apps, ui.theme.accent);

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
        const hovered = menu_ptr_x >= left and menu_ptr_y >= rect.y and menu_ptr_y < rect.y + rect.h;

        paint_app_row(surface, rect, app, hovered);

    }

}

fn paint_search_results(surface: *const gfx.Surface, width: i32) void {

    var y = search_height();
    var any = false;

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

        any = true;

        const rect = Rect{ .x = 6, .y = y + 3, .w = width - 12, .h = row_height() - 6 };
        const hovered = menu_ptr_y >= rect.y and menu_ptr_y < rect.y + rect.h;

        paint_app_row(surface, rect, app, hovered);

        y += row_height();

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

    ui.fill_round_rect(surface, rect, 8, color);
    ui.stroke_round_rect(surface, rect, 8, 1, ui.theme.border);

}

fn row_hover(surface: *const gfx.Surface, rect: Rect) void {

    ui.fill_round_rect(surface, rect, 6, ui.theme.hover);

}

// A worker thread wakes the main loop twice a second to refresh the clock and window list.

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

fn ticker() callconv(.c) noreturn {

    while (true) {

        lib.time.sleep_ms(500);

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
