// Taskbar: the desktop's persistent panel. It docks a compositor panel window to the screen bottom, shows a button
// per open window (polled from the compositor's window list), a live clock, and a launcher button that opens a
// searchable menu of applications. Selecting an app asks the launcher server to spawn it - the taskbar itself holds
// no spawn authority. A worker thread ticks twice a second so the clock and window list stay current without input.

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

const bar_height: i32 = 40;
const launcher_width: i32 = 44;
const clock_width: i32 = 92;
const window_button_max: i32 = 184;
const button_gap: i32 = 4;

const menu_width: u32 = 340;
const row_height: i32 = 56;
const search_height: i32 = 46;

const bar_bg = gfx.rgb(24, 24, 24);
const bar_border = gfx.rgb(56, 56, 56);

const max_apps = 32;

var font: lib.ttf.Face = undefined;
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

var launch_endpoint: cap.Handle = 0;

var keyboard = lib.keymap.Keyboard{};
var search_storage: [48]u8 = undefined;
var search = ui.EditBuffer{ .bytes = &search_storage };

var bar_ptr_x: i32 = -1;
var menu_ptr_y: i32 = -1;

// Which element the pointer last hovered, so a move only repaints when the highlight would actually change.
var last_bar_hover: i32 = -3;
var last_menu_hover: i32 = -3;

var ready: cap.Handle = 0;
var tick: u32 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window_list = try lib.wm.List.init(&connection, cap.memory);
    try window_list.subscribe();

    bar = try connection.create_window(0, @intCast(bar_height), proto.window.flag_panel, "taskbar");

    app_count = lib.wm.load_apps(&bundle, apps[0..]);
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

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) {

            refresh_windows();
            paint_bar();

        }

    }

}

fn refresh_windows() void {

    window_count = window_list.refresh(windows[0..]);

}

// Event handling

fn handle(event: events.Event) void {

    if (menu) |menu_window| {

        if (event.window == menu_window.id) return handle_menu(event);

    }

    if (event.window == bar.id) handle_bar(event);

}

fn handle_bar(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => {

            if (event.code != events.button_left) return;

            if (event.x < launcher_width) {

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

        },

        else => {},

    }

}

fn bar_hover_token(x: i32) i32 {

    if (x < launcher_width) return -2;

    const layout = button_layout();

    if (layout.width <= 0 or x < layout.start) return -1;

    var index: usize = 0;

    while (index < window_count) : (index += 1) {

        const left = layout.start + @as(i32, @intCast(index)) * (layout.width + button_gap);

        if (x >= left and x < left + layout.width) return @intCast(index);

    }

    return -1;

}

