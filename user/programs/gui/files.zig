// File Manager: multi-tab browser over the Strata filesystem with list and grid views.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;
const Entry = proto.filesystem.Entry;
const Color = gfx.Color;

pub const app_meta = .{
    .title = "Files",
    .description = "Browse and manage files.",
    .icon = "folder",
    .category = "System",
};

comptime {

    _ = lib.start;

}

const max_entries = 256;
const max_path = 512;
const max_tabs = 6;
const preview_bytes = 2048;
const event_batch_max = 32;

// Banner holds up control, directory tabs, and view switcher.
const banner_h: i32 = 44;
const content_top: i32 = banner_h;
const row_height: i32 = 32;

const grid_cell_w: i32 = 100;
const grid_cell_h: i32 = 108;
const grid_gap: i32 = 8;
const grid_pad: i32 = 10;
const grid_preview: i32 = 64;

const tab_min_w: i32 = 72;
const tab_max_w: i32 = 140;
const tab_close_w: i32 = 18;
const chrome_btn: i32 = 28;
const view_btn: i32 = 30;

// Dark frost used for the banner and inspector over Quartz.
const chrome_tint = lib.draw.rgb(14, 14, 14);
const chrome_solid = lib.draw.rgb(22, 22, 22);

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var menu_window: ?lib.window.Window = null;

var client: ?lib.fs.Client = null;

const ViewMode = enum(u8) {

    row,
    grid,

};

const Tab = struct {

    path: [max_path]u8 = undefined,
    path_len: usize = 1,

    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,

    selected: ?usize = null,
    scroll: usize = 0,

    fn path_slice(self: *const Tab) []const u8 {

        return self.path[0..self.path_len];

    }

    fn set_path(self: *Tab, next: []const u8) void {

        const length = @min(next.len, self.path.len);

        @memcpy(self.path[0..length], next[0..length]);
        self.path_len = length;

    }

    fn basename(self: *const Tab) []const u8 {

        const full = self.path_slice();

        if (full.len <= 1) return "/";

        if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {

            if (slash + 1 < full.len) return full[slash + 1 ..];

        }

        return full;

    }

    fn clear(self: *Tab) void {

        @memset(std.mem.asBytes(self), 0);
        self.path_len = 1;
        self.path[0] = '/';

    }

};

var tabs: [max_tabs]Tab = undefined;
var tab_count: usize = 1;
var active_tab: usize = 0;
var view_mode: ViewMode = .row;

var preview: [preview_bytes]u8 = undefined;
var preview_len: usize = 0;
var preview_is_text = false;

// Thumbnail cache for selected image previews (one decode at a time).
const thumb_file_cap = 64 * 1024;
const thumb_decode_cap = 256 * 1024;

var thumb_file: [thumb_file_cap]u8 = undefined;
var thumb_decode: [thumb_decode_cap]u8 = undefined;
var thumb_path: [max_path]u8 = undefined;
var thumb_path_len: usize = 0;
var thumb_image: ?lib.draw.image.Buffer = null;
var thumb_valid = false;

const MenuAction = enum {

    edit_notepad,
    open_image,
    view_details,
    add_desktop,
    rename_item,
    delete_item,

};

const MenuRow = union(enum) {

    action: MenuAction,
    separator,

};

const menu_rows = [_]MenuRow{

    .{ .action = .edit_notepad },
    .{ .action = .open_image },
    .{ .action = .view_details },
    .{ .action = .add_desktop },
    .{ .separator = {} },
    .{ .action = .rename_item },
    .{ .separator = {} },
    .{ .action = .delete_item },

};

const menu_row_h: i32 = 30;
const menu_separator_h: i32 = 9;
const menu_w: i32 = 200;
const menu_inset: i32 = 4;
const menu_label_pad: i32 = 12;
const menu_blur_guard_ms: u64 = 100;

const details_w: i32 = 340;
const details_h: i32 = 240;

const prompt_width: i32 = 380;
const prompt_height: i32 = 140;

const drag_threshold: i32 = 6;

const DropTarget = union(enum) {

    none,
    parent,
    directory: usize,

};

var menu_open = false;
var menu_x: i32 = 0;
var menu_y: i32 = 0;
var menu_hover: ?usize = null;
var menu_target: ?usize = null;
var menu_opened_ms: u64 = 0;

var details_open = false;
var details_writable = true;
var details_path: [max_path]u8 = undefined;
var details_path_len: usize = 0;
var details_name: [48]u8 = undefined;
var details_name_len: usize = 0;
var details_kind: u8 = 0;
var details_length: u64 = 0;
var details_status: []const u8 = "";

var pointer_x: i32 = -1;
var pointer_y: i32 = -1;
var last_hover: i32 = -3;

var prompt_open = false;
var prompt_source: [max_path]u8 = undefined;
var prompt_source_len: usize = 0;
var prompt_status: []const u8 = "";

var keyboard = lib.keymap.Keyboard{};
var name_storage: [max_path]u8 = undefined;
var name_field = ui.EditBuffer{ .bytes = &name_storage };

// Drag-to-move: press an entry, drag onto a folder or the banner (parent), release to drop.
var press_index: ?usize = null;
var press_x: i32 = 0;
var press_y: i32 = 0;
var drag_active = false;
var drag_index: ?usize = null;
var drop_target: DropTarget = .none;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(800, 520, 0, "Files");

    // Zero in place — never materialize a multi-tab temporary on the 512 KiB stack.
    @memset(std.mem.asBytes(&tabs), 0);
    tabs[0].set_path("/");
    tab_count = 1;
    active_tab = 0;

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

        if (client) |*handle| set_cwd(start_directory(handle));

        reload();

    } else |_| {}

    paint();

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

        if (dispatch_batch(batch[0..count])) return;

    }

}

fn tab() *Tab {

    return &tabs[active_tab];

}

fn tab_const() *const Tab {

    return &tabs[active_tab];

}

fn cwd() []const u8 {

    return tab_const().path_slice();

}

/// Returns true when the window should close.
fn dispatch_batch(batch: []const events.Event) bool {

    var last_move: ?events.Event = null;
    var last_menu_move: ?events.Event = null;
    var scroll_delta: i64 = 0;

    for (batch) |event| {

        if (lib.prefs.apply_event(event)) {

            paint();
            paint_menu_window();

            continue;

        }

        if (event.window == menu_window_id() and event.window != 0) {

            if (event.kind == events.kind_pointer_move) {

                last_menu_move = event;

            } else {

                handle_menu_event(event);

            }

            continue;

        }

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return true;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                clamp_scroll();
                paint();

            },

            events.kind_button_down => button_down(event),

            events.kind_button_up => button_up(event),

            events.kind_key_down => {

                if (prompt_open) prompt_key(event.code);

            },

            events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

            events.kind_window_blur => cancel_press(),

            events.kind_scroll => {

                if (!menu_open and !details_open and !prompt_open and !drag_active) scroll_delta += event.value;

            },

            events.kind_pointer_move => last_move = event,

            else => {},

        }

    }

    if (scroll_delta != 0) wheel(scroll_delta);

    if (last_move) |event| handle_pointer_move(event);
    if (last_menu_move) |event| handle_menu_pointer_move(event);

    return false;

}

fn menu_window_id() u64 {

    return if (menu_window) |popup| popup.id else 0;

}

fn handle_menu_event(event: events.Event) void {

    switch (event.kind) {

        events.kind_button_down => {

            if (event.code != events.button_left) {

                close_menu();

                return;

            }

            const hit = menu_hit(event.x, event.y) orelse {

                close_menu();

                return;

            };
            const action = menu_action(hit) orelse {

                close_menu();

                return;

            };
            const target = menu_target;

            close_menu();

            if (target) |index| run_menu_action(action, index);

        },

        events.kind_key_down => {

            if (keyboard.modifier(events.kind_key_down, event.code)) return;

            var buffer: [3]u8 = undefined;
            const bytes = keyboard.bytes(event.code, &buffer);

            if (bytes.len == 1 and bytes[0] == 0x1b) close_menu();

        },

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),
        events.kind_window_blur => {

            if (lib.time.now_ms() - menu_opened_ms >= menu_blur_guard_ms) close_menu();

        },

        else => {},

    }

}

