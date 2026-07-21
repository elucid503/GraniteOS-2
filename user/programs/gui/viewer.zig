// Image Viewer: display PNG files. Opens a staged path from Files or the shared file picker.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Images",
    .description = "View PNG images.",
    .icon = "image",
    .category = "Graphics",
};

comptime {

    _ = lib.start;

}

const toolbar_h: i32 = 48;
const pad: i32 = 12;
const radius: i32 = 8;
const max_path = lib.file_picker.max_path;
const max_file_bytes = 6 * 1024 * 1024;

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var client: ?lib.fs.Client = null;
var picker: lib.file_picker.FilePicker = undefined;

var path_storage: [max_path]u8 = undefined;
var file_path: []const u8 = "";

// File bytes and decoded pixels share this heap; file storage is freed after decode.
var decode_heap: lib.mem.Heap = .{ .authority = 0 };

var image: ?lib.draw.image.Buffer = null;
var status: []const u8 = "Open an image";
var hover: i32 = -1;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(720, 480, 0, "Images");
    _ = lib.draw.round.masks_for(radius);
    _ = lib.draw.round.masks_for(6);

    decode_heap = lib.mem.Heap.init(cap.memory);

    if (lib.fs.Client.connect(cap.memory)) |opened| {

        client = opened;

    } else |_| {}

    picker.init();

    const staged = load_staged_path();

    // Paint the window (toolbar, pane, status) before any blocking filesystem call. A large PNG's read can
    // take a while on this OS's block driver; without this, the window shows nothing but its raw, unpainted
    // backing store (visually solid black) for the entire read instead of the toolbar and a status line.
    if (staged) status = "Loading...";

    paint();

    if (staged) {

        load_image(file_path);
        paint();

    } else if (client != null) {

        open_picker();
        paint();

    } else {

        status = "Filesystem unavailable";
        paint();

    }

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

            events.kind_button_down => {

                if (event.code == events.button_left) click(event.x, event.y);

            },

            events.kind_pointer_move => {

                if (picker.open) {

                    if (picker.pointer_move(event.x, event.y, win_w(), win_h())) paint();

                } else {

                    const next: i32 = if (toolbar_hit(event.x, event.y) != null) 1 else -1;

                    if (next != hover) {

                        hover = next;
                        paint();

                    }

                    update_cursor(event.x, event.y);

                }

            },

            events.kind_key_down => {

                if (picker.open) {

                    _ = picker.key(event.code);

                    if (picker.take_result()) |path| {

                        load_image(path);
                        paint();

                    } else if (!picker.open) {

                        paint();

                    } else paint();

                } else key_down(event.code);

            },

            events.kind_key_up => picker.key_up(event.code),

            events.kind_scroll => {

                if (picker.open and picker.scroll_by(event.value, win_w(), win_h())) paint();

            },

            events.kind_prefs_changed => {

                _ = lib.prefs.apply_event(event);
                paint();

            },

            else => {},

        }

    }

}

fn load_staged_path() bool {

    var buffer: [max_path]u8 = undefined;
    const path = lib.prefs.take_open_path(&buffer) orelse return false;
    const length = @min(path.len, path_storage.len);

    @memcpy(path_storage[0..length], path[0..length]);
    file_path = path_storage[0..length];

    return true;

}

fn open_picker() void {

    const handle = if (client) |*c| c else {

        status = "Filesystem unavailable";
        return;

    };

    const start = if (file_path.len != 0) parent_dir(file_path) else "/root/user";

    picker.show_open(handle, &font, .image, start);

}

fn click(x: i32, y: i32) void {

    if (picker.open) {

        _ = picker.click(x, y, win_w(), win_h());

        if (picker.take_result()) |path| load_image(path);

        paint();
        return;

    }

    if (toolbar_hit(x, y)) |action| {

        switch (action) {

            .open => {

                open_picker();
                paint();

            },

        }

    }

}

const Action = enum { open };

fn toolbar_hit(x: i32, y: i32) ?Action {

    if (y < 0 or y >= toolbar_h) return null;

    const rect = Rect{ .x = pad, .y = 10, .w = 72, .h = 28 };

    if (rect.contains(x, y)) return .open;

    return null;

}

fn key_down(code: u16) void {

    var keyboard = lib.keymap.Keyboard{};
    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len == 1 and (bytes[0] == 'o' or bytes[0] == 'O')) {

        open_picker();
        paint();

    }

}

fn clear_image() void {

    if (image) |*img| {

        img.deinit(decode_heap.allocator());
        image = null;

    }

}

