// PL011 console driver (07-userspace-ddd.md Section 5.1): an ordinary process holding only its MMIO window, its Interrupt, and an Endpoint. RX is interrupt-driven - the driver binds its line to a Notification and blocks in `wait`, never spinning. Serves the Stream interface in cooked mode: buffered lines, echo, backspace.

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

const Handle = cap.Handle;
const Message = ipc.Message;

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

// The per-session shared buffer (05-server-protocol.md): attached once, then reused by every read/write.

var session_base: usize = 0;
var session_capacity: usize = 0;

pub fn main(_: u64) callconv(.c) noreturn {

    run() catch {};

    lib.start.exit();

}

fn run() !void {

    // Drivers live in the fixed band above the MLFQ so an interrupt wake runs promptly.

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    uart = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);

    rx_notification = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, rx_notification, rx_bit);

    init_uart();

    put_text("console: driver up\n");

    // The canonical loop, inlined because `read` blocks inside its handler on the RX notification.

    var in = Message.zeroed;

    while (true) {

        _ = try sys.receive(cap.driver.endpoint, &in);

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(&in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

fn dispatch(in: *const Message, out: *Message) i64 {

    return switch (in.data[0]) {

        proto.identify => identify(out),
        proto.stream.read => read(in.data[1], in.data[2]),
        proto.stream.write => write(in.data[1], in.data[2]),
        proto.stream.set_mode => set_mode(in.data[1]),
        proto.stream.attach => attach(in),

        else => -7, // Invalid: servers reuse the shared codes (05-server-protocol.md)

    };

}

fn identify(out: *Message) i64 {

    out.data[1] = proto.stream.interface_id;
    out.data[2] = proto.stream.version;

    return 0;

}

// Map the client's shared buffer once; every later read/write passes only offset/length into it.

fn attach(in: *const Message) i64 {

    if (in.handle_count < 1) return -7;

    session_base = sys.map(cap.self_space, in.handles[0].handle, 0, sys.read | sys.write) catch return -7;
    session_capacity = @intCast(in.data[1]);

    return 0;

}

// Cooked-mode read: gather one line into the session buffer, echoing as it is typed; one IPC per line.

fn read(offset: u64, capacity: u64) i64 {

    const span = session_span(offset, capacity) orelse return -7;

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

fn write(offset: u64, length: u64) i64 {

    const span = session_span(offset, length) orelse return -7;

    put_text(span);

    return @intCast(span.len);

}

// Cooked is all M4 speaks; raw mode arrives with the library LineEditor (M5+).

fn set_mode(mode: u64) i64 {

    if (mode == proto.stream.mode_cooked) return 0;

    return -4; // NotAllowed

}

fn session_span(offset: u64, length: u64) ?[]u8 {

    if (session_base == 0) return null;
    if (offset > session_capacity or length > session_capacity - offset) return null;

    const buffer: [*]u8 = @ptrFromInt(session_base);

    return buffer[@intCast(offset)..@intCast(offset + length)];

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
