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

var font: lib.draw.text.Face = undefined;
var bundle: lib.bundle.Bundle = undefined;

var connection: lib.window.Connection = undefined;
var window_list: lib.wm.List = undefined;
var bar: lib.window.Window = undefined;

var menu: ?lib.window.Window = null;
var menu_open = false;

var pin_menu: ?lib.window.Window = null;
var pin_menu_open = false;
var pin_menu_widget = ui.Menu{};
var pin_menu_program: [lib.prefs.max_pin_program]u8 = undefined;
var pin_menu_program_len: usize = 0;
var pin_menu_pinned = false;

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
const overflow_id: u32 = 99;
const window_id_base: u32 = 100;
const category_id_base: u32 = 1000;
const browse_id_base: u32 = 2000;
const search_id_base: u32 = 3000;

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

    reload_pins();
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

        if (list_due) {

            paint_bar();

        } else if (clock_due) {

            paint_clock_only();

        }

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

/// Merge open windows with pinned-but-not-running apps into one indicator list: every open window gets
/// a button (its pin state resolved from the catalog match, if any), followed by any pinned app that has
/// no window currently open for it.
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

    if (event.kind == events.kind_prefs_changed) {

        apply_prefs_changed();
        return;

    }

    if (pin_menu) |pin_menu_window| {

        if (event.window == pin_menu_window.id) return handle_pin_menu(event);

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

fn update_menu_cursor(x: i32, y: i32) void {

    if (y < search_height()) lib.cursor.set(&connection, .selector)
    else if (menu_regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn apply_prefs_changed() void {

    lib.prefs.refresh();
    reload_pins();
    rebuild_items();

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

            const id = bar_regions.hit(event.x, event.y);

            if (event.code == events.button_left) {

                close_pin_menu();

                if (id == launcher_id) {

                    toggle_menu();
                    return;

                }

                if (id >= window_id_base) activate_item(id - window_id_base);

                return;

            }

            if (event.code == events.button_right) {

                if (id >= window_id_base) open_pin_menu(id - window_id_base, event.x);

            }

        },

        events.kind_pointer_move => {

            if (bar_regions.pointer_move(event.x, event.y)) paint_bar();

            update_bar_cursor(event.x, event.y);

        },

        events.kind_window_resize => {

            bar.resize(@intCast(event.x), @intCast(bar_height())) catch {};

            if (menu_open) {

                if (lib.wm.screen_info(&connection)) |screen| {

                    if (menu) |menu_window| lib.wm.move_window(&connection, menu_window.id, 0, menu_y(screen.height)) catch {};

                } else |_| {}

            }

            close_pin_menu();

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

            // Hovering a category flies its apps out to the side, so the active group tracks the pointer.
            if (!searching() and event.x < category_col_width()) {

                if (category_at(event.y)) |index| {

                    if (index != active_category) {

                        active_category = index;
                        need = true;

                    }

                }

            }

            if (menu_regions.pointer_move(event.x, event.y)) need = true;

            if (need) paint_menu();

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

    return @as(i32, @intCast(screen_height)) - bar_height() - dock_margin() - @as(i32, @intCast(menu_height())) - 10;

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

    close_pin_menu();

    ensure_menu() catch return;

    search.clear();
    active_category = 0;

    _ = menu_regions.leave();

    // Reopen at the browse size; a prior session may have left the window expanded for search results.
    sync_menu_size();

    const menu_window = menu orelse return;

    if (lib.wm.screen_info(&connection)) |screen| {

        lib.wm.move_window(&connection, menu_window.id, dock_margin(), menu_y(screen.height)) catch {};

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

    var window = try connection.create_window(pin_menu_width(), pin_menu_height(), proto.window.flag_undecorated, "pin-menu");

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

    // The menu's own rounded fill leaves its true corner pixels untouched, so prime them first (matches
    // ensure_menu()'s treatment of the launcher popup).
    surface.fill(ui.theme.surface);

    pin_menu_widget.paint(surface, &font);

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

    // Important: we update the in-memory pin list first
    if (pin_menu_pinned) {

        untrack_pinned_program(program);

    } else {

        track_pinned_program(program);

    }

    _ = lib.prefs.save_taskbar_pins(pinned_programs[0..pinned_count]);

    close_pin_menu();

    rebuild_items();
    paint_bar();

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

    paint_clock(surface, width);

    bar.present_all() catch {};

}

fn paint_clock(surface: *const gfx.Surface, width: i32) void {

    const rect = Rect{ .x = width - clock_width(), .y = 0, .w = clock_width(), .h = bar_height() };
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

    surface.fill_rect(rect, ui.theme.surface_alt);
    paint_clock(surface, width);

    bar.present(rect) catch {};

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

/// Where the search box's text content starts and ends, past its leading icon - shared by the paint routine
/// and by click-to-position so the two never disagree about where the text actually sits.
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

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

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

    ui.fill_round_rect(surface, rect, dock_radius(), color);
    ui.stroke_round_rect(surface, rect, dock_radius(), 1, ui.theme.border);

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
