// Mail: a read-only IMAP inbox reader.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const imap = lib.imap;
const mime = lib.mime;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

// TLS needs a freestanding entropy source.
pub const std_options = lib.rng.std_options;

pub const app_meta = .{
    .title = "Mail",
    .description = "Read your Gmail inbox.",
    .icon = "mail",
    .category = "Internet",
};

comptime {

    _ = lib.start;

}

// Layout.

const toolbar_h: i32 = 46;
const status_h: i32 = 26;
const row_h: i32 = 62;
const pad: i32 = 12;
const min_list_w: i32 = 260;
const list_share = 42;

// Workers.

const page_size = 4096;

// TLS handshake needs ~32 KiB stack; matches fetch.zig worker_stack_pages.
const worker_stack_pages = 64;

const max_messages = 30;
const raw_capacity = 20 * 1024;
const body_capacity = 10 * 1024;

const account_name = "mail";

// Worker states.

const state_setup: u32 = 0;
const state_connecting: u32 = 1;
const state_listing: u32 = 2;
const state_ready: u32 = 3;
const state_opening: u32 = 4;
const state_failed: u32 = 5;

const fail_none: u32 = 0;
const fail_connect: u32 = 1;
const fail_auth: u32 = 2;
const fail_mailbox: u32 = 3;
const fail_dropped: u32 = 4;

const Field = enum {

    none,
    server,
    address,
    password,

};

const id_refresh: u32 = 1;
const id_account: u32 = 2;
const id_connect: u32 = 3;
const id_server: u32 = 4;
const id_address: u32 = 5;
const id_password: u32 = 6;
const id_row_base: u32 = 100;

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var regions = ui.HitRegions{};
var keyboard = lib.keymap.Keyboard{};

// Setup form.

var server_storage: [96]u8 = undefined;
var address_storage: [96]u8 = undefined;
var password_storage: [96]u8 = undefined;
var mask_storage: [96]u8 = undefined;

var server_field: ui.EditBuffer = undefined;
var address_field: ui.EditBuffer = undefined;
var password_field: ui.EditBuffer = undefined;

var focused: Field = .server;
var caret_on = true;
var showing_setup = true;

// Session state shared with the worker.

var worker_state: u32 = state_setup;
var failure: u32 = fail_none;

var connect_serial: u32 = 0;
var refresh_serial: u32 = 0;
var open_serial: u32 = 0;
var open_sequence: u32 = 0;

var messages: [max_messages]imap.Envelope = undefined;
var message_count: usize = 0;
var messages_serial: u32 = 0;
var shown_messages_serial: u32 = 0;

var body_text: [body_capacity]u8 = undefined;
var body_len: usize = 0;
var body_truncated = false;
var body_serial: u32 = 0;
var shown_body_serial: u32 = 0;

var selected: usize = 0;
var list_scroll: i32 = 0;
var body_scroll: i32 = 0;
var body_height_cache: i32 = 0;

var ui_wake: u32 = 0;
var running: u32 = 1;
var worker_alive: u32 = 0;

// Owned by the worker.

