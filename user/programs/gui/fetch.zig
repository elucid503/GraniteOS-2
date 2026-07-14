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

const ip_storage_size = 64;
const port_storage_size = 8;
const path_storage_size = 256;

const ip_field_w: i32 = 130;
const port_field_w: i32 = 56;
const go_button_w: i32 = 56;
const label_w: i32 = 38;

const response_capacity = 262_144;
const recv_chunk = 4096;

const State = enum(u8) {

    idle,
    running,
    done,
    failed,

};

const Focus = enum {

    ip,
    port,
    path,

};

var font: lib.draw.text.Face = undefined;
var mono: lib.draw.bitmap.Font = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var ip_storage: [ip_storage_size]u8 = undefined;
var port_storage: [port_storage_size]u8 = undefined;
var path_storage: [path_storage_size]u8 = undefined;

var ip_buffer: ui.EditBuffer = undefined;
var port_buffer: ui.EditBuffer = undefined;
var path_buffer: ui.EditBuffer = undefined;

var focused: Focus = .ip;
var keyboard = lib.keymap.Keyboard{};

var scroll_row: usize = 0;
var dragging_scrollbar = false;

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
var request_host: [ip_storage_size]u8 = undefined;
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

    ip_buffer = ui.EditBuffer.init(&ip_storage);
    port_buffer = ui.EditBuffer.init(&port_storage);
    path_buffer = ui.EditBuffer.init(&path_storage);

    set_field(&ip_buffer, "1.1.1.1");
    set_field(&port_buffer, "80");
    set_field(&path_buffer, "/");

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

                events.kind_button_down => {

                    if (event.code == events.button_left) {

                        if (mouse_down(event.x, event.y)) dirty = true;

                    }

                },

                events.kind_button_up => {

                    if (event.code == events.button_left) dragging_scrollbar = false;

                },

                events.kind_pointer_move => {

                    if (dragging_scrollbar) {

                        if (drag_scrollbar(event.y)) dirty = true;

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

        .ip => &ip_buffer,
        .port => &port_buffer,
        .path => &path_buffer,

    };

    return target.feed(bytes);

}

fn mouse_down(x: i32, y: i32) bool {

    const track = scrollbar_rect();

    if (track.contains(x, y) and scroll_model().overflowing()) {

        dragging_scrollbar = true;

        return drag_scrollbar(y);

    }

    if (ip_field_rect().contains(x, y)) {

        focused = .ip;
        return true;

    }

    if (port_field_rect().contains(x, y)) {

        focused = .port;
        return true;

    }

    if (path_field_rect().contains(x, y)) {

        focused = .path;
        return true;

    }

    if (go_button_rect().contains(x, y)) {

        start_fetch();
        return true;

    }

    return false;

}

fn update_cursor(x: i32, y: i32) void {

    if (y < toolbar_height and (ip_field_rect().contains(x, y) or port_field_rect().contains(x, y) or path_field_rect().contains(x, y))) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (y < toolbar_height and go_button_rect().contains(x, y)) {

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

fn start_fetch() void {

    const ip_text = ip_buffer.slice();

    if (ip_text.len == 0) {

        fail("invalid host");
        return;

    }

    const port = std.fmt.parseInt(u16, port_buffer.slice(), 10) catch {

        fail("invalid port");
        return;

    };

    const path = if (path_buffer.len == 0) "/" else path_buffer.slice();

    lock.acquire();

    request_port = port;

    request_path_len = @min(path.len, request_path.len);
    @memcpy(request_path[0..request_path_len], path[0..request_path_len]);

    request_host_len = @min(ip_text.len, request_host.len);
    @memcpy(request_host[0..request_host_len], ip_text[0..request_host_len]);

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

    var host_local: [ip_storage_size]u8 = undefined;
    const host_len = request_host_len;

    @memcpy(host_local[0..host_len], request_host[0..host_len]);

    lock.release();

    const start_ms = lib.time.now_ms();

    var socket = lib.net.Socket.connect_host(cap.memory, host_local[0..host_len], port) catch |failure| {

        fail(@errorName(failure));
        return;

    };

    defer socket.close();

    var request_buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{

        path_local[0..path_len],
        host_local[0..host_len],

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

fn ip_field_rect() Rect {

    return .{ .x = margin + label_w, .y = field_y, .w = ip_field_w, .h = field_h };

}

fn port_field_rect() Rect {

    const ip = ip_field_rect();

    return .{ .x = ip.x + ip.w + margin + label_w, .y = field_y, .w = port_field_w, .h = field_h };

}

fn path_field_rect() Rect {

    const port = port_field_rect();
    const start = port.x + port.w + margin + label_w;
    const width: i32 = @intCast(window.surface.width);
    const end = width - margin - go_button_w - margin;

    return .{ .x = start, .y = field_y, .w = @max(40, end - start), .h = field_h };

}

fn go_button_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = width - margin - go_button_w, .y = field_y, .w = go_button_w, .h = field_h };

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

    return @intCast(@max(1, @divTrunc(usable, @as(i32, @intCast(mono.width)))));

}

fn visible_rows() usize {

    const area = textarea_rect();
    const usable = area.h - 12;

    return @intCast(@max(1, @divTrunc(usable, mono.line_height())));

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

    paint_field(surface, "Host", ip_field_rect(), ip_buffer.slice(), focused == .ip);
    paint_field(surface, "Port", port_field_rect(), port_buffer.slice(), focused == .port);
    paint_field(surface, "Path", path_field_rect(), path_buffer.slice(), focused == .path);

    const go = go_button_rect();

    ui.fill_round_rect(surface, go, 5, ui.theme.accent_dim);
    text_center(surface, go, 13, "Go", ui.theme.text);

}

fn paint_field(surface: *const gfx.Surface, label: []const u8, rect: Rect, value: []const u8, active: bool) void {

    const label_rect = Rect{ .x = rect.x - label_w, .y = rect.y, .w = label_w - 4, .h = rect.h };

    text_in(surface, label_rect, 0, 11, label, ui.theme.text_faint);

    ui.fill_round_rect(surface, rect, 5, ui.theme.surface);
    ui.stroke_round_rect(surface, rect, 5, 1, if (active) ui.theme.accent else ui.theme.border);

    const inner = rect.inset(6);
    const clipped = surface.clipped(inner);
    const visible = ui.truncate(&font, value, 13, inner.w);
    const y = inner.y + @divTrunc(inner.h - font.line_height(13), 2);

    font.draw(&clipped, inner.x, y, 13, visible, ui.theme.text);

    if (active) {

        const caret_x = inner.x + font.text_width(visible, 13) + 1;

        surface.fill_rect(.{ .x = @min(caret_x, inner.x + inner.w - 1), .y = inner.y, .w = 1, .h = inner.h }, ui.theme.accent);

    }

}

fn paint_summary(surface: *const gfx.Surface) void {

    const area = summary_rect();
    const y = area.y + @divTrunc(area.h - font.line_height(12), 2);

    switch (state) {

        .idle => font.draw(surface, area.x + margin, y, 12, "Enter a host, port, and path, then press Go (or Enter).", ui.theme.text_faint),

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

        mono.draw(&clipped, inner.x, inner.y, "Response will appear here.", ui.theme.text_faint);

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
    const line_h = mono.line_height();
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

                mono.draw(surface, inner.x, inner.y + @as(i32, @intCast(shown)) * line_h, clipped_line, color);

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
