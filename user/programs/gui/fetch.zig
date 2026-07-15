// Fetch: a GUI front end for the TCP/HTTP stack

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const app_meta = .{

    .title = "Fetch",
    .description = "Fetch a web address",
    .category = "Internet",
    .icon = "network",

};

comptime {

    _ = lib.start;

}

const toolbar_height: i32 = 40;
const summary_height: i32 = 26;
const field_h: i32 = 28;
const field_y: i32 = 6;
const margin: i32 = 12;

const url_storage_size = 512;
const host_storage_size = 128;
const path_storage_size = 384;
const port_storage_size = 8;

const port_toggle_w: i32 = 50;
const port_field_w: i32 = 60;
const go_button_w: i32 = 56;
const label_w: i32 = 32;

const response_capacity = 262_144;
const recv_chunk = 4096;

const State = enum(u8) {

    idle,
    running,
    done,
    failed,

};

const Focus = enum {

    url,
    port,

};

var font: lib.draw.text.Face = undefined;
var mono: lib.draw.text.Face = undefined;

const mono_px: u32 = 13;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var url_storage: [url_storage_size]u8 = undefined;
var port_storage: [port_storage_size]u8 = undefined;

var url_buffer: ui.EditBuffer = undefined;
var port_buffer: ui.EditBuffer = undefined;

// Port field hidden until toggled; most URLs need no explicit port.
var port_enabled = false;

var focused: Focus = .url;
var keyboard = lib.keymap.Keyboard{};

var scroll_row: usize = 0;
var dragging_scrollbar = false;
var dragging_field = false;

// Shared between the worker thread and the paint loop.

var lock: ipc.Lock = .{};

var state: State = .idle;
var response: [response_capacity]u8 = undefined;
var response_len: usize = 0;
var error_message: [96]u8 = undefined;
var error_len: usize = 0;
var elapsed_ms: u64 = 0;

var request_port: u16 = 0;
var request_path: [path_storage_size]u8 = undefined;
var request_path_len: usize = 0;
var request_host: [host_storage_size]u8 = undefined;
var request_host_len: usize = 0;

var ready: cap.Handle = 0;
var tick: u32 = 0;
var running: u32 = 1;
var request_pending: u32 = 0;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);
    mono = try lib.desktop.console_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window = try connection.create_window(760, 560, 0, "Fetch");

    url_buffer = ui.EditBuffer.init(&url_storage);
    port_buffer = ui.EditBuffer.init(&port_storage);

    set_field(&url_buffer, "http://example.com/");

    paint();

    try start_worker();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    window.destroy();
                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    dirty = true;

                },

                events.kind_key_down => {

                    if (key_down(event.code)) dirty = true;

                },

                events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

                events.kind_button_down => {

                    if (event.code == events.button_left) {

                        if (mouse_down(event.x, event.y)) dirty = true;

                    }

                },

                events.kind_button_up => {

                    if (event.code == events.button_left) {

                        dragging_scrollbar = false;
                        dragging_field = false;

                    }

                },

                events.kind_pointer_move => {

                    if (dragging_scrollbar) {

                        if (drag_scrollbar(event.y)) dirty = true;

                    } else if (dragging_field) {

                        if (field_drag_to(event.x)) dirty = true;

                    }

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => {

                    if (wheel(event.value)) dirty = true;

                },

                events.kind_prefs_changed => {

                    lib.prefs.refresh();
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) dirty = true;

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn set_field(buffer: *ui.EditBuffer, text: []const u8) void {

    const length = @min(text.len, buffer.bytes.len);

    @memcpy(buffer.bytes[0..length], text[0..length]);
    buffer.len = length;
    buffer.cursor = length;

}

// --- input handling ---

fn key_down(code: u16) bool {

    if (keyboard.modifier(events.kind_key_down, code)) return false;

    var scratch: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &scratch);

    if (bytes.len == 0) return false;

    if (bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n')) {

        start_fetch();
        return true;

    }

    const target: *ui.EditBuffer = switch (focused) {

        .url => &url_buffer,
        .port => &port_buffer,

    };

    return target.feed(bytes, keyboard.shift);

}

/// Map a click to a byte index in buffer; extend selection when extend is true.
fn position_field(buffer: *ui.EditBuffer, rect: Rect, x: i32, extend: bool) bool {

    const inner_w = rect.w - 2 * ui.field_pad;
    const rel_x = x - rect.x - ui.field_pad;
    const index = ui.field_click_index(&font, buffer.slice(), 13, buffer.cursor, inner_w, rel_x);

    return buffer.set_cursor(index, extend);

}