var client: imap.Client = .{};
var raw_message: [raw_capacity]u8 = undefined;
var scratch_body: [body_capacity]u8 = undefined;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try lib.wm.open_main(&connection, 900, 620, "Mail");

    _ = lib.draw.round.masks_for(8);

    server_field = ui.EditBuffer.init(&server_storage);
    address_field = ui.EditBuffer.init(&address_storage);
    password_field = ui.EditBuffer.init(&password_storage);

    load_account();

    try start_worker();

    // Same pattern as CDN session restore: saved credentials connect on launch.
    if (address_field.len > 0 and password_field.len > 0) start_connect();

    paint();

    var blink: u64 = lib.time.now_ms();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            if (lib.window.text_selection(event)) dirty = true;

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);

                    // Wait for the worker so IMAP/TLS detaches before the process dies.
                    var waits: usize = 0;

                    while (@atomicLoad(u32, &worker_alive, .acquire) != 0 and waits < 3500) : (waits += 1) {

                        lib.time.sleep_ms(10);

                    }

                    lib.wm.close_main(&connection, &window);

                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    measure_cached_body();

                    dirty = true;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left and click(event.x, event.y)) dirty = true;

                },

                events.kind_pointer_move => {

                    if (regions.pointer_move(event.x, event.y)) dirty = true;

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => {

                    if (wheel(event.value, event.x)) dirty = true;

                },

                events.kind_key_down => {

                    if (key_down(event.code)) dirty = true;

                },

                events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &ui_wake, .Xchg, 0, .acquire) != 0) dirty = true;

        const listing = @atomicLoad(u32, &messages_serial, .acquire);

        if (listing != shown_messages_serial) {

            shown_messages_serial = listing;
            showing_setup = false;
            list_scroll = 0;
            selected = 0;

            // Open the newest message straight away, the way a mail client would.
            open_selected();

            dirty = true;

        }

        const body = @atomicLoad(u32, &body_serial, .acquire);

        if (body != shown_body_serial) {

            shown_body_serial = body;
            body_scroll = 0;

            measure_cached_body();

            dirty = true;

        }

        const now = lib.time.now_ms();

        if (showing_setup and focused != .none and now -% blink >= 500) {

            blink = now;
            caret_on = !caret_on;

            dirty = true;

        }

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &ui_wake, .acquire) != 0) continue;

        // Only the caret needs a timer; otherwise park until an event or the worker wakes us.
        if (showing_setup and focused != .none) lib.time.sleep_ms(60) else _ = sys.wait(ready) catch {};

    }

}

// Account settings under /cfgs/mail.config: host, address, base64(app-password).

fn load_account() void {

    set_field(&server_field, "imap.gmail.com");

    var storage: [384]u8 = undefined;
    const text = lib.config.load(account_name, &storage) catch return;

    var lines = std.mem.splitScalar(u8, text, '\n');

    if (lines.next()) |host| {

        if (host.len > 0) set_field(&server_field, host);

    }

    if (lines.next()) |user| set_field(&address_field, user);

    if (lines.next()) |encoded| {

        const trimmed = std.mem.trim(u8, encoded, " \t\r");

        if (trimmed.len == 0) return;

        var secret: [96]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(trimmed) catch return;

        if (decoded_len > secret.len) return;

        std.base64.standard.Decoder.decode(secret[0..decoded_len], trimmed) catch return;
        set_field(&password_field, secret[0..decoded_len]);
        @memset(secret[0..decoded_len], 0);

    }

}

fn save_account() void {

    const password = password_field.slice();
    var encoded: [128]u8 = undefined;
    const enc_size = std.base64.standard.Encoder.calcSize(password.len);

    if (enc_size > encoded.len) return;

    const secret = std.base64.standard.Encoder.encode(encoded[0..enc_size], password);

    var storage: [384]u8 = undefined;
    const text = std.fmt.bufPrint(&storage, "{s}\n{s}\n{s}\n", .{

        server_field.slice(),
        address_field.slice(),
        secret,

    }) catch return;

    lib.config.save(account_name, text) catch {};

}

fn set_field(buffer: *ui.EditBuffer, text: []const u8) void {

    buffer.clear();

    for (text) |byte| _ = buffer.insert(byte);

}

// Worker.

fn start_worker() !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    @atomicStore(u32, &worker_alive, 1, .release);

    var heap = lib.mem.Heap.init(cap.memory);

    var handled_connect: u32 = 0;
    var handled_refresh: u32 = 0;
    var handled_open: u32 = 0;

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        const connect_request = @atomicLoad(u32, &connect_serial, .acquire);

        if (connect_request != handled_connect) {

            handled_connect = connect_request;
            handled_refresh = @atomicLoad(u32, &refresh_serial, .acquire);

            open_session(&heap);

            continue;

        }

        const refresh_request = @atomicLoad(u32, &refresh_serial, .acquire);

        if (refresh_request != handled_refresh) {

            handled_refresh = refresh_request;

            // A dropped session reconnects on Refresh rather than stranding the user on an error.
            if (client.live) list_inbox() else open_session(&heap);

            continue;

        }

        const open_request = @atomicLoad(u32, &open_serial, .acquire);

        if (open_request != handled_open and client.live) {

            handled_open = open_request;

            open_message(@atomicLoad(u32, &open_sequence, .acquire));

            continue;

        }

        lib.time.sleep_ms(40);

    }

    client.close();
    @atomicStore(u32, &worker_alive, 0, .release);
    lib.start.exit();

}

