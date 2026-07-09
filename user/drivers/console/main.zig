// Console driver (07-userspace-ddd.md Section 5.1): PL011 (MMIO) or 16550 (port I/O). RX is interrupt-driven.

const builtin = @import("builtin");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;
const platform = lib.platform;

const Handle = cap.Handle;
const Message = ipc.Message;

comptime {

    _ = lib.start;

}

// PL011 registers (offsets from the mapped window).

const pl011_data = 0x00;
const pl011_flags = 0x18;
const pl011_line_control = 0x2c;
const pl011_control = 0x30;
const pl011_interrupt_mask = 0x38;
const pl011_interrupt_clear = 0x44;

const pl011_receive_empty: u32 = 1 << 4;
const pl011_transmit_full: u32 = 1 << 5;
const pl011_word_length_8: u32 = 0b11 << 5;
const pl011_enable_uart: u32 = 1;
const pl011_enable_transmit: u32 = 1 << 8;
const pl011_enable_receive: u32 = 1 << 9;
const pl011_receive_interrupt: u32 = 1 << 4;
const pl011_all_interrupts: u32 = 0x7ff;

// 16550 port offsets from the I/O base.

const uart_data: u16 = 0;
const uart_ier: u16 = 1;
const uart_fcr: u16 = 2;
const uart_lcr: u16 = 3;
const uart_mcr: u16 = 4;
const uart_lsr: u16 = 5;

const lsr_data_ready: u8 = 1 << 0;
const lsr_transmit_empty: u8 = 1 << 5;
const ier_received_data: u8 = 1 << 0;

const rx_bit: u64 = 1;

var uart_kind: platform.UartKind = .pl011;
var uart_mmio: usize = 0;
var uart_port: u16 = 0;
var rx_notification: Handle = 0;
var uart_lock: ipc.Lock = .{};

const max_sessions = 16;

const Mode = struct {

    mode: u64 = proto.stream.mode_cooked,

};

const Sessions = lib.session.Sessions(Mode, max_sessions);
const Session = Sessions.Session;

var sessions: Sessions = .{};

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        put_text("console: fatal ");
        put_text(@errorName(failure));
        put_text("\n");

        return 1;

    };

    return 0;

}

fn run() !void {

    try sys.configure(cap.self_thread, .scheduling_class, cap.class_driver);

    const kind_raw = lib.start.word(3);
    const base = lib.start.word(4);

    uart_kind = std.meta.intToEnum(platform.UartKind, @as(u32, @truncate(kind_raw))) catch .pl011;

    if (uart_kind == .uart16550) {

        uart_port = @intCast(base);

    } else {

        uart_mmio = try sys.map(cap.self_space, cap.driver.device, 0, sys.read | sys.write);

    }

    rx_notification = try sys.create(.notification, 0, 0);
    try sys.bind(cap.driver.interrupt, rx_notification, rx_bit);

    init_uart();

    if (uart_kind == .uart16550) {

        put_text("Console: 16550 driver ... Loaded\n");

    } else {

        put_text("Console: PL011 driver ... Loaded\n");

    }

    ipc.serve_pool(cap.driver.endpoint, 2, dispatch);

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

fn read_cooked(span: []u8) i64 {

    var length: usize = 0;

    while (true) {

        uart_lock.acquire();

        if (receive_pending()) {

            const byte = read_byte();
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

fn read_raw(span: []u8) i64 {

    if (span.len == 0) return -7;

    while (true) {

        uart_lock.acquire();

        if (receive_pending()) {

            span[0] = read_byte();
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

fn init_uart() void {

    if (uart_kind == .uart16550) {

        sys.port_out(1, uart_port + uart_ier, 0) catch {};
        sys.port_out(1, uart_port + uart_lcr, 0x80) catch {};
        sys.port_out(1, uart_port + uart_data, 0x01) catch {};
        sys.port_out(1, uart_port + uart_ier, 0x00) catch {};
        sys.port_out(1, uart_port + uart_lcr, 0x03) catch {};
        sys.port_out(1, uart_port + uart_fcr, 0xc7) catch {};
        sys.port_out(1, uart_port + uart_mcr, 0x0b) catch {};
        sys.port_out(1, uart_port + uart_ier, ier_received_data) catch {};
        return;

    }

    register(pl011_control).* = 0;
    register(pl011_interrupt_clear).* = pl011_all_interrupts;
    register(pl011_line_control).* = pl011_word_length_8;
    register(pl011_interrupt_mask).* = pl011_receive_interrupt;
    register(pl011_control).* = pl011_enable_uart | pl011_enable_transmit | pl011_enable_receive;

}

fn receive_pending() bool {

    if (uart_kind == .uart16550) {

        const status = sys.port_in(1, uart_port + uart_lsr) catch return false;
        return status & lsr_data_ready != 0;

    }

    return register(pl011_flags).* & pl011_receive_empty == 0;

}

fn read_byte() u8 {

    if (uart_kind == .uart16550) {

        return @truncate(sys.port_in(1, uart_port + uart_data) catch 0);

    }

    return @truncate(register(pl011_data).*);

}

fn put_text(text: []const u8) void {

    for (text) |byte| {

        if (byte == '\n') put_byte('\r');

        put_byte(byte);

    }

}

fn put_byte(byte: u8) void {

    uart_lock.acquire();

    if (uart_kind == .uart16550) {

        while (true) {

            const status = sys.port_in(1, uart_port + uart_lsr) catch break;

            if (status & lsr_transmit_empty != 0) break;

            sys.yield();

        }

        sys.port_out(1, uart_port + uart_data, byte) catch {};

    } else {

        while (register(pl011_flags).* & pl011_transmit_full != 0) {

            sys.yield();

        }

        register(pl011_data).* = byte;

    }

    uart_lock.release();

}

fn register(offset: usize) *volatile u32 {

    return @ptrFromInt(uart_mmio + offset);

}

const std = @import("std");
