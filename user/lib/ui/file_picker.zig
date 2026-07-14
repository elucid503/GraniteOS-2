// Modal file selector for GUI apps: open or save against the Strata filesystem.
// Hosts paint the dialog over their window and feed pointer/key events until take_result() yields a path.

const std = @import("std");

const draw = @import("../draw/draw.zig");
const text_mod = @import("../draw/text.zig");
const events = @import("../gfx/events.zig");
const fs = @import("../fs/fs.zig");
const keymap = @import("../keymap.zig");
const proto = @import("../ipc/proto.zig");

const ui = @import("ui.zig");

const Face = text_mod.Face;
const Rect = draw.Rect;
const Surface = draw.Surface;
const Entry = proto.filesystem.Entry;

pub const Mode = enum {

    open,
    save,

};

pub const Filter = enum {

    all,
    png,
    wav,

};

pub const max_path = 512;
pub const max_entries = 128;
pub const max_name = 96;

const dialog_w: i32 = 440;
const dialog_h: i32 = 360;
const title_h: i32 = 40;
const toolbar_h: i32 = 36;
const row_h: i32 = 30;
const footer_h: i32 = 56;
const pad: i32 = 14;
const btn_w: i32 = 90;
const btn_h: i32 = 30;
const radius: i32 = 8;
const chip_radius: i32 = 6;

