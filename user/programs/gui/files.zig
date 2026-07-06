// File Manager: a two-pane browser over the Strata filesystem. The left pane lists the working directory (folders
// first, with sizes); clicking a folder descends into it and the toolbar's up button climbs back out. The right
// pane shows details for the selected entry and a short text preview for files. It is a plain Filesystem client -
// the same interface the shell's fs utilities speak - so it reflects exactly what is on disk.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;
const Entry = proto.filesystem.Entry;

pub const app_meta = .{
    .title = "Files",
    .description = "Browse the filesystem",
    .icon = "folder",
};

comptime {

    _ = lib.start;

}

const max_entries = 256;
const max_path = 512;
const preview_bytes = 2048;

const toolbar_height: i32 = 38;
const row_height: i32 = 26;
const list_start: i32 = toolbar_height + 6;

var font: lib.ttf.Face = undefined;

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

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(760, 480, 0, "Files");

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;
        set_cwd(start_directory());
        reload();

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
                clamp_scroll();
                paint();

            },

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_scroll => wheel(event.value),

            events.kind_pointer_move => {

                pointer_y = event.y;

                const token = hover_token(event.x, event.y);

                if (token != last_hover) {

                    last_hover = token;
                    paint();

                }

            },

            else => {},

        }

    }

}

fn start_directory() []const u8 {

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

fn hover_token(x: i32, y: i32) i32 {

    if (y < list_start or x >= list_width()) return -1;

    return @divTrunc(y - list_start, row_height);

}

fn click(x: i32, y: i32) void {

    if (y < toolbar_height) {

        if (x < 40) navigate_up();

        return;

    }

    const list_w = list_width();

    if (x >= list_w) return;

    if (y < list_start) return;

    const row: usize = @intCast(@divTrunc(y - list_start, row_height));
    const index = scroll + row;

    if (index >= entry_count) return;

    open_entry(index);

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

    selected = index;
    load_preview(entry);
    paint();

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

        ui.text(surface, &font, 20, list_start + 12, 14, "Filesystem unavailable - no disk attached.", ui.theme.text_dim);
        window.present_all() catch {};

        return;

    }

    paint_list(surface, height);
    paint_details(surface, width, height);

    window.present_all() catch {};

}

fn paint_toolbar(surface: *const gfx.Surface, width: i32) void {

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_height }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = toolbar_height, .w = width, .h = 1 }, ui.theme.border);

    ui.icon(surface, .{ .x = 8, .y = 7, .w = 24, .h = 24 }, lib.icons.arrow_up, ui.theme.text);

    ui.text_in(surface, &font, .{ .x = 44, .y = 0, .w = width - 52, .h = toolbar_height }, 0, 13, cwd, ui.theme.text);

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

        ui.text(surface, &font, 16, list_start + 10, 13, "Empty directory", ui.theme.text_dim);

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
        const hovered = pointer_y >= y and pointer_y < y + row_height;

        if (is_selected) {

            surface.fill_rect(rect, ui.theme.accent_dim);

        } else if (hovered) {

            surface.fill_rect(rect, ui.theme.hover);

        }

        const is_dir = entry.kind == proto.filesystem.kind_directory;
        const icon = if (is_dir) lib.icons.folder else lib.icons.file;
        const tint = if (is_dir) ui.theme.accent else ui.theme.text_dim;

        ui.icon(surface, .{ .x = 10, .y = y + 5, .w = 16, .h = 16 }, icon, tint);

        ui.text_in(surface, &font, .{ .x = 34, .y = y, .w = content_w - 120, .h = row_height }, 0, 13, entry.name[0..entry.name_len], ui.theme.text);

        if (!is_dir) {

            var buffer: [24]u8 = undefined;
            const size = human_size(entry.length, &buffer);

            ui.text_in(surface, &font, .{ .x = content_w - 86, .y = y, .w = 80, .h = row_height }, 0, 12, size, ui.theme.text_faint);

        }

    }

    ui.scrollbar(surface, .{ .x = width - gutter, .y = list_start, .w = gutter, .h = height - list_start }, list_scroll());

}

fn paint_details(surface: *const gfx.Surface, width: i32, height: i32) void {

    const x = list_width();

    surface.fill_rect(.{ .x = x, .y = list_start, .w = width - x, .h = height - list_start }, ui.theme.surface);
    surface.fill_rect(.{ .x = x, .y = list_start, .w = 1, .h = height - list_start }, ui.theme.border);

    const pad = x + 16;

    const index = selected orelse {

        var count_buffer: [48]u8 = undefined;
        const summary = std.fmt.bufPrint(&count_buffer, "{d} items", .{entry_count}) catch "";

        ui.text(surface, &font, pad, list_start + 16, 14, "No selection", ui.theme.text_dim);
        ui.text(surface, &font, pad, list_start + 40, 13, summary, ui.theme.text_faint);

        return;

    };

    const entry = entries[index];

    ui.text(surface, &font, pad, list_start + 14, 15, entry.name[0..entry.name_len], ui.theme.text);

    var meta: [64]u8 = undefined;
    const size = human_size(entry.length, meta[0..24]);
    const line = std.fmt.bufPrint(meta[24..], "file  -  {s}", .{size}) catch "file";

    ui.text(surface, &font, pad, list_start + 38, 12, line, ui.theme.text_dim);

    surface.fill_rect(.{ .x = pad, .y = list_start + 58, .w = width - pad - 16, .h = 1 }, ui.theme.border);

    if (preview_len == 0) {

        ui.text(surface, &font, pad, list_start + 70, 12, "(empty file)", ui.theme.text_faint);

        return;

    }

    if (!preview_is_text) {

        ui.text(surface, &font, pad, list_start + 70, 12, "Binary file - no preview", ui.theme.text_faint);

        return;

    }

    const preview_rect = Rect{ .x = pad, .y = list_start + 68, .w = width - pad - 16, .h = height - list_start - 78 };

    draw_preview(surface, preview_rect);

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

fn human_size(bytes: u64, buffer: []u8) []const u8 {

    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d} KiB", .{bytes / 1024}) catch "";

    return std.fmt.bufPrint(buffer, "{d} MiB", .{bytes / (1024 * 1024)}) catch "";

}
