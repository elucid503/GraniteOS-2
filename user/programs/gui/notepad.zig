// Notepad: a simple text editor for files on disk.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Notepad",
    .description = "Edit text files",
    .icon = "file",
    .category = "Accessories",
};

comptime {

    _ = lib.start;

}

const max_content = 32768;
const max_path = 512;

const toolbar_height: i32 = 40;

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var client: ?lib.fs.Client = null;

var content: [max_content]u8 = undefined;
var content_len: usize = 0;
var cursor: usize = 0;
var scroll_row: usize = 0;
var dirty = false;

var path_storage: [max_path]u8 = undefined;
var file_path: []const u8 = "untitled.txt";

var keyboard = lib.keymap.Keyboard{};

var caret_tick: u32 = 0;
var caret_on = true;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(640, 480, 0, "Notepad");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;
        load_staged_path();
        load_file();

    } else |_| {}

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

            events.kind_key_down => key_down(event.code),

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_pointer_move => update_cursor(event.x, event.y),

            events.kind_prefs_changed => {

                lib.prefs.refresh();
                paint();

            },

            else => {},

        }

        caret_tick += 1;

        if (caret_tick % 30 == 0) {

            caret_on = !caret_on;
            paint();

        }

    }

}

fn load_staged_path() void {

    var buffer: [max_path]u8 = undefined;

    const path = lib.prefs.take_open_path(&buffer) orelse return;

    const length = @min(path.len, path_storage.len);

    @memcpy(path_storage[0..length], path[0..length]);
    file_path = path_storage[0..length];

}

fn load_file() void {

    content_len = 0;
    cursor = 0;
    scroll_row = 0;
    dirty = false;

    const handle = if (client) |*c| c else return;

    const file = handle.open_path(file_path, 0) catch return;
    defer handle.close_file(file) catch {};

    var offset: u64 = 0;
    var buffer: [4096]u8 = undefined;

    while (content_len < max_content) {

        const read = handle.read(file, offset, &buffer) catch break;

        if (read == 0) break;

        const amount = @min(read, max_content - content_len);

        @memcpy(content[content_len..][0..amount], buffer[0..amount]);
        content_len += amount;
        offset += read;

    }

}

fn save_file() void {

    const handle = if (client) |*c| c else return;

    _ = handle.delete(file_path) catch {};
    handle.create(file_path, proto.filesystem.kind_file) catch return;

    const file = handle.open_path(file_path, 0) catch return;
    defer handle.close_file(file) catch {};

    var offset: u64 = 0;

    while (offset < content_len) {

        const written = handle.write(file, offset, content[@intCast(offset)..content_len]) catch break;

        if (written == 0) break;

        offset += written;

    }

    dirty = false;

}

fn key_down(code: u16) void {

    if (keyboard.modifier(events.kind_key_down, code)) return;

    if (code == 29 or code == 97) {

        if (keyboard.ctrl) {

            save_file();
            paint();

        }

        return;

    }

    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len == 0) return;

    if (bytes.len == 1 and bytes[0] == '\r') return;

    if (bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[') {

        switch (bytes[2]) {

            'A' => move_up(),
            'B' => move_down(),
            'C' => move_right(),
            'D' => move_left(),
            'H' => cursor = row_start(cursor_row()),
            'F' => cursor = row_start(cursor_row() + 1),

            else => {},

        }

        clamp_scroll();
        paint();

        return;

    }

    if (bytes.len == 1) {

        switch (bytes[0]) {

            0x08, 0x7f => delete_before(),

            '\n' => insert_char('\n'),

            else => {

                if (bytes[0] >= 0x20 and bytes[0] < 0x7f) insert_char(bytes[0]);

            },

        }

        clamp_scroll();
        paint();

    }

}

fn insert_char(ch: u8) void {

    if (content_len >= max_content) return;

    var index = content_len;

    while (index > cursor) : (index -= 1) content[index] = content[index - 1];

    content[cursor] = ch;
    content_len += 1;
    cursor += 1;
    dirty = true;

}

fn delete_before() void {

    if (cursor == 0) return;

    var index = cursor - 1;

    while (index + 1 < content_len) : (index += 1) content[index] = content[index + 1];

    content_len -= 1;
    cursor -= 1;
    dirty = true;

}

fn move_left() void {

    if (cursor > 0) cursor -= 1;

}

fn move_right() void {

    if (cursor < content_len) cursor += 1;

}

fn move_up() void {

    const row = cursor_row();
    if (row == 0) return;

    const target_col = cursor_col();
    const prev_start = row_start(row - 1);
    const prev_len = row_len(row - 1);

    cursor = prev_start + @min(target_col, prev_len);

}

fn move_down() void {

    const row = cursor_row();
    const next_start = row_start(row + 1);

    if (next_start >= content_len and (content_len == 0 or content[content_len - 1] != '\n')) return;
    if (next_start > content_len) return;

    const target_col = cursor_col();
    const next_len = row_len(row + 1);

    cursor = next_start + @min(target_col, next_len);

}

fn cursor_row() usize {

    var row: usize = 0;

    for (content[0..cursor]) |ch| {

        if (ch == '\n') row += 1;

    }

    return row;

}