/// Continue click-drag from mouse_down, extending the focused field selection.
fn field_drag_to(x: i32) bool {

    return switch (focused) {

        .url => position_field(&url_buffer, url_field_rect(), x, true),
        .port => position_field(&port_buffer, port_field_rect(), x, true),

    };

}

fn mouse_down(x: i32, y: i32) bool {

    const track = scrollbar_rect();

    if (track.contains(x, y) and scroll_model().overflowing()) {

        dragging_scrollbar = true;

        return drag_scrollbar(y);

    }

    if (url_field_rect().contains(x, y)) {

        focused = .url;
        _ = position_field(&url_buffer, url_field_rect(), x, keyboard.shift);
        dragging_field = true;

        return true;

    }

    if (port_toggle_rect().contains(x, y)) {

        port_enabled = !port_enabled;

        if (port_enabled and port_buffer.len == 0) set_field(&port_buffer, "80");
        if (!port_enabled and focused == .port) focused = .url;

        return true;

    }

    if (port_enabled and port_field_rect().contains(x, y)) {

        focused = .port;
        _ = position_field(&port_buffer, port_field_rect(), x, keyboard.shift);
        dragging_field = true;

        return true;

    }

    if (go_button_rect().contains(x, y)) {

        start_fetch();
        return true;

    }

    return false;

}

fn update_cursor(x: i32, y: i32) void {

    if (y < toolbar_height and (url_field_rect().contains(x, y) or (port_enabled and port_field_rect().contains(x, y)))) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (y < toolbar_height and (go_button_rect().contains(x, y) or port_toggle_rect().contains(x, y))) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    lib.cursor.set(&connection, .pointer);

}

fn wheel(delta: i64) bool {

    const before = scroll_row;

    scroll_row = @intCast(scroll_model().wheel(delta, 3));

    return scroll_row != before;

}

fn drag_scrollbar(y: i32) bool {

    const track = scrollbar_rect();
    const before = scroll_row;

    scroll_row = @intCast(scroll_model().offset_at(track.h, y - track.y));

    return scroll_row != before;

}

// --- fetch request lifecycle ---

/// Prepend http:// when missing so bare hosts parse; lib.url.parse still requires a scheme.
fn with_scheme(raw: []const u8, scratch: []u8) ?[]const u8 {

    if (std.mem.indexOf(u8, raw, "://") != null) return raw;

    return std.fmt.bufPrint(scratch, "http://{s}", .{raw}) catch null;

}

fn start_fetch() void {

    const raw = url_buffer.slice();

    if (raw.len == 0) {

        fail("enter a url");
        return;

    }

    var scratch: [url_storage_size + 8]u8 = undefined;
    const text = with_scheme(raw, &scratch) orelse {

        fail("url too long");
        return;

    };

    if (std.mem.startsWith(u8, text, "https://")) {

        fail("https is not supported (http only)");
        return;

    }

    const parsed = lib.url.parse(text) orelse {

        fail("invalid url");
        return;

    };

    var port = parsed.port;

    if (port_enabled) {

        port = std.fmt.parseInt(u16, port_buffer.slice(), 10) catch {

            fail("invalid port");
            return;

        };

    }

    lock.acquire();

    request_port = port;

    request_path_len = @min(parsed.path.len, request_path.len);
    @memcpy(request_path[0..request_path_len], parsed.path[0..request_path_len]);

    request_host_len = @min(parsed.host.len, request_host.len);
    @memcpy(request_host[0..request_host_len], parsed.host[0..request_host_len]);

    state = .running;
    response_len = 0;
    error_len = 0;
    scroll_row = 0;

    lock.release();

    @atomicStore(u32, &request_pending, 1, .release);

    // Paint the in-flight state before the (potentially slow) fetch runs, so the window never looks frozen.
    paint();

}

fn fail(text: []const u8) void {

    lock.acquire();

    state = .failed;
    error_len = @min(text.len, error_message.len);
    @memcpy(error_message[0..error_len], text[0..error_len]);

    lock.release();

    notify_ui();

}

fn notify_ui() void {

    @atomicStore(u32, &tick, 1, .release);
    sys.notify(ready, lib.proto.window.ring_bit) catch {};

}

// --- worker thread ---

const worker_stack_pages = 16;
const page_size = 4096;

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        lib.time.sleep_ms(20);

        if (@atomicLoad(u32, &running, .acquire) == 0) break;
        if (@atomicRmw(u32, &request_pending, .Xchg, 0, .acquire) == 0) continue;

        do_fetch();

    }

    lib.start.exit();

}

