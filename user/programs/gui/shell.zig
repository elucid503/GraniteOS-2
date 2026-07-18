// Shell: a graphical terminal that runs MARBLE.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Handle = cap.Handle;
const Message = ipc.Message;

pub const app_meta = .{

    .title = "Terminal",
    .description = "Run the MARBLE shell.",
    .icon = "terminal",
    .category = "System",

};

comptime {

    _ = lib.start;

}

const margin: i32 = 8;
const max_cols = 128;
const max_rows = 48;
const max_scrollback = 512;
const mono_px: u32 = 13;

const tty_workers = 3;
const worker_stack_pages = 16;
const page_size = 4096;
const shutdown_method: u64 = 0xffff_ffff_ffff_fffe;

var console: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: Handle = 0;
var focused = true;

var bundle_length: usize = 0;
var bundle_offset: usize = 0;
var core_count: u64 = 1;

var tty: Handle = 0;
var child_deaths: Handle = 0;
var shutting_down: u32 = 0;
var marble_running: u32 = 0;

var marble_cwd_storage: [256]u8 = undefined;
var marble_cwd_len: usize = 0;

// Character grid and escape parser; screen_lock guards tty writes vs GUI paint snapshots.

var screen_lock: ipc.Lock = .{};

// Fixed max_cols stride so resize only changes visible dims, not buffer layout (avoids maximize scramble).
var cells: [max_rows * max_cols]u8 = [_]u8{' '} ** (max_rows * max_cols);
var cols: usize = 80;
var rows: usize = 24;
var cx: usize = 0;
var cy: usize = 0;

// Scrollback ring; scroll_row counts from oldest history line like notepad.
var scrollback: [max_scrollback * max_cols]u8 = [_]u8{' '} ** (max_scrollback * max_cols);
var scrollback_head: usize = 0;
var scrollback_count: usize = 0;
var scroll_row: usize = 0;
var follow_bottom: bool = true;
var dragging_scrollbar = false;

fn cell_at(row: usize, col: usize) usize {

    return row * max_cols + col;

}

fn history_len() usize {

    return scrollback_count + rows;

}

fn max_scroll() usize {

    const total = history_len();

    return if (total > rows) total - rows else 0;

}

fn at_bottom() bool {

    return scroll_row >= max_scroll();

}

fn stick_bottom() void {

    follow_bottom = true;
    scroll_row = max_scroll();

}

fn clamp_scroll() void {

    const max = max_scroll();

    if (scroll_row > max) scroll_row = max;

    follow_bottom = scroll_row >= max;

}

fn push_scrollback_line(line: []const u8) void {

    const dst = scrollback[scrollback_head * max_cols ..][0..max_cols];

    @memset(dst, ' ');

    const n = @min(line.len, max_cols);

    @memcpy(dst[0..n], line[0..n]);

    scrollback_head = (scrollback_head + 1) % max_scrollback;

    if (scrollback_count < max_scrollback) scrollback_count += 1;

}

/// Logical history row 0 is the oldest scrollback line; the live screen follows after.
fn history_line(hist_row: usize) []const u8 {

    if (hist_row < scrollback_count) {

        const oldest = (scrollback_head + max_scrollback - scrollback_count) % max_scrollback;
        const index = (oldest + hist_row) % max_scrollback;

        return scrollback[index * max_cols ..][0..max_cols];

    }

    const live = hist_row - scrollback_count;

    if (live >= rows) return cells[0..max_cols];

    return cells[cell_at(live, 0)..][0..max_cols];

}

const EscState = enum {

    normal,
    escape,
    csi,

};

var esc_state: EscState = .normal;
var csi_params: [16]u8 = undefined;
var csi_len: usize = 0;

var dirty: u32 = 0;

// The keystroke queue: the GUI thread fills it, stdin reads drain it.

var input_lock: ipc.Lock = .{};
var input_ready: Handle = 0;

const input_capacity = 512;

