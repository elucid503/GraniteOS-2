// Requests: GUI HTTP API client (methods, headers, body, JSON pretty-print).

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const std_options = lib.rng.std_options;

pub const app_meta = .{

    .title = "Requests",
    .description = "Make API requests.",
    .category = "Internet",
    .icon = "arrow-up",

};

comptime {

    _ = lib.start;

}

const margin: i32 = 18;
const gap: i32 = 14;
const field_h: i32 = 30;
const method_h: i32 = 30;
const method_w: i32 = 62;
const send_w: i32 = 72;
const label_h: i32 = 18;
const tab_h: i32 = 30;
const headers_h: i32 = 64;
const body_h: i32 = 88;
const radius: i32 = 6;

const url_storage_size = 512;
const headers_storage_size = 1024;
const body_storage_size = 8192;
const max_headers = 16;
const response_capacity = 262_144;
const display_capacity = 262_144;

const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE" };

// Demo presets — public APIs that answer each verb without an auth token.
const Demo = struct {

    url: []const u8,
    headers: []const u8,
    body: []const u8,

};

const demos = [_]Demo{

    .{

        .url = "https://jsonplaceholder.typicode.com/posts/1",
        .headers = "Accept: application/json",
        .body = "",

    },
    .{

        .url = "https://jsonplaceholder.typicode.com/posts",
        .headers = "Accept: application/json\nContent-Type: application/json",
        .body = "{\n  \"title\": \"hello\",\n  \"body\": \"from GraniteOS\",\n  \"userId\": 1\n}",

    },
    .{

        .url = "https://jsonplaceholder.typicode.com/posts/1",
        .headers = "Accept: application/json\nContent-Type: application/json",
        .body = "{\n  \"id\": 1,\n  \"title\": \"updated\",\n  \"body\": \"full replace\",\n  \"userId\": 1\n}",

    },
    .{

        .url = "https://jsonplaceholder.typicode.com/posts/1",
        .headers = "Accept: application/json\nContent-Type: application/json",
        .body = "{\n  \"title\": \"patched title\"\n}",

    },
    .{

        .url = "https://jsonplaceholder.typicode.com/posts/1",
        .headers = "Accept: application/json",
        .body = "",

    },

};

const State = enum(u8) {

    idle,
    running,
    done,
    failed,

};

const Focus = enum {

    url,
    headers,
    body,

};

const View = enum(u8) {

    body,
    headers,
    raw,

};

var font: lib.draw.text.Face = undefined;
var mono: lib.draw.text.Face = undefined;

const mono_px: u32 = 13;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;

var url_storage: [url_storage_size]u8 = undefined;
var headers_storage: [headers_storage_size]u8 = undefined;
var body_storage: [body_storage_size]u8 = undefined;

var url_buffer: ui.EditBuffer = undefined;
var headers_buffer: ui.EditBuffer = undefined;
var body_buffer: ui.EditBuffer = undefined;

var method_index: usize = 0;
var focused: Focus = .url;
var view: View = .body;
var keyboard = lib.keymap.Keyboard{};

var scroll_row: usize = 0;
var body_scroll: usize = 0;
var dragging_scrollbar = false;
var dragging_body_scrollbar = false;
var dragging_field = false;
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;

var regions = ui.HitRegions{};

var lock: ipc.Lock = .{};

var state: State = .idle;
var response_raw: [response_capacity]u8 = undefined;
var response_raw_len: usize = 0;
var display: [display_capacity]u8 = undefined;
var display_len: usize = 0;
var error_message: [96]u8 = undefined;
var error_len: usize = 0;
var elapsed_ms: u64 = 0;
var status_code: u16 = 0;
var body_bytes: usize = 0;

var request_method: [8]u8 = undefined;
var request_method_len: usize = 0;
var request_url: [url_storage_size + 8]u8 = undefined;
var request_url_len: usize = 0;
var request_headers: [headers_storage_size]u8 = undefined;
var request_headers_len: usize = 0;
var request_body: [body_storage_size]u8 = undefined;
var request_body_len: usize = 0;