fn load_image(path: []const u8) void {

    const handle = if (client) |*c| c else {

        status = "Filesystem unavailable";
        return;

    };

    const length = @min(path.len, path_storage.len);

    @memcpy(path_storage[0..length], path[0..length]);
    file_path = path_storage[0..length];

    const file_info = handle.stat(file_path) catch {

        status = "Cannot open file";
        clear_image();
        return;

    };

    if (file_info.length == 0) {

        status = "Empty file";
        clear_image();
        return;

    }

    if (file_info.length > max_file_bytes) {

        status = "Image file is too large";
        clear_image();
        return;

    }

    const file_len: usize = @intCast(file_info.length);
    const file_bytes = decode_heap.alloc(file_len) catch {

        status = "Out of memory for image buffers";
        clear_image();
        return;

    };
    defer decode_heap.free(file_bytes);

    const file = handle.open_path(file_path, 0) catch {

        status = "Cannot open file";
        clear_image();
        return;

    };
    defer handle.close_file(file) catch {};

    var offset: u64 = 0;
    var chunks: usize = 0;

    while (offset < file_len) {

        const read = handle.read(file, offset, file_bytes[@intCast(offset)..]) catch {

            status = "Read failed";
            clear_image();
            return;

        };

        if (read == 0) break;

        offset += read;
        chunks += 1;

        if ((chunks & 15) == 0) sys.yield();

    }

    if (offset == 0) {

        status = "Empty file";
        clear_image();
        return;

    }

    const payload = file_bytes[0..@intCast(offset)];

    if (lib.draw.image.detect(payload) == null) {

        status = "Not a supported image";
        clear_image();
        return;

    }

    clear_image();

    image = lib.draw.image.decode(decode_heap.allocator(), payload) catch |err| {

        status = switch (err) {

            error.OutOfMemory => "Image too large to decode",
            error.Truncated => "Image file is incomplete",
            error.Unsupported => "Unsupported image encoding",
            else => "Not a supported image",

        };
        image = null;
        return;

    };

    if (image) |img| {

        if (img.width == 0 or img.height == 0 or img.pixels.len == 0) {

            status = "Empty image";
            clear_image();
            return;

        }

    }

    status = file_path;

}

fn paint() void {

    const surface = &window.surface;
    const width = win_w();
    const height = win_h();

    surface.fill(ui.theme.window_bg);

    // Toolbar.
    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_h }, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h - 1, .w = width, .h = 1 }, ui.theme.border);

    const open_rect = Rect{ .x = pad, .y = 10, .w = 72, .h = 28 };
    const hot = hover == 1;

    ui.fill_round_rect(surface, open_rect, 6, if (hot) ui.theme.hover else ui.theme.surface_alt);
    ui.stroke_round_rect(surface, open_rect, 6, 1, ui.theme.border);

    const label = "Open";
    const tw = font.text_width(label, 13);

    font.draw(surface, open_rect.x + @divTrunc(open_rect.w - tw, 2), open_rect.y + 6, 13, label, ui.theme.text);
    font.draw(surface, open_rect.x + open_rect.w + 14, 15, 12, status, ui.theme.text_dim);

    // Image pane.
    const pane = Rect{ .x = pad, .y = toolbar_h + pad, .w = width - pad * 2, .h = height - toolbar_h - pad * 2 };

    ui.fill_round_rect(surface, pane, radius, ui.theme.surface_alt);
    ui.stroke_round_rect(surface, pane, radius, 1, ui.theme.border);

    if (image) |img| {

        const view = lib.draw.image.Image.from_buffer(img);
        const inner = pane.inset(8);

        view.draw_fit(surface, inner);

        var info: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&info, "{d} x {d}", .{ img.width, img.height }) catch "";

        font.draw(surface, pane.x + 12, pane.y + pane.h - 22, 11, text, ui.theme.text_faint);

    } else if (!picker.open) {

        const hint = "Open a PNG, or launch from Files";
        const hw = font.text_width(hint, 13);

        font.draw(surface, pane.x + @divTrunc(pane.w - hw, 2), pane.y + @divTrunc(pane.h, 2), 13, hint, ui.theme.text_faint);

    }

    if (picker.open) picker.paint(surface, width, height);

    gfx.fence();
    window.present_all() catch {};

}

fn win_w() i32 {

    return @intCast(window.surface.width);

}

fn win_h() i32 {

    return @intCast(window.surface.height);

}

fn parent_dir(path: []const u8) []const u8 {

    if (path.len <= 1) return "/";

    var index = path.len;

    while (index > 0) {

        index -= 1;

        if (path[index] == '/') {

            if (index == 0) return "/";

            return path[0..index];

        }

    }

    return "/";

}

fn update_cursor(x: i32, y: i32) void {

    if (toolbar_hit(x, y) != null) lib.cursor.set(&connection, .clicker)
    else lib.cursor.set(&connection, .pointer);

}