var input_buffer: [input_capacity]u8 = undefined;
var input_head: usize = 0;
var input_tail: usize = 0;

// tty sessions (per client shared buffer + line mode), exactly like the console driver.

const Mode = struct {

    mode: u64 = proto.stream.mode_cooked,

};

const Sessions = lib.session.Sessions(Mode, 16);

var sessions: Sessions = .{};
var sessions_lock: ipc.Lock = .{};

var keyboard = lib.keymap.Keyboard{};

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    bundle_length = @intCast(lib.start.word(3));
    bundle_offset = @intCast(lib.start.word(4));
    core_count = @max(1, lib.start.word(proto.init.core_count_word));

    var bundle = try lib.desktop.open_bundle();
    console = try lib.desktop.console_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window = try connection.create_window(724, 436, lib.proto.window.flag_quartz, "Terminal");

    resize_grid();

    tty = try sys.create(.endpoint, 0, 0);
    child_deaths = try sys.create(.endpoint, 0, 0);
    input_ready = try sys.create(.notification, 0, 0);

    init_marble_cwd();

    try spawn_marble();

    try start_tty_workers();
    try start_reaper();

    paint();

    while (true) {

        _ = sys.wait(ready) catch {};

        while (connection.poll_event()) |event| {

            if (handle(event)) return;

        }

        if (@atomicRmw(u32, &dirty, .Xchg, 0, .acquire) != 0) paint();

    }

}

fn resize_grid() void {

    const usable_w = @as(i32, @intCast(window.surface.width)) - 2 * margin - ui.scrollbar_width - 4;
    const usable_h = @as(i32, @intCast(window.surface.height)) - 2 * margin;
    const cell_w = console.mono_width(mono_px);
    const cell_h = console.mono_height(mono_px);

    cols = @min(max_cols, @as(usize, @intCast(@max(1, @divTrunc(usable_w, cell_w)))));
    rows = @min(max_rows, @as(usize, @intCast(@max(1, @divTrunc(usable_h, cell_h)))));

    // Storage stride is fixed at max_cols, so existing lines stay put; only the cursor must clamp.
    cx = @min(cx, cols - 1);
    cy = @min(cy, rows - 1);

    if (follow_bottom) stick_bottom() else clamp_scroll();

}

fn scrollbar_rect() gfx.Rect {

    const height: i32 = @intCast(window.surface.height);

    return .{

        .x = @as(i32, @intCast(window.surface.width)) - ui.scrollbar_width - 2,
        .y = margin,
        .w = ui.scrollbar_width,
        .h = @max(0, height - 2 * margin),

    };

}

fn scroll_model() ui.Scroll {

    return .{

        .offset = @intCast(scroll_row),
        .content = @intCast(history_len()),
        .viewport = @intCast(rows),

    };

}

fn wheel(delta: i64) bool {

    screen_lock.acquire();
    defer screen_lock.release();

    const before = scroll_row;

    scroll_row = @intCast(scroll_model().wheel(delta, 3));
    follow_bottom = at_bottom();

    return scroll_row != before;

}

fn drag_scrollbar(y: i32) bool {

    screen_lock.acquire();
    defer screen_lock.release();

    const track = scrollbar_rect();
    const before = scroll_row;

    scroll_row = @intCast(scroll_model().offset_at(track.h, y - track.y));
    follow_bottom = at_bottom();

    return scroll_row != before;

}

fn update_cursor(x: i32, y: i32) void {

    if (scrollbar_rect().contains(x, y) and max_scroll() > 0) {

        lib.cursor.set(&connection, .pointer);

        return;

    }

    const content = gfx.Rect{

        .x = margin,
        .y = margin,
        .w = @as(i32, @intCast(window.surface.width)) - 2 * margin - ui.scrollbar_width - 4,
        .h = @as(i32, @intCast(window.surface.height)) - 2 * margin,

    };

    if (content.contains(x, y)) lib.cursor.set(&connection, .selector)
    else lib.cursor.set(&connection, .pointer);

}

// Keyboard