var ready: cap.Handle = 0;
var tick: u32 = 0;
var running: u32 = 1;
var request_pending: u32 = 0;

const id_method_base: u32 = 1;
const id_send: u32 = 20;
const id_view_base: u32 = 30;
const id_url: u32 = 40;
const id_headers: u32 = 41;
const id_body: u32 = 42;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);
    mono = try lib.desktop.console_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window = try lib.wm.open_main(&connection, 920, 680, "Requests");

    url_buffer = ui.EditBuffer.init(&url_storage);
    headers_buffer = ui.EditBuffer.init(&headers_storage);
    body_buffer = ui.EditBuffer.init(&body_storage);

    apply_demo(0);

    paint();

    try start_worker();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            if (lib.window.text_selection(event)) dirty = true;

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);
                    lib.wm.close_main(&connection, &window);
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
                        dragging_body_scrollbar = false;
                        dragging_field = false;

                    }

                },

                events.kind_pointer_move => {

                    pointer_x = event.x;
                    pointer_y = event.y;

                    if (dragging_scrollbar) {

                        if (drag_scrollbar(event.y)) dirty = true;

                    } else if (dragging_body_scrollbar) {

                        if (drag_body_scrollbar(event.y)) dirty = true;

                    } else if (dragging_field) {

                        if (field_drag_to(event.x, event.y)) dirty = true;

                    }

                    if (regions.pointer_move(event.x, event.y)) dirty = true;

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => {

                    if (wheel(event.value)) dirty = true;

                },

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
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
    buffer.anchor = null;

}

fn apply_demo(index: usize) void {

    const demo = demos[index];

    set_field(&url_buffer, demo.url);
    set_field(&headers_buffer, demo.headers);
    set_field(&body_buffer, demo.body);
    body_scroll = 0;

}

// --- input ---

fn key_down(code: u16) bool {

    if (keyboard.modifier(events.kind_key_down, code)) return false;

    var scratch: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &scratch);

    if (bytes.len == 0) return false;

    if (bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n')) {

        if (focused == .url) {

            start_request();
            return true;

        }

        const changed = active_buffer().insert('\n');

        if (changed and focused == .body) ensure_body_cursor_visible();

        return changed;

    }

    if (bytes.len == 1 and bytes[0] == '\t') {

        focused = switch (focused) {

            .url => .headers,
            .headers => .body,
            .body => .url,

        };

        return true;

    }

    const changed = active_buffer().feed(bytes, keyboard.shift);

    if (changed and focused == .body) ensure_body_cursor_visible();

    return changed;

}

fn active_buffer() *ui.EditBuffer {

    return switch (focused) {

        .url => &url_buffer,
        .headers => &headers_buffer,
        .body => &body_buffer,

    };

}

fn mouse_down(x: i32, y: i32) bool {

    pointer_x = x;
    pointer_y = y;

    const body_track = body_scrollbar_rect();

    if (body_track.contains(x, y) and body_scroll_model().overflowing()) {

        dragging_body_scrollbar = true;

        return drag_body_scrollbar(y);

    }

    const track = scrollbar_rect();

    if (track.contains(x, y) and scroll_model().overflowing()) {

        dragging_scrollbar = true;

        return drag_scrollbar(y);

    }

    const id = regions.hit(x, y);

    if (id >= id_method_base and id < id_method_base + methods.len) {

        method_index = id - id_method_base;
        apply_demo(method_index);
        focused = .url;

        return true;

    }

    if (id == id_send) {

        start_request();
        return true;

    }

    if (id >= id_view_base and id < id_view_base + 3) {

        view = @enumFromInt(id - id_view_base);
        rebuild_display();
        scroll_row = 0;

        return true;

    }

    if (id == id_url) {

        focused = .url;
        _ = position_field(&url_buffer, url_field_rect(), x, y, false, 0);
        dragging_field = true;

        return true;

    }

    if (id == id_headers) {

        focused = .headers;
        _ = position_field(&headers_buffer, headers_field_rect(), x, y, true, 0);
        dragging_field = true;

        return true;

    }

    if (id == id_body) {

        focused = .body;
        _ = position_field(&body_buffer, body_field_rect(), x, y, true, body_scroll);
        dragging_field = true;

        return true;

    }

    return false;

}