fn open_session(heap: *lib.mem.Heap) void {

    client.close();

    set_state(state_connecting, fail_none);

    var host: [96]u8 = undefined;
    var user: [96]u8 = undefined;
    var secret: [96]u8 = undefined;

    const host_len = copy_field(&server_field, &host);
    const user_len = copy_field(&address_field, &user);
    const secret_len = copy_field(&password_field, &secret);

    if (host_len == 0 or user_len == 0 or secret_len == 0) {

        set_state(state_failed, fail_auth);
        return;

    }

    client.connect(cap.memory, heap, host[0..host_len], 993, true) catch {

        set_state(state_failed, fail_connect);
        return;

    };

    client.login(user[0..user_len], secret[0..secret_len]) catch {

        client.close();
        set_state(state_failed, fail_auth);

        return;

    };

    // Wipe the copy as soon as the handshake is done; the field still holds it for reconnects.
    @memset(secret[0..secret_len], 0);

    list_inbox();

}

fn list_inbox() void {

    set_state(state_listing, fail_none);

    const exists = client.examine("INBOX") catch {

        client.close();
        set_state(state_failed, fail_mailbox);

        return;

    };

    if (exists == 0) {

        message_count = 0;

        _ = @atomicRmw(u32, &messages_serial, .Add, 1, .acq_rel);

        set_state(state_ready, fail_none);

        return;

    }

    // Newest page only: the last `max_messages` sequence numbers.
    const last = exists;
    const first = if (exists > max_messages) exists - max_messages + 1 else 1;

    const count = client.fetch_envelopes(first, last, messages[0..]) catch {

        client.close();
        set_state(state_failed, fail_dropped);

        return;

    };

    message_count = count;

    _ = @atomicRmw(u32, &messages_serial, .Add, 1, .acq_rel);

    set_state(state_ready, fail_none);

}

fn open_message(sequence: u32) void {

    set_state(state_opening, fail_none);

    const length = client.fetch_message(sequence, &raw_message) catch {

        client.close();
        set_state(state_failed, fail_dropped);

        return;

    };

    const found = mime.extract_body(raw_message[0..length], &scratch_body);

    body_len = if (found.html)
        copy_out(mime.strip_html(found.text, &body_text))
    else
        copy_out(found.text);

    body_truncated = length >= raw_message.len;

    _ = @atomicRmw(u32, &body_serial, .Add, 1, .acq_rel);

    set_state(state_ready, fail_none);

}

/// strip_html writes straight into body_text; the plain path needs an explicit copy.
fn copy_out(text: []const u8) usize {

    if (text.ptr == &body_text) return text.len;

    const length = @min(text.len, body_text.len);

    @memcpy(body_text[0..length], text[0..length]);

    return length;

}

fn copy_field(buffer: *const ui.EditBuffer, out: []u8) usize {

    const text = buffer.slice();
    const length = @min(text.len, out.len);

    @memcpy(out[0..length], text[0..length]);

    return length;

}

fn set_state(state: u32, reason: u32) void {

    @atomicStore(u32, &failure, reason, .release);
    @atomicStore(u32, &worker_state, state, .release);

    wake_ui();

}

fn wake_ui() void {

    @atomicStore(u32, &ui_wake, 1, .release);

    sys.notify(ready, lib.proto.window.ring_bit) catch {};

}

// Input.

fn click(x: i32, y: i32) bool {

    const id = regions.hit(x, y);

    if (showing_setup) {

        switch (id) {

            id_server => return focus_field(.server, x),
            id_address => return focus_field(.address, x),
            id_password => return focus_field(.password, x),

            id_connect => {

                start_connect();
                return true;

            },

            else => {

                focused = .none;
                return true;

            },

        }

    }

    if (id == id_refresh) {

        _ = @atomicRmw(u32, &refresh_serial, .Add, 1, .acq_rel);
        return true;

    }

    if (id == id_account) {

        showing_setup = true;
        focused = .password;

        return true;

    }

    if (id >= id_row_base) {

        const index = id - id_row_base;

        if (index >= message_count) return false;

        selected = index;

        open_selected();

        return true;

    }

    return false;

}