fn handle(event: events.Event) bool {

    switch (event.kind) {

        events.kind_window_close => {

            terminate_marble();
            window.destroy();
            stop_workers();

            return true;

        },

        events.kind_key_down => key(event.code),

        events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

        events.kind_window_resize => {

            window.resize(@intCast(event.x), @intCast(event.y)) catch {};

            screen_lock.acquire();
            resize_grid();
            screen_lock.release();

            paint();

        },

        events.kind_window_focus => {

            focused = true;
            paint();

        },

        events.kind_window_blur => {

            focused = false;
            paint();

        },

        events.kind_button_down => {

            if (event.code == events.button_left) {

                if (scrollbar_rect().contains(event.x, event.y) and max_scroll() > 0) {

                    dragging_scrollbar = true;
                    _ = drag_scrollbar(event.y);
                    paint();

                }

            }

        },

        events.kind_button_up => {

            if (event.code == events.button_left) dragging_scrollbar = false;

        },

        events.kind_pointer_move => {

            if (dragging_scrollbar) {

                if (drag_scrollbar(event.y)) paint();
                lib.cursor.set(&connection, .pointer);

            } else {

                update_cursor(event.x, event.y);

            }

        },

        events.kind_scroll => {

            if (wheel(event.value)) paint();

        },

        events.kind_prefs_changed => {

            _ = lib.prefs.apply_event(event);
            paint();

        },

        else => {},

    }

    return false;

}

fn key(code: u16) void {

    if (keyboard.modifier(events.kind_key_down, code)) return;

    var buffer: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &buffer);

    if (bytes.len == 0) return;

    // Typing jumps back to the live prompt (same idea as notepad keeping the caret in view).
    if (!at_bottom()) {

        screen_lock.acquire();
        stick_bottom();
        screen_lock.release();
        paint();

    }

    input_lock.acquire();

    for (bytes) |byte| {

        if (input_tail -% input_head < input_capacity) {

            input_buffer[input_tail % input_capacity] = byte;
            input_tail +%= 1;

        }

    }

    input_lock.release();

    sys.notify(input_ready, 1) catch {};

}

fn input_pop() ?u8 {

    input_lock.acquire();
    defer input_lock.release();

    if (input_head == input_tail) return null;

    const byte = input_buffer[input_head % input_capacity];
    input_head +%= 1;

    return byte;

}

// Stream tty with worker pool so a blocked read never stalls another client's write.

fn start_tty_workers() !void {

    var started: usize = 0;

    while (started < tty_workers) : (started += 1) {

        try start_thread(&tty_worker);

    }

}

fn tty_worker() callconv(.c) noreturn {

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(tty, &in) catch continue;

        if (in.data[0] == shutdown_method) lib.start.exit();

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.stream.read => read(badge, in.data[1], in.data[2]),
        proto.stream.write => write(badge, in.data[1], in.data[2]),
        proto.stream.set_mode => set_mode(badge, in.data[1]),
        proto.stream.attach => attach(badge, in),

        else => -7,

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.stream.interface_id;
    out.data[2] = proto.stream.version;

    return 0;

}

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    sessions_lock.acquire();
    defer sessions_lock.release();

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(in.data[1]);

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn set_mode(badge: u64, mode: u64) i64 {

    if (mode != proto.stream.mode_cooked and mode != proto.stream.mode_raw) return -7;

    sessions_lock.acquire();
    defer sessions_lock.release();

    const session = sessions.find(badge) orelse return -7;
    session.extra.mode = mode;

    return 0;

}

fn write(badge: u64, offset: u64, length: u64) i64 {

    const span = session_span(badge, offset, length) orelse return -7;

    screen_lock.acquire();

    for (span) |byte| feed(byte);

    screen_lock.release();

    wake_paint();

    return @intCast(span.len);

}

// Reads drain the keystroke queue; raw is one byte, cooked echoes/edits a line like the console driver.

