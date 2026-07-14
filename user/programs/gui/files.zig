// File Manager: a two-pane browser over the Strata filesystem.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;
const Entry = proto.filesystem.Entry;

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
const preview_bytes = 2048;
const event_batch_max = 32;

const toolbar_height: i32 = 38;
const row_height: i32 = 32;
const list_start: i32 = toolbar_height + 6;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var client: ?lib.fs.Client = null;

var cwd_storage: [max_path]u8 = undefined;
var cwd: []const u8 = "/";

var entries: [max_entries]Entry = undefined;
var entry_count: usize = 0;

var selected: ?usize = null;
var scroll: usize = 0;

var pointer_y: i32 = -1;
var last_hover: i32 = -3;

var preview: [preview_bytes]u8 = undefined;
var preview_len: usize = 0;
var preview_is_text = false;

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

var prompt_open = false;
var prompt_source: [max_path]u8 = undefined;
var prompt_source_len: usize = 0;
var prompt_status: []const u8 = "";

var keyboard = lib.keymap.Keyboard{};
var name_storage: [max_path]u8 = undefined;
var name_field = ui.EditBuffer{ .bytes = &name_storage };

// Drag-to-move: press an entry, drag onto a folder or the toolbar (parent), release to drop.
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
    window = try connection.create_window(760, 480, 0, "Files");

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

/// Returns true when the window should close.
fn dispatch_batch(batch: []const events.Event) bool {

    var last_move: ?events.Event = null;
    var scroll_delta: i64 = 0;

    for (batch) |event| {

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

            events.kind_prefs_changed => {

                lib.prefs.refresh();
                paint();

            },

            events.kind_scroll => {

                if (!menu_open and !details_open and !prompt_open and !drag_active) scroll_delta += event.value;

            },

            events.kind_pointer_move => last_move = event,

            else => {},

        }

    }

    if (scroll_delta != 0) wheel(scroll_delta);

    if (last_move) |event| handle_pointer_move(event);

    return false;

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

        // Toolbar up is handled on press; list entries open on release so a drag can steal the gesture.
        if (index < entry_count) open_entry(index);

        return;

    }

}