fn focus_field(field: Field, x: i32) bool {

    focused = field;
    caret_on = true;

    const buffer = field_buffer(field) orelse return true;
    const rect = field_rect(field);
    const inner = rect.w - 2 * ui.field_pad;
    const index = ui.field_click_index(&font, buffer.slice(), 13, buffer.cursor, inner, x - rect.x - ui.field_pad);

    _ = buffer.set_cursor(index, false);

    return true;

}

fn field_buffer(field: Field) ?*ui.EditBuffer {

    return switch (field) {

        .server => &server_field,
        .address => &address_field,
        .password => &password_field,
        .none => null,

    };

}

fn start_connect() void {

    save_account();

    focused = .none;

    _ = @atomicRmw(u32, &connect_serial, .Add, 1, .acq_rel);

}

fn open_selected() void {

    if (selected >= message_count) return;

    body_len = 0;

    @atomicStore(u32, &open_sequence, messages[selected].seq, .release);

    _ = @atomicRmw(u32, &open_serial, .Add, 1, .acq_rel);

}

fn key_down(code: u16) bool {

    if (keyboard.modifier(events.kind_key_down, code)) return false;

    var scratch: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &scratch);

    if (bytes.len == 0) return false;

    const enter = bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n');
    const tab = bytes.len == 1 and bytes[0] == '\t';

    if (showing_setup) {

        if (enter) {

            start_connect();
            return true;

        }

        if (tab) {

            focused = switch (focused) {

                .server => .address,
                .address => .password,

                else => .server,

            };

            caret_on = true;

            return true;

        }

        const buffer = field_buffer(focused) orelse return false;

        caret_on = true;

        return buffer.feed(bytes, keyboard.shift);

    }

    // Arrow keys walk the message list.
    if (bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[') {

        const step: i32 = switch (bytes[2]) {

            'A' => -1,
            'B' => 1,

            else => return false,

        };

        if (message_count == 0) return false;

        const next = std.math.clamp(@as(i32, @intCast(selected)) + step, 0, @as(i32, @intCast(message_count - 1)));

        if (next == @as(i32, @intCast(selected))) return false;

        selected = @intCast(next);

        reveal_selected();
        open_selected();

        return true;

    }

    if (enter) {

        open_selected();
        return true;

    }

    return false;

}

fn reveal_selected() void {

    const view = list_rect();
    const top = @as(i32, @intCast(selected)) * row_h;

    if (top < list_scroll) list_scroll = top;
    if (top + row_h > list_scroll + view.h - pad) list_scroll = top + row_h - view.h + pad;

    list_scroll = @max(0, list_scroll);

}

fn wheel(delta: i64, x: i32) bool {

    if (showing_setup) return false;

    // The pointer picks the pane: message list on the left, message body on the right.
    if (x < list_rect().x + list_rect().w) {

        const before = list_scroll;

        list_scroll = @intCast(list_model().wheel(delta, row_h));

        return list_scroll != before;

    }

    const before = body_scroll;

    body_scroll = @intCast(body_model().wheel(delta, 48));

    return body_scroll != before;

}

fn list_model() ui.Scroll {

    return .{

        .offset = list_scroll,
        .content = @as(i32, @intCast(message_count)) * row_h + pad,
        .viewport = list_rect().h,

    };

}

fn body_model() ui.Scroll {

    return .{

        .offset = body_scroll,
        .content = body_height_cache,
        .viewport = reader_rect().h,

    };

}

fn update_cursor(x: i32, y: i32) void {

    if (showing_setup and (field_rect(.server).contains(x, y) or field_rect(.address).contains(x, y) or field_rect(.password).contains(x, y))) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker) else lib.cursor.set(&connection, .pointer);

}

// Layout.

fn win_w() i32 {

    return @intCast(window.surface.width);

}

fn win_h() i32 {

    return @intCast(window.surface.height);

}

fn content_rect() Rect {

    return .{ .x = 0, .y = toolbar_h, .w = win_w(), .h = win_h() - toolbar_h - status_h };

}

