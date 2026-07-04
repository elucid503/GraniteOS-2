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

// Per-client shared buffers (05-server-protocol.md): attached once, then reused by every read/write. Badges are the
// Session badges; Startup uses 0, Marble uses 1.

const max_sessions = 16;

const Session = struct {

    base: usize = 0,
    capacity: usize = 0,

};

var sessions: [max_sessions]Session = [_]Session{.{}} ** max_sessions;

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

    // The canonical loop, inlined because `read` blocks inside its handler on the RX notification.

    var in = Message.zeroed;

    while (true) {

        const badge = try sys.receive(cap.driver.endpoint, &in);
        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, &in, &out));

        try sys.reply(in.reply, &out);

    }

}

fn dispatch(badge: u64, in: *const Message, out: *Message) i64 {

    return switch (in.data[0]) {

        proto.identify => identify(out),
        proto.stream.read => read(badge, in.data[1], in.data[2]),
        proto.stream.write => write(badge, in.data[1], in.data[2]),
        proto.stream.set_mode => set_mode(in.data[1]),
        proto.stream.attach => attach(badge, in),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.stream.interface_id;
    out.data[2] = proto.stream.version;

    return 0;

}

// Map the client's shared buffer once; every later read/write passes only offset/length into it.

fn attach(badge: u64, in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    const session = session_for(badge) orelse return -7;

    session.base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session.capacity = @intCast(in.data[1]);

    return 0;

}

// Cooked-mode read: gather one line into the session buffer, echoing as it is typed; one IPC per line.

fn read(badge: u64, offset: u64, capacity: u64) i64 {

    const span = session_span(badge, offset, capacity) orelse return -7;

    var length: usize = 0;

    while (true) {

        while (receive_pending()) {

            const byte: u8 = @truncate(register(data).*);

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

        }

        // Nothing buffered: re-arm the line, then sleep until the next RX interrupt.

        _ = sys.acknowledge(cap.driver.interrupt) catch {};
        _ = sys.wait(rx_notification) catch return @intCast(length);

    }

}

fn write(badge: u64, offset: u64, length: u64) i64 {

    const span = session_span(badge, offset, length) orelse return -7;

    put_text(span);

    return @intCast(span.len);

}

// Cooked is all M4 speaks; raw mode arrives with the library LineEditor (M5+).

fn set_mode(mode: u64) i64 {

    if (mode == proto.stream.mode_cooked) return 0;

    return -4; // NotAllowed

}

fn session_span(badge: u64, offset: u64, length: u64) ?[]u8 {

    const session = session_for(badge) orelse return null;

    if (session.base == 0) return null;
    if (offset > session.capacity or length > session.capacity - offset) return null;

    const buffer: [*]u8 = @ptrFromInt(session.base);

    return buffer[@intCast(offset)..@intCast(offset + length)];

}

fn session_for(badge: u64) ?*Session {

    if (badge >= max_sessions) return null;

    return &sessions[@intCast(badge)];

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

    while (register(flags).* & transmit_full != 0) {}

    register(data).* = byte;

}

fn register(offset: usize) *volatile u32 {

    return @ptrFromInt(uart + offset);

}