fn field_drag_to(x: i32, y: i32) bool {

    return switch (focused) {

        .url => position_field(&url_buffer, url_field_rect(), x, y, false, 0),
        .headers => position_field(&headers_buffer, headers_field_rect(), x, y, true, 0),
        .body => position_field(&body_buffer, body_field_rect(), x, y, true, body_scroll),

    };

}

fn position_field(buffer: *ui.EditBuffer, rect: Rect, x: i32, y: i32, multiline: bool, scroll: usize) bool {

    const inner = rect.inset(ui.field_pad);
    const rel_x = x - inner.x;
    const text = buffer.slice();

    if (!multiline) {

        const index = ui.field_click_index(&font, text, 13, buffer.cursor, inner.w, rel_x);

        return buffer.set_cursor(index, keyboard.shift);

    }

    const line_h = mono.mono_height(mono_px);
    const row: usize = scroll + @as(usize, @intCast(@max(0, @divTrunc(y - inner.y, line_h))));
    const col: usize = @intCast(@max(0, @divTrunc(rel_x, mono.mono_width(mono_px))));

    var line: usize = 0;
    var index: usize = 0;
    var line_start: usize = 0;

    while (index <= text.len) : (index += 1) {

        const at_end = index == text.len;
        const at_break = at_end or text[index] == '\n';

        if (!at_break) continue;

        if (line == row) {

            const line_len = index - line_start;
            const at = line_start + @min(col, line_len);

            return buffer.set_cursor(at, keyboard.shift);

        }

        line += 1;
        line_start = index + 1;

        if (at_end) break;

    }

    return buffer.set_cursor(text.len, keyboard.shift);

}

fn update_cursor(x: i32, y: i32) void {

    const id = regions.hit(x, y);

    if (id == id_url or id == id_headers or id == id_body) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (id == id_send or (id >= id_method_base and id < id_method_base + methods.len) or (id >= id_view_base and id < id_view_base + 3)) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    lib.cursor.set(&connection, .pointer);

}

