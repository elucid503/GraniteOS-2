const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{
    .title = "Geode",
    .description = "Play PCM WAV audio files.",
    .icon = "music",
    .category = "Media",
};

comptime {

    _ = lib.start;

}

const max_path = lib.file_picker.max_path;
const max_file_bytes = 8 * 1024 * 1024;
const toolbar_h: i32 = 48;
const pad: i32 = 12;
const worker_stack_pages = 16;
const page_size = 4096;

const playback_idle: u32 = 0;
const playback_requested: u32 = 1;
const playback_running: u32 = 2;
const playback_failed: u32 = 3;

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var files: ?lib.fs.Client = null;
var picker: lib.file_picker.FilePicker = undefined;

var file_region: cap.Handle = 0;
var file_base: usize = 0;
var file_bytes: []u8 = &.{};
var file_length: usize = 0;

var path_storage: [max_path]u8 = undefined;
var file_path: []const u8 = "";
var wave: ?lib.wav.Wave = null;
var status: []const u8 = "Open a WAV file";
var playback_state: u32 = playback_idle;

// Playback controls shared with the worker thread. The worker publishes `playback_cursor` (bytes into the sample data) and reads `volume_gain` per chunk; the UI thread posts a frame-aligned `seek_target`.
var playback_cursor: usize = 0;
var seek_target: i64 = -1;
var volume_gain: u32 = 200;

var volume_slider: ui.Slider = .{ .value = 780 };
var seek_slider: ui.Slider = .{};

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);
    connection = try lib.desktop.connect(cap.memory);
    window = try connection.create_window(600, 360, 0, "Geode");

    file_region = try sys.create(.region, max_file_bytes, cap.memory);
    file_base = try sys.map(cap.self_space, file_region, 0, sys.read | sys.write);
    file_bytes = @as([*]u8, @ptrFromInt(file_base))[0..max_file_bytes];

    files = lib.fs.Client.connect(cap.memory) catch null;
    picker.init();
    apply_volume();
    try start_worker();

    const staged = load_staged_path();

    paint();

    if (staged) {

        load_wave(file_path);
        paint();

    } else if (files != null) {

        open_picker();
        paint();

    } else {

        status = "Filesystem unavailable";
        paint();

    }

    var shown_playback_state = @atomicLoad(u32, &playback_state, .acquire);
    var shown_cursor = @atomicLoad(usize, &playback_cursor, .acquire);

    var dirty = true; // Coalesces repaints

    while (true) {

        const event = connection.poll_event() orelse {

            const current = @atomicLoad(u32, &playback_state, .acquire);
            const cursor = @atomicLoad(usize, &playback_cursor, .acquire);

            if (current != shown_playback_state or cursor != shown_cursor) {

                shown_playback_state = current;
                shown_cursor = cursor;
                dirty = true;

            }

            if (dirty) {

                paint();
                dirty = false;

            }

            _ = sys.wait(ready) catch {};
            continue;

        };

        switch (event.kind) {

            events.kind_window_close => {

                window.destroy();
                return;

            },

            events.kind_window_resize => {

                window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                dirty = true;

            },

            events.kind_button_down => if (event.code == events.button_left and click(event.x, event.y)) {

                dirty = true;

            },

            events.kind_button_up => if (event.code == events.button_left) {

                volume_slider.release();
                seek_slider.release();

            },

            events.kind_pointer_move => {

                if (picker.open) {

                    if (picker.pointer_move(event.x, event.y, win_w(), win_h())) dirty = true;

                } else if (volume_slider.dragging) {

                    if (volume_slider.drag(volume_rect(), event.x)) {

                        apply_volume();
                        dirty = true;

                    }

                } else if (seek_slider.dragging) {

                    if (seek_slider.drag(seek_rect(), event.x)) {

                        apply_seek();
                        dirty = true;

                    }

                }

            },

            events.kind_key_down => {

                if (picker.open) {

                    _ = picker.key(event.code);

                    if (picker.take_result()) |path| load_wave(path);

                    dirty = true;

                }

            },

            events.kind_scroll => if (picker.open and picker.scroll_by(event.value, win_w(), win_h())) {

                dirty = true;

            },

            events.kind_prefs_changed => {

                lib.prefs.refresh();
                dirty = true;

            },

            else => {},

        }

    }

}