fn handle_menu(event: events.Event) void {

    switch (event.kind) {

        events.kind_key_down => menu_key(event.code),

        events.kind_button_down => {

            if (event.code == events.button_left) menu_click(event.y);

        },

        events.kind_pointer_move => {

            menu_ptr_y = event.y;

            const token = menu_hover_token(event.y);

            if (token != last_menu_hover) {

                last_menu_hover = token;
                paint_menu();

            }

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

    const index: usize = @intCast(@divTrunc(x - layout.start, layout.width + button_gap));

    if (index >= window_count) return;

    if (windows[index].minimized != 0) {

        lib.wm.restore(&connection, windows[index].id) catch {};

    } else {

        lib.wm.activate(&connection, windows[index].id) catch {};

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

fn menu_click(y: i32) void {

    const app = menu_app_at_y(y) orelse return;

    launch(app.program);
    close_menu();

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

fn open_menu() void {

    search.clear();
    menu_ptr_y = -1;
    last_menu_hover = -3;

    const height: u32 = @intCast(search_height + @as(i32, @intCast(app_count)) * row_height + 8);

    menu = connection.create_window(menu_width, height, proto.window.flag_undecorated, "menu") catch return;
    menu_open = true;

    paint_menu();
    paint_bar();

}

fn close_menu() void {

    if (menu) |*menu_window| {

        menu_window.destroy();

    }

    menu = null;
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

fn menu_hover_token(y: i32) i32 {

    if (y < search_height) return -1;

    var row: i32 = 0;

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

        const top = search_height + row * row_height;
        const rect = Rect{ .x = 4, .y = top, .w = @as(i32, @intCast(menu_width)) - 8, .h = row_height - 4 };

        if (y >= rect.y and y < rect.y + rect.h) return row;

        row += 1;

    }

    return -2;

}

fn menu_app_at_y(y: i32) ?lib.wm.App {

    if (y < search_height) return null;

    var row: i32 = 0;

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

        const top = search_height + row * row_height;
        const rect = Rect{ .x = 4, .y = top, .w = @as(i32, @intCast(menu_width)) - 8, .h = row_height - 4 };

        if (y >= rect.y and y < rect.y + rect.h) return app;

        row += 1;

    }

    return null;

}

// Rendering

const ButtonLayout = struct {

    start: i32,
    width: i32,

};

fn button_layout() ButtonLayout {

    const start = launcher_width + button_gap;
    const end = @as(i32, @intCast(bar.surface.width)) - clock_width - button_gap;
    const available = end - start;

    if (window_count == 0 or available <= 0) return .{ .start = start, .width = 0 };

    const each = @divTrunc(available, @as(i32, @intCast(window_count))) - button_gap;

    return .{ .start = start, .width = @min(window_button_max, @max(0, each)) };

}

fn paint_bar() void {

    const surface = &bar.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(bar_bg);
    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = 1 }, bar_border);

    // Launcher button.

    const launcher_rect = Rect{ .x = 0, .y = 0, .w = launcher_width, .h = bar_height };

    if (menu_open) surface.fill_rect(launcher_rect, ui.theme.accent_dim);

    ui.icon(surface, .{ .x = 11, .y = 8, .w = 22, .h = 22 }, lib.icons.apps, ui.theme.text);

    // Window buttons.

    const layout = button_layout();
    var index: usize = 0;

    while (index < window_count and layout.width > 0) : (index += 1) {

        const x = layout.start + @as(i32, @intCast(index)) * (layout.width + button_gap);
        const rect = Rect{ .x = x, .y = 5, .w = layout.width, .h = bar_height - 10 };

        const info_entry = windows[index];
        const focused = info_entry.focused != 0;
        const minimized = info_entry.minimized != 0;
        const hovered = bar_ptr_x >= rect.x and bar_ptr_x < rect.x + rect.w;

        const fill = if (minimized) ui.theme.surface else if (focused) ui.theme.accent_dim else if (hovered) ui.theme.hover else ui.theme.surface_alt;

        surface.fill_rect(rect, fill);

        if (focused) surface.fill_rect(.{ .x = rect.x, .y = rect.y + rect.h - 2, .w = rect.w, .h = 2 }, ui.theme.accent);

        const title = info_entry.title[0..@min(@as(usize, @intCast(info_entry.title_len)), proto.window.max_title)];

        ui.text_in(surface, &font, rect, 10, 13, title, ui.theme.text);

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

    const rect = Rect{ .x = width - clock_width, .y = 0, .w = clock_width, .h = bar_height };

    ui.text_center(surface, &font, rect, 14, text, ui.theme.text_dim);

}

fn paint_menu() void {

    const menu_window = menu orelse return;
    const surface = &menu_window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.window_bg);
    surface.stroke_rect(surface.bounds(), 1, ui.theme.border);

    // Search box.

    const search_rect = Rect{ .x = 8, .y = 8, .w = width - 16, .h = search_height - 12 };

    surface.fill_rect(search_rect, ui.theme.surface);
    surface.stroke_rect(search_rect, 1, ui.theme.accent);

    const icon_size: i32 = 20;
    const icon_x = search_rect.x + 8;
    const icon_y = search_rect.y + @divTrunc(search_rect.h - icon_size, 2);

    ui.icon(surface, .{ .x = icon_x, .y = icon_y, .w = icon_size, .h = icon_size }, lib.icons.search, ui.theme.text_dim);

    const text_x = icon_x + icon_size + 8;
    const text_w = width - text_x - 8;
    const query = search.slice();

    if (query.len == 0) {

        ui.text_in(surface, &font, .{ .x = text_x, .y = search_rect.y, .w = text_w, .h = search_rect.h }, 0, 13, "Search applications", ui.theme.text_faint);

    } else {

        ui.text_in(surface, &font, .{ .x = text_x, .y = search_rect.y, .w = text_w, .h = search_rect.h }, 0, 13, query, ui.theme.text);

    }

    // Caret at the edit cursor, clamped to the box.

    const before = query[0..@min(search.cursor, query.len)];
    const caret_x = @min(text_x + font.text_width(before, 13), text_x + text_w);
    const caret_h = @min(search_rect.h - 8, font.line_height(13));
    const caret_y = search_rect.y + @divTrunc(search_rect.h - caret_h, 2);

    surface.fill_rect(.{ .x = caret_x, .y = caret_y, .w = 1, .h = caret_h }, ui.theme.text);

    // Filtered application rows.

    var y = search_height;
    var any = false;

    for (apps[0..app_count]) |app| {

        if (!matches(app)) continue;

        any = true;

        const rect = Rect{ .x = 4, .y = y, .w = width - 8, .h = row_height - 4 };
        const hovered = menu_ptr_y >= rect.y and menu_ptr_y < rect.y + rect.h;

        if (hovered) surface.fill_rect(rect, ui.theme.hover);

        ui.icon(surface, .{ .x = 14, .y = y + 14, .w = 26, .h = 26 }, app.icon, ui.theme.accent);

        ui.text(surface, &font, 52, y + 9, 15, app.title, ui.theme.text);
        ui.text(surface, &font, 52, y + 30, 12, app.description, ui.theme.text_dim);

        y += row_height;

    }

    if (!any) {

        ui.text(surface, &font, 20, search_height + 12, 13, "No matching applications", ui.theme.text_dim);

    }

    menu_window.present_all() catch {};

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

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}

fn list_watcher() callconv(.c) noreturn {

    while (true) {

        _ = sys.wait(window_list.list_ready) catch continue;

        @atomicStore(u32, &tick, 1, .release);

        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}