fn start_directory(handle: *lib.fs.Client) []const u8 {

    // Desktop pins and other launchers can stage a path for the next Files window.
    var staged: [max_path]u8 = undefined;

    if (lib.prefs.take_open_path(&staged)) |path| {

        // Copy out of the staging buffer first - take_open_path returns a slice of `staged`.
        const length = @min(path.len, cwd_storage.len);
        @memcpy(cwd_storage[0..length], path[0..length]);
        const saved = cwd_storage[0..length];

        if (handle.stat(saved)) |stat| {

            if (stat.kind == proto.filesystem.kind_directory) return saved;

            // A staged file falls back to its parent directory.
            if (std.mem.lastIndexOfScalar(u8, saved, '/')) |slash| {

                const parent = if (slash == 0) "/" else saved[0..slash];
                const parent_len = @min(parent.len, cwd_storage.len);

                // parent may alias cwd_storage; use a tiny scratch when needed.
                if (parent.ptr == cwd_storage[0..].ptr) {

                    return cwd_storage[0..parent_len];

                }

                @memcpy(cwd_storage[0..parent_len], parent[0..parent_len]);
                return cwd_storage[0..parent_len];

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

    const length = @min(path.len, cwd_storage.len);

    @memcpy(cwd_storage[0..length], path[0..length]);
    cwd = cwd_storage[0..length];

    if (client) |*handle| handle.cwd = cwd;

}

fn reload() void {

    entry_count = 0;
    selected = null;
    scroll = 0;
    preview_len = 0;

    const handle = if (client) |*c| c else return;

    const listing = handle.list(cwd) catch return;

    for (listing) |entry| {

        if (entry_count >= max_entries) break;

        entries[entry_count] = entry;
        entry_count += 1;

    }

    sort_entries();

}

fn sort_entries() void {

    var i: usize = 1;

    while (i < entry_count) : (i += 1) {

        var j = i;

        while (j > 0 and precedes(entries[j], entries[j - 1])) : (j -= 1) {

            const swap = entries[j];
            entries[j] = entries[j - 1];
            entries[j - 1] = swap;

        }

    }

}

fn precedes(a: Entry, b: Entry) bool {

    const a_dir = a.kind == proto.filesystem.kind_directory;
    const b_dir = b.kind == proto.filesystem.kind_directory;

    if (a_dir != b_dir) return a_dir;

    return std.mem.lessThan(u8, a.name[0..a.name_len], b.name[0..b.name_len]);

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

        // Hand cursor over a valid drop; default pointer when the release would cancel.
        const valid = switch (resolve_drop(x, y)) {

            .none => false,
            else => true,

        };

        lib.cursor.set(&connection, if (valid) .clicker else .pointer);
        return;

    }

    if (y < toolbar_height and x < 40) lib.cursor.set(&connection, .clicker)
    else if (hover_token(x, y) >= 0) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}

fn hover_token(x: i32, y: i32) i32 {

    if (y < list_start or x >= list_width()) return -1;

    return @divTrunc(y - list_start, row_height);

}

fn entry_index_at(x: i32, y: i32) ?usize {

    if (y < list_start or x >= list_width()) return null;

    const row: usize = @intCast(@divTrunc(y - list_start, row_height));
    const index = scroll + row;

    if (index >= entry_count) return null;

    return index;

}

fn open_context(x: i32, y: i32) void {

    const index = entry_index_at(x, y) orelse return;

    selected = index;
    menu_target = index;
    menu_x = x;
    menu_y = y;
    menu_hover = null;
    menu_open = true;

    // Keep the menu on-screen.
    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const menu_h = menu_content_height() + menu_inset * 2;

    if (menu_x + menu_w > width) menu_x = @max(0, width - menu_w);
    if (menu_y + menu_h > height) menu_y = @max(0, height - menu_h);

    paint();

}

fn close_menu() void {

    if (!menu_open) return;

    menu_open = false;
    menu_hover = null;
    menu_target = null;
    paint();

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

fn run_menu_action(action: MenuAction, index: usize) void {

    if (index >= entry_count) return;

    const entry = entries[index];
    var path_buffer: [max_path]u8 = undefined;
    const path = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &path_buffer) catch return;

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

                // Wake the desktop layer so pins appear without a reboot.
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

    // Mirrors paint_prompt's layout: 16px padding, then the fixed-height title label, an 8px gap, then this
    // field - deterministic regardless of whether the status label below it is shown.
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

    // If the item left this directory, drop selection; otherwise keep browsing.
    reload();

    selected = null;

    for (entries[0..entry_count], 0..) |entry, index| {

        var path_buffer: [max_path]u8 = undefined;
        const path = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &path_buffer) catch continue;

        if (std.mem.eql(u8, path, dest)) {

            selected = index;
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

    return cwd;

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

        // Click outside the modal dismisses it.
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

    if (y < toolbar_height) {

        if (x < 40) navigate_up();

        return;

    }

    const index = entry_index_at(x, y) orelse return;

    press_index = index;
    press_x = x;
    press_y = y;
    selected = index;

    const entry = entries[index];

    if (entry.kind != proto.filesystem.kind_directory) load_preview(entry);

    paint();

}

fn cancel_press() void {

    press_index = null;
    drag_active = false;
    drag_index = null;
    drop_target = .none;

}

fn track_drag(x: i32, y: i32) void {

    if (drag_active) {

        // Repaint every move so the ghost chip stays glued to the cursor.
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

    // Toolbar (top strip) is the "move to parent" drop zone.
    if (y < toolbar_height) {

        if (cwd.len <= 1) return .none;

        return .parent;

    }

    const target = entry_index_at(x, y) orelse return .none;

    if (target == source) return .none;
    if (entries[target].kind != proto.filesystem.kind_directory) return .none;

    return .{ .directory = target };

}

fn apply_drop(source_index: usize, target: DropTarget) void {

    if (source_index >= entry_count) {

        paint();
        return;

    }

    switch (target) {

        .none => paint(),

        .parent => {

            if (cwd.len <= 1) {

                paint();
                return;

            }

            const parent = path_parent(cwd);
            move_entry_into(source_index, parent);

        },

        .directory => |dir_index| {

            if (dir_index >= entry_count) {

                paint();
                return;

            }

            const dir = entries[dir_index];
            var dir_buf: [max_path]u8 = undefined;
            const dir_path = lib.fs.canonicalize(cwd, dir.name[0..dir.name_len], &dir_buf) catch {

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

    if (source_index >= entry_count) {

        paint();
        return;

    }

    const entry = entries[source_index];
    var source_buf: [max_path]u8 = undefined;
    const source = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &source_buf) catch {

        paint();
        return;

    };

    // Refuse dropping a directory onto itself.
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

    const entry = entries[index];

    if (entry.kind == proto.filesystem.kind_directory) {

        var buffer: [max_path]u8 = undefined;
        const target = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &buffer) catch return;

        set_cwd(target);
        reload();
        paint();

        return;

    }

    var path_buffer: [max_path]u8 = undefined;
    const path = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &path_buffer) catch return;

    if (is_image_name(entry.name[0..entry.name_len])) {

        lib.wm.launch_with_path("viewer", path);
        return;

    }

    if (lib.file_picker.has_extension(entry.name[0..entry.name_len], "wav")) {

        lib.wm.launch_with_path("audio-gui", path);
        return;

    }

    if (is_text_file(entry)) {

        lib.wm.launch_with_path("notepad", path);
        return;

    }

    selected = index;
    load_preview(entry);
    paint();

}

fn is_image_name(name: []const u8) bool {

    return lib.file_picker.has_extension(name, "png");

}

fn is_text_file(entry: Entry) bool {

    if (entry.length == 0) return true;

    const handle = if (client) |*c| c else return false;

    var path_buffer: [max_path]u8 = undefined;
    const path = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &path_buffer) catch return false;

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
    const parent = lib.fs.canonicalize(cwd, "..", &buffer) catch return;

    set_cwd(parent);
    reload();
    paint();

}

fn wheel(delta: i64) void {

    const rows = visible_rows();

    if (delta < 0 and scroll + rows < entry_count) {

        scroll += 1;

    } else if (delta > 0 and scroll > 0) {

        scroll -= 1;

    } else {

        return;

    }

    paint();

}

fn load_preview(entry: Entry) void {

    preview_len = 0;
    preview_is_text = true;

    const handle = if (client) |*c| c else return;

    var path_buffer: [max_path]u8 = undefined;
    const path = lib.fs.canonicalize(cwd, entry.name[0..entry.name_len], &path_buffer) catch return;

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

// Rendering

fn list_width() i32 {

    return @divTrunc(@as(i32, @intCast(window.surface.width)) * 3, 5);

}

fn visible_rows() usize {

    const height = @as(i32, @intCast(window.surface.height)) - list_start;

    return @intCast(@max(0, @divTrunc(height, row_height)));

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill(ui.theme.window_bg);

    paint_toolbar(surface, width);

    if (client == null) {

        text(surface, 20, list_start + 12, 14, "Filesystem unavailable - no disk attached.", ui.theme.text_dim);
        window.present_all() catch {};

        return;

    }

    paint_list(surface, height);
    paint_side_panel(surface, width, height);

    if (drag_active) paint_drag_indicator(surface);

    if (menu_open) paint_menu(surface);
    if (details_open) paint_details_modal(surface);
    if (prompt_open) paint_prompt(surface);

    window.present_all() catch {};

}

fn paint_drag_indicator(surface: *const gfx.Surface) void {

    const index = drag_index orelse return;

    if (index >= entry_count) return;

    const entry = entries[index];
    const name = entry.name[0..entry.name_len];

    const chip_h: i32 = 28;
    const icon_box: i32 = 16;
    const pad: i32 = 8;
    const gap: i32 = 6;
    const max_label_w: i32 = 140;

    const visible = ui.truncate(&font, name, 12, max_label_w);
    const label_w = font.text_width(visible, 12);
    const chip_w = pad + icon_box + gap + label_w + pad;

    // Sit just below-right of the pointer so the hot tip stays free for hit-testing.
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
    const icon = if (is_dir) lib.icons.folder else lib.icons.file;
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

fn paint_toolbar(surface: *const gfx.Surface, width: i32) void {

    const parent_hot = drag_active and drop_target == .parent;

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_height }, if (parent_hot) ui.theme.accent_dim else ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = toolbar_height, .w = width, .h = 1 }, ui.theme.border);

    lib.draw.vector.icon_in(surface, .{ .x = 8, .y = 7, .w = 24, .h = 24 }, lib.icons.arrow_up, ui.theme.text);

    if (drag_active and cwd.len > 1) {

        // While dragging, the whole top strip is the parent drop target.
        const hint: []const u8 = if (parent_hot) "Drop to move up" else "Drag here to move up";

        text_in(surface, .{ .x = 44, .y = 0, .w = width - 52, .h = toolbar_height }, 0, 13, hint, ui.theme.text);

    } else {

        text_in(surface, .{ .x = 44, .y = 0, .w = width - 52, .h = toolbar_height }, 0, 13, cwd, ui.theme.text);

    }

}

fn list_scroll() ui.Scroll {

    return .{

        .offset = @intCast(scroll),
        .content = @intCast(entry_count),
        .viewport = @intCast(visible_rows()),

    };

}

fn clamp_scroll() void {

    scroll = @intCast(list_scroll().clamped());

}

fn paint_list(surface: *const gfx.Surface, height: i32) void {

    const width = list_width();

    // A gutter on the right holds the scrollbar so long directory listings read as overflowing, not truncated.
    const gutter = ui.scrollbar_width;
    const content_w = width - gutter;

    surface.fill_rect(.{ .x = 0, .y = list_start, .w = width, .h = height - list_start }, ui.theme.window_bg);

    if (entry_count == 0) {

        text(surface, 16, list_start + 10, 13, "Empty directory", ui.theme.text_dim);

        return;

    }

    const rows = visible_rows();
    var row: usize = 0;

    while (row < rows and scroll + row < entry_count) : (row += 1) {

        const index = scroll + row;
        const entry = entries[index];
        const y = list_start + @as(i32, @intCast(row)) * row_height;
        const rect = Rect{ .x = 0, .y = y, .w = content_w, .h = row_height };

        const is_selected = selected != null and selected.? == index;
        const is_drop = switch (drop_target) {

            .directory => |dir| dir == index,
            else => false,

        };
        const hovered = !drag_active and pointer_y >= y and pointer_y < y + row_height and pointer_x < width;

        if (is_drop) {

            ui.fill_round_rect(surface, rect.inset(3), 5, ui.theme.accent_dim);

        } else if (is_selected) {

            ui.fill_round_rect(surface, rect.inset(3), 5, if (drag_active) ui.theme.hover else ui.theme.accent_dim);

        } else if (hovered) {

            ui.fill_round_rect(surface, rect.inset(3), 5, ui.theme.hover);

        }

        const is_dir = entry.kind == proto.filesystem.kind_directory;
        const icon = if (is_dir) lib.icons.folder else lib.icons.file;
        const tint = if (is_dir) ui.theme.accent else ui.theme.text_dim;

        lib.draw.vector.icon_in(surface, .{ .x = 10, .y = y + @divTrunc(row_height - 16, 2), .w = 16, .h = 16 }, icon, tint);

        text_in(surface, .{ .x = 34, .y = y, .w = content_w - 120, .h = row_height }, 0, 13, entry.name[0..entry.name_len], ui.theme.text);

        if (!is_dir) {

            var buffer: [24]u8 = undefined;
            const size = human_size(entry.length, &buffer);

            text_in(surface, .{ .x = content_w - 86, .y = y, .w = 80, .h = row_height }, 0, 12, size, ui.theme.text_faint);

        }

    }

    ui.scrollbar(surface, .{ .x = width - gutter, .y = list_start, .w = gutter, .h = height - list_start }, list_scroll());

}

fn paint_side_panel(surface: *const gfx.Surface, width: i32, height: i32) void {

    const x = list_width();

    surface.fill_rect(.{ .x = x, .y = list_start, .w = width - x, .h = height - list_start }, ui.theme.surface);
    surface.fill_rect(.{ .x = x, .y = list_start, .w = 1, .h = height - list_start }, ui.theme.border);

    const pad = x + 16;

    const index = selected orelse {

        var count_buffer: [48]u8 = undefined;
        const summary = std.fmt.bufPrint(&count_buffer, "{d} items", .{entry_count}) catch "";

        text(surface, pad, list_start + 16, 14, "No selection", ui.theme.text_dim);
        text(surface, pad, list_start + 40, 13, summary, ui.theme.text_faint);

        return;

    };

    const entry = entries[index];

    text(surface, pad, list_start + 14, 15, entry.name[0..entry.name_len], ui.theme.text);

    var meta: [64]u8 = undefined;
    const size = human_size(entry.length, meta[0..24]);
    const kind_label: []const u8 = if (entry.kind == proto.filesystem.kind_directory) "directory" else "file";
    const line = std.fmt.bufPrint(meta[24..], "{s}  -  {s}", .{ kind_label, size }) catch kind_label;

    text(surface, pad, list_start + 38, 12, line, ui.theme.text_dim);

    surface.fill_rect(.{ .x = pad, .y = list_start + 58, .w = width - pad - 16, .h = 1 }, ui.theme.border);

    if (entry.kind == proto.filesystem.kind_directory) {

        text(surface, pad, list_start + 70, 12, "Folder - open to browse", ui.theme.text_faint);

        return;

    }

    if (preview_len == 0) {

        text(surface, pad, list_start + 70, 12, "(empty file)", ui.theme.text_faint);

        return;

    }

    if (!preview_is_text) {

        text(surface, pad, list_start + 70, 12, "Binary file - no preview", ui.theme.text_faint);

        return;

    }

    const preview_rect = Rect{ .x = pad, .y = list_start + 68, .w = width - pad - 16, .h = height - list_start - 78 };

    draw_preview(surface, preview_rect);

}

fn paint_menu(surface: *const gfx.Surface) void {

    const bounds = Rect{

        .x = menu_x,
        .y = menu_y,
        .w = menu_w,
        .h = menu_content_height() + menu_inset * 2,

    };

    ui.fill_round_rect(surface, bounds, 6, ui.theme.surface);
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

                // Draw without truncate-to-fit clipping so labels are never cut mid-word.
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

// The TTF face has no wrapped helper, so lay the preview out line by line, clipping to the pane.

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
