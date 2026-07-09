// Context: the desktop right-click manager, wallpaper layer, and pinned file/folder icons.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;
const DesktopPin = lib.prefs.DesktopPin;

comptime {

    _ = lib.start;

}

const home_dir = "/root/user";

const MenuAction = enum {

    create_file,
    create_folder,
    open_marble,
    remove_pin,

};

const MenuRow = union(enum) {

    action: MenuAction,
    separator,

};

const desktop_menu_rows = [_]MenuRow{

    .{ .action = .create_file },
    .{ .action = .create_folder },
    .{ .separator = {} },
    .{ .action = .open_marble },

};

const pin_menu_rows = [_]MenuRow{

    .{ .action = .remove_pin },

};

const menu_row_h: i32 = 30;
const menu_separator_h: i32 = 9;
const menu_w: i32 = 190;
const menu_inset: i32 = 4;

const prompt_width: i32 = 300;
const prompt_height: i32 = 120;
const blur_guard_ms: u64 = 100;
const event_batch_max = 32;

const pin_cell_w: i32 = 96;
const pin_cell_h: i32 = 88;
const pin_icon: i32 = 36;
const pin_margin: i32 = 24;
const pin_gap: i32 = 12;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var desktop: lib.window.Window = undefined;

var menu_open = false;
var menu_x: i32 = 0;
var menu_y: i32 = 0;
var menu_hover: ?usize = null;
var menu_opened_ms: u64 = 0;
var menu_on_pin: ?usize = null;

var prompt_open = false;
var prompt_kind: PromptKind = .file;

var client: ?lib.fs.Client = null;

var keyboard = lib.keymap.Keyboard{};
var name_storage: [64]u8 = undefined;
var name_field = ui.EditBuffer{ .bytes = &name_storage };

var pins: [lib.prefs.max_desktop_pins]DesktopPin = undefined;
var pin_count: usize = 0;
var pin_is_dir: [lib.prefs.max_desktop_pins]bool = [_]bool{false} ** lib.prefs.max_desktop_pins;
var pin_hover: ?usize = null;
var pins_loaded_ms: u64 = 0;

const PromptKind = enum {

    file,
    folder,

};

fn active_menu_rows() []const MenuRow {

    return if (menu_on_pin != null) pin_menu_rows[0..] else desktop_menu_rows[0..];

}

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);

    const screen = try lib.wm.screen_info(&connection);

    desktop = try connection.create_window(screen.width, screen.height, proto.window.flag_desktop, "desktop");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

        if (client) |*handle| handle.cwd = home_dir;

    } else |_| {}

    reload_pins();
    paint_desktop();

    while (true) {

        var batch: [event_batch_max]events.Event = undefined;
        var count: usize = 0;

        batch[count] = try connection.wait_event();
        count += 1;

        while (count < event_batch_max) {

            if (connection.poll_event()) |event| {

                batch[count] = event;
                count += 1;

            } else break;

        }

        dispatch_batch(batch[0..count]);

    }

}

fn owns_event(event: events.Event) bool {

    return event.window == desktop.id or event.window == 0;

}

fn dispatch_batch(batch: []const events.Event) void {

    for (batch) |event| {

        if (!owns_event(event)) continue;
        if (event.kind != events.kind_button_down) continue;

        handle_desktop(event);

    }

    var last_move: ?events.Event = null;

    for (batch) |event| {

        if (!owns_event(event)) continue;
        if (event.kind == events.kind_button_down) continue;

        if (event.kind == events.kind_pointer_move) {

            last_move = event;
            continue;

        }

        handle_desktop(event);

    }

    if (last_move) |event| handle_desktop(event);

}