fn handle_menu_pointer_move(event: events.Event) void {

    if (!menu_open) return;

    const hit = menu_hit(event.x, event.y);

    lib.cursor.set(&connection, if (hit != null) .clicker else .pointer);

    if (hit == menu_hover) return;

    menu_hover = hit;
    paint_menu_window();

}

fn handle_pointer_move(event: events.Event) void {

    pointer_x = event.x;
    pointer_y = event.y;

    if (prompt_open) {

        update_cursor(event.x, event.y);
        return;

    }

    if (press_index != null or drag_active) {

        track_drag(event.x, event.y);
        update_cursor(event.x, event.y);
        return;

    }

    if (menu_open) {

        const hit = menu_hit(event.x, event.y);

        if (hit != menu_hover) {

            menu_hover = hit;
            paint();

        }

    } else if (details_open) {

        const token: i32 = if (details_hit(event.x, event.y) != null) 1 else 0;

        if (token != last_hover) {

            last_hover = token;
            paint();

        }

    } else {

        const token = hover_token(event.x, event.y);

        if (token != last_hover) {

            last_hover = token;
            paint();

        }

    }

    update_cursor(event.x, event.y);

}

fn button_down(event: events.Event) void {

    if (event.code != events.button_left and event.code != events.button_right) return;

    if (prompt_open) {

        if (event.code == events.button_left) prompt_click(event.x, event.y);

        return;

    }

    if (details_open) {

        if (event.code == events.button_left) details_click(event.x, event.y);

        return;

    }

    if (menu_open) {

        if (event.code == events.button_left) {

            if (menu_hit(event.x, event.y)) |hit| {

                const action = menu_action(hit) orelse {

                    close_menu();
                    return;

                };

                const target = menu_target;
                close_menu();

                if (target) |index| run_menu_action(action, index);

                return;

            }

            close_menu();
            return;

        }

        if (event.code == events.button_right) {

            close_menu();
            open_context(event.x, event.y);
            return;

        }

    }

    if (event.code == events.button_right) {

        cancel_press();
        open_context(event.x, event.y);
        return;

    }

    press_begin(event.x, event.y);

}

fn button_up(event: events.Event) void {

    if (event.code != events.button_left) return;

    if (prompt_open or details_open or menu_open) return;

    if (drag_active) {

        const target = resolve_drop(event.x, event.y);
        const index = drag_index;
        cancel_press();

        if (index) |source| apply_drop(source, target);

        return;

    }

    if (press_index) |index| {

        cancel_press();

        // Banner and expand chevrons handle on press; list/grid entries open on release so a drag can steal the gesture.
        if (index < content_count()) open_entry(index);

        return;

    }

}

fn start_directory(handle: *lib.fs.Client) []const u8 {

    // Desktop pins and other launchers can stage a path for the next Files window.
    var staged: [max_path]u8 = undefined;

    if (lib.prefs.take_open_path(&staged)) |path| {

        // Copy out of the staging buffer first - take_open_path returns a slice of `staged`.
        const length = @min(path.len, max_path);
        @memcpy(tabs[0].path[0..length], path[0..length]);
        tabs[0].path_len = length;
        const saved = tabs[0].path[0..length];

        if (handle.stat(saved)) |stat| {

            if (stat.kind == proto.filesystem.kind_directory) return saved;

            // A staged file falls back to its parent directory.
            if (std.mem.lastIndexOfScalar(u8, saved, '/')) |slash| {

                const parent = if (slash == 0) "/" else saved[0..slash];
                const parent_len = @min(parent.len, max_path);

                tabs[0].set_path(parent[0..parent_len]);
                return tabs[0].path_slice();

            }

        } else |_| {

            // Stat failed: still open the staged absolute path if it looks valid.
            if (saved.len > 0 and saved[0] == '/') return saved;

        }

    }

    const home = lib.start.cwd();

    if (home.len > 0 and home[0] == '/') return home;

    return "/";

}

fn set_cwd(path: []const u8) void {

    tab().set_path(path);

    if (client) |*handle| handle.cwd = cwd();

}

fn reload() void {

    const t = tab();

    t.entry_count = 0;
    t.selected = null;
    t.scroll = 0;
    preview_len = 0;
    invalidate_thumb();

    const handle = if (client) |*c| c else return;

    handle.cwd = t.path_slice();

    const listing = handle.list(t.path_slice()) catch return;

    for (listing) |entry| {

        if (t.entry_count >= max_entries) break;

        t.entries[t.entry_count] = entry;
        t.entry_count += 1;

    }

    sort_entries(t);

}

fn sort_entries(t: *Tab) void {

    var i: usize = 1;

    while (i < t.entry_count) : (i += 1) {

        var j = i;

        while (j > 0 and precedes(t.entries[j], t.entries[j - 1])) : (j -= 1) {

            const swap = t.entries[j];
            t.entries[j] = t.entries[j - 1];
            t.entries[j - 1] = swap;

        }

    }

}

fn precedes(a: Entry, b: Entry) bool {

    const a_dir = a.kind == proto.filesystem.kind_directory;
    const b_dir = b.kind == proto.filesystem.kind_directory;

    if (a_dir != b_dir) return a_dir;

    return std.mem.lessThan(u8, a.name[0..a.name_len], b.name[0..b.name_len]);

}

fn switch_tab(index: usize) void {

    if (index >= tab_count or index == active_tab) return;

    active_tab = index;
    preview_len = 0;
    invalidate_thumb();

    if (client) |*handle| handle.cwd = cwd();

    clamp_scroll();
    paint();

}

fn open_tab(path: []const u8) void {

    if (tab_count >= max_tabs) return;

    const index = tab_count;
    tabs[index].clear();
    tabs[index].set_path(path);
    tab_count += 1;
    active_tab = index;

    reload();
    paint();

}

fn close_tab(index: usize) void {

    if (tab_count <= 1 or index >= tab_count) return;

    var i = index;

    while (i + 1 < tab_count) : (i += 1) {

        // Byte copy avoids a large Tab temporary on the stack.
        @memcpy(std.mem.asBytes(&tabs[i]), std.mem.asBytes(&tabs[i + 1]));

    }

    tab_count -= 1;

    if (active_tab > index) active_tab -= 1
    else if (active_tab >= tab_count) active_tab = tab_count - 1;

    preview_len = 0;
    invalidate_thumb();

    if (client) |*handle| handle.cwd = cwd();

    clamp_scroll();
    paint();

}

fn set_view(mode: ViewMode) void {

    if (view_mode == mode) return;

    view_mode = mode;
    tab().scroll = 0;

    if (tab().selected) |s| {

        if (s >= content_count()) {

            tab().selected = null;
            preview_len = 0;
            invalidate_thumb();

        }

    }

    clamp_scroll();
    paint();

}

// Interaction