fn wheel(delta: i64) bool {

    if (body_field_rect().contains(pointer_x, pointer_y)) {

        const before = body_scroll;

        body_scroll = @intCast(body_scroll_model().wheel(delta, 3));

        return body_scroll != before;

    }

    if (response_rect().contains(pointer_x, pointer_y) or scrollbar_rect().contains(pointer_x, pointer_y)) {

        const before = scroll_row;

        scroll_row = @intCast(scroll_model().wheel(delta, 3));

        return scroll_row != before;

    }

    if (focused == .body) {

        const before = body_scroll;

        body_scroll = @intCast(body_scroll_model().wheel(delta, 3));

        return body_scroll != before;

    }

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

fn drag_body_scrollbar(y: i32) bool {

    const track = body_scrollbar_rect();
    const before = body_scroll;

    body_scroll = @intCast(body_scroll_model().offset_at(track.h, y - track.y));

    return body_scroll != before;

}

fn cursor_line(buffer: *const ui.EditBuffer) usize {

    var line: usize = 0;
    var index: usize = 0;

    while (index < buffer.cursor and index < buffer.len) : (index += 1) {

        if (buffer.bytes[index] == '\n') line += 1;

    }

    return line;

}

fn ensure_body_cursor_visible() void {

    const line = cursor_line(&body_buffer);
    const visible = body_visible_rows();

    if (line < body_scroll) {

        body_scroll = line;

    } else if (line >= body_scroll + visible) {

        body_scroll = line + 1 - visible;

    }

}

// --- request lifecycle ---

fn with_scheme(raw: []const u8, scratch: []u8) ?[]const u8 {

    if (std.mem.indexOf(u8, raw, "://") != null) return raw;

    return std.fmt.bufPrint(scratch, "https://{s}", .{raw}) catch null;

}

fn start_request() void {

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

    if (lib.url.parse(text) == null) {

        fail("invalid url");
        return;

    }

    const method = methods[method_index];
    const body_text = body_buffer.slice();

    if (body_text.len != 0 and (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD"))) {

        fail("GET cannot carry a body");
        return;

    }

    lock.acquire();

    request_method_len = method.len;
    @memcpy(request_method[0..request_method_len], method);

    request_url_len = @min(text.len, request_url.len);
    @memcpy(request_url[0..request_url_len], text[0..request_url_len]);

    request_headers_len = @min(headers_buffer.len, request_headers.len);
    @memcpy(request_headers[0..request_headers_len], headers_buffer.bytes[0..request_headers_len]);

    request_body_len = @min(body_buffer.len, request_body.len);
    @memcpy(request_body[0..request_body_len], body_buffer.bytes[0..request_body_len]);

    state = .running;
    response_raw_len = 0;
    display_len = 0;
    error_len = 0;
    status_code = 0;
    body_bytes = 0;
    scroll_row = 0;

    lock.release();

    @atomicStore(u32, &request_pending, 1, .release);
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

fn rebuild_display() void {

    lock.acquire();
    defer lock.release();

    if (state != .done or response_raw_len == 0) {

        display_len = 0;
        return;

    }

    const parsed = lib.http.parse_response(response_raw[0..response_raw_len]) catch {

        display_len = response_raw_len;
        @memcpy(display[0..display_len], response_raw[0..display_len]);
        return;

    };

    switch (view) {

        .raw => {

            display_len = response_raw_len;
            @memcpy(display[0..display_len], response_raw[0..display_len]);

        },

        .headers => {

            display_len = @min(parsed.headers.len, display.len);
            @memcpy(display[0..display_len], parsed.headers[0..display_len]);

        },

        .body => {

            if (lib.json.looks_like(parsed.body)) {

                if (lib.json.format(parsed.body, display[0..])) |pretty| {

                    display_len = pretty.len;

                } else |_| {

                    display_len = @min(parsed.body.len, display.len);
                    @memcpy(display[0..display_len], parsed.body[0..display_len]);

                }

            } else {

                display_len = @min(parsed.body.len, display.len);
                @memcpy(display[0..display_len], parsed.body[0..display_len]);

            }

        },

    }

}

// --- worker ---

const worker_stack_pages = 64;
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

        do_request();

    }

    lib.start.exit();

}

fn do_request() void {

    lock.acquire();

    var method_local: [8]u8 = undefined;
    const method_len = request_method_len;
    @memcpy(method_local[0..method_len], request_method[0..method_len]);

    var url_local: [url_storage_size + 8]u8 = undefined;
    const url_len = request_url_len;
    @memcpy(url_local[0..url_len], request_url[0..url_len]);

    var headers_local: [headers_storage_size]u8 = undefined;
    const headers_len = request_headers_len;
    @memcpy(headers_local[0..headers_len], request_headers[0..headers_len]);

    var body_local: [body_storage_size]u8 = undefined;
    const body_len = request_body_len;
    @memcpy(body_local[0..body_len], request_body[0..body_len]);

    lock.release();

    var header_list: [max_headers]lib.http.Header = undefined;
    var header_count: usize = 0;
    var saw_content_type = false;

    var lines = std.mem.splitScalar(u8, headers_local[0..headers_len], '\n');

    while (lines.next()) |raw_line| {

        var line = raw_line;

        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        line = std.mem.trim(u8, line, " \t");

        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {

            fail("bad header line");
            return;

        };

        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (name.len == 0) {

            fail("empty header name");
            return;

        }

        if (header_count >= header_list.len) {

            fail("too many headers");
            return;

        }

        if (std.ascii.eqlIgnoreCase(name, "Content-Type")) saw_content_type = true;

        header_list[header_count] = .{ .name = name, .value = value };
        header_count += 1;

    }

    // Default JSON content type when the body looks like JSON and the user did not set one.
    if (body_len != 0 and !saw_content_type and lib.json.looks_like(body_local[0..body_len])) {

        if (header_count < header_list.len) {

            header_list[header_count] = .{ .name = "Content-Type", .value = "application/json" };
            header_count += 1;

        }

    }

    const start_ms = lib.time.now_ms();
    var heap = lib.mem.Heap.init(cap.memory);

    const result = lib.http.request(cap.memory, &heap, .{

        .method = method_local[0..method_len],
        .url = url_local[0..url_len],
        .headers = header_list[0..header_count],
        .body = body_local[0..body_len],

    }, &response_raw) catch |failure| {

        fail(@errorName(failure));
        return;

    };

    lock.acquire();

    response_raw_len = (@intFromPtr(result.body.ptr) - @intFromPtr(&response_raw)) + result.body.len;
    status_code = result.status;
    body_bytes = result.body.len;
    elapsed_ms = lib.time.now_ms() - start_ms;
    state = .done;

    lock.release();

    rebuild_display();
    notify_ui();

}

// --- layout ---

fn method_bar_y() i32 {

    return margin;

}

fn url_row_y() i32 {

    return method_bar_y() + method_h + gap;

}

fn headers_label_y() i32 {

    return url_row_y() + field_h + gap + 4;

}

fn headers_field_y() i32 {

    return headers_label_y() + label_h + 2;

}

fn body_label_y() i32 {

    return headers_field_y() + headers_h + gap;

}

fn body_field_y() i32 {

    return body_label_y() + label_h + 2;

}

fn divider_y() i32 {

    return body_field_y() + body_h + gap;

}

fn tabs_y() i32 {

    return divider_y() + 1 + gap;

}

fn response_y() i32 {

    return tabs_y() + tab_h + gap;

}

fn url_field_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const start = margin;
    const end = width - margin - send_w - gap;

    return .{ .x = start, .y = url_row_y(), .w = @max(80, end - start), .h = field_h };

}

