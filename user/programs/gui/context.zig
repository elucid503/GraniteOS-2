// Context: the desktop right-click manager, wallpaper layer, and pinned file/folder icons.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;
const DesktopPin = lib.prefs.DesktopPin;

comptime {

    _ = lib.start;

}

const home_dir = "/root/user";

// Decode arena: IDAT (~160 KiB) + full-res XRGB pixels (~8 MiB at 1920x1080) + row scratch.
const wallpaper_arena_bytes = 12 * 1024 * 1024;

const MenuAction = enum {

    create_file,
    create_folder,
    open_marble,
    remove_pin,

};

// Row labels and their actions stay parallel; ui.Menu owns layout, hover, hit-testing, and painting.

const desktop_menu_rows = [_]ui.Menu.Row{

    .{ .item = "Create New File" },
    .{ .item = "Create New Folder" },
    .separator,
    .{ .item = "Open MARBLE Here" },

};

const desktop_menu_actions = [_]?MenuAction{ .create_file, .create_folder, null, .open_marble };

const pin_menu_rows = [_]ui.Menu.Row{

    .{ .item = "Remove from Desktop" },

};

const pin_menu_actions = [_]?MenuAction{.remove_pin};

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
var bundle: lib.bundle.Bundle = undefined;

var connection: lib.window.Connection = undefined;
var desktop: lib.window.Window = undefined;

var wallpaper_image: ?lib.draw.png.Image = null;
var wallpaper_theme: ?lib.prefs.ThemeId = null;
var wallpaper_arena: []u8 = &.{};

var menu = ui.Menu{};
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

fn active_menu_actions() []const ?MenuAction {

    return if (menu_on_pin != null) pin_menu_actions[0..] else desktop_menu_actions[0..];

}

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);

    const screen = try lib.wm.screen_info(&connection);

    desktop = try connection.create_window(screen.width, screen.height, proto.window.flag_desktop, "desktop");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

        if (client) |*handle| handle.cwd = home_dir;

    } else |_| {}

    reload_wallpaper();
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

            if (menu.open) {

                if (menu.pointer_move(event.x, event.y)) paint_menu_region();

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

            if (menu.open or prompt_open) {

                close_menu();
                close_prompt();

            }

        },

        events.kind_prefs_changed => {

            lib.prefs.refresh();
            reload_wallpaper();
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

    if (menu.open) {

        if (menu.hit(x, y) != null) lib.cursor.set(&connection, .clicker)
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

    if (previous_pins != pin_count and !menu.open and !prompt_open) paint_desktop();

    if (prompt_open) {

        if (event.code == events.button_left) prompt_click(event.x, event.y);

        return;

    }

    if (menu.open and event.code == events.button_left) {

        if (menu.hit(event.x, event.y)) |hit| {

            const action = active_menu_actions()[hit];
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

    if (menu.open) {

        close_menu();
        return;

    }

    if (pin_at(event.x, event.y)) |index| open_pin(index);

}

fn open_menu(x: i32, y: i32, pin_index: ?usize) void {

    close_prompt();

    menu_on_pin = pin_index;
    menu_opened_ms = lib.time.now_ms();

    const rows: []const ui.Menu.Row = if (pin_index != null) pin_menu_rows[0..] else desktop_menu_rows[0..];

    menu.open_at(rows, x, y, @intCast(desktop.surface.width), @intCast(desktop.surface.height));

    paint_desktop();

}

fn close_menu() void {

    if (!menu.open) return;

    menu.close();
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

fn paint_menu_region() void {

    // Menu hover redraws the whole desktop so pin icons under the menu stay correct.
    paint_desktop();

}

fn paint_desktop() void {

    const surface = &desktop.surface;

    paint_wallpaper(surface, null);
    paint_pins(surface);

    menu.paint(surface, &font);

    if (prompt_open) paint_prompt(surface);

    desktop.present_all() catch {};

}

/// Decode the active theme's wallpaper from the module bundle (one PNG under wallpaper/default).
fn reload_wallpaper() void {

    const theme = lib.prefs.active_theme;

    if (wallpaper_theme) |current| {

        if (current == theme and wallpaper_image != null) return;

    }

    wallpaper_image = null;
    wallpaper_theme = theme;

    ensure_wallpaper_arena() catch return;

    var fba = std.heap.FixedBufferAllocator.init(wallpaper_arena);
    const bytes = bundle.find(lib.prefs.wallpaper_bundle_name(theme)) orelse return;

    wallpaper_image = lib.draw.png.decode(fba.allocator(), bytes) catch null;

}

fn ensure_wallpaper_arena() !void {

    if (wallpaper_arena.len != 0) return;

    const region = try sys.create(.region, wallpaper_arena_bytes, cap.memory);
    const base = try sys.map(cap.self_space, region, 0, sys.read | sys.write);

    wallpaper_arena = @as([*]u8, @ptrFromInt(base))[0..wallpaper_arena_bytes];

}

/// Fill `rect` (or the full surface) with the cover-fitted wallpaper, or the theme solid color if missing.
fn paint_wallpaper(surface: *const gfx.Surface, rect: ?Rect) void {

    if (wallpaper_image) |image| {

        const view = lib.draw.image.Image.from_png(image);
        const full = surface.bounds();

        if (rect) |region| {

            var clipped = surface.clipped(region);

            view.draw_cover(&clipped, full);

        } else {

            view.draw_cover(surface, full);

        }

        return;

    }

    if (rect) |region| {

        surface.fill_rect(region, lib.prefs.wallpaper());

    } else {

        surface.fill(lib.prefs.wallpaper());

    }

}

/// Only repaint the pin cells that changed hover state — avoids a full desktop present on every move.
fn paint_pin_hover(previous: ?usize, next: ?usize) void {

    if (menu.open or prompt_open) {

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

    paint_wallpaper(surface, cell);

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