fn do_fetch() void {

    lock.acquire();

    const port = request_port;

    var path_local: [path_storage_size]u8 = undefined;
    const path_len = request_path_len;

    @memcpy(path_local[0..path_len], request_path[0..path_len]);

    var host_local: [host_storage_size]u8 = undefined;
    const host_len = request_host_len;

    @memcpy(host_local[0..host_len], request_host[0..host_len]);

    lock.release();

    const start_ms = lib.time.now_ms();

    var socket = lib.net.Socket.connect_host(cap.memory, host_local[0..host_len], port) catch |failure| {

        fail(@errorName(failure));
        return;

    };

    defer socket.close();

    // Include port in Host header when non-default for name-based virtual hosts.
    var host_header_buffer: [host_storage_size + 8]u8 = undefined;
    const host_header = if (port == 80)
        host_local[0..host_len]
    else
        std.fmt.bufPrint(&host_header_buffer, "{s}:{d}", .{ host_local[0..host_len], port }) catch host_local[0..host_len];

    var request_buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{

        path_local[0..path_len],
        host_header,

    }) catch {

        fail("request too long");
        return;

    };

    socket.send_all(request) catch |failure| {

        fail(@errorName(failure));
        return;

    };

    var chunk: [recv_chunk]u8 = undefined;

    while (true) {

        const length = socket.recv(&chunk) catch |failure| {

            lock.acquire();
            const have_data = response_len > 0;
            lock.release();

            if (!have_data) {

                fail(@errorName(failure));
                return;

            }

            break;

        };

        if (length == 0) break;

        lock.acquire();

        const room = response.len - response_len;
        const take = @min(length, room);

        @memcpy(response[response_len..][0..take], chunk[0..take]);
        response_len += take;

        const overflowed = take < length;

        lock.release();

        notify_ui();

        if (overflowed) break;

    }

    lock.acquire();

    state = .done;
    elapsed_ms = lib.time.now_ms() - start_ms;

    lock.release();

    notify_ui();

}

// --- layout ---

fn go_button_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = width - margin - go_button_w, .y = field_y, .w = go_button_w, .h = field_h };

}

fn port_toggle_rect() Rect {

    const go = go_button_rect();

    return .{ .x = go.x - margin - port_toggle_w, .y = field_y, .w = port_toggle_w, .h = field_h };

}

fn port_field_rect() Rect {

    const toggle = port_toggle_rect();

    return .{ .x = toggle.x - margin - port_field_w, .y = field_y, .w = port_field_w, .h = field_h };

}

fn url_field_rect() Rect {

    const start = margin + label_w;
    const end = if (port_enabled) port_field_rect().x - margin else port_toggle_rect().x - margin;

    return .{ .x = start, .y = field_y, .w = @max(80, end - start), .h = field_h };

}

fn summary_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = 0, .y = toolbar_height, .w = width, .h = summary_height };

}

fn textarea_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const top = toolbar_height + summary_height + 8;

    return .{ .x = margin, .y = top, .w = width - margin * 2, .h = @max(0, height - top - margin) };

}

fn scrollbar_rect() Rect {

    const area = textarea_rect();

    return .{ .x = area.x + area.w - ui.scrollbar_width - 2, .y = area.y + 2, .w = ui.scrollbar_width, .h = @max(0, area.h - 4) };

}

fn text_columns() usize {

    const area = textarea_rect();
    const usable = area.w - 12 - ui.scrollbar_width - 4;

    return @intCast(@max(1, @divTrunc(usable, mono.mono_width(mono_px))));

}

fn visible_rows() usize {

    const area = textarea_rect();
    const usable = area.h - 12;

    return @intCast(@max(1, @divTrunc(usable, mono.mono_height(mono_px))));

}

fn total_rows(text: []const u8) usize {

    var rows: usize = 1;

    for (text) |byte| {

        if (byte == '\n') rows += 1;

    }

    return rows;

}

fn scroll_model() ui.Scroll {

    lock.acquire();
    const text = response[0..response_len];
    lock.release();

    return .{

        .offset = @intCast(scroll_row),
        .content = @intCast(total_rows(text)),
        .viewport = @intCast(visible_rows()),

    };

}

// --- rendering ---

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(ui.theme.window_bg);

    paint_toolbar(surface, width);

    lock.acquire();
    defer lock.release();

    paint_summary(surface);
    paint_textarea(surface);

    window.present_all() catch {};

}