fn load_staged_path() bool {

    var buffer: [max_path]u8 = undefined;
    const path = lib.prefs.take_open_path(&buffer) orelse return false;

    set_path(path);

    return true;

}

fn set_path(path: []const u8) void {

    const length = @min(path.len, path_storage.len);

    @memcpy(path_storage[0..length], path[0..length]);
    file_path = path_storage[0..length];

}

fn open_picker() void {

    const client = if (files) |*value| value else return;
    const start = if (file_path.len == 0) "/root/user" else parent_dir(file_path);

    picker.show_open(client, &font, .wav, start);

}

fn load_wave(path: []const u8) void {

    const client = if (files) |*value| value else return;

    set_path(path);

    const file = client.open_path(file_path, 0) catch {

        status = "Cannot open file";
        wave = null;
        return;

    };
    defer client.close_file(file) catch {};

    file_length = 0;

    while (file_length < file_bytes.len) {

        const count = client.read(file, file_length, file_bytes[file_length..]) catch {

            status = "Read failed";
            wave = null;
            return;

        };

        if (count == 0) break;

        file_length += count;

    }

    wave = lib.wav.parse(file_bytes[0..file_length]) catch {

        status = "Unsupported WAV (use PCM 8/16-bit)";
        return;

    };

    @atomicStore(usize, &playback_cursor, 0, .release);
    @atomicStore(i64, &seek_target, -1, .release);
    @atomicStore(u32, &playback_state, playback_idle, .release);
    status = file_path;

}

fn request_playback() void {

    const loaded = wave orelse return;
    if (@atomicLoad(u32, &playback_state, .acquire) == playback_running) return;

    // Replay from the top once the cursor has reached the end.
    if (@atomicLoad(usize, &playback_cursor, .acquire) >= loaded.samples.len) {

        @atomicStore(usize, &playback_cursor, 0, .release);

    }

    @atomicStore(i64, &seek_target, -1, .release);
    @atomicStore(u32, &playback_state, playback_requested, .release);

}

fn play() bool {

    const loaded = wave orelse return false;
    var audio = lib.audio.Client.connect(cap.memory) catch {

        return false;

    };
    defer audio.deinit();

    audio.configure(loaded.format.sample_rate, loaded.format.channels) catch {

        return false;

    };

    var scratch: [lib.proto.audio.max_write]u8 = undefined;
    var offset = frame_align(@atomicLoad(usize, &playback_cursor, .acquire), loaded);

    while (offset < loaded.samples.len) {

        const target = @atomicLoad(i64, &seek_target, .acquire);

        if (target >= 0) {

            offset = frame_align(@intCast(target), loaded);
            @atomicStore(i64, &seek_target, -1, .release);

        }

        @atomicStore(usize, &playback_cursor, offset, .release);
        sys.notify(ready, proto.window.ring_bit) catch {};

        const chunk = lib.audio.convert(loaded, offset, &scratch, @atomicLoad(u32, &volume_gain, .acquire));

        if (chunk.consumed == 0) break;

        _ = audio.write(chunk.bytes) catch {

            return false;

        };

        offset += chunk.consumed;

    }

    @atomicStore(usize, &playback_cursor, loaded.samples.len, .release);
    sys.notify(ready, proto.window.ring_bit) catch {};
    audio.flush() catch {};

    return true;

}

fn frame_align(offset: usize, loaded: lib.wav.Wave) usize {

    const clamped = @min(offset, loaded.samples.len);

    return clamped - clamped % loaded.format.block_align;

}