fn cursor_col() usize {

    const start = row_start(cursor_row());

    return cursor - start;

}

fn row_start(target: usize) usize {

    if (target == 0) return 0;

    var row: usize = 0;

    for (content[0..content_len], 0..) |ch, index| {

        if (ch == '\n') {

            row += 1;

            if (row == target) return index + 1;

        }

    }

    return content_len;

}

fn row_len(target: usize) usize {

    const start = row_start(target);
    var end = start;

    while (end < content_len and content[end] != '\n') end += 1;

    return end - start;

}

fn click(x: i32, y: i32) void {

    if (y < toolbar_height) {

        const save_x = @as(i32, @intCast(window.surface.width)) - 80;

        if (x >= save_x and x < save_x + 72) {

            save_file();
            paint();

        }

        return;

    }

    place_cursor_at(x, y);
    caret_on = true;
    clamp_scroll();
    paint();

}

fn update_cursor(x: i32, y: i32) void {

    if (y < toolbar_height) {

        const save_x = @as(i32, @intCast(window.surface.width)) - 80;

        if (x >= save_x and x < save_x + 72) lib.cursor.set(&connection, .clicker)
        else lib.cursor.set(&connection, .pointer);

        return;

    }

    lib.cursor.set(&connection, .selector);

}

fn place_cursor_at(x: i32, y: i32) void {

    const text_x = 12;
    const text_y = toolbar_height + 8;
    const line_h = 18;
    const font_size = 14;

    if (y < text_y) return;

    const row = scroll_row + @as(usize, @intCast(@max(0, @divTrunc(y - text_y, line_h))));
    const line = line_at(row);
    const col_x = x - text_x;

    if (col_x <= 0) {

        cursor = row_start(row);
        return;

    }

    cursor = row_start(row) + col_from_x(line, col_x, font_size);

}

fn line_at(row: usize) []const u8 {

    const start = row_start(row);
    var end = start;

    while (end < content_len and content[end] != '\n') end += 1;

    return content[start..end];

}

fn col_from_x(line: []const u8, x: i32, font_size: u32) usize {

    var index: usize = 0;
    var last_fit: usize = 0;

    while (index <= line.len) : (index += 1) {

        const width = font.text_width(line[0..index], font_size);

        if (width > x) return last_fit;

        last_fit = index;

    }

    return line.len;

}

fn visible_rows() usize {

    const start = toolbar_height + 8;
    const height = @as(i32, @intCast(window.surface.height)) - start;

    return @intCast(@max(1, @divTrunc(height, 18)));

}

fn clamp_scroll() void {

    const row = cursor_row();

    if (row < scroll_row) scroll_row = row;

    if (row >= scroll_row + visible_rows()) scroll_row = row - visible_rows() + 1;

}

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.window_bg);

    paint_toolbar(surface, width);

    const text_x = 12;
    const text_y = toolbar_height + 8;
    const line_h = 18;
    const font_size = 14;
    const max_w = width - text_x * 2;

    var row: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;

    while (index <= content_len and row < visible_rows()) : (index += 1) {

        const at_end = index == content_len;

        if (at_end or content[index] == '\n') {

            if (row + scroll_row == cursor_row() and caret_on) {

                const before = content[line_start..@min(cursor, index)];
                const caret_x = text_x + font.text_width(before, font_size);

                surface.fill_rect(.{ .x = caret_x, .y = text_y + @as(i32, @intCast(row)) * line_h, .w = 1, .h = line_h - 2 }, ui.theme.accent);

            }

            const line = content[line_start..index];
            const clipped = ui.truncate(&font, line, font_size, max_w);

            font.draw(surface, text_x, text_y + @as(i32, @intCast(row)) * line_h, font_size, clipped, ui.theme.text);

            row += 1;
            line_start = index + 1;

            if (at_end) break;

        }

    }

    if (content_len == 0 and caret_on) {

        surface.fill_rect(.{ .x = text_x, .y = text_y, .w = 1, .h = line_h - 2 }, ui.theme.accent);

    }

    window.present_all() catch {};

}

fn paint_toolbar(surface: *const gfx.Surface, width: i32) void {

    const bar_h = toolbar_height;

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = bar_h }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = bar_h, .w = width, .h = 1 }, ui.theme.border);

    const save_rect = Rect{ .x = width - 80, .y = 6, .w = 72, .h = 28 };
    const save_fill = if (dirty) ui.theme.accent_dim else ui.theme.active;

    ui.fill_round_rect(surface, save_rect, 5, save_fill);
    text_center(surface, save_rect, 13, "Save", ui.theme.text);

    const title = ui.truncate(&font, file_path, 13, width - 104);

    text_in(surface, .{ .x = 12, .y = 0, .w = width - 104, .h = bar_h }, 0, 13, title, ui.theme.text_dim);

}

fn text_in(surface: *const gfx.Surface, rect: Rect, inset: i32, size: u32, value: []const u8, color: gfx.Color) void {

    const inner = rect.inset(inset);
    const clipped = surface.clipped(inner);
    const visible = ui.truncate(&font, value, size, inner.w);
    const y = inner.y + @divTrunc(inner.h - font.line_height(size), 2);

    font.draw(&clipped, inner.x, y, size, visible, color);

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, value: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, value, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}