fn handle_desktop(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => button_down(event),

        events.kind_pointer_move => {

            update_cursor(event.x, event.y);

            if (menu_open) {

                const hit = menu_hit(event.x, event.y);

                if (hit != menu_hover) {

                    menu_hover = hit;
                    paint_menu_region();

                }

                return;

            }

            const pin = pin_at(event.x, event.y);

            if (pin != pin_hover) {

                const previous = pin_hover;
                pin_hover = pin;
                paint_pin_hover(previous, pin);

            }

        },

        events.kind_key_down => {

            if (prompt_open) prompt_key(event.code);

        },

        events.kind_window_resize => {

            desktop.resize(@intCast(event.x), @intCast(event.y)) catch {};
            paint_desktop();

        },

        events.kind_window_blur => {

            if (lib.time.now_ms() - menu_opened_ms < blur_guard_ms) return;

            if (menu_open or prompt_open) {

                close_menu();
                close_prompt();

            }

        },

        events.kind_prefs_changed => {

            lib.prefs.refresh();
            reload_pins();
            paint_desktop();

        },

        else => {},

    }

}

fn reload_pins() void {

    pin_count = lib.prefs.load_desktop_pins(pins[0..]);
    pins_loaded_ms = lib.time.now_ms();

    for (pins[0..pin_count], 0..) |pin, index| {

        pin_is_dir[index] = false;

        if (client) |*handle| {

            if (handle.stat(pin.slice())) |stat| {

                pin_is_dir[index] = stat.kind == proto.filesystem.kind_directory;

            } else |_| {}

        }

    }

}

fn reload_pins_if_stale() void {

    // Files broadcasts prefs_changed on pin add; still re-check on click as a backstop.
    if (lib.time.now_ms() -% pins_loaded_ms < 250) return;

    reload_pins();

}