fn send_button_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = width - margin - send_w, .y = url_row_y(), .w = send_w, .h = field_h };

}

fn headers_field_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = margin, .y = headers_field_y(), .w = width - margin * 2, .h = headers_h };

}

fn body_field_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = margin, .y = body_field_y(), .w = width - margin * 2, .h = body_h };

}

fn body_scrollbar_rect() Rect {

    const area = body_field_rect();

    return .{ .x = area.x + area.w - ui.scrollbar_width - 4, .y = area.y + 4, .w = ui.scrollbar_width, .h = @max(0, area.h - 8) };

}

fn response_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const top = response_y();

    return .{ .x = margin, .y = top, .w = width - margin * 2, .h = @max(0, height - top - margin) };

}

fn scrollbar_rect() Rect {

    const area = response_rect();

    return .{ .x = area.x + area.w - ui.scrollbar_width - 2, .y = area.y + 2, .w = ui.scrollbar_width, .h = @max(0, area.h - 4) };

}

fn text_columns() usize {

    const area = response_rect();
    const usable = area.w - 12 - ui.scrollbar_width - 4;

    return @intCast(@max(1, @divTrunc(usable, mono.mono_width(mono_px))));

}

fn visible_rows() usize {

    const area = response_rect();
    const usable = area.h - 12;

    return @intCast(@max(1, @divTrunc(usable, mono.mono_height(mono_px))));

}

fn body_visible_rows() usize {

    const area = body_field_rect();
    const usable = area.h - 2 * ui.field_pad;

    return @intCast(@max(1, @divTrunc(usable, mono.mono_height(mono_px))));

}

fn total_rows(text: []const u8) usize {

    if (text.len == 0) return 1;

    var rows: usize = 1;

    for (text) |byte| {

        if (byte == '\n') rows += 1;

    }

    return rows;

}

fn scroll_model() ui.Scroll {

    lock.acquire();
    const text = display[0..display_len];
    lock.release();

    return .{

        .offset = @intCast(scroll_row),
        .content = @intCast(total_rows(text)),
        .viewport = @intCast(visible_rows()),

    };

}

fn body_scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(body_scroll),
        .content = @intCast(total_rows(body_buffer.slice())),
        .viewport = @intCast(body_visible_rows()),

    };

}

// --- rendering ---