fn list_rect() Rect {

    const content = content_rect();
    const width = @max(min_list_w, @divTrunc(content.w * list_share, 100));

    return .{ .x = content.x, .y = content.y, .w = @min(width, content.w), .h = content.h };

}

fn reader_rect() Rect {

    const content = content_rect();
    const list = list_rect();

    return .{ .x = list.x + list.w, .y = content.y, .w = content.w - list.w, .h = content.h };

}

fn row_rect(index: usize) Rect {

    const list = list_rect();

    return .{

        .x = list.x + pad,
        .y = list.y + pad + @as(i32, @intCast(index)) * row_h - list_scroll,

        .w = list.w - pad * 2 - ui.scrollbar_width,
        .h = row_h - 4,

    };

}

fn status_rect() Rect {

    return .{ .x = 0, .y = win_h() - status_h, .w = win_w(), .h = status_h };

}

// Form spacing: 24px inset, 16px label-to-field, 20px row gap, 24px bottom margin.

const form_inset: i32 = 24;
const form_label_gap: i32 = 16;
const form_row_gap: i32 = 20;
const form_field_h: i32 = 32;
const form_button_h: i32 = 36;

const form_rows: i32 = 3;
const form_row_pitch: i32 = form_label_gap + form_field_h + form_row_gap;

/// Distance from the top of the card to the first field's label.
const form_header_h: i32 = 84;

fn form_rect() Rect {

    const width: i32 = @min(420, win_w() - pad * 4);
    const height = form_header_h + form_rows * form_row_pitch + form_button_h + 22 + form_inset;

    return .{

        .x = @divTrunc(win_w() - width, 2),
        .y = @max(toolbar_h + pad, @divTrunc(win_h() - height, 2)),

        .w = width,
        .h = height,

    };

}

fn field_rect(field: Field) Rect {

    const form = form_rect();
    const row: i32 = switch (field) {

        .server => 0,
        .address => 1,
        .password => 2,

        .none => 0,

    };

    return .{

        .x = form.x + form_inset,
        .y = form.y + form_header_h + row * form_row_pitch + form_label_gap,

        .w = form.w - form_inset * 2,
        .h = form_field_h,

    };

}

fn connect_rect() Rect {

    const form = form_rect();
    const last = field_rect(.password);

    return .{

        .x = form.x + form_inset,
        .y = last.y + last.h + form_row_gap + 4,

        .w = form.w - form_inset * 2,
        .h = form_button_h,

    };

}

// Painting.

fn paint() void {

    const surface = &window.surface;

    surface.fill(lib.draw.transparent);
    regions.reset();

    paint_toolbar(surface);

    if (showing_setup) paint_setup(surface) else {

        paint_list(surface);
        paint_reader(surface);

    }

    paint_status(surface);

    gfx.fence();
    window.present_all() catch {};

}

fn paint_toolbar(surface: *const gfx.Surface) void {

    const bar = Rect{ .x = 0, .y = 0, .w = win_w(), .h = toolbar_h };

    surface.fill_rect(bar, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h - 1, .w = bar.w, .h = 1 }, ui.theme.border);

    lib.draw.vector.icon_in(surface, .{ .x = pad + 2, .y = 13, .w = 20, .h = 20 }, lib.icons.mail, ui.theme.text_dim);

    font.draw(surface, pad + 30, 14, 15, "Inbox", ui.theme.text);

    if (!showing_setup and message_count > 0) {

        var counter: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&counter, "{d} messages", .{message_count}) catch "";

        font.draw(surface, pad + 84, 17, 12, label, ui.theme.text_faint);

    }

    if (showing_setup) return;

    const account = Rect{ .x = win_w() - pad - 92, .y = 8, .w = 92, .h = 30 };
    const refresh = Rect{ .x = account.x - 96, .y = 8, .w = 92, .h = 30 };

    regions.add(id_refresh, refresh);
    regions.add(id_account, account);

    const busy = @atomicLoad(u32, &worker_state, .acquire) == state_listing;

    ui.widgets.button(surface, &font, refresh, if (busy) "..." else "Refresh", .{

        .hovered = regions.hovered(id_refresh),
        .outlined = true,

    }, .{ .size = 13, .idle = ui.theme.surface });

    ui.widgets.button(surface, &font, account, "Account", .{

        .hovered = regions.hovered(id_account),
        .outlined = true,

    }, .{ .size = 13, .idle = ui.theme.surface });

}