fn read(badge: u64, offset: u64, capacity: u64) i64 {

    const raw = is_raw(badge);
    const span = session_span(badge, offset, capacity) orelse return -7;

    if (raw) return read_raw(span);

    return read_cooked(span);

}

fn read_raw(span: []u8) i64 {

    if (span.len == 0) return -7;

    while (true) {

        if (@atomicLoad(u32, &shutting_down, .acquire) != 0) return 0;

        if (input_pop()) |byte| {

            span[0] = byte;

            return 1;

        }

        _ = sys.wait(input_ready) catch return 0;

    }

}

fn read_cooked(span: []u8) i64 {

    var length: usize = 0;

    while (true) {

        if (@atomicLoad(u32, &shutting_down, .acquire) != 0) return @intCast(length);

        const byte = input_pop() orelse {

            _ = sys.wait(input_ready) catch return @intCast(length);

            continue;

        };

        if (byte == '\r' or byte == '\n') {

            echo('\n');

            return @intCast(length);

        }

        if (byte == 0x04) return @intCast(length); // Ctrl-D: end of input

        if (byte == 0x7f or byte == 0x08) {

            if (length > 0) {

                length -= 1;
                echo(0x08);
                echo(' ');
                echo(0x08);

            }

            continue;

        }

        if (byte >= 0x20 and byte < 0x7f and length < span.len) {

            span[length] = byte;
            length += 1;
            echo(byte);

        }

    }

}

fn echo(byte: u8) void {

    screen_lock.acquire();
    feed(byte);
    screen_lock.release();

    wake_paint();

}

fn is_raw(badge: u64) bool {

    sessions_lock.acquire();
    defer sessions_lock.release();

    const session = sessions.find(badge) orelse return false;

    return session.extra.mode == proto.stream.mode_raw;

}

fn session_span(badge: u64, offset: u64, length: u64) ?[]u8 {

    sessions_lock.acquire();
    defer sessions_lock.release();

    const session = sessions.find(badge) orelse return null;

    if (session.base == 0) return null;
    if (offset > session.capacity or length > session.capacity - offset) return null;

    const buffer: [*]u8 = @ptrFromInt(session.base);

    return buffer[@intCast(offset)..@intCast(offset + length)];

}

fn wake_paint() void {

    @atomicStore(u32, &dirty, 1, .release);

    sys.notify(ready, proto.window.ring_bit) catch {};

}

// Small VT100 subset: printable text, CR/LF/backspace/tab, and erase/cursor CSI sequences.

fn feed(byte: u8) void {

    switch (esc_state) {

        .normal => feed_normal(byte),

        .escape => {

            esc_state = if (byte == '[') .csi else .normal;
            csi_len = 0;

        },

        .csi => {

            if (byte >= 0x40 and byte <= 0x7e) {

                execute_csi(byte);
                esc_state = .normal;

            } else if (csi_len < csi_params.len) {

                csi_params[csi_len] = byte;
                csi_len += 1;

            }

        },

    }

}

fn feed_normal(byte: u8) void {

    switch (byte) {

        0x1b => esc_state = .escape,

        '\r' => cx = 0,

        '\n' => {

            cx = 0;
            line_feed();

        },

        0x08 => {

            if (cx > 0) cx -= 1;

        },

        '\t' => cx = @min(cols - 1, (cx / 8 + 1) * 8),

        0x07 => {},

        else => {

            if (byte >= 0x20 and byte < 0x7f) put(byte);

        },

    }

}

fn put(byte: u8) void {

    cells[cell_at(cy, cx)] = byte;
    cx += 1;

    if (cx >= cols) {

        cx = 0;
        line_feed();

    }

}

fn line_feed() void {

    cy += 1;

    if (cy >= rows) {

        scroll_up();
        cy = rows - 1;

    }

}