fn paint() void {

    const surface = &window.surface;
    const width: i32 = @intCast(surface.width);

    surface.fill(lib.draw.transparent);
    regions.reset();

    paint_methods(surface);
    paint_url_row(surface);
    paint_request_fields(surface);
    paint_divider(surface, width);
    paint_view_tabs(surface, width);

    lock.acquire();
    paint_response(surface);
    lock.release();

    window.present_all() catch {};

}

fn paint_methods(surface: *const gfx.Surface) void {

    var x: i32 = margin;
    const y = method_bar_y();

    for (methods, 0..) |label, index| {

        const rect = Rect{ .x = x, .y = y, .w = method_w, .h = method_h };
        const selected = index == method_index;
        const hovered = regions.hovered(id_method_base + @as(u32, @intCast(index)));

        regions.add(id_method_base + @as(u32, @intCast(index)), rect);

        ui.button(surface, &font, rect, label, .{

            .hovered = hovered,
            .selected = selected,
            .accent = selected,
            .outlined = true,

        }, .{ .radius = 5, .size = 12 });

        x += method_w + 8;

    }

}

fn paint_url_row(surface: *const gfx.Surface) void {

    const url_rect = url_field_rect();
    const send = send_button_rect();

    regions.add(id_url, url_rect);
    regions.add(id_send, send);

    ui.paint_text_field(surface, &font, url_rect, &url_buffer, "https://…", focused == .url, focused == .url, 13);

    ui.button(surface, &font, send, "Send", .{

        .hovered = regions.hovered(id_send),
        .accent = true,
        .outlined = true,

    }, .{ .radius = 5, .size = 13 });

}

fn paint_request_fields(surface: *const gfx.Surface) void {

    font.draw(surface, margin, headers_label_y(), 12, "Headers", ui.theme.text_faint);

    const headers_rect = headers_field_rect();
    regions.add(id_headers, headers_rect);
    paint_multiline_field(surface, headers_rect, &headers_buffer, focused == .headers, 0, false);

    font.draw(surface, margin, body_label_y(), 12, "Body", ui.theme.text_faint);

    const body_rect = body_field_rect();
    regions.add(id_body, body_rect);
    paint_multiline_field(surface, body_rect, &body_buffer, focused == .body, body_scroll, true);

}

fn paint_multiline_field(surface: *const gfx.Surface, rect: Rect, buffer: *const ui.EditBuffer, active: bool, scroll: usize, show_scroll: bool) void {

    ui.fill_round_rect(surface, rect, radius, ui.theme.surface);
    ui.stroke_round_rect(surface, rect, radius, 1, if (active) ui.theme.accent else ui.theme.border);

    const inner = rect.inset(ui.field_pad);
    const clipped = surface.clipped(inner);
    const line_h = mono.mono_height(mono_px);
    const text = buffer.slice();
    const max_rows: usize = @intCast(@max(1, @divTrunc(inner.h, line_h)));

    if (text.len == 0) return;

    var row: usize = 0;
    var shown: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;

    while (index <= text.len and shown < max_rows) : (index += 1) {

        const at_end = index == text.len;

        if (!at_end and text[index] != '\n') continue;

        if (row >= scroll) {

            var line = text[line_start..index];

            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            const draw_y = inner.y + @as(i32, @intCast(shown)) * line_h;

            mono.draw_mono(&clipped, inner.x, draw_y, mono_px, line, ui.theme.text);

            if (active and buffer.cursor >= line_start and buffer.cursor <= index) {

                const col = buffer.cursor - line_start;
                const caret_x = inner.x + @as(i32, @intCast(col)) * mono.mono_width(mono_px);

                surface.fill_rect(.{ .x = caret_x, .y = draw_y, .w = 1, .h = line_h }, ui.theme.accent);

            }

            shown += 1;

        }

        row += 1;
        line_start = index + 1;

        if (at_end) break;

    }

    if (show_scroll) {

        ui.scrollbar(surface, body_scrollbar_rect(), body_scroll_model());

    }

}

fn paint_divider(surface: *const gfx.Surface, width: i32) void {

    surface.fill_rect(.{ .x = margin, .y = divider_y(), .w = width - margin * 2, .h = 1 }, ui.theme.border);

}