/// The password field paints through a same-length run of stars, so the caret still lands right.
fn masked(buffer: *const ui.EditBuffer) ui.EditBuffer {

    const length = @min(buffer.len, mask_storage.len);

    @memset(mask_storage[0..length], '*');

    return .{

        .bytes = &mask_storage,
        .len = length,
        .cursor = @min(buffer.cursor, length),

    };

}

fn paint_setup(surface: *const gfx.Surface) void {

    const form = form_rect();

    ui.fill_round_rect(surface, form, 10, ui.theme.surface);
    ui.stroke_round_rect(surface, form, 10, 1, ui.theme.border);

    font.draw(surface, form.x + form_inset, form.y + form_inset, 17, "Connect to your inbox", ui.theme.text);
    font.draw(surface, form.x + form_inset, form.y + form_inset + 28, 12, "An IMAP server is required to access mail.", ui.theme.text_faint);

    const rows = [_]struct { field: Field, id: u32, label: []const u8, hint: []const u8 }{

        .{ .field = .server, .id = id_server, .label = "Server", .hint = "imap.example.com" },
        .{ .field = .address, .id = id_address, .label = "Address", .hint = "you@example.com" },
        .{ .field = .password, .id = id_password, .label = "Password", .hint = "app password" },

    };

    for (rows) |row| {

        const rect = field_rect(row.field);

        regions.add(row.id, rect);

        font.draw(surface, rect.x, rect.y - form_label_gap, 11, row.label, ui.theme.text_dim);

        const active = focused == row.field;
        const buffer = field_buffer(row.field).?;
        const shown = if (row.field == .password) masked(buffer) else buffer.*;

        ui.paint_text_field(surface, &font, rect, &shown, row.hint, active, active and caret_on, 13);

    }

    const connect = connect_rect();

    regions.add(id_connect, connect);

    // Naming the current step matters: "Connecting..." through a long inbox load reads as a hang.
    const label = switch (@atomicLoad(u32, &worker_state, .acquire)) {

        state_connecting => "Connecting...",
        state_listing => "Loading inbox...",

        else => "Connect",

    };

    ui.widgets.button(surface, &font, connect, label, .{

        .hovered = regions.hovered(id_connect),
        .accent = true,

    }, .{ .size = 14 });

    text_center(surface, .{ .x = form.x, .y = connect.y + connect.h + 6, .w = form.w, .h = 16 }, 11, "Your app password is stored locally.", ui.theme.text_faint);

}

fn paint_list(surface: *const gfx.Surface) void {

    const list = list_rect();
    const clipped = surface.clipped(list);

    surface.fill_rect(.{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h }, ui.theme.border);

    if (message_count == 0) {

        text_center(surface, list, 13, empty_message(), ui.theme.text_faint);

        return;

    }

    for (messages[0..message_count], 0..) |*envelope, index| {

        const rect = row_rect(index);

        if (rect.y + rect.h < list.y or rect.y > list.y + list.h) continue;

        const id = id_row_base + @as(u32, @intCast(index));

        regions.add(id, rect);

        if (index == selected) {

            ui.fill_round_rect(&clipped, rect, 7, ui.theme.accent_dim);

        } else if (regions.hovered(id)) {

            ui.fill_round_rect(&clipped, rect, 7, ui.theme.hover);

        }

        var text_x = rect.x + 14;

        // Unread mail gets a dot and full-strength text; read mail sits back.
        if (!envelope.seen) {

            ui.fill_round_rect(&clipped, .{ .x = rect.x + 8, .y = rect.y + 24, .w = 6, .h = 6 }, 3, ui.theme.accent);

            text_x += 12;

        }

        const date = short_date(envelope.when());
        const date_w = font.text_width(date, 11);
        const text_w = rect.x + rect.w - 14 - date_w - 10 - text_x;

        font.draw(&clipped, rect.x + rect.w - 14 - date_w, rect.y + 12, 11, date, ui.theme.text_faint);

        const sender = if (envelope.sender().len > 0) envelope.sender() else "(unknown sender)";
        const subject = if (envelope.title().len > 0) envelope.title() else "(no subject)";

        font.draw(&clipped, text_x, rect.y + 10, 14, ui.truncate(&font, sender, 14, text_w), if (envelope.seen) ui.theme.text_dim else ui.theme.text);
        font.draw(&clipped, text_x, rect.y + 32, 12, ui.truncate(&font, subject, 12, text_w + date_w), ui.theme.text_dim);

    }

    const model = list_model();

    if (model.overflowing()) {

        ui.scrollbar(surface, .{ .x = list.x + list.w - ui.scrollbar_width - 2, .y = list.y + 2, .w = ui.scrollbar_width, .h = list.h - 4 }, model);

    }

}