pub const FilePicker = struct {

    open: bool = false,
    mode: Mode = .open,
    filter: Filter = .all,

    client: ?*fs.Client = null,
    font: ?*const Face = null,

    path_storage: [max_path]u8 = undefined,
    path_len: usize = 1,

    name_storage: [max_name]u8 = undefined,
    name_field: ui.EditBuffer = undefined,

    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    selected: ?usize = null,
    scroll: usize = 0,

    status: []const u8 = "",
    hover: i32 = -1,

    result_storage: [max_path]u8 = undefined,
    result_len: usize = 0,
    has_result: bool = false,

    keyboard: keymap.Keyboard = .{},

    pub fn init(self: *FilePicker) void {

        self.name_field = .{ .bytes = &self.name_storage };
        self.path_storage[0] = '/';
        self.path_len = 1;
        self.open = false;
        self.has_result = false;
        self.entry_count = 0;
        self.selected = null;
        self.scroll = 0;
        self.status = "";

    }

    pub fn cwd(self: *const FilePicker) []const u8 {

        return self.path_storage[0..self.path_len];

    }

    pub fn show_open(self: *FilePicker, client: *fs.Client, font: *const Face, filter: Filter, start_dir: []const u8) void {

        self.prepare(client, font, .open, filter, start_dir, "");

    }

    pub fn show_save(self: *FilePicker, client: *fs.Client, font: *const Face, filter: Filter, start_dir: []const u8, default_name: []const u8) void {

        self.prepare(client, font, .save, filter, start_dir, default_name);

    }

    fn prepare(self: *FilePicker, client: *fs.Client, font: *const Face, mode: Mode, filter: Filter, start_dir: []const u8, default_name: []const u8) void {

        self.client = client;
        self.font = font;
        self.mode = mode;
        self.filter = filter;
        self.has_result = false;
        self.result_len = 0;
        self.selected = null;
        self.scroll = 0;
        self.status = "";
        self.hover = -1;
        self.open = true;

        self.set_path(if (start_dir.len == 0) "/" else start_dir);
        self.set_name(default_name);
        self.reload();

    }

    pub fn close(self: *FilePicker) void {

        self.open = false;
        self.status = "";

    }

    /// Consume a confirmed path once; returns null when idle or cancelled.
    pub fn take_result(self: *FilePicker) ?[]const u8 {

        if (!self.has_result) return null;

        self.has_result = false;
        self.open = false;

        return self.result_storage[0..self.result_len];

    }

    pub fn paint(self: *FilePicker, surface: *const Surface, window_w: i32, window_h: i32) void {

        if (!self.open) return;

        const font = self.font orelse return;
        const frame = dialog_frame(window_w, window_h);

        surface.fill_rect_alpha(surface.bounds(), draw.rgb(0, 0, 0), 120);
        ui.fill_round_rect(surface, frame, radius, ui.theme.surface);
        ui.stroke_round_rect(surface, frame, radius, 1, ui.theme.border);

        const title = switch (self.mode) {

            .open => "Open File",
            .save => "Save File",

        };

        font.draw(surface, frame.x + pad, frame.y + 12, 14, title, ui.theme.text);

        // Path bar.
        const path_rect = Rect{

            .x = frame.x + pad,
            .y = frame.y + title_h,
            .w = frame.w - pad * 2 - 76,
            .h = toolbar_h - 6,

        };

        ui.fill_round_rect(surface, path_rect, chip_radius, ui.theme.window_bg);
        ui.stroke_round_rect(surface, path_rect, chip_radius, 1, ui.theme.border);
        font.draw(surface, path_rect.x + 10, path_rect.y + 7, 12, self.cwd(), ui.theme.text_dim);

        const up_rect = Rect{ .x = frame.x + frame.w - pad - 68, .y = path_rect.y, .w = 68, .h = path_rect.h };

        paint_button(surface, font, up_rect, "Up", self.hover == 1);

        // Entry list.
        const list = list_rect(frame);

        ui.fill_round_rect(surface, list, chip_radius, ui.theme.window_bg);
        ui.stroke_round_rect(surface, list, chip_radius, 1, ui.theme.border);

        const visible = visible_rows(list);
        var index = self.scroll;
        var row: usize = 0;

        while (row < visible and index < self.entry_count) : ({
            row += 1;
            index += 1;
        }) {

            const entry = self.entries[index];
            const y = list.y + 4 + @as(i32, @intCast(row)) * row_h;
            const row_rect = Rect{ .x = list.x + 4, .y = y, .w = list.w - 8, .h = row_h - 2 };
            const is_sel = self.selected == index;
            const is_hover = self.hover == @as(i32, @intCast(100 + index));

            if (is_sel) ui.fill_round_rect(surface, row_rect, 4, ui.theme.active)
            else if (is_hover) ui.fill_round_rect(surface, row_rect, 4, ui.theme.hover);

            const label_color = if (entry.kind == proto.filesystem.kind_directory) ui.theme.accent else ui.theme.text;
            const name = entry.name[0..entry.name_len];
            const prefix: []const u8 = if (entry.kind == proto.filesystem.kind_directory) "/" else "";

            var label_buf: [max_name + 2]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ prefix, name }) catch name;

            font.draw(surface, row_rect.x + 10, row_rect.y + 7, 12, label, label_color);

        }

        // Save name field / status.
        const footer_y = frame.y + frame.h - footer_h;

        if (self.mode == .save) {

            const field = save_field_rect(frame, footer_y);

            ui.paint_field_chrome(surface, field, true);
            ui.paint_field_content(surface, font, save_field_inner(field), &self.name_field, "filename.png", true, 12);

        }

        if (self.status.len != 0) {

            const status_y: i32 = footer_y + if (self.mode == .save) btn_h + 4 else @as(i32, 4);

            font.draw(surface, frame.x + pad, status_y, 11, self.status, ui.theme.warn);

        }

        const btn_y: i32 = footer_y + if (self.mode == .save) @as(i32, 0) else @as(i32, 10);
        const cancel = Rect{ .x = frame.x + frame.w - pad - btn_w * 2 - 10, .y = btn_y, .w = btn_w, .h = btn_h };
        const ok = Rect{ .x = frame.x + frame.w - pad - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };
        const ok_label: []const u8 = switch (self.mode) {

            .open => "Open",
            .save => "Save",

        };

        paint_button(surface, font, cancel, "Cancel", self.hover == 2);
        paint_button(surface, font, ok, ok_label, self.hover == 3);

    }

    pub fn pointer_move(self: *FilePicker, x: i32, y: i32, window_w: i32, window_h: i32) bool {

        if (!self.open) return false;

        const next = self.hit(x, y, window_w, window_h);

        if (next == self.hover) return false;

        self.hover = next;

        return true;

    }

    pub fn click(self: *FilePicker, x: i32, y: i32, window_w: i32, window_h: i32) bool {

        if (!self.open) return false;

        const frame = dialog_frame(window_w, window_h);

        if (!frame.contains(x, y)) {

            self.close();
            return true;

        }

        const id = self.hit(x, y, window_w, window_h);

        if (id == 1) {

            self.navigate_up();
            return true;

        }

        if (id == 2) {

            self.close();
            return true;

        }

        if (id == 3) {

            self.confirm();
            return true;

        }

        if (id == 4) {

            const footer_y = frame.y + frame.h - footer_h;
            const field = save_field_rect(frame, footer_y);
            const inner = save_field_inner(field);
            const index = ui.field_click_index(self.font orelse return true, self.name_field.slice(), 12, self.name_field.cursor, inner.w, x - inner.x);

            _ = self.name_field.set_cursor(index, self.keyboard.shift);

            return true;

        }

        if (id >= 100) {

            const index: usize = @intCast(id - 100);

            if (index >= self.entry_count) return true;

            const entry = self.entries[index];

            if (entry.kind == proto.filesystem.kind_directory) {

                self.enter(entry.name[0..entry.name_len]);
                return true;

            }

            if (self.selected == index) {

                self.confirm_entry(entry);
                return true;

            }

            self.selected = index;
            self.set_name(entry.name[0..entry.name_len]);
            self.status = "";

            return true;

        }

        return true;

    }

    pub fn scroll_by(self: *FilePicker, delta: i64, window_w: i32, window_h: i32) bool {

        if (!self.open) return false;

        _ = window_w;
        _ = window_h;

        if (delta == 0) return false;

        const max_scroll = if (self.entry_count > 8) self.entry_count - 8 else 0;

        if (delta < 0) {

            if (self.scroll > 0) self.scroll -= 1;

        } else if (self.scroll < max_scroll) {

            self.scroll += 1;

        }

        return true;

    }

    pub fn key(self: *FilePicker, code: u16) bool {

        if (!self.open) return false;

        if (self.mode != .save) {

            if (code == 1) self.close(); // Esc-ish: left to host mapping if present
            return true;

        }

        if (self.keyboard.modifier(events.kind_key_down, code)) return false;

        var buffer: [3]u8 = undefined;
        const bytes = self.keyboard.bytes(code, &buffer);

        if (bytes.len == 1 and bytes[0] == '\r') {

            self.confirm();
            return true;

        }

        return self.name_field.feed(bytes, self.keyboard.shift);

    }

    /// Release-side counterpart to `key`: keeps Shift/Ctrl/Caps from sticking once a save-name field has seen them.
    pub fn key_up(self: *FilePicker, code: u16) void {

        _ = self.keyboard.modifier(events.kind_key_up, code);

    }

    fn confirm(self: *FilePicker) void {

        if (self.mode == .open) {

            if (self.selected) |index| {

                if (index < self.entry_count) {

                    self.confirm_entry(self.entries[index]);
                    return;

                }

            }

            self.status = "Select a file";
            return;

        }

        const name = self.name_field.slice();

        if (name.len == 0) {

            self.status = "Enter a file name";
            return;

        }

        if (std.mem.indexOfScalar(u8, name, '/') != null) {

            self.status = "Name cannot contain /";
            return;

        }

        var path_buf: [max_path]u8 = undefined;
        const full = fs.canonicalize(self.cwd(), name, &path_buf) catch {

            self.status = "Invalid path";
            return;

        };

        self.finish(full);

    }

    fn confirm_entry(self: *FilePicker, entry: Entry) void {

        if (entry.kind == proto.filesystem.kind_directory) {

            self.enter(entry.name[0..entry.name_len]);
            return;

        }

        var path_buf: [max_path]u8 = undefined;
        const full = fs.canonicalize(self.cwd(), entry.name[0..entry.name_len], &path_buf) catch {

            self.status = "Invalid path";
            return;

        };

        self.finish(full);

    }

    fn finish(self: *FilePicker, path: []const u8) void {

        const length = @min(path.len, self.result_storage.len);

        @memcpy(self.result_storage[0..length], path[0..length]);
        self.result_len = length;
        self.has_result = true;
        self.open = false;
        self.status = "";

    }

    fn enter(self: *FilePicker, name: []const u8) void {

        var path_buf: [max_path]u8 = undefined;
        const next = fs.canonicalize(self.cwd(), name, &path_buf) catch {

            self.status = "Cannot open folder";
            return;

        };

        self.set_path(next);
        self.selected = null;
        self.scroll = 0;
        self.status = "";
        self.reload();

    }

    fn navigate_up(self: *FilePicker) void {

        var path_buf: [max_path]u8 = undefined;
        const parent = fs.canonicalize(self.cwd(), "..", &path_buf) catch return;

        self.set_path(parent);
        self.selected = null;
        self.scroll = 0;
        self.reload();

    }

    fn reload(self: *FilePicker) void {

        self.entry_count = 0;

        const client = self.client orelse return;
        const listed = client.list(self.cwd()) catch {

            self.status = "Cannot list directory";
            return;

        };

        for (listed) |entry| {

            if (self.entry_count >= max_entries) break;

            if (entry.kind == proto.filesystem.kind_directory) {

                self.entries[self.entry_count] = entry;
                self.entry_count += 1;
                continue;

            }

            if (self.passes_filter(entry.name[0..entry.name_len])) {

                self.entries[self.entry_count] = entry;
                self.entry_count += 1;

            }

        }

        sort_entries(self.entries[0..self.entry_count]);

    }

    fn passes_filter(self: *const FilePicker, name: []const u8) bool {

        return switch (self.filter) {

            .all => true,
            .png => has_extension(name, "png"),
            .wav => has_extension(name, "wav"),

        };

    }

    fn set_path(self: *FilePicker, path: []const u8) void {

        const length = @min(path.len, self.path_storage.len);

        @memcpy(self.path_storage[0..length], path[0..length]);
        self.path_len = length;

    }

    fn set_name(self: *FilePicker, name: []const u8) void {

        self.name_field.clear();

        for (name) |byte| {

            if (byte < 0x20 or byte >= 0x7f) continue;
            if (!self.name_field.insert(byte)) break;

        }

    }

    fn hit(self: *const FilePicker, x: i32, y: i32, window_w: i32, window_h: i32) i32 {

        const frame = dialog_frame(window_w, window_h);

        if (!frame.contains(x, y)) return -1;

        const path_rect = Rect{

            .x = frame.x + pad,
            .y = frame.y + title_h,
            .w = frame.w - pad * 2 - 72,
            .h = toolbar_h - 6,

        };
        const up_rect = Rect{ .x = frame.x + frame.w - pad - 64, .y = path_rect.y, .w = 64, .h = path_rect.h };

        if (up_rect.contains(x, y)) return 1;

        const list = list_rect(frame);

        if (list.contains(x, y)) {

            const row = @divTrunc(y - list.y - 2, row_h);

            if (row >= 0) {

                const index = self.scroll + @as(usize, @intCast(row));

                if (index < self.entry_count) return @intCast(100 + index);

            }

            return 0;

        }

        const footer_y = frame.y + frame.h - footer_h;

        if (self.mode == .save and save_field_rect(frame, footer_y).contains(x, y)) return 4;

        const btn_y: i32 = footer_y + if (self.mode == .save) @as(i32, 0) else @as(i32, 8);
        const cancel = Rect{ .x = frame.x + frame.w - pad - btn_w * 2 - 8, .y = btn_y, .w = btn_w, .h = btn_h };
        const ok = Rect{ .x = frame.x + frame.w - pad - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };

        if (cancel.contains(x, y)) return 2;
        if (ok.contains(x, y)) return 3;

        return 0;

    }

};