fn apply_volume() void {

    volume_gain = @intCast(@divTrunc(volume_slider.value * lib.audio.gain_unity, volume_slider.span));

}

fn apply_seek() void {

    const loaded = wave orelse return;
    const byte_offset = @divTrunc(@as(i64, seek_slider.value) * @as(i64, @intCast(loaded.samples.len)), seek_slider.span);

    if (@atomicLoad(u32, &playback_state, .acquire) == playback_running) {

        @atomicStore(i64, &seek_target, byte_offset, .release);

    } else {

        @atomicStore(usize, &playback_cursor, frame_align(@intCast(byte_offset), loaded), .release);

    }

}

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    while (true) {

        if (@atomicLoad(u32, &playback_state, .acquire) != playback_requested) {

            lib.time.sleep_ms(10);
            continue;

        }

        @atomicStore(u32, &playback_state, playback_running, .release);
        sys.notify(ready, proto.window.ring_bit) catch {};

        const next: u32 = if (play()) playback_idle else playback_failed;

        @atomicStore(u32, &playback_state, next, .release);
        sys.notify(ready, proto.window.ring_bit) catch {};

    }

}

/// Handle a left click; returns true when the window needs a repaint.
fn click(x: i32, y: i32) bool {

    if (picker.open) {

        _ = picker.click(x, y, win_w(), win_h());

        if (picker.take_result()) |path| load_wave(path);

        return true;

    }

    if (wave != null) {

        if (seek_slider.press(seek_rect(), x, y)) {

            apply_seek();
            return true;

        }

        if (volume_slider.press(volume_rect(), x, y)) {

            apply_volume();
            return true;

        }

    }

    // Loading a new file would swap `wave` out from under the worker, so gate Open/Play while it runs.
    const state = @atomicLoad(u32, &playback_state, .acquire);

    if (state == playback_requested or state == playback_running) return false;

    if ((Rect{ .x = pad, .y = 10, .w = 72, .h = 28 }).contains(x, y)) {

        open_picker();
        return true;

    } else if ((Rect{ .x = 96, .y = 10, .w = 72, .h = 28 }).contains(x, y)) {

        request_playback();
        return true;

    }

    return false;

}