fn empty_message() []const u8 {

    return switch (@atomicLoad(u32, &worker_state, .acquire)) {

        state_connecting => "Connecting...",
        state_listing => "Loading your inbox...",
        state_failed => "Could not load the inbox.",

        else => "No messages.",

    };

}

fn paint_reader(surface: *const gfx.Surface) void {

    const reader = reader_rect();

    if (reader.w < 200) return;

    const clipped = surface.clipped(reader);
    const inner = reader.inset(pad + 8);

    if (selected >= message_count) {

        lib.draw.vector.icon_in(&clipped, .{ .x = inner.x + @divTrunc(inner.w - 48, 2), .y = inner.y + @divTrunc(inner.h, 2) - 48, .w = 48, .h = 48 }, lib.icons.mail, ui.theme.text_faint);

        text_center(&clipped, .{ .x = inner.x, .y = inner.y + @divTrunc(inner.h, 2), .w = inner.w, .h = 20 }, 13, "Select a message to read it", ui.theme.text_dim);

        return;

    }

    const envelope = &messages[selected];

    var cursor = inner.y;

    cursor += paint_paragraph(&clipped, .{ .x = inner.x, .y = cursor, .w = inner.w, .h = 60 }, 19, if (envelope.title().len > 0) envelope.title() else "(no subject)", ui.theme.text, 2);

    cursor += 6;

    font.draw(&clipped, inner.x, cursor, 13, ui.truncate(&font, envelope.sender(), 13, inner.w), ui.theme.text_dim);

    cursor += 20;

    font.draw(&clipped, inner.x, cursor, 11, ui.truncate(&font, envelope.when(), 11, inner.w), ui.theme.text_faint);

    cursor += 22;

    clipped.fill_rect(.{ .x = inner.x, .y = cursor, .w = inner.w, .h = 1 }, ui.theme.border);

    cursor += 14;

    const body = Rect{ .x = inner.x, .y = cursor, .w = inner.w, .h = inner.y + inner.h - cursor };

    if (@atomicLoad(u32, &worker_state, .acquire) == state_opening) {

        font.draw(&clipped, body.x, body.y, 13, "Opening...", ui.theme.text_faint);

        return;

    }

    if (body_len == 0) {

        font.draw(&clipped, body.x, body.y, 13, "This message has no readable text.", ui.theme.text_faint);

        return;

    }

    const body_clip = surface.clipped(body);

    paint_body(&body_clip, body, body_text[0..body_len], -body_scroll);

    const model = body_model();

    if (model.overflowing()) {

        ui.scrollbar(surface, .{ .x = reader.x + reader.w - ui.scrollbar_width - 2, .y = body.y, .w = ui.scrollbar_width, .h = body.h }, model);

    }

}

/// Cache body wrap height per message and resize; 10 KiB text is too costly per paint.
fn measure_cached_body() void {

    body_height_cache = if (body_len == 0) 0 else measure_body(reader_rect().inset(pad + 8).w, body_text[0..body_len]);

}