fn save_field_rect(frame: Rect, footer_y: i32) Rect {

    return .{ .x = frame.x + pad, .y = footer_y, .w = frame.w - pad * 2 - btn_w * 2 - 16, .h = btn_h };

}

const save_field_pad: i32 = 10;

fn save_field_inner(field: Rect) Rect {

    return .{ .x = field.x + save_field_pad, .y = field.y, .w = field.w - 2 * save_field_pad, .h = field.h };

}

fn dialog_frame(window_w: i32, window_h: i32) Rect {

    return .{

        .x = @divTrunc(window_w - dialog_w, 2),
        .y = @divTrunc(window_h - dialog_h, 2),
        .w = dialog_w,
        .h = dialog_h,

    };

}

fn list_rect(frame: Rect) Rect {

    return .{

        .x = frame.x + pad,
        .y = frame.y + title_h + toolbar_h,
        .w = frame.w - pad * 2,
        .h = frame.h - title_h - toolbar_h - footer_h - 4,

    };

}

fn visible_rows(list: Rect) usize {

    if (list.h <= 4) return 0;

    return @intCast(@divTrunc(list.h - 4, row_h));

}

fn paint_button(surface: *const Surface, font: *const Face, rect: Rect, label: []const u8, hover: bool) void {

    ui.fill_round_rect(surface, rect, chip_radius, if (hover) ui.theme.hover else ui.theme.surface_alt);
    ui.stroke_round_rect(surface, rect, chip_radius, 1, ui.theme.border);

    const text_w = font.text_width(label, 12);
    const tx = rect.x + @divTrunc(rect.w - text_w, 2);
    const ty = rect.y + @divTrunc(rect.h - font.line_height(12), 2);

    font.draw(surface, tx, ty, 12, label, ui.theme.text);

}

pub fn has_extension(name: []const u8, ext: []const u8) bool {

    if (name.len <= ext.len + 1) return false;
    if (name[name.len - ext.len - 1] != '.') return false;

    const tail = name[name.len - ext.len ..];

    if (tail.len != ext.len) return false;

    for (tail, ext) |a, b| {

        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;

        if (la != lb) return false;

    }

    return true;

}

fn sort_entries(entries: []Entry) void {

    var i: usize = 0;

    while (i + 1 < entries.len) : (i += 1) {

        var j = i + 1;

        while (j < entries.len) : (j += 1) {

            if (entry_less(entries[j], entries[i])) {

                const tmp = entries[i];
                entries[i] = entries[j];
                entries[j] = tmp;

            }

        }

    }

}

fn entry_less(a: Entry, b: Entry) bool {

    const a_dir = a.kind == proto.filesystem.kind_directory;
    const b_dir = b.kind == proto.filesystem.kind_directory;

    if (a_dir != b_dir) return a_dir;

    const an = a.name[0..a.name_len];
    const bn = b.name[0..b.name_len];

    return std.mem.order(u8, an, bn) == .lt;

}
