// PL011 console driver (07-userspace-ddd.md Section 5.1): an ordinary process holding only its MMIO window, its Interrupt, and an Endpoint. RX is interrupt-driven - the driver binds its line to a Notification and blocks in `wait`, never spinning. Serves the Stream interface in cooked mode: buffered lines, echo, backspace.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

// PL011 registers (offsets from the mapped window).

const data = 0x00; // DR
const flags = 0x18; // FR
const line_control = 0x2c; // LCRH
const control = 0x30; // CR
const interrupt_mask = 0x38; // IMSC
const interrupt_clear = 0x44; // ICR

const receive_empty: u32 = 1 << 4; // FR.RXFE
const transmit_full: u32 = 1 << 5; // FR.TXFF

const word_length_8: u32 = 0b11 << 5; // LCRH.WLEN, FIFOs off so every byte raises RX
const enable_uart: u32 = 1; // CR.UARTEN
const enable_transmit: u32 = 1 << 8; // CR.TXE
const enable_receive: u32 = 1 << 9; // CR.RXE
const receive_interrupt: u32 = 1 << 4; // IMSC.RXIM
const all_interrupts: u32 = 0x7ff;

const rx_bit: u64 = 1; // the notification bit the interrupt is bound to

var uart: usize = 0;
var rx_notification: Handle = 0;
var uart_lock: ipc.Lock = .{};

// Per-client shared buffers (05-server-protocol.md): attached once, then reused by every read/write. Sessions are keyed
// by the caller's badge — small ones granted by Flint/Marble, larger ones minted per lookup by the name service.

const max_sessions = 16;

const Mode = struct {

    mode: u64 = proto.stream.mode_cooked,

};

const Sessions = lib.session.Sessions(Mode, max_sessions);
const Session = Sessions.Session;

var sessions: Sessions = .{};

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        if (uart != 0) {

            put_text("console: fatal ");
            put_text(@errorName(failure));
            put_text("\n");

        }

        return 1;

    };

    return 0;

}

fn run() !void {

    // Drivers live in the fixed band above the MLFQ so an interrupt wake runs promptly.

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    uart = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);

    rx_notification = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, rx_notification, rx_bit);

    init_uart();

    put_text("Console: PL011 driver ... Loaded\n");

    ipc.serve_pool(cap.driver.endpoint, 2, dispatch);

}

fn dispatch(badge: u64, method: u64, in: *const Message, out: *Message) i64 {

    return switch (method) {

        proto.identify => identify(out),
        proto.stream.read => read(badge, in.data[1], in.data[2]),
        proto.stream.write => write(badge, in.data[1], in.data[2]),
        proto.stream.set_mode => set_mode(badge, in.data[1]),
        proto.stream.attach => attach(badge, in),
        proto.stream.detach => detach(badge),

        else => -7,

    };

}

fn detach(badge: u64) i64 {

    sessions.close(badge);
    return 0;

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.stream.interface_id;
    out.data[2] = proto.stream.version;

    return 0;

}

// Map the client's shared buffer once; every later read/write passes only offset/length into it.

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const session = sessions.open(badge);

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;

    session.capacity = @intCast(in.data[1]);

    sys.close(in.handles[0].handle) catch {};

    return 0;

}

fn read(badge: u64, offset: u64, capacity: u64) i64 {

    const session = session_for(badge) orelse return -7;
    const span = session_span(badge, offset, capacity) orelse return -7;

    if (session.extra.mode == proto.stream.mode_raw) return read_raw(span);

    return read_cooked(span);

}

// Cooked-mode read: gather one line into the session buffer, echoing as it is typed; one IPC per line.

fn read_cooked(span: []u8) i64 {

    var length: usize = 0;

    while (true) {

        uart_lock.acquire();

        if (receive_pending()) {

            const byte: u8 = @truncate(register(data).*);
            uart_lock.release();

            if (byte == '\r' or byte == '\n') {

                put_text("\n");

                _ = sys.acknowledge(cap.driver.interrupt) catch {};

                return @intCast(length);

            }

            if (byte == 0x7f or byte == 0x08) {

                if (length > 0) {

                    length -= 1;
                    put_text("\x08 \x08");

                }

                continue;

            }

            if (byte >= 0x20 and byte < 0x7f and length < span.len) {

                span[length] = byte;
                length += 1;
                put_byte(byte);

            }

            continue;

        }

        uart_lock.release();

        _ = sys.acknowledge(cap.driver.interrupt) catch {};
        _ = sys.wait(rx_notification) catch return @intCast(length);

    }

}

// Raw-mode read: return one byte per call with no echo.

fn read_raw(span: []u8) i64 {

    if (span.len == 0) return -7;

    while (true) {

        uart_lock.acquire();

        if (receive_pending()) {

            span[0] = @truncate(register(data).*);
            uart_lock.release();

            _ = sys.acknowledge(cap.driver.interrupt) catch {};

            return 1;

        }

        uart_lock.release();

        _ = sys.acknowledge(cap.driver.interrupt) catch {};
        _ = sys.wait(rx_notification) catch return 0;

    }

}

fn write(badge: u64, offset: u64, length: u64) i64 {

    const span = session_span(badge, offset, length) orelse return -7;

    put_text(span);

    return @intCast(span.len);

}

fn set_mode(badge: u64, mode: u64) i64 {

    const session = session_for(badge) orelse return -7;

    if (mode != proto.stream.mode_cooked and mode != proto.stream.mode_raw) return -7;

    session.extra.mode = mode;

    return 0;

}

fn session_span(badge: u64, offset: u64, length: u64) ?[]u8 {

    const session = session_for(badge) orelse return null;

    if (session.base == 0) return null;
    if (offset > session.capacity or length > session.capacity - offset) return null;

    const buffer: [*]u8 = @ptrFromInt(session.base);

    return buffer[@intCast(offset)..@intCast(offset + length)];

}

fn session_for(badge: u64) ?*Session {

    return sessions.find(badge);

}

// Hardware access

fn init_uart() void {

    register(control).* = 0;
    register(interrupt_clear).* = all_interrupts;
    register(line_control).* = word_length_8;
    register(interrupt_mask).* = receive_interrupt;
    register(control).* = enable_uart | enable_transmit | enable_receive;

}

fn receive_pending() bool {

    return register(flags).* & receive_empty == 0;

}

fn put_text(text: []const u8) void {

    for (text) |byte| {

        // Serial terminals expect a carriage return before the line feed.

        if (byte == '\n') put_byte('\r');

        put_byte(byte);

    }

}

fn put_byte(byte: u8) void {

    uart_lock.acquire();

    // PL011 TX is polled; yield while the host chardev drains - a tight spin here blocks the console
    // server's reply and every caller waiting on stream.write (including drivers mid-startup).

    while (register(flags).* & transmit_full != 0) {

        sys.yield();

    }

    register(data).* = byte;

    uart_lock.release();

}

fn register(offset: usize) *volatile u32 {

    return @ptrFromInt(uart + offset);

}