/// Word-wrapped body text. `offset` shifts everything vertically for scrolling.
fn paint_body(surface: *const gfx.Surface, rect: Rect, text: []const u8, offset: i32) void {

    const size: u32 = 13;
    const line_height = font.line_height(size) + 5;

    var y = rect.y + offset;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |raw| {

        const paragraph = std.mem.trimRight(u8, raw, "\r");

        if (paragraph.len == 0) {

            y += @divTrunc(line_height, 2);
            continue;

        }

        var remaining = paragraph;

        while (remaining.len > 0) {

            const take = wrap_point(remaining, size, rect.w);

            if (y + line_height > rect.y and y < rect.y + rect.h) {

                font.draw(surface, rect.x, y, size, remaining[0..take], ui.theme.text);

            }

            y += line_height;
            remaining = std.mem.trimLeft(u8, remaining[take..], " ");

        }

    }

    if (body_truncated and y < rect.y + rect.h) {

        font.draw(surface, rect.x, y + 8, 11, "Message truncated.", ui.theme.text_faint);

    }

}

fn measure_body(width: i32, text: []const u8) i32 {

    const size: u32 = 13;
    const line_height = font.line_height(size) + 5;

    var total: i32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |raw| {

        const paragraph = std.mem.trimRight(u8, raw, "\r");

        if (paragraph.len == 0) {

            total += @divTrunc(line_height, 2);
            continue;

        }

        var remaining = paragraph;

        while (remaining.len > 0) {

            const take = wrap_point(remaining, size, width);

            total += line_height;
            remaining = std.mem.trimLeft(u8, remaining[take..], " ");

        }

    }

    return total + line_height;

}

/// How many bytes of `text` fit in `width`, broken on a space where possible.
fn wrap_point(text: []const u8, size: u32, width: i32) usize {

    const fits = ui.truncate(&font, text, size, width).len;

    if (fits >= text.len) return text.len;
    if (fits == 0) return 1;

    if (std.mem.lastIndexOfScalar(u8, text[0..fits], ' ')) |space| {

        if (space > 0) return space;

    }

    return fits;

}

/// Trim an RFC 5322 date down to its day and month without a full date parser.
fn short_date(raw: []const u8) []const u8 {

    var text = raw;

    // Drop a leading weekday ("Mon, ").
    if (std.mem.indexOfScalar(u8, text, ',')) |comma| text = std.mem.trimLeft(u8, text[comma + 1 ..], " ");

    var parts = std.mem.splitScalar(u8, text, ' ');
    const day = parts.next() orelse return raw;
    const month = parts.next() orelse return day;

    return text[0 .. day.len + 1 + month.len];

}

fn paint_status(surface: *const gfx.Surface) void {

    const bar = status_rect();

    surface.fill_rect(bar, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = bar.y, .w = bar.w, .h = 1 }, ui.theme.border);

    const state = @atomicLoad(u32, &worker_state, .acquire);

    font.draw(surface, pad, bar.y + 6, 11, status_line(state), if (state == state_failed) ui.theme.warn else ui.theme.text_faint);

    if (showing_setup or address_field.len == 0) return;

    const text = address_field.slice();
    const width = font.text_width(text, 11);

    font.draw(surface, win_w() - pad - width, bar.y + 6, 11, text, ui.theme.text_faint);

}

fn status_line(state: u32) []const u8 {

    return switch (state) {

        state_connecting => "Connecting over TLS...",
        state_listing => "Fetching messages...",
        state_opening => "Opening message...",
        state_ready => "Connected",

        state_failed => switch (@atomicLoad(u32, &failure, .acquire)) {

            fail_auth => "Sign-in refused. Gmail requires an App Password.",
            fail_mailbox => "Could not open INBOX.",
            fail_dropped => "Connection lost. Press Refresh to reconnect.",

            else => "Could not reach the server.",

        },

        else => "Not connected",

    };

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, value: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, value, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

/// Wrapped text with a hard line cap, for headings. Returns the height used.
fn paint_paragraph(surface: *const gfx.Surface, rect: Rect, size: u32, text: []const u8, color: gfx.Color, limit: usize) i32 {

    const line_height = font.line_height(size) + 4;

    var remaining = text;
    var y = rect.y;
    var lines: usize = 0;

    while (remaining.len > 0 and lines < limit) : (lines += 1) {

        const take = wrap_point(remaining, size, rect.w);

        font.draw(surface, rect.x, y, size, remaining[0..take], color);

        y += line_height;
        remaining = std.mem.trimLeft(u8, remaining[take..], " ");

    }

    return @max(line_height, y - rect.y);

}