fn paint_view_tabs(surface: *const gfx.Surface, width: i32) void {

    const labels = [_][]const u8{ "Body", "Headers", "Raw" };
    const tab_w: i32 = 76;
    var x: i32 = margin;
    const y = tabs_y();

    for (labels, 0..) |label, index| {

        const rect = Rect{ .x = x, .y = y, .w = tab_w, .h = tab_h };
        const selected = @intFromEnum(view) == index;

        regions.add(id_view_base + @as(u32, @intCast(index)), rect);

        ui.button(surface, &font, rect, label, .{

            .hovered = regions.hovered(id_view_base + @as(u32, @intCast(index))),
            .selected = selected,
            .outlined = true,

        }, .{ .radius = 5, .size = 12 });

        x += tab_w + 8;

    }

    paint_status_inline(surface, width, y);

}

fn paint_status_inline(surface: *const gfx.Surface, width: i32, y: i32) void {

    lock.acquire();
    defer lock.release();

    var line: [128]u8 = undefined;
    var text: []const u8 = "";
    var color = ui.theme.text_faint;

    switch (state) {

        .idle => {},

        .running => {

            text = "Sending…";
            color = ui.theme.text_dim;

        },

        .failed => {

            text = std.fmt.bufPrint(&line, "Error: {s}", .{error_message[0..error_len]}) catch "Error";
            color = ui.theme.warn;

        },

        .done => {

            text = std.fmt.bufPrint(&line, "HTTP {d}  ·  {d} B  ·  {d} ms", .{

                status_code,
                body_bytes,
                elapsed_ms,

            }) catch "";
            color = if (status_code >= 200 and status_code < 400) ui.theme.good else ui.theme.warn;

        },

    }

    if (text.len == 0) return;

    const tabs_end = margin + 3 * 76 + 2 * 8 + gap;
    const max_w = @max(0, width - margin - tabs_end);
    const visible = ui.truncate(&font, text, 12, max_w);
    const text_w = font.text_width(visible, 12);
    const draw_x = width - margin - text_w;
    const draw_y = y + @divTrunc(tab_h - font.line_height(12), 2);

    font.draw(surface, draw_x, draw_y, 12, visible, color);

}

fn paint_response(surface: *const gfx.Surface) void {

    const area = response_rect();

    ui.fill_round_rect(surface, area, radius, ui.theme.surface);
    ui.stroke_round_rect(surface, area, radius, 1, ui.theme.border);

    const text = display[0..display_len];
    const inner = area.inset(6);
    const clipped = surface.clipped(inner);

    if (text.len == 0) {

        if (state == .running) {

            mono.draw_mono(&clipped, inner.x, inner.y, mono_px, "Waiting…", ui.theme.text_faint);

        }

    } else {

        paint_lines(&clipped, inner, text);

    }

    ui.scrollbar(surface, scrollbar_rect(), .{

        .offset = @intCast(scroll_row),
        .content = @intCast(total_rows(text)),
        .viewport = @intCast(visible_rows()),

    });

}

fn paint_lines(surface: *const gfx.Surface, inner: Rect, text: []const u8) void {

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
                const color = line_color(line, row);

                mono.draw_mono(surface, inner.x, inner.y + @as(i32, @intCast(shown)) * line_h, mono_px, clipped_line, color);

                shown += 1;

            }

            row += 1;
            line_start = index + 1;

            if (at_end) break;

        }

    }

}

fn line_color(line: []const u8, row: usize) gfx.Color {

    _ = row;

    if (line.len > 0 and (line[0] == '{' or line[0] == '}' or line[0] == '[' or line[0] == ']')) return ui.theme.accent;

    if (std.mem.indexOfScalar(u8, line, ':') != null and line.len > 0 and line[0] == ' ') return ui.theme.text;

    if (std.mem.startsWith(u8, line, "HTTP/")) {

        const code = status_code;

        if (code >= 200 and code < 400) return ui.theme.good;
        if (code != 0) return ui.theme.warn;

    }

    return ui.theme.text;

}