fn paint() void {

    const surface = &window.surface;
    const width = win_w();
    const height = win_h();

    surface.fill(ui.theme.window_bg);
    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_h }, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h - 1, .w = width, .h = 1 }, ui.theme.border);

    button(surface, .{ .x = pad, .y = 10, .w = 72, .h = 28 }, "Open");
    button(surface, .{ .x = 96, .y = 10, .w = 72, .h = 28 }, "Play");
    const current_status = switch (@atomicLoad(u32, &playback_state, .acquire)) {

        playback_requested, playback_running => "Playing...",
        playback_failed => "Playback failed",
        else => status,

    };

    font.draw(surface, 182, 15, 12, current_status, ui.theme.text_dim);

    const pane = Rect{ .x = pad, .y = toolbar_h + pad, .w = width - pad * 2, .h = height - toolbar_h - pad * 2 };

    ui.fill_round_rect(surface, pane, 8, ui.theme.surface_alt);
    ui.stroke_round_rect(surface, pane, 8, 1, ui.theme.border);

    const content_x = pane.x + 24;

    if (wave) |loaded| {

        const name = base_name(file_path);

        lib.draw.vector.icon_in(surface, .{ .x = content_x, .y = pane.y + 26, .w = 22, .h = 22 }, lib.icons.music, ui.theme.accent);

        const name_max = pane.x + pane.w - 24 - (content_x + 32);

        font.draw(surface, content_x + 32, pane.y + 29, 18, ui.truncate(&font, name, 18, name_max), ui.theme.text);

        var info: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&info, "{d} Hz   {d} channel{s}   {d}-bit PCM", .{
            loaded.format.sample_rate,
            loaded.format.channels,
            if (loaded.format.channels == 1) "" else "s",
            loaded.format.bits_per_sample,
        }) catch "";

        font.draw(surface, content_x, pane.y + 64, 13, text, ui.theme.text_dim);

        const cursor = @atomicLoad(usize, &playback_cursor, .acquire);
        const seek = seek_rect();

        seek_slider.set_fraction(@intCast(cursor), @intCast(loaded.samples.len));
        seek_slider.paint(surface, seek, ui.theme.accent, ui.theme.border, ui.theme.text);

        var cur_buf: [16]u8 = undefined;
        var dur_buf: [16]u8 = undefined;
        const played_ms = if (loaded.format.sample_rate == 0) 0 else (@as(u64, cursor / loaded.format.block_align) * 1000) / loaded.format.sample_rate;
        const labels_y = seek.y + 14;

        font.draw(surface, seek.x, labels_y, 12, time_text(&cur_buf, played_ms), ui.theme.text_dim);

        const dur = time_text(&dur_buf, loaded.duration_ms());

        font.draw(surface, seek.x + seek.w - font.text_width(dur, 12), labels_y, 12, dur, ui.theme.text_dim);

        const vol = volume_rect();

        font.draw(surface, vol.x, vol.y - 22, 12, "Volume", ui.theme.text_dim);
        volume_slider.paint(surface, vol, ui.theme.accent, ui.theme.border, ui.theme.text);

        var vol_buf: [8]u8 = undefined;
        const percent = @divTrunc(volume_slider.value * 100, volume_slider.span);
        const vol_text = std.fmt.bufPrint(&vol_buf, "{d}%", .{percent}) catch "";

        font.draw(surface, vol.x + vol.w + 14, vol.y + @divTrunc(vol.h - font.line_height(12), 2), 12, vol_text, ui.theme.text_dim);

    } else {

        const prompt = "Open a WAV file, or launch one from Files";

        lib.draw.vector.icon_in(surface, .{ .x = pane.x + @divTrunc(pane.w - 40, 2), .y = pane.y + @divTrunc(pane.h, 2) - 44, .w = 40, .h = 40 }, lib.icons.music, ui.theme.text_faint);

        font.draw(surface, pane.x + @divTrunc(pane.w - font.text_width(prompt, 14), 2), pane.y + @divTrunc(pane.h, 2) + 12, 14, prompt, ui.theme.text_dim);

    }

    if (picker.open) picker.paint(surface, width, height);

    gfx.fence();
    window.present_all() catch {};

}

fn button(surface: *gfx.Surface, rect: Rect, text: []const u8) void {

    ui.fill_round_rect(surface, rect, 6, ui.theme.surface);
    ui.stroke_round_rect(surface, rect, 6, 1, ui.theme.border);

    const width = font.text_width(text, 13);

    font.draw(surface, rect.x + @divTrunc(rect.w - width, 2), rect.y + 6, 13, text, ui.theme.text);

}

fn seek_rect() Rect {

    const x = pad + 24;

    return .{ .x = x, .y = toolbar_h + pad + 108, .w = win_w() - pad * 2 - 48, .h = 16 };

}

fn volume_rect() Rect {

    const x = pad + 24;

    return .{ .x = x, .y = toolbar_h + pad + 186, .w = @min(240, win_w() - pad * 2 - 48), .h = 16 };

}

fn time_text(buffer: []u8, ms: u64) []const u8 {

    const seconds = ms / 1000;

    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ seconds / 60, seconds % 60 }) catch "";

}

fn win_w() i32 {

    return @intCast(window.surface.width);

}

fn win_h() i32 {

    return @intCast(window.surface.height);

}

fn parent_dir(path: []const u8) []const u8 {

    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";

    return if (index == 0) "/" else path[0..index];

}

fn base_name(path: []const u8) []const u8 {

    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;

    return path[index + 1 ..];

}
