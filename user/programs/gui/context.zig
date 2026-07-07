// Context: the desktop right-click manager. A fullscreen chrome layer beneath ordinary windows catches right-clicks
// on blank desktop space and offers Create New File / Create New Folder. Menus and prompts paint on this layer so
// no popup window ever flashes at the wrong position.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;

comptime {

    _ = lib.start;

}

const home_dir = "/root/user";

const menu_items = [_]ui.MenuItem{

    .{ .label = "Create New File" },
    .{ .label = "Create New Folder" },

};

const prompt_width: i32 = 300;
const prompt_height: i32 = 120;
const blur_guard_ms: u64 = 100;
const event_batch_max = 32;

var font: lib.ttf.Face = undefined;

var connection: lib.window.Connection = undefined;
var desktop: lib.window.Window = undefined;

var menu_open = false;
var menu_x: i32 = 0;
var menu_y: i32 = 0;
var menu_hover: ?usize = null;
var menu_opened_ms: u64 = 0;

var prompt_open = false;
var prompt_kind: PromptKind = .file;

var client: ?lib.fs.Client = null;

var keyboard = lib.keymap.Keyboard{};
var name_storage: [64]u8 = undefined;
var name_field = ui.EditBuffer{ .bytes = &name_storage };

const PromptKind = enum {

    file,
    folder,

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

    const screen = try lib.wm.screen_info(&connection);

    desktop = try connection.create_window(screen.width, screen.height, proto.window.flag_desktop, "desktop");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

        if (client) |*handle| handle.cwd = home_dir;

    } else |_| {}

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

            if (!menu_open) return;

            const hit = ui.menu_hit(event.x, event.y, menu_x, menu_y, menu_items.len);

            if (hit == menu_hover) return;

            menu_hover = hit;
            paint_desktop();

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
            paint_desktop();

        },

        else => {},

    }

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

        if (ui.menu_hit(x, y, menu_x, menu_y, menu_items.len) != null) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    lib.cursor.set(&connection, .pointer);

}

fn button_down(event: events.Event) void {

    if (event.code != events.button_left and event.code != events.button_right) return;

    if (prompt_open) {

        if (event.code == events.button_left) prompt_click(event.x, event.y);

        return;

    }

    if (menu_open and event.code == events.button_left) {

        if (ui.menu_hit(event.x, event.y, menu_x, menu_y, menu_items.len)) |hit| {

            close_menu();

            switch (hit) {

                0 => open_prompt(.file),
                1 => open_prompt(.folder),

                else => {},

            }

            return;

        }

        close_menu();

        return;

    }

    if (event.code == events.button_right) {

        open_menu(event.x, event.y);
        return;

    }

    if (menu_open) close_menu();

}

fn open_menu(x: i32, y: i32) void {

    close_prompt();

    menu_x = x;
    menu_y = y;
    menu_hover = null;
    menu_open = true;
    menu_opened_ms = lib.time.now_ms();

    paint_desktop();

}

fn close_menu() void {

    if (!menu_open) return;

    menu_open = false;
    menu_hover = null;

    paint_desktop();

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

fn paint_desktop() void {

    const surface = &desktop.surface;

    surface.fill(lib.prefs.wallpaper());

    if (menu_open) {

        ui.context_menu(surface, &font, menu_x, menu_y, &menu_items, menu_hover);

    }

    if (prompt_open) paint_prompt(surface);

    desktop.present_all() catch {};

}

fn paint_prompt(surface: *const gfx.Surface) void {

    const rect = prompt_rect();

    ui.panel(surface, rect, ui.theme.window_bg);

    const title = switch (prompt_kind) {

        .file => "New file name",
        .folder => "New folder name",

    };

    ui.text(surface, &font, rect.x + 16, rect.y + 14, 14, title, ui.theme.text);

    const field = Rect{ .x = rect.x + 16, .y = rect.y + 36, .w = rect.w - 32, .h = 28 };

    ui.text_field(surface, &font, field, 13, &name_field, "name", .{ .focused = true, .caret_on = true });

    const create = Rect{ .x = rect.x + 16, .y = rect.y + 72, .w = 100, .h = 32 };
    const cancel = Rect{ .x = rect.x + 124, .y = rect.y + 72, .w = 100, .h = 32 };

    ui.button(surface, &font, create, "Create", 13, .accent);
    ui.button(surface, &font, cancel, "Cancel", 13, .normal);

}