fn update_cursor(x: i32, y: i32) void {

    if (prompt_open) {

        const rect = prompt_rect();
        const field = Rect{ .x = rect.x + 16, .y = rect.y + 40, .w = rect.w - 32, .h = 28 };
        const confirm = Rect{ .x = rect.x + 16, .y = rect.y + 84, .w = 100, .h = 32 };
        const cancel = Rect{ .x = rect.x + 124, .y = rect.y + 84, .w = 100, .h = 32 };

        if (field.contains(x, y)) lib.cursor.set(&connection, .selector)
        else if (confirm.contains(x, y) or cancel.contains(x, y)) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    if (details_open) {

        if (details_hit(x, y) != null) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    if (menu_open) {

        if (menu_hit(x, y) != null) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    if (drag_active) {

        const valid = switch (resolve_drop(x, y)) {

            .none => false,
            else => true,

        };

        lib.cursor.set(&connection, if (valid) .clicker else .pointer);
        return;

    }

    if (chrome_hot(x, y) or hover_token(x, y) >= 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn chrome_hot(x: i32, y: i32) bool {

    if (y >= banner_h) return false;

    if (up_btn_rect().contains(x, y)) return true;
    if (new_tab_rect().contains(x, y)) return true;
    if (view_btn_rect(.row).contains(x, y)) return true;
    if (view_btn_rect(.grid).contains(x, y)) return true;

    var i: usize = 0;

    while (i < tab_count) : (i += 1) {

        if (tab_rect(i).contains(x, y)) return true;

    }

    return false;

}

fn hover_token(x: i32, y: i32) i32 {

    if (y < content_top or x >= list_width()) return -1;

    return switch (view_mode) {

        .row => blk: {

            const row: i32 = @divTrunc(y - content_top, row_height);
            break :blk if (row < 0) -1 else row;

        },

        .grid => blk: {

            const cols = grid_columns();
            if (cols <= 0) break :blk -1;

            const local_x = x - grid_pad;
            const local_y = y - content_top - grid_pad;

            if (local_x < 0 or local_y < 0) break :blk -1;

            const col = @divTrunc(local_x, grid_cell_w + grid_gap);
            const row = @divTrunc(local_y, grid_cell_h + grid_gap);

            if (col < 0 or col >= cols or row < 0) break :blk -1;

            break :blk row * cols + col;

        },

    };

}

fn content_count() usize {

    return tab_const().entry_count;

}

fn entry_index_at(x: i32, y: i32) ?usize {

    if (y < content_top or x >= list_width()) return null;

    return switch (view_mode) {

        .row => blk: {

            const row: usize = @intCast(@divTrunc(y - content_top, row_height));
            const index = tab_const().scroll + row;

            if (index >= tab_const().entry_count) break :blk null;

            break :blk index;

        },

        .grid => blk: {

            const cols = grid_columns();
            if (cols <= 0) break :blk null;

            const local_x = x - grid_pad;
            const local_y = y - content_top - grid_pad;

            if (local_x < 0 or local_y < 0) break :blk null;

            const col: usize = @intCast(@divTrunc(local_x, grid_cell_w + grid_gap));
            const row_local: usize = @intCast(@divTrunc(local_y, grid_cell_h + grid_gap));

            if (col >= @as(usize, @intCast(cols))) break :blk null;

            // Cell may sit in the gap between tiles.
            const cell_x = @as(i32, @intCast(col)) * (grid_cell_w + grid_gap);
            const cell_y = @as(i32, @intCast(row_local)) * (grid_cell_h + grid_gap);

            if (local_x >= cell_x + grid_cell_w or local_y >= cell_y + grid_cell_h) break :blk null;

            const index = (tab_const().scroll + row_local) * @as(usize, @intCast(cols)) + col;

            if (index >= tab_const().entry_count) break :blk null;

            break :blk index;

        },

    };

}

fn open_context(x: i32, y: i32) void {

    const index = entry_index_at(x, y) orelse return;
    const menu_h = menu_content_height() + menu_inset * 2;
    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    var placement_x = x;
    var placement_y = y;

    select_index(index);
    menu_target = index;
    menu_hover = null;
    menu_open = true;
    menu_opened_ms = lib.time.now_ms();

    if (placement_x + menu_w > width) placement_x = @max(0, width - menu_w);
    if (placement_y + menu_h > height) placement_y = @max(0, height - menu_h);

    ensure_menu_window() catch {

        menu_open = false;
        menu_target = null;

        return;

    };

    const popup = menu_window orelse return;

    lib.wm.place_relative(&connection, popup.id, window.id, placement_x, placement_y) catch {

        menu_open = false;
        menu_target = null;

        return;

    };

    menu_x = 0;
    menu_y = 0;
    paint();
    paint_menu_content();

    gfx.fence();
    lib.wm.restore(&connection, popup.id) catch {};
    popup.present_all() catch {};

}

fn close_menu() void {

    if (!menu_open) return;

    menu_open = false;
    menu_hover = null;
    menu_target = null;

    if (menu_window) |popup| lib.wm.minimize(&connection, popup.id) catch {};

    paint();

}

fn ensure_menu_window() !void {

    const width: u32 = @intCast(menu_w);
    const height: u32 = @intCast(menu_content_height() + menu_inset * 2);

    if (menu_window) |*popup| {

        if (popup.surface.width == width and popup.surface.height == height) return;

        try popup.resize(width, height);

        return;

    }

    const popup = try connection.create_window(width, height, proto.window.flag_undecorated, "files-menu");

    try lib.wm.minimize(&connection, popup.id);

    menu_window = popup;

}

fn menu_label(action: MenuAction) []const u8 {

    return switch (action) {

        .edit_notepad => "Edit via Notepad",
        .open_image => "Open with Images",
        .view_details => "View Details",
        .add_desktop => "Add To Desktop",
        .rename_item => "Rename",
        .delete_item => "Delete Item",

    };

}

fn menu_action(index: usize) ?MenuAction {

    if (index >= menu_rows.len) return null;

    return switch (menu_rows[index]) {

        .action => |action| action,
        .separator => null,

    };

}

fn menu_content_height() i32 {

    var height: i32 = 0;

    for (menu_rows) |row| {

        height += switch (row) {

            .action => menu_row_h,
            .separator => menu_separator_h,

        };

    }

    return height;

}

fn menu_hit(x: i32, y: i32) ?usize {

    if (x < menu_x or x >= menu_x + menu_w) return null;

    var cursor_y = menu_y + menu_inset;

    if (y < cursor_y) return null;

    for (menu_rows, 0..) |row, index| {

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

fn entry_at(index: usize) ?Entry {

    const t = tab_const();

    if (index >= t.entry_count) return null;

    return t.entries[index];

}

fn path_at(index: usize, buffer: *[max_path]u8) ?[]const u8 {

    const t = tab_const();

    if (index >= t.entry_count) return null;

    const entry = t.entries[index];

    return lib.fs.canonicalize(t.path_slice(), entry.name[0..entry.name_len], buffer) catch null;

}

fn select_index(index: usize) void {

    const t = tab();
    t.selected = index;

    if (entry_at(index)) |entry| {

        if (entry.kind != proto.filesystem.kind_directory) load_preview_entry(entry, index)
        else preview_len = 0;

    }

}

fn run_menu_action(action: MenuAction, index: usize) void {

    const entry = entry_at(index) orelse return;
    var path_buffer: [max_path]u8 = undefined;
    const path = path_at(index, &path_buffer) orelse return;

    switch (action) {

        .edit_notepad => {

            lib.wm.launch_with_path("notepad", path);

        },

        .open_image => {

            lib.wm.launch_with_path("viewer", path);

        },

        .view_details => open_details(entry, path),

        .add_desktop => {

            if (lib.prefs.add_desktop_pin(path)) {

                lib.prefs.broadcast_change(&connection);

            }

        },

        .rename_item => open_prompt(path, entry.name[0..entry.name_len]),

        .delete_item => {

            const handle = if (client) |*c| c else return;

            handle.delete(path) catch return;
            reload();
            paint();

        },

    }

}

fn open_prompt(source_path: []const u8, initial: []const u8) void {

    close_menu();
    close_details();
    cancel_press();

    prompt_status = "";

    prompt_source_len = @min(source_path.len, prompt_source.len);
    @memcpy(prompt_source[0..prompt_source_len], source_path[0..prompt_source_len]);

    set_edit_text(initial);
    prompt_open = true;
    paint();

}

fn close_prompt() void {

    if (!prompt_open) return;

    prompt_open = false;
    prompt_status = "";
    paint();

}

fn set_edit_text(content: []const u8) void {

    name_field.clear();

    const length = @min(content.len, name_storage.len);

    @memcpy(name_storage[0..length], content[0..length]);
    name_field.len = length;
    name_field.cursor = length;

}

fn prompt_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{

        .x = @divTrunc(width - prompt_width, 2),
        .y = @divTrunc(height - prompt_height, 2),
        .w = prompt_width,
        .h = prompt_height,

    };

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

    if (name_field.feed(bytes, keyboard.shift)) paint();

}

fn prompt_click(x: i32, y: i32) void {

    const rect = prompt_rect();
    const confirm = Rect{ .x = rect.x + 16, .y = rect.y + 84, .w = 100, .h = 32 };
    const cancel = Rect{ .x = rect.x + 124, .y = rect.y + 84, .w = 100, .h = 32 };

    if (confirm.contains(x, y)) {

        confirm_prompt();
        return;

    }

    if (cancel.contains(x, y)) {

        close_prompt();
        return;

    }

    const field_rect = Rect{ .x = rect.x + 16, .y = rect.y + 38, .w = rect.w - 32, .h = 28 };

    if (field_rect.contains(x, y)) {

        const inner_w = field_rect.w - 2 * ui.field_pad;
        const rel_x = x - field_rect.x - ui.field_pad;
        const index = ui.field_click_index(&font, name_field.slice(), 13, name_field.cursor, inner_w, rel_x);

        _ = name_field.set_cursor(index, keyboard.shift);
        paint();

        return;

    }

    if (!rect.contains(x, y)) close_prompt();

}

fn confirm_prompt() void {

    const handle = if (client) |*c| c else return;
    const source = prompt_source[0..prompt_source_len];
    const typed = name_field.slice();

    if (typed.len == 0) {

        prompt_status = "Name required";
        paint();
        return;

    }

    var dest_buf: [max_path]u8 = undefined;
    const parent = path_parent(source);
    const dest = lib.fs.canonicalize(parent, typed, &dest_buf) catch {

        prompt_status = "Invalid name";
        paint();
        return;

    };

    if (std.mem.eql(u8, source, dest)) {

        close_prompt();
        return;

    }

    handle.rename(source, dest) catch {

        prompt_status = "Rename failed";
        paint();
        return;

    };

    reload();

    tab().selected = null;

    for (0..content_count()) |index| {

        var path_buffer: [max_path]u8 = undefined;
        const path = path_at(index, &path_buffer) orelse continue;

        if (std.mem.eql(u8, path, dest)) {

            tab().selected = index;
            break;

        }

    }

    close_prompt();

}

fn path_parent(path: []const u8) []const u8 {

    if (path.len <= 1) return "/";

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {

        if (slash == 0) return "/";

        return path[0..slash];

    }

    return cwd();

}

fn open_details(entry: Entry, path: []const u8) void {

    details_name_len = @min(entry.name_len, details_name.len);
    @memcpy(details_name[0..details_name_len], entry.name[0..details_name_len]);

    details_path_len = @min(path.len, details_path.len);
    @memcpy(details_path[0..details_path_len], path[0..details_path_len]);

    details_kind = entry.kind;
    details_length = entry.length;
    details_status = "";
    details_writable = true;

    if (client) |*handle| {

        if (handle.stat(path)) |stat| {

            details_kind = @truncate(stat.kind);
            details_length = stat.length;
            details_writable = (stat.permissions & proto.filesystem.permission_write) != 0;

        } else |_| {}

    }

    details_open = true;
    paint();

}

fn close_details() void {

    if (!details_open) return;

    details_open = false;
    paint();

}

fn details_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{

        .x = @divTrunc(width - details_w, 2),
        .y = @divTrunc(height - details_h, 2),
        .w = details_w,
        .h = details_h,

    };

}

fn details_writable_toggle() Rect {

    const rect = details_rect();

    return .{ .x = rect.x + 16, .y = rect.y + 140, .w = 148, .h = 30 };

}

fn details_close_btn() Rect {

    const rect = details_rect();

    return .{ .x = rect.x + rect.w - 100, .y = rect.y + rect.h - 46, .w = 84, .h = 30 };

}

fn details_hit(x: i32, y: i32) ?enum { toggle, close } {

    if (details_writable_toggle().contains(x, y)) return .toggle;
    if (details_close_btn().contains(x, y)) return .close;

    return null;

}

fn details_click(x: i32, y: i32) void {

    const hit = details_hit(x, y) orelse {

        if (!details_rect().contains(x, y)) close_details();

        return;

    };

    switch (hit) {

        .toggle => toggle_details_writable(),
        .close => close_details(),

    }

}

fn toggle_details_writable() void {

    const handle = if (client) |*c| c else return;
    const path = details_path[0..details_path_len];

    details_writable = !details_writable;

    const mask: u64 = if (details_writable) proto.filesystem.permission_write else 0;

    handle.set_permissions(path, mask) catch {

        details_writable = !details_writable;
        details_status = "Permission change failed";
        paint();
        return;

    };

    details_status = if (details_writable) "Writable" else "Read-only";
    paint();

}

fn press_begin(x: i32, y: i32) void {

    if (prompt_open) close_prompt();
    if (menu_open) close_menu();

    cancel_press();

    if (y < banner_h) {

        chrome_press(x, y);
        return;

    }

    const index = entry_index_at(x, y) orelse return;

    press_index = index;
    press_x = x;
    press_y = y;
    select_index(index);
    paint();

}

fn chrome_press(x: i32, y: i32) void {

    if (up_btn_rect().contains(x, y)) {

        navigate_up();
        return;

    }

    if (new_tab_rect().contains(x, y)) {

        open_tab(cwd());
        return;

    }

    if (view_btn_rect(.row).contains(x, y)) {

        set_view(.row);
        return;

    }

    if (view_btn_rect(.grid).contains(x, y)) {

        set_view(.grid);
        return;

    }

    var i: usize = 0;

    while (i < tab_count) : (i += 1) {

        const rect = tab_rect(i);

        if (!rect.contains(x, y)) continue;

        if (tab_count > 1 and tab_close_rect(i).contains(x, y)) {

            close_tab(i);
            return;

        }

        switch_tab(i);
        return;

    }

}

fn cancel_press() void {

    press_index = null;
    drag_active = false;
    drag_index = null;
    drop_target = .none;

}

fn track_drag(x: i32, y: i32) void {

    if (drag_active) {

        drop_target = resolve_drop(x, y);
        paint();
        return;

    }

    const index = press_index orelse return;
    const dx = x - press_x;
    const dy = y - press_y;

    if (dx * dx + dy * dy < drag_threshold * drag_threshold) return;

    drag_active = true;
    drag_index = index;
    drop_target = resolve_drop(x, y);
    last_hover = -3;
    paint();

}

fn resolve_drop(x: i32, y: i32) DropTarget {

    const source = drag_index orelse return .none;

    // Banner strip is the "move to parent" drop zone.
    if (y < banner_h) {

        if (cwd().len <= 1) return .none;

        return .parent;

    }

    const target = entry_index_at(x, y) orelse return .none;

    if (target == source) return .none;
    if (tab_const().entries[target].kind != proto.filesystem.kind_directory) return .none;

    return .{ .directory = target };

}

fn apply_drop(source_index: usize, target: DropTarget) void {

    if (source_index >= content_count()) {

        paint();
        return;

    }

    switch (target) {

        .none => paint(),

        .parent => {

            if (cwd().len <= 1) {

                paint();
                return;

            }

            const parent = path_parent(cwd());
            move_entry_into(source_index, parent);

        },

        .directory => |dir_index| {

            var dir_buf: [max_path]u8 = undefined;
            const dir_path = path_at(dir_index, &dir_buf) orelse {

                paint();
                return;

            };

            move_entry_into(source_index, dir_path);

        },

    }

}

fn move_entry_into(source_index: usize, dest_dir: []const u8) void {

    const handle = if (client) |*c| c else {

        paint();
        return;

    };

    var source_buf: [max_path]u8 = undefined;
    const source = path_at(source_index, &source_buf) orelse {

        paint();
        return;

    };

    const entry = entry_at(source_index) orelse {

        paint();
        return;

    };

    if (std.mem.eql(u8, source, dest_dir)) {

        paint();
        return;

    }

    var dest_buf: [max_path]u8 = undefined;
    const dest = lib.fs.canonicalize(dest_dir, entry.name[0..entry.name_len], &dest_buf) catch {

        paint();
        return;

    };

    if (std.mem.eql(u8, source, dest)) {

        paint();
        return;

    }

    handle.rename(source, dest) catch {

        paint();
        return;

    };

    reload();
    paint();

}

fn open_entry(index: usize) void {

    const t = tab();

    if (index >= t.entry_count) return;

    const entry = t.entries[index];

    if (entry.kind == proto.filesystem.kind_directory) {

        var buffer: [max_path]u8 = undefined;
        const target = lib.fs.canonicalize(t.path_slice(), entry.name[0..entry.name_len], &buffer) catch return;

        set_cwd(target);
        reload();
        paint();

        return;

    }

    open_file(entry, index);

}

fn open_file(entry: Entry, index: usize) void {

    var path_buffer: [max_path]u8 = undefined;
    const path = path_at(index, &path_buffer) orelse return;

    if (lib.handler.match(entry.name[0..entry.name_len])) |slot| {

        lib.wm.launch_with_path(slot.app(), path);
        return;

    }

    if (is_text_file_path(path, entry)) {

        lib.wm.launch_with_path("notepad", path);
        return;

    }

    select_index(index);
    paint();

}

fn is_image_name(name: []const u8) bool {

    return lib.handler.is_kind(name, .image);

}

fn is_text_file_path(path: []const u8, entry: Entry) bool {

    if (entry.length == 0) return true;

    const handle = if (client) |*c| c else return false;

    const file = handle.open_path(path, 0) catch return false;
    defer handle.close_file(file) catch {};

    var sample: [256]u8 = undefined;
    const read = handle.read(file, 0, &sample) catch return false;

    for (sample[0..read]) |byte| {

        if (byte != '\n' and byte != '\r' and byte != '\t' and (byte < 0x20 or byte > 0x7e)) return false;

    }

    return true;

}

fn navigate_up() void {

    var buffer: [max_path]u8 = undefined;
    const parent = lib.fs.canonicalize(cwd(), "..", &buffer) catch return;

    set_cwd(parent);
    reload();
    paint();

}

fn wheel(delta: i64) void {

    const t = tab();
    const units = visible_units();
    const total = scroll_total();

    if (delta < 0 and t.scroll + units < total) {

        t.scroll += 1;

    } else if (delta > 0 and t.scroll > 0) {

        t.scroll -= 1;

    } else {

        return;

    }

    paint();

}

fn load_preview_entry(_: Entry, index: usize) void {

    preview_len = 0;
    preview_is_text = true;

    const handle = if (client) |*c| c else return;

    var path_buffer: [max_path]u8 = undefined;
    const path = path_at(index, &path_buffer) orelse return;

    const file = handle.open_path(path, 0) catch return;
    defer handle.close_file(file) catch {};

    const read = handle.read(file, 0, preview[0..]) catch return;

    preview_len = read;

    for (preview[0..read]) |byte| {

        if (byte != '\n' and byte != '\r' and byte != '\t' and (byte < 0x20 or byte > 0x7e)) {

            preview_is_text = false;
            break;

        }

    }

}

// Layout geometry

fn list_width() i32 {

    return @divTrunc(@as(i32, @intCast(window.surface.width)) * 3, 5);

}

fn grid_columns() i32 {

    const width = list_width() - ui.scrollbar_width - grid_pad * 2;

    if (width < grid_cell_w) return 1;

    return @max(1, @divTrunc(width + grid_gap, grid_cell_w + grid_gap));

}

fn visible_units() usize {

    const height = @as(i32, @intCast(window.surface.height)) - content_top;

    return switch (view_mode) {

        .row => @intCast(@max(0, @divTrunc(height, row_height))),

        .grid => blk: {

            const inner = height - grid_pad * 2;
            const rows = @max(0, @divTrunc(inner + grid_gap, grid_cell_h + grid_gap));
            break :blk @intCast(rows);

        },

    };

}

fn scroll_total() usize {

    return switch (view_mode) {

        .row => tab_const().entry_count,

        .grid => blk: {

            const cols = @as(usize, @intCast(@max(1, grid_columns())));
            const count = tab_const().entry_count;
            break :blk (count + cols - 1) / cols;

        },

    };

}

fn list_scroll() ui.Scroll {

    return .{

        .offset = @intCast(tab_const().scroll),
        .content = @intCast(scroll_total()),
        .viewport = @intCast(visible_units()),

    };

}

fn clamp_scroll() void {

    tab().scroll = @intCast(list_scroll().clamped());

}

// Banner geometry

fn up_btn_rect() Rect {

    return .{ .x = 8, .y = @divTrunc(banner_h - chrome_btn, 2), .w = chrome_btn, .h = chrome_btn };

}

fn tabs_origin_x() i32 {

    return up_btn_rect().x + up_btn_rect().w + 8;

}

fn view_cluster_width() i32 {

    return view_btn * 2 + 4;

}

fn view_cluster_x() i32 {

    const width: i32 = @intCast(window.surface.width);

    return width - 8 - view_cluster_width();

}

fn new_tab_rect() Rect {

    const tabs_end = tabs_origin_x() + tabs_strip_width() + 4;

    return .{ .x = tabs_end, .y = @divTrunc(banner_h - chrome_btn, 2), .w = chrome_btn, .h = chrome_btn };

}

fn tabs_strip_width() i32 {

    if (tab_count == 0) return 0;

    const each = tab_slot_width();

    return each * @as(i32, @intCast(tab_count));

}

fn tab_slot_width() i32 {

    const left = tabs_origin_x();
    // Reserve + button and view cluster with a gap.
    const right = view_cluster_x() - chrome_btn - 16;
    const available = @max(tab_min_w, right - left);

    if (tab_count == 0) return tab_min_w;

    const each = @divTrunc(available, @as(i32, @intCast(tab_count)));

    return @min(tab_max_w, @max(tab_min_w, each));

}

fn tab_rect(index: usize) Rect {

    const each = tab_slot_width();
    const x = tabs_origin_x() + @as(i32, @intCast(index)) * each;

    return .{ .x = x, .y = 6, .w = each - 4, .h = banner_h - 12 };

}

fn tab_close_rect(index: usize) Rect {

    const rect = tab_rect(index);

    return .{ .x = rect.x + rect.w - tab_close_w - 4, .y = rect.y + @divTrunc(rect.h - tab_close_w, 2), .w = tab_close_w, .h = tab_close_w };

}

fn view_btn_rect(mode: ViewMode) Rect {

    const slot: i32 = switch (mode) {

        .row => 0,
        .grid => 1,

    };

    const x = view_cluster_x() + slot * (view_btn + 4);

    return .{ .x = x, .y = @divTrunc(banner_h - view_btn, 2), .w = view_btn, .h = view_btn };

}

// Rendering

fn paint_chrome_rect(surface: *const gfx.Surface, rect: Rect) void {

    if (rect.is_empty()) return;

    surface.fill_rect(rect, chrome_solid);

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill(ui.theme.window_bg);

    paint_banner(surface, width);

    if (client == null) {

        text(surface, 20, content_top + 12, 14, "Filesystem unavailable - no disk attached.", ui.theme.text_dim);
        window.present_all() catch {};

        return;

    }

    paint_content(surface, height);
    paint_side_panel(surface, width, height);

    if (drag_active) paint_drag_indicator(surface);

    if (details_open) paint_details_modal(surface);
    if (prompt_open) paint_prompt(surface);

    window.present_all() catch {};

}

fn paint_banner(surface: *const gfx.Surface, width: i32) void {

    const parent_hot = drag_active and drop_target == .parent;
    const banner = Rect{ .x = 0, .y = 0, .w = width, .h = banner_h };

    if (parent_hot) {

        surface.fill_rect(banner, ui.theme.accent_dim);

    } else {

        paint_chrome_rect(surface, banner);

    }

    surface.fill_rect(.{ .x = 0, .y = banner_h - 1, .w = width, .h = 1 }, ui.theme.border);

    // Up
    const up = up_btn_rect();
    const up_hot = pointer_y < banner_h and up.contains(pointer_x, pointer_y) and !drag_active;

    if (up_hot) ui.fill_round_rect(surface, up, 6, ui.theme.hover);

    lib.draw.vector.icon_in(surface, .{ .x = up.x + 2, .y = up.y + 2, .w = 24, .h = 24 }, lib.icons.arrow_up, ui.theme.text);

    if (drag_active and cwd().len > 1) {

        const hint: []const u8 = if (parent_hot) "Drop to move up" else "Drag here to move up";

        text_in(surface, .{ .x = tabs_origin_x(), .y = 0, .w = view_cluster_x() - tabs_origin_x() - 8, .h = banner_h }, 0, 13, hint, ui.theme.text);

    } else {

        paint_tabs(surface);
        paint_new_tab(surface);
        paint_view_switcher(surface);

    }

}

fn paint_tabs(surface: *const gfx.Surface) void {

    var i: usize = 0;

    while (i < tab_count) : (i += 1) {

        const rect = tab_rect(i);
        const active = i == active_tab;
        const hovered = !drag_active and rect.contains(pointer_x, pointer_y);
        const fill = if (active) ui.theme.active else if (hovered) ui.theme.hover else null;

        if (fill) |color| ui.fill_round_rect(surface, rect, 6, color);

        if (active) ui.stroke_round_rect(surface, rect, 6, 1, ui.theme.border);

        const label = tabs[i].basename();
        const close_space: i32 = if (tab_count > 1) tab_close_w + 6 else 4;
        const label_rect = Rect{ .x = rect.x + 8, .y = rect.y, .w = rect.w - close_space - 8, .h = rect.h };

        text_in(surface, label_rect, 0, 12, label, if (active) ui.theme.text else ui.theme.text_dim);

        if (tab_count > 1) {

            const close = tab_close_rect(i);
            const close_hot = close.contains(pointer_x, pointer_y);

            if (close_hot) ui.fill_round_rect(surface, close, 4, ui.theme.hover);

            const cx = close.x + @divTrunc(close.w, 2);
            const cy = close.y + @divTrunc(close.h, 2);
            const arm: i32 = 4;
            const color = if (close_hot) ui.theme.text else ui.theme.text_dim;
            var d: i32 = -arm;

            while (d <= arm) : (d += 1) {

                surface.fill_rect(.{ .x = cx + d, .y = cy + d, .w = 1, .h = 1 }, color);
                surface.fill_rect(.{ .x = cx + d, .y = cy - d, .w = 1, .h = 1 }, color);

            }

        }

    }

}

fn paint_new_tab(surface: *const gfx.Surface) void {

    if (tab_count >= max_tabs) return;

    const rect = new_tab_rect();
    const hot = !drag_active and rect.contains(pointer_x, pointer_y);

    if (hot) ui.fill_round_rect(surface, rect, 6, ui.theme.hover);

    const cx = rect.x + @divTrunc(rect.w, 2);
    const cy = rect.y + @divTrunc(rect.h, 2);
    const arm: i32 = 6;
    const color = if (hot) ui.theme.text else ui.theme.text_dim;

    surface.fill_rect(.{ .x = cx - arm, .y = cy, .w = arm * 2 + 1, .h = 1 }, color);
    surface.fill_rect(.{ .x = cx, .y = cy - arm, .w = 1, .h = arm * 2 + 1 }, color);

}

fn paint_view_switcher(surface: *const gfx.Surface) void {

    const modes = [_]ViewMode{ .row, .grid };

    for (modes) |mode| {

        const rect = view_btn_rect(mode);
        const active = view_mode == mode;
        const hot = !drag_active and rect.contains(pointer_x, pointer_y);

        if (active) ui.fill_round_rect(surface, rect, 6, ui.theme.active)
        else if (hot) ui.fill_round_rect(surface, rect, 6, ui.theme.hover);

        const color = if (active) ui.theme.text else ui.theme.text_dim;

        paint_view_icon(surface, rect, mode, color);

    }

}

fn paint_view_icon(surface: *const gfx.Surface, rect: Rect, mode: ViewMode, color: Color) void {

    const cx = rect.x + @divTrunc(rect.w, 2);
    const cy = rect.y + @divTrunc(rect.h, 2);

    switch (mode) {

        .row => {

            // Three horizontal lines.
            var i: i32 = 0;

            while (i < 3) : (i += 1) {

                const y = cy - 6 + i * 6;

                surface.fill_rect(.{ .x = cx - 7, .y = y, .w = 14, .h = 2 }, color);

            }

        },

        .grid => {

            lib.draw.vector.icon_in(surface, .{ .x = rect.x + 5, .y = rect.y + 5, .w = 20, .h = 20 }, lib.icons.apps, color);

        },

    }

}

fn paint_content(surface: *const gfx.Surface, height: i32) void {

    switch (view_mode) {

        .row => paint_list(surface, height),
        .grid => paint_grid(surface, height),

    }

}

fn paint_drag_indicator(surface: *const gfx.Surface) void {

    const index = drag_index orelse return;
    const entry = entry_at(index) orelse return;
    const name = entry.name[0..entry.name_len];

    const chip_h: i32 = 28;
    const icon_box: i32 = 16;
    const pad: i32 = 8;
    const gap: i32 = 6;
    const max_label_w: i32 = 140;

    const visible = ui.truncate(&font, name, 12, max_label_w);
    const label_w = font.text_width(visible, 12);
    const chip_w = pad + icon_box + gap + label_w + pad;

    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    var x = pointer_x + 14;
    var y = pointer_y + 16;

    if (x + chip_w > width) x = @max(0, width - chip_w);
    if (y + chip_h > height) y = @max(0, height - chip_h);
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    const rect = Rect{ .x = x, .y = y, .w = chip_w, .h = chip_h };

    ui.fill_round_rect(surface, rect, 6, ui.theme.surface);
    ui.stroke_round_rect(surface, rect, 6, 1, ui.theme.border);

    const is_dir = entry.kind == proto.filesystem.kind_directory;
    const icon = entry_icon(entry);
    const tint = if (is_dir) ui.theme.accent else ui.theme.text_dim;

    lib.draw.vector.icon_in(surface, .{

        .x = x + pad,
        .y = y + @divTrunc(chip_h - icon_box, 2),
        .w = icon_box,
        .h = icon_box,

    }, icon, tint);

    const text_y = y + @divTrunc(chip_h - font.line_height(12), 2);

    font.draw(surface, x + pad + icon_box + gap, text_y, 12, visible, ui.theme.text);

}

fn paint_prompt(surface: *const gfx.Surface) void {

    const rect = prompt_rect();
    var page = ui.Page{ .font = &font };

    page.begin(@intCast(surface.width), @intCast(surface.height), .{

        .width = .{ .px = @intCast(surface.width) },
        .height = .{ .px = @intCast(surface.height) },

    });

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

    _ = page.label(panel, "Rename item", .{

        .height = .{ .px = 14 },
        .size = 14,
        .color = ui.theme.text,

    });

    _ = page.field(panel, &name_field, "new name", true, .{

        .width = .{ .grow = 1 },
        .height = .{ .px = 28 },
        .size = 13,

    });

    if (prompt_status.len > 0) {

        _ = page.label(panel, prompt_status, .{

            .height = .{ .px = 12 },
            .size = 11,
            .color = ui.theme.warn,

        });

    }

    const buttons = page.box(panel, .{

        .direction = .row,
        .height = .{ .px = 32 },
        .gap = 8,

    });

    _ = page.button(buttons, 1, "Rename", .{

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

fn paint_list(surface: *const gfx.Surface, height: i32) void {

    const t = tab_const();
    const width = list_width();
    const gutter = ui.scrollbar_width;
    const content_w = width - gutter;

    surface.fill_rect(.{ .x = 0, .y = content_top, .w = width, .h = height - content_top }, ui.theme.window_bg);

    if (t.entry_count == 0) {

        text(surface, 16, content_top + 10, 13, "Empty directory", ui.theme.text_dim);
        return;

    }

    const rows = visible_units();
    var row: usize = 0;

    while (row < rows and t.scroll + row < t.entry_count) : (row += 1) {

        const index = t.scroll + row;
        const entry = t.entries[index];
        const y = content_top + @as(i32, @intCast(row)) * row_height;
        const rect = Rect{ .x = 0, .y = y, .w = content_w, .h = row_height };

        paint_row_background(surface, rect, index, width);

        const is_dir = entry.kind == proto.filesystem.kind_directory;
        const icon = entry_icon(entry);
        const tint = if (is_dir) ui.theme.accent else ui.theme.text_dim;

        lib.draw.vector.icon_in(surface, .{ .x = 10, .y = y + @divTrunc(row_height - 16, 2), .w = 16, .h = 16 }, icon, tint);

        text_in(surface, .{ .x = 34, .y = y, .w = content_w - 120, .h = row_height }, 0, 13, entry.name[0..entry.name_len], ui.theme.text);

        if (!is_dir) {

            var buffer: [24]u8 = undefined;
            const size = human_size(entry.length, &buffer);

            text_in(surface, .{ .x = content_w - 86, .y = y, .w = 80, .h = row_height }, 0, 12, size, ui.theme.text_faint);

        }

    }

    ui.scrollbar(surface, .{ .x = width - gutter, .y = content_top, .w = gutter, .h = height - content_top }, list_scroll());

}

fn paint_grid(surface: *const gfx.Surface, height: i32) void {

    const t = tab_const();
    const width = list_width();
    const gutter = ui.scrollbar_width;
    const content_w = width - gutter;

    surface.fill_rect(.{ .x = 0, .y = content_top, .w = width, .h = height - content_top }, ui.theme.window_bg);

    if (t.entry_count == 0) {

        text(surface, 16, content_top + 10, 13, "Empty directory", ui.theme.text_dim);
        return;

    }

    const cols = grid_columns();
    const vis_rows = visible_units();
    var row: usize = 0;

    while (row < vis_rows) : (row += 1) {

        const grid_row = t.scroll + row;
        var col: i32 = 0;

        while (col < cols) : (col += 1) {

            const index = grid_row * @as(usize, @intCast(cols)) + @as(usize, @intCast(col));

            if (index >= t.entry_count) break;

            const entry = t.entries[index];
            const x = grid_pad + col * (grid_cell_w + grid_gap);
            const y = content_top + grid_pad + @as(i32, @intCast(row)) * (grid_cell_h + grid_gap);
            const rect = Rect{ .x = x, .y = y, .w = grid_cell_w, .h = grid_cell_h };

            if (y + grid_cell_h > height) break;

            paint_grid_cell(surface, rect, entry, index);

        }

    }

    ui.scrollbar(surface, .{ .x = width - gutter, .y = content_top, .w = gutter, .h = height - content_top }, list_scroll());

    _ = content_w;

}

fn paint_grid_cell(surface: *const gfx.Surface, rect: Rect, entry: Entry, index: usize) void {

    const t = tab_const();
    const is_selected = t.selected != null and t.selected.? == index;
    const is_drop = switch (drop_target) {

        .directory => |dir| dir == index,
        else => false,

    };
    const hovered = !drag_active and pointer_x >= rect.x and pointer_x < rect.x + rect.w and pointer_y >= rect.y and pointer_y < rect.y + rect.h;

    if (is_drop) {

        ui.fill_round_rect(surface, rect, 8, ui.theme.accent_dim);

    } else if (is_selected) {

        ui.fill_round_rect(surface, rect, 8, if (drag_active) ui.theme.hover else ui.theme.accent_dim);

    } else if (hovered) {

        ui.fill_round_rect(surface, rect, 8, ui.theme.hover);

    }

    const preview_rect = Rect{

        .x = rect.x + @divTrunc(rect.w - grid_preview, 2),
        .y = rect.y + 8,
        .w = grid_preview,
        .h = grid_preview,

    };

    ui.fill_round_rect(surface, preview_rect, 8, ui.theme.surface_alt);

    const is_dir = entry.kind == proto.filesystem.kind_directory;
    const icon = entry_icon(entry);
    const tint = if (is_dir) ui.theme.accent else ui.theme.text_dim;
    const icon_box: i32 = 32;

    // Prefer a live PNG fit for the selected image; other tiles use type icons so paint stays cheap.
    var drew_image = false;

    if (!is_dir and is_image_name(entry.name[0..entry.name_len])) {

        const selected = tab_const().selected != null and tab_const().selected.? == index;

        if (selected and ensure_thumb(index, entry)) {

            if (thumb_image) |img| {

                const view = lib.draw.image.Image.from_buffer(img);
                view.draw_fit(surface, preview_rect.inset(4));
                drew_image = true;

            }

        }

    }

    if (!drew_image) {

        lib.draw.vector.icon_in(surface, .{

            .x = preview_rect.x + @divTrunc(preview_rect.w - icon_box, 2),
            .y = preview_rect.y + @divTrunc(preview_rect.h - icon_box, 2),
            .w = icon_box,
            .h = icon_box,

        }, icon, tint);

    }

    const name_rect = Rect{ .x = rect.x + 4, .y = rect.y + grid_preview + 12, .w = rect.w - 8, .h = 20 };

    text_centered(surface, name_rect, 11, entry.name[0..entry.name_len], ui.theme.text);

}

fn paint_row_background(surface: *const gfx.Surface, rect: Rect, index: usize, list_w: i32) void {

    const t = tab_const();
    const is_selected = t.selected != null and t.selected.? == index;
    const is_drop = switch (drop_target) {

        .directory => |dir| dir == index,
        else => false,

    };
    const hovered = !drag_active and pointer_y >= rect.y and pointer_y < rect.y + rect.h and pointer_x < list_w and pointer_x >= 0 and pointer_y >= content_top;

    if (is_drop) {

        ui.fill_round_rect(surface, rect.inset(3), 5, ui.theme.accent_dim);

    } else if (is_selected) {

        ui.fill_round_rect(surface, rect.inset(3), 5, if (drag_active) ui.theme.hover else ui.theme.accent_dim);

    } else if (hovered) {

        ui.fill_round_rect(surface, rect.inset(3), 5, ui.theme.hover);

    }

}

fn paint_side_panel(surface: *const gfx.Surface, width: i32, height: i32) void {

    const x = list_width();
    // Flush under the banner — no gap.
    const panel = Rect{ .x = x, .y = content_top, .w = width - x, .h = height - content_top };

    paint_chrome_rect(surface, panel);
    surface.fill_rect(.{ .x = x, .y = content_top, .w = 1, .h = height - content_top }, ui.theme.border);

    const pad = x + 16;
    const t = tab_const();

    const index = t.selected orelse {

        var count_buffer: [48]u8 = undefined;
        const summary = std.fmt.bufPrint(&count_buffer, "{d} items", .{t.entry_count}) catch "";

        text(surface, pad, content_top + 16, 14, "No selection", ui.theme.text_dim);
        text(surface, pad, content_top + 40, 13, summary, ui.theme.text_faint);
        text(surface, pad, content_top + 64, 12, t.path_slice(), ui.theme.text_faint);

        return;

    };

    const entry = entry_at(index) orelse return;

    text(surface, pad, content_top + 14, 15, entry.name[0..entry.name_len], ui.theme.text);

    var meta: [64]u8 = undefined;
    const size = human_size(entry.length, meta[0..24]);
    const kind_label: []const u8 = if (entry.kind == proto.filesystem.kind_directory) "directory" else "file";
    const line = std.fmt.bufPrint(meta[24..], "{s}  -  {s}", .{ kind_label, size }) catch kind_label;

    text(surface, pad, content_top + 38, 12, line, ui.theme.text_dim);

    surface.fill_rect(.{ .x = pad, .y = content_top + 58, .w = width - pad - 16, .h = 1 }, ui.theme.border);

    if (entry.kind == proto.filesystem.kind_directory) {

        text(surface, pad, content_top + 70, 12, "Folder - open to browse", ui.theme.text_faint);

        return;

    }

    // Image preview in the inspector when the selection is a PNG.
    if (is_image_name(entry.name[0..entry.name_len])) {

        const image_rect = Rect{ .x = pad, .y = content_top + 70, .w = width - pad - 16, .h = @min(160, height - content_top - 100) };

        ui.fill_round_rect(surface, image_rect, 6, ui.theme.surface_alt);

        if (ensure_thumb(index, entry)) {

            if (thumb_image) |img| {

                const view = lib.draw.image.Image.from_buffer(img);
                view.draw_fit(surface, image_rect.inset(6));

            }

        } else {

            text(surface, pad + 8, content_top + 78, 12, "Image preview unavailable", ui.theme.text_faint);

        }

        return;

    }

    if (preview_len == 0) {

        text(surface, pad, content_top + 70, 12, "(empty file)", ui.theme.text_faint);

        return;

    }

    if (!preview_is_text) {

        text(surface, pad, content_top + 70, 12, "Binary file - no preview", ui.theme.text_faint);

        return;

    }

    const preview_rect = Rect{ .x = pad, .y = content_top + 68, .w = width - pad - 16, .h = height - content_top - 78 };

    draw_preview(surface, preview_rect);

}

fn paint_menu_window() void {

    if (!menu_open) return;

    const popup = menu_window orelse return;

    paint_menu_content();
    popup.present_all() catch {};

}

fn paint_menu_content() void {

    const popup = menu_window orelse return;

    paint_menu(&popup.surface);

}

fn paint_menu(surface: *const gfx.Surface) void {

    const bounds = Rect{

        .x = menu_x,
        .y = menu_y,
        .w = menu_w,
        .h = menu_content_height() + menu_inset * 2,

    };

    surface.fill(lib.draw.transparent);
    lib.draw.round.fill_round_rect(surface, bounds, 6, ui.theme.surface);
    ui.stroke_round_rect(surface, bounds, 6, 1, ui.theme.border);

    var cursor_y = menu_y + menu_inset;

    for (menu_rows, 0..) |row, index| {

        switch (row) {

            .action => |action| {

                const rect = Rect{ .x = menu_x + menu_inset, .y = cursor_y, .w = menu_w - 2 * menu_inset, .h = menu_row_h - 1 };
                const hovered = menu_hover != null and menu_hover.? == index;
                const danger = action == .delete_item;

                if (hovered) ui.fill_round_rect(surface, rect, 4, ui.theme.hover);

                const color = if (danger) ui.theme.warn else ui.theme.text;
                const label = menu_label(action);
                const text_y = rect.y + @divTrunc(rect.h - font.line_height(13), 2);

                font.draw(surface, rect.x + menu_label_pad, text_y, 13, label, color);

                cursor_y += menu_row_h;

            },

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

fn paint_details_modal(surface: *const gfx.Surface) void {

    const rect = details_rect();

    ui.fill_round_rect(surface, rect, 8, ui.theme.surface);
    ui.stroke_round_rect(surface, rect, 8, 1, ui.theme.border);

    const pad: i32 = 18;
    const content_w = rect.w - pad * 2;

    text(surface, rect.x + pad, rect.y + 16, 15, "Item details", ui.theme.text_dim);

    const name = details_name[0..details_name_len];
    const name_visible = ui.truncate(&font, name, 16, content_w);

    text(surface, rect.x + pad, rect.y + 42, 16, name_visible, ui.theme.text);

    surface.fill_rect(.{ .x = rect.x + pad, .y = rect.y + 68, .w = content_w, .h = 1 }, ui.theme.border);

    const kind_label: []const u8 = if (details_kind == proto.filesystem.kind_directory) "Directory" else "File";
    text(surface, rect.x + pad, rect.y + 82, 13, kind_label, ui.theme.text_dim);

    var size_buf: [32]u8 = undefined;
    const size = human_size(details_length, &size_buf);
    text(surface, rect.x + pad, rect.y + 104, 13, size, ui.theme.text_dim);

    const path_visible = ui.truncate(&font, details_path[0..details_path_len], 12, content_w);
    text(surface, rect.x + pad, rect.y + 126, 12, path_visible, ui.theme.text_faint);

    const toggle = details_writable_toggle();
    const hovered_toggle = pointer_x >= toggle.x and pointer_x < toggle.x + toggle.w and pointer_y >= toggle.y and pointer_y < toggle.y + toggle.h;

    ui.fill_round_rect(surface, toggle, 6, if (hovered_toggle) ui.theme.hover else ui.theme.surface_alt);

    const toggle_label = if (details_writable) "Writable: yes" else "Writable: no";
    text_centered(surface, toggle, 12, toggle_label, ui.theme.text);

    if (details_status.len > 0) text(surface, rect.x + pad, rect.y + 178, 11, details_status, ui.theme.text_dim);

    const close = details_close_btn();
    const hovered_close = pointer_x >= close.x and pointer_x < close.x + close.w and pointer_y >= close.y and pointer_y < close.y + close.h;

    ui.fill_round_rect(surface, close, 6, if (hovered_close) ui.theme.hover else ui.theme.accent_dim);
    text_centered(surface, close, 13, "Close", ui.theme.text);

}

fn draw_preview(surface: *const gfx.Surface, rect: Rect) void {

    var y = rect.y;
    var line_start: usize = 0;
    var index: usize = 0;

    while (index <= preview_len and y + 16 <= rect.y + rect.h) : (index += 1) {

        const at_end = index == preview_len;

        if (at_end or preview[index] == '\n') {

            const line = preview[line_start..index];
            const clipped = ui.truncate(&font, line, 12, rect.w);

            font.draw(surface, rect.x, y, 12, clipped, ui.theme.text_dim);

            y += 17;
            line_start = index + 1;

            if (at_end) break;

        }

    }

}

fn entry_icon(entry: Entry) []const u8 {

    if (entry.kind == proto.filesystem.kind_directory) return lib.icons.folder;

    const name = entry.name[0..entry.name_len];

    if (lib.handler.match(name)) |slot| {

        return switch (slot.kind) {

            .image => lib.icons.image,
            .audio => lib.icons.music,
            .text => lib.icons.file,

        };

    }

    return lib.icons.file;

}

// Grid / inspector PNG thumbnail (small files only).

fn invalidate_thumb() void {

    thumb_valid = false;
    thumb_path_len = 0;
    thumb_image = null;

}

fn ensure_thumb(index: usize, entry: Entry) bool {

    if (entry.length == 0 or entry.length > thumb_file_cap) return false;

    var path_buffer: [max_path]u8 = undefined;
    const path = path_at(index, &path_buffer) orelse return false;

    if (thumb_valid and thumb_path_len == path.len and std.mem.eql(u8, thumb_path[0..thumb_path_len], path)) {

        return thumb_image != null;

    }

    thumb_valid = false;
    thumb_image = null;
    thumb_path_len = @min(path.len, thumb_path.len);
    @memcpy(thumb_path[0..thumb_path_len], path[0..thumb_path_len]);

    const handle = if (client) |*c| c else return false;

    const file = handle.open_path(path, 0) catch return false;
    defer handle.close_file(file) catch {};

    const to_read: usize = @intCast(@min(entry.length, thumb_file_cap));
    const read = handle.read(file, 0, thumb_file[0..to_read]) catch return false;

    if (read < 8) return false;

    var fba = std.heap.FixedBufferAllocator.init(thumb_decode[0..]);

    thumb_image = lib.draw.image.decode(fba.allocator(), thumb_file[0..read]) catch {

        thumb_valid = true;
        return false;

    };

    // Drop absurdly large decoded images so the fixed arena stays stable.
    if (thumb_image) |img| {

        if (img.width > 2048 or img.height > 2048) {

            thumb_image = null;
            thumb_valid = true;
            return false;

        }

    }

    thumb_valid = true;

    return thumb_image != null;

}

fn text(surface: *const gfx.Surface, x: i32, y: i32, size: u32, content: []const u8, color: gfx.Color) void {

    font.draw(surface, x, y, size, content, color);

}

fn text_in(surface: *const gfx.Surface, rect: Rect, inset: i32, size: u32, content: []const u8, color: gfx.Color) void {

    const inner = rect.inset(inset);
    const clipped = surface.clipped(inner);
    const visible = ui.truncate(&font, content, size, inner.w);
    const y = inner.y + @divTrunc(inner.h - font.line_height(size), 2);

    font.draw(&clipped, inner.x, y, size, visible, color);

}

fn text_centered(surface: *const gfx.Surface, rect: Rect, size: u32, content: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, content, size, rect.w - 8);
    const text_w = font.text_width(visible, size);
    const x = rect.x + @divTrunc(rect.w - text_w, 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

fn human_size(bytes: u64, buffer: []u8) []const u8 {

    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d} KiB", .{bytes / 1024}) catch "";

    return std.fmt.bufPrint(buffer, "{d} MiB", .{bytes / (1024 * 1024)}) catch "";

}