fn paint_toolbar(surface: *const gfx.Surface, width: i32) void {

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_height }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = toolbar_height, .w = width, .h = 1 }, ui.theme.border);

    paint_field(surface, "URL", &url_buffer, url_field_rect(), focused == .url);

    const toggle = port_toggle_rect();

    ui.fill_round_rect(surface, toggle, 5, if (port_enabled) ui.theme.accent_dim else ui.theme.surface);
    ui.stroke_round_rect(surface, toggle, 5, 1, if (port_enabled) ui.theme.accent else ui.theme.border);
    text_center(surface, toggle, 12, "Port", if (port_enabled) ui.theme.text else ui.theme.text_dim);

    if (port_enabled) paint_field(surface, "", &port_buffer, port_field_rect(), focused == .port);

    const go = go_button_rect();

    ui.fill_round_rect(surface, go, 5, ui.theme.accent_dim);
    text_center(surface, go, 13, "Go", ui.theme.text);

}

fn paint_field(surface: *const gfx.Surface, label: []const u8, buffer: *const ui.EditBuffer, rect: Rect, active: bool) void {

    const label_rect = Rect{ .x = rect.x - label_w, .y = rect.y, .w = label_w - 4, .h = rect.h };

    text_in(surface, label_rect, 0, 11, label, ui.theme.text_faint);

    ui.paint_text_field(surface, &font, rect, buffer, "", active, active, 13);

}

fn paint_summary(surface: *const gfx.Surface) void {

    const area = summary_rect();
    const y = area.y + @divTrunc(area.h - font.line_height(12), 2);

    switch (state) {

        .idle => font.draw(surface, area.x + margin, y, 12, "Enter a URL, then press Go (or Enter). Use Port for a non-default port.", ui.theme.text_faint),

        .running => font.draw(surface, area.x + margin, y, 12, "Fetching...", ui.theme.text_dim),

        .failed => {

            var line: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "Error: {s}", .{error_message[0..error_len]}) catch "Error";

            font.draw(surface, area.x + margin, y, 12, text, ui.theme.warn);

        },

        .done => {

            const text = response[0..response_len];
            const code = status_code(text);
            const color = if (code >= 200 and code < 400) ui.theme.good else ui.theme.warn;

            var line: [96]u8 = undefined;
            const summary = if (code != 0)
                std.fmt.bufPrint(&line, "HTTP {d}   {d} bytes   {d} ms", .{ code, response_len, elapsed_ms }) catch ""
            else
                std.fmt.bufPrint(&line, "{d} bytes   {d} ms", .{ response_len, elapsed_ms }) catch "";

            font.draw(surface, area.x + margin, y, 12, summary, color);

        },

    }

}

fn status_code(text: []const u8) u16 {

    var index: usize = 0;

    while (index < text.len and text[index] != ' ') : (index += 1) {}

    if (index >= text.len) return 0;

    index += 1;

    var end = index;

    while (end < text.len and text[end] >= '0' and text[end] <= '9') : (end += 1) {}

    if (end - index != 3) return 0;

    return std.fmt.parseInt(u16, text[index..end], 10) catch 0;

}

fn paint_textarea(surface: *const gfx.Surface) void {

    const area = textarea_rect();

    ui.fill_round_rect(surface, area, 6, ui.theme.surface);
    ui.stroke_round_rect(surface, area, 6, 1, ui.theme.border);

    const text = response[0..response_len];
    const inner = area.inset(6);
    const clipped = surface.clipped(inner);

    if (text.len == 0) {

        mono.draw_mono(&clipped, inner.x, inner.y, mono_px, "Response will appear here.", ui.theme.text_faint);

    } else {

        paint_response_lines(&clipped, inner, text);

    }

    ui.scrollbar(surface, scrollbar_rect(), .{

        .offset = @intCast(scroll_row),
        .content = @intCast(total_rows(text)),
        .viewport = @intCast(visible_rows()),

    });

}

fn paint_response_lines(surface: *const gfx.Surface, inner: Rect, text: []const u8) void {

    const columns = text_columns();
    const line_h = mono.mono_height(mono_px);
    const shown_rows = visible_rows();

    var row: usize = 0;
    var shown: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;

    while (index <= text.len and shown < shown_rows) : (index += 1) {

        const at_end = index == text.len;

        if (at_end or text[index] == '\n') {

            if (row >= scroll_row) {

                var line = text[line_start..index];

                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

                const clipped_line = line[0..@min(line.len, columns)];
                const color = if (row == 0) status_line_color(text) else ui.theme.text;

                mono.draw_mono(surface, inner.x, inner.y + @as(i32, @intCast(shown)) * line_h, mono_px, clipped_line, color);

                shown += 1;

            }

            row += 1;
            line_start = index + 1;

            if (at_end) break;

        }

    }

}

fn status_line_color(text: []const u8) gfx.Color {

    const code = status_code(text);

    if (code == 0) return ui.theme.text;

    return if (code >= 200 and code < 400) ui.theme.good else ui.theme.warn;

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