fn update_cursor(x: i32, y: i32) void {

    if (prompt_open) {

        const rect = prompt_rect();
        const field = Rect{ .x = rect.x + 16, .y = rect.y + 36, .w = rect.w - 32, .h = 28 };
        const create = Rect{ .x = rect.x + 16, .y = rect.y + 72, .w = 100, .h = 32 };
        const cancel = Rect{ .x = rect.x + 124, .y = rect.y + 72, .w = 100, .h = 32 };

        if (field.contains(x, y)) lib.cursor.set(&connection, .selector)
        else if (create.contains(x, y) or cancel.contains(x, y)) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    if (menu_open) {

        if (menu_hit(x, y) != null) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    if (pin_at(x, y) != null) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn button_down(event: events.Event) void {

    if (event.code != events.button_left and event.code != events.button_right) return;

    // Pick up pins added by the file manager without a busy poll.
    const previous_pins = pin_count;
    reload_pins_if_stale();

    if (previous_pins != pin_count and !menu_open and !prompt_open) paint_desktop();

    if (prompt_open) {

        if (event.code == events.button_left) prompt_click(event.x, event.y);

        return;

    }

    if (menu_open and event.code == events.button_left) {

        if (menu_hit(event.x, event.y)) |hit| {

            const action = menu_action(hit);
            const pin_index = menu_on_pin;

            close_menu();

            const chosen = action orelse return;

            switch (chosen) {

                .create_file => open_prompt(.file),
                .create_folder => open_prompt(.folder),
                .open_marble => open_marble_here(),
                .remove_pin => {

                    if (pin_index) |index| remove_pin_at(index);

                },

            }

            return;

        }

        close_menu();

        return;

    }

    if (event.code == events.button_right) {

        if (pin_at(event.x, event.y)) |index| {

            open_menu(event.x, event.y, index);

        } else {

            open_menu(event.x, event.y, null);

        }

        return;

    }

    if (menu_open) {

        close_menu();
        return;

    }

    if (pin_at(event.x, event.y)) |index| open_pin(index);

}

fn open_menu(x: i32, y: i32, pin_index: ?usize) void {

    close_prompt();

    menu_x = x;
    menu_y = y;
    menu_hover = null;
    menu_on_pin = pin_index;
    menu_open = true;
    menu_opened_ms = lib.time.now_ms();

    // Clamp to the desktop surface.
    const width: i32 = @intCast(desktop.surface.width);
    const height: i32 = @intCast(desktop.surface.height);
    const menu_h = menu_content_height() + menu_inset * 2;

    if (menu_x + menu_w > width) menu_x = @max(0, width - menu_w);
    if (menu_y + menu_h > height) menu_y = @max(0, height - menu_h);

    paint_desktop();

}

fn close_menu() void {

    if (!menu_open) return;

    menu_open = false;
    menu_hover = null;
    menu_on_pin = null;

    paint_desktop();

}

fn remove_pin_at(index: usize) void {

    if (index >= pin_count) return;

    _ = lib.prefs.remove_desktop_pin(pins[index].slice());
    reload_pins();
    paint_desktop();

}

fn open_pin(index: usize) void {

    if (index >= pin_count) return;

    const path = pins[index].slice();

    // Re-stat on open so a cold pin_is_dir cache never opens a folder in Notepad (empty black window).
    var is_dir = pin_is_dir[index];

    if (client) |*handle| {

        if (handle.stat(path)) |stat| {

            is_dir = stat.kind == proto.filesystem.kind_directory;
            pin_is_dir[index] = is_dir;

        } else |_| {}

    }

    if (is_dir) {

        lib.wm.launch_with_path("files", path);

    } else {

        lib.wm.launch_with_path("notepad", path);

    }

}

fn pin_cell(index: usize) Rect {

    const cols = @max(1, @divTrunc(@as(i32, @intCast(desktop.surface.width)) - pin_margin * 2 + pin_gap, pin_cell_w + pin_gap));
    const col: i32 = @intCast(@as(usize, @intCast(index)) % @as(usize, @intCast(cols)));
    const row: i32 = @intCast(@as(usize, @intCast(index)) / @as(usize, @intCast(cols)));

    return .{

        .x = pin_margin + col * (pin_cell_w + pin_gap),
        .y = pin_margin + row * (pin_cell_h + pin_gap),
        .w = pin_cell_w,
        .h = pin_cell_h,

    };

}

fn pin_at(x: i32, y: i32) ?usize {

    var index: usize = 0;

    while (index < pin_count) : (index += 1) {

        if (pin_cell(index).contains(x, y)) return index;

    }

    return null;

}

fn pin_label(path: []const u8) []const u8 {

    if (path.len <= 1) return path;

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {

        if (slash + 1 < path.len) return path[slash + 1 ..];

    }

    return path;

}

fn open_prompt(kind: PromptKind) void {

    close_menu();

    prompt_kind = kind;
    name_field.clear();
    prompt_open = true;

    paint_desktop();

}

fn close_prompt() void {

    if (!prompt_open) return;

    prompt_open = false;

    paint_desktop();

}

fn prompt_key(code: u16) void {

    if (keyboard.modifier(events.kind_key_down, code)) return;

    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len == 1 and bytes[0] == '\r') {

        confirm_prompt();
        return;

    }

    if (bytes.len == 1 and bytes[0] == 0x1b) {

        close_prompt();
        return;

    }

    if (name_field.feed(bytes)) paint_desktop();

}

fn prompt_click(x: i32, y: i32) void {

    const rect = prompt_rect();

    const create = Rect{ .x = rect.x + 16, .y = rect.y + 72, .w = 100, .h = 32 };
    const cancel = Rect{ .x = rect.x + 124, .y = rect.y + 72, .w = 100, .h = 32 };

    if (create.contains(x, y)) {

        confirm_prompt();
        return;

    }

    if (cancel.contains(x, y)) close_prompt();

}

fn open_marble_here() void {

    lib.wm.launch_with_path("shell", home_dir);

}

fn menu_label(action: MenuAction) []const u8 {

    return switch (action) {

        .create_file => "Create New File",
        .create_folder => "Create New Folder",
        .open_marble => "Open MARBLE Here",
        .remove_pin => "Remove from Desktop",

    };

}

fn menu_action(index: usize) ?MenuAction {

    const rows = active_menu_rows();

    if (index >= rows.len) return null;

    return switch (rows[index]) {

        .action => |action| action,
        .separator => null,

    };

}

fn menu_content_height() i32 {

    var height: i32 = 0;

    for (active_menu_rows()) |row| {

        height += switch (row) {

            .action => menu_row_h,
            .separator => menu_separator_h,

        };

    }

    return height;

}

fn confirm_prompt() void {

    const name = name_field.slice();

    if (name.len == 0) return;

    const handle = if (client) |*c| c else return;

    switch (prompt_kind) {

        .file => _ = handle.create(name, proto.filesystem.kind_file) catch {},
        .folder => _ = handle.mkdir(name) catch {},

    }

    close_prompt();

}

fn prompt_rect() Rect {

    const width: i32 = @intCast(desktop.surface.width);
    const height: i32 = @intCast(desktop.surface.height);

    return .{

        .x = @divTrunc(width - prompt_width, 2),
        .y = @divTrunc(height - prompt_height, 2),
        .w = prompt_width,
        .h = prompt_height,

    };

}

fn menu_bounds() Rect {

    return .{

        .x = menu_x,
        .y = menu_y,
        .w = menu_w,
        .h = menu_content_height() + menu_inset * 2,

    };

}

fn paint_menu_region() void {

    // Menu hover redraws the whole desktop so pin icons under the menu stay correct.
    paint_desktop();

}

fn paint_desktop() void {

    const surface = &desktop.surface;

    surface.fill(lib.prefs.wallpaper());
    paint_pins(surface);

    if (menu_open) paint_menu(surface);

    if (prompt_open) paint_prompt(surface);

    desktop.present_all() catch {};

}

/// Only repaint the pin cells that changed hover state — avoids a full desktop present on every move.
fn paint_pin_hover(previous: ?usize, next: ?usize) void {

    if (menu_open or prompt_open) {

        paint_desktop();
        return;

    }

    const surface = &desktop.surface;
    var damage = Rect.empty;

    if (previous) |index| {

        if (index < pin_count) {

            const cell = pin_cell(index);

            paint_one_pin(surface, index);
            damage = damage.cover(cell);

        }

    }

    if (next) |index| {

        if (index < pin_count) {

            const cell = pin_cell(index);

            paint_one_pin(surface, index);
            damage = damage.cover(cell);

        }

    }

    if (!damage.is_empty()) desktop.present(damage) catch {};

}

fn paint_pins(surface: *const gfx.Surface) void {

    var index: usize = 0;

    while (index < pin_count) : (index += 1) {

        paint_one_pin(surface, index);

    }

}

fn paint_one_pin(surface: *const gfx.Surface, index: usize) void {

    if (index >= pin_count) return;

    const cell = pin_cell(index);

    surface.fill_rect(cell, lib.prefs.wallpaper());

    const hovered = pin_hover != null and pin_hover.? == index;

    if (hovered) ui.fill_round_rect(surface, cell, 8, ui.theme.hover);

    const icon = if (pin_is_dir[index]) lib.icons.folder else lib.icons.file;
    const tint = if (pin_is_dir[index]) ui.theme.accent else ui.theme.text_dim;
    const icon_x = cell.x + @divTrunc(cell.w - pin_icon, 2);
    const icon_y = cell.y + 10;

    lib.draw.vector.icon_in(surface, .{ .x = icon_x, .y = icon_y, .w = pin_icon, .h = pin_icon }, icon, tint);

    const label = pin_label(pins[index].slice());
    const visible = ui.truncate(&font, label, 12, cell.w - 8);
    const text_w = font.text_width(visible, 12);
    const text_x = cell.x + @divTrunc(cell.w - text_w, 2);
    const text_y = icon_y + pin_icon + 8;

    font.draw(surface, text_x, text_y, 12, visible, ui.theme.text);

}

fn paint_prompt(surface: *const gfx.Surface) void {

    const rect = prompt_rect();
    var page = ui.Page{ .font = &font };

    page.begin(@intCast(surface.width), @intCast(surface.height), .{

        .width = .{ .px = @intCast(surface.width) },
        .height = .{ .px = @intCast(surface.height) },

    });

    const title = switch (prompt_kind) {

        .file => "New file name",
        .folder => "New folder name",

    };

    const panel = page.box(ui.Page.root, .{

        .direction = .column,
        .width = .{ .px = rect.w },
        .height = .{ .px = rect.h },
        .margin = .{ .left = rect.x, .top = rect.y },
        .padding = ui.Edge.all(16),
        .gap = 8,
        .background = ui.theme.window_bg,
        .border = ui.theme.border,
        .radius = 8,

    });

    _ = page.label(panel, title, .{

        .height = .{ .px = 14 },
        .size = 14,
        .color = ui.theme.text,

    });

    _ = page.field(panel, &name_field, "name", true, .{

        .width = .{ .grow = 1 },
        .height = .{ .px = 28 },
        .size = 13,

    });

    const buttons = page.box(panel, .{

        .direction = .row,
        .height = .{ .px = 32 },
        .gap = 8,

    });

    _ = page.button(buttons, 1, "Create", .{

        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
        .size = 13,
        .background = ui.theme.accent_dim,

    });

    _ = page.button(buttons, 2, "Cancel", .{

        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
        .size = 13,

    });

    page.end();
    page.paint(surface);

}

fn menu_hit(x: i32, y: i32) ?usize {

    if (x < menu_x or x >= menu_x + menu_w) return null;

    var cursor_y = menu_y + menu_inset;

    if (y < cursor_y) return null;

    const rows = active_menu_rows();

    for (rows, 0..) |row, index| {

        const span = switch (row) {

            .action => menu_row_h,
            .separator => menu_separator_h,

        };

        if (y >= cursor_y and y < cursor_y + span) {

            return switch (row) {

                .action => index,
                .separator => null,

            };

        }

        cursor_y += span;

    }

    return null;

}

fn paint_menu(surface: *const gfx.Surface) void {

    var page = ui.Page{ .font = &font };

    page.begin(@intCast(surface.width), @intCast(surface.height), .{

        .width = .{ .px = @intCast(surface.width) },
        .height = .{ .px = @intCast(surface.height) },

    });

    const menu = page.box(ui.Page.root, .{

        .direction = .column,
        .width = .{ .px = menu_w },
        .height = .{ .px = menu_content_height() + menu_inset * 2 },
        .margin = .{ .left = menu_x, .top = menu_y },
        .padding = ui.Edge.all(menu_inset),
        .background = ui.theme.surface,
        .border = ui.theme.border,
        .radius = 6,

    });

    const rows = active_menu_rows();

    for (rows, 0..) |row, index| {

        switch (row) {

            .action => |action| {

                const hovered = menu_hover != null and menu_hover.? == index;

                _ = page.label(menu, menu_label(action), .{

                    .width = .{ .grow = 1 },
                    .height = .{ .px = menu_row_h - 1 },
                    .padding = ui.Edge.symmetric(12, 0),
                    .size = 13,
                    .color = ui.theme.text,
                    .background = if (hovered) ui.theme.hover else null,
                    .radius = 4,

                });

            },

            .separator => {

                _ = page.box(menu, .{

                    .width = .{ .grow = 1 },
                    .height = .{ .px = menu_separator_h },
                    .margin = ui.Edge.only(0, 0, 2, 0),

                });

            },

        }

    }

    page.end();
    page.paint(surface);

    var cursor_y = menu_y + menu_inset;

    for (rows) |row| {

        switch (row) {

            .action => cursor_y += menu_row_h,

            .separator => {

                const line_y = cursor_y + @divTrunc(menu_separator_h, 2);

                surface.fill_rect(.{

                    .x = menu_x + menu_inset + 8,
                    .y = line_y,
                    .w = menu_w - 2 * menu_inset - 16,
                    .h = 1,

                }, ui.theme.border);

                cursor_y += menu_separator_h;

            },

        }

    }

}
