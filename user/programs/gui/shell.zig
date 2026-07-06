// Shell: a graphical terminal that runs MARBLE. It implements the Stream interface itself - the very interface the
// console driver speaks - so it hands the unmodified MARBLE binary a badged endpoint as its tty and renders the
// character stream MARBLE and its children write. Keystrokes from the compositor are queued and returned to their
// stdin reads. Worker threads serve the tty (a blocking read must not stall another program's write); the GUI thread
// owns the window and a small VT100-subset cell grid. MARBLE gets real pipelines, history, and program execution.

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
    .description = "MARBLE command shell",
    .icon = "terminal",
};

comptime {

    _ = lib.start;

}

const margin: i32 = 8;
const max_cols = 128;
const max_rows = 48;

const tty_workers = 3;
const worker_stack_pages = 16;
const page_size = 4096;
const shutdown_method: u64 = 0xffff_ffff_ffff_fffe;

const fg = gfx.rgb(206, 206, 206);
const bg = gfx.rgb(16, 16, 16);
const cursor_color = gfx.rgb(200, 200, 200);

var console: lib.font.Font = undefined;

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

// The character grid, its cursor, and the escape-sequence parser. Guarded by screen_lock: the tty workers mutate it
// on write/echo, the GUI thread snapshots it to paint.

var screen_lock: ipc.Lock = .{};

var cells: [max_rows * max_cols]u8 = [_]u8{' '} ** (max_rows * max_cols);
var cols: usize = 80;
var rows: usize = 24;
var cx: usize = 0;
var cy: usize = 0;

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

    bundle_length = @intCast(lib.start.word(3));
    bundle_offset = @intCast(lib.start.word(4));
    core_count = @max(1, lib.start.word(proto.init.core_count_word));

    var bundle = try lib.desktop.open_bundle();
    console = try lib.desktop.console_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;

    window = try connection.create_window(724, 436, 0, "Terminal");

    resize_grid();

    tty = try sys.create(.endpoint, 0, 0);
    child_deaths = try sys.create(.endpoint, 0, 0);
    input_ready = try sys.create(.notification, 0, 0);

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

    const usable_w = @as(i32, @intCast(window.surface.width)) - 2 * margin;
    const usable_h = @as(i32, @intCast(window.surface.height)) - 2 * margin;

    cols = @min(max_cols, @as(usize, @intCast(@max(1, @divTrunc(usable_w, @as(i32, @intCast(console.width)))))));
    rows = @min(max_rows, @as(usize, @intCast(@max(1, @divTrunc(usable_h, @as(i32, @intCast(console.height)))))));

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

        events.kind_window_focus => {

            focused = true;
            paint();

        },

        events.kind_window_blur => {

            focused = false;
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

// tty server (the Stream interface). Multiple worker threads share the endpoint so a blocked read never stalls a
// write from another program.

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

// A read pulls from the shared keystroke queue. Raw mode returns a single byte; cooked mode gathers a line with echo
// and local editing, mirroring the console driver so programs like `cat` and MARBLE's editor both behave.

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

// The terminal emulator: a small VT100 subset covering what MARBLE and the bundled programs emit - printable text,
// CR/LF/backspace/tab, and the erase and cursor-move CSI sequences.

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

    cells[cy * cols + cx] = byte;
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

    var row: usize = 1;

    while (row < rows) : (row += 1) {

        @memcpy(cells[(row - 1) * cols .. (row - 1) * cols + cols], cells[row * cols .. row * cols + cols]);

    }

    @memset(cells[(rows - 1) * cols .. (rows - 1) * cols + cols], ' ');

}

fn execute_csi(final: u8) void {

    switch (final) {

        'J' => {

            // Erase display (default and "2" both clear the whole grid here).
            @memset(cells[0 .. rows * cols], ' ');

        },

        'K' => {

            // Erase from the cursor to the end of the line.
            @memset(cells[cy * cols + cx .. cy * cols + cols], ' ');

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

// Rendering: snapshot the grid under the lock, then draw it row by row and overlay the cursor.

var snapshot: [max_rows * max_cols]u8 = undefined;

fn paint() void {

    screen_lock.acquire();

    @memcpy(snapshot[0 .. rows * cols], cells[0 .. rows * cols]);

    const snap_cx = cx;
    const snap_cy = cy;

    screen_lock.release();

    const surface = &window.surface;
    const char_w: i32 = @intCast(console.width);
    const char_h: i32 = @intCast(console.height);

    surface.fill(bg);

    var row: usize = 0;

    while (row < rows) : (row += 1) {

        const y = margin + @as(i32, @intCast(row)) * char_h;

        console.draw(surface, margin, y, snapshot[row * cols .. row * cols + cols], fg);

    }

    // Cursor: a solid block when focused, an outline when not.

    const cursor_rect = gfx.Rect{

        .x = margin + @as(i32, @intCast(snap_cx)) * char_w,
        .y = margin + @as(i32, @intCast(snap_cy)) * char_h,

        .w = char_w,
        .h = char_h,

    };

    if (focused) {

        surface.fill_rect(cursor_rect, cursor_color);

        const under = snapshot[snap_cy * cols + snap_cx];

        if (under >= 0x20 and under < 0x7f) {

            console.draw(surface, cursor_rect.x, cursor_rect.y, &[_]u8{under}, bg);

        }

    } else {

        surface.stroke_rect(cursor_rect, 1, cursor_color);

    }

    window.present_all() catch {};

}

// MARBLE runs as a child with its stdio wired to this terminal's tty, exactly as Flint launches it against the
// console - so it is the real shell, not a reimplementation. When it exits (the `exit` builtin), the reaper starts a
// fresh session so the window stays alive.

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
        .cwd = "/root/user",

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

        // MARBLE exited (its `exit` builtin, or a crash): a short backoff keeps a crash-on-start from respawning in a
        // tight loop, then start a fresh session.

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