fn scroll_up() void {

    // Preserve the outgoing top line in the scrollback ring.
    push_scrollback_line(cells[cell_at(0, 0)..][0..max_cols]);

    var row: usize = 1;

    while (row < rows) : (row += 1) {

        const dst = cell_at(row - 1, 0);
        const src = cell_at(row, 0);

        @memcpy(cells[dst .. dst + max_cols], cells[src .. src + max_cols]);

    }

    @memset(cells[cell_at(rows - 1, 0) .. cell_at(rows - 1, 0) + max_cols], ' ');

    // Pin the view to the live bottom when the user was already following output.
    if (follow_bottom) stick_bottom();

}

fn execute_csi(final: u8) void {

    switch (final) {

        'J' => {

            // Erase display (default and "2" both clear the whole grid here).
            @memset(cells[0 .. rows * max_cols], ' ');

        },

        'K' => {

            // Erase from the cursor to the end of the visible line.
            @memset(cells[cell_at(cy, cx) .. cell_at(cy, cols)], ' ');

        },

        'H', 'f' => {

            const target = parse_cursor();

            cy = @min(rows - 1, target.row);
            cx = @min(cols - 1, target.col);

        },

        else => {},

    }

}

const Cursor = struct {

    row: usize,
    col: usize,

};

fn parse_cursor() Cursor {

    var row: usize = 0;
    var col: usize = 0;
    var index: usize = 0;

    row = parse_number(&index);

    if (index < csi_len and csi_params[index] == ';') {

        index += 1;
        col = parse_number(&index);

    }

    return .{

        .row = if (row > 0) row - 1 else 0,
        .col = if (col > 0) col - 1 else 0,

    };

}

fn parse_number(index: *usize) usize {

    var value: usize = 0;

    while (index.* < csi_len and csi_params[index.*] >= '0' and csi_params[index.*] <= '9') : (index.* += 1) {

        value = value * 10 + (csi_params[index.*] - '0');

    }

    return value;

}

// Rendering: snapshot the visible history band under the lock, then draw it and the cursor / scrollbar.

var snapshot: [max_rows * max_cols]u8 = undefined;

fn paint() void {

    const bg = ui.theme.window_bg;
    const fg = ui.theme.text;
    const cursor_color = ui.theme.accent;

    screen_lock.acquire();

    if (follow_bottom) stick_bottom() else clamp_scroll();

    const snap_cx = cx;
    const snap_cy = cy;
    const snap_cols = cols;
    const snap_rows = rows;
    const snap_scroll = scroll_row;
    const snap_sb_count = scrollback_count;
    const view = scroll_model();

    var row: usize = 0;

    while (row < snap_rows) : (row += 1) {

        const hist = snap_scroll + row;
        const line = history_line(hist);
        const dst = cell_at(row, 0);

        @memcpy(snapshot[dst .. dst + max_cols], line[0..max_cols]);

    }

    screen_lock.release();

    const surface = &window.surface;
    const char_w = console.mono_width(mono_px);
    const char_h = console.mono_height(mono_px);

    lib.quartz.fill_window(surface, bg, @intFromEnum(lib.prefs.quartz_level));

    row = 0;

    while (row < snap_rows) : (row += 1) {

        const y = margin + @as(i32, @intCast(row)) * char_h;
        const line = snapshot[cell_at(row, 0) .. cell_at(row, 0) + snap_cols];

        console.draw_mono(surface, margin, y, mono_px, line, fg);

    }

    // Cursor only when the live cursor row is in the current view band.
    const cursor_hist = snap_sb_count + snap_cy;

    if (cursor_hist >= snap_scroll and cursor_hist < snap_scroll + snap_rows) {

        const view_row = cursor_hist - snap_scroll;

        const cursor_rect = gfx.Rect{

            .x = margin + @as(i32, @intCast(snap_cx)) * char_w,
            .y = margin + @as(i32, @intCast(view_row)) * char_h,

            .w = char_w,
            .h = char_h,

        };

        if (focused) {

            surface.fill_rect(cursor_rect, cursor_color);

            const under = snapshot[cell_at(view_row, snap_cx)];

            if (under >= 0x20 and under < 0x7f) {

                console.draw_mono(surface, cursor_rect.x, cursor_rect.y, mono_px, &[_]u8{under}, bg);

            }

        } else {

            surface.stroke_rect(cursor_rect, 1, cursor_color);

        }

    }

    ui.scrollbar(surface, scrollbar_rect(), view);

    window.present_all() catch {};

}

fn init_marble_cwd() void {

    const default = "/root/user";

    if (lib.prefs.take_open_path(&marble_cwd_storage)) |path| {

        marble_cwd_len = path.len;

        return;

    }

    @memcpy(marble_cwd_storage[0..default.len], default);
    marble_cwd_len = default.len;

}

fn marble_cwd() []const u8 {

    return marble_cwd_storage[0..marble_cwd_len];

}

// Real MARBLE child on this tty; reaper respawns after exit so the window stays alive.

fn spawn_marble() !void {

    const bundle = try lib.desktop.open_bundle();
    const image = bundle.find("marble") orelse return error.NotFound;

    const init_endpoint = try sys.create(.endpoint, 0, 0);
    errdefer sys.close(init_endpoint) catch {};

    const report = try sys.copy(child_deaths, 1);
    errdefer sys.close(report) catch {};

    const stdio = try sys.copy(tty, 1);
    errdefer sys.close(stdio) catch {};

    const grants = [_]Handle{

        stdio,
        stdio,
        stdio,
        cap.name_service,
        cap.memory,
        init_endpoint,
        report,
        stdio,
        stdio,
        cap.gui.bundle,

    };

    const child = try lib.elf.spawn_program(.{

        .image = image,
        .authority = cap.memory,
        .args = &.{"marble"},
        .grants = &grants,
        .data3 = bundle_length,
        .data4 = bundle_offset,
        .data5 = core_count,
        .cwd = marble_cwd(),

    });

    sys.close(child) catch {};
    sys.close(init_endpoint) catch {};
    sys.close(report) catch {};
    sys.close(stdio) catch {};

    @atomicStore(u32, &marble_running, 1, .release);

}

fn request_marble_exit() void {

    const cmd = "exit\n";

    input_lock.acquire();

    for (cmd) |byte| {

        if (input_tail -% input_head < input_capacity) {

            input_buffer[input_tail % input_capacity] = byte;
            input_tail +%= 1;

        }

    }

    input_lock.release();

    sys.notify(input_ready, 1) catch {};

}

fn wait_marble_exit() void {

    var spins: u32 = 0;

    while (@atomicLoad(u32, &marble_running, .acquire) != 0 and spins < 500) : (spins += 1) {

        lib.time.sleep_ms(10);

    }

}

fn terminate_marble() void {

    if (@atomicLoad(u32, &marble_running, .acquire) == 0) return;

    request_marble_exit();
    wait_marble_exit();

}

fn start_reaper() !void {

    try start_thread(&reaper);

}

fn reaper() callconv(.c) noreturn {

    var message = Message.zeroed;

    while (true) {

        _ = sys.receive(child_deaths, &message) catch continue;

        if (message.data[0] == shutdown_method) lib.start.exit();

        @atomicStore(u32, &marble_running, 0, .release);

        if (@atomicLoad(u32, &shutting_down, .acquire) != 0) lib.start.exit();

        // Back off before respawn so a crash-on-start does not tight-loop.

        lib.time.sleep_ms(300);

        if (@atomicLoad(u32, &shutting_down, .acquire) != 0) lib.start.exit();

        spawn_marble() catch {};

    }

}

fn stop_workers() void {

    @atomicStore(u32, &shutting_down, 1, .release);

    var message = Message.zeroed;
    message.data[0] = shutdown_method;

    sys.notify(input_ready, 1) catch {};

    var index: usize = 0;

    while (index < tty_workers) : (index += 1) {

        sys.send(tty, &message) catch {};

    }

    sys.send(child_deaths, &message) catch {};

}

fn start_thread(entry: *const fn () callconv(.c) noreturn) !void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(entry), base + worker_stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}
