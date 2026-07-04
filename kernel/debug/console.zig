// Panic-only debug console over the PL011 UART (06-kernel-ddd.md Section 14): polled, not a service - the real console is a user driver.

const board = @import("../arch/board/virt.zig");

const data_register = 0x00; // DR: write a byte to transmit
const flag_register = 0x18; // FR
const transmit_fifo_full = 1 << 5; // FR.TXFF

fn register(offset: usize) *volatile u32 {

    return @ptrFromInt(board.uart_base + offset);

}

pub fn debug_putchar(byte: u8) void {

    const flags = register(flag_register);

    while (flags.* & transmit_fifo_full != 0) {}

    register(data_register).* = byte;

}

pub fn debug_print(text: []const u8) void {

    for (text) |byte| {

        // Serial terminals expect a carriage return before the line feed.

        if (byte == '\n') {

            debug_putchar('\r');

        }

        debug_putchar(byte);

    }

}

pub fn debug_print_dec(value: u64) void {

    var buffer: [20]u8 = undefined;
    var length: usize = 0;
    var remaining = value;

    if (remaining == 0) {

        debug_putchar('0');
        return;

    }

    while (remaining > 0) {

        buffer[length] = @intCast('0' + (remaining % 10));
        length += 1;
        remaining /= 10;

    }

    while (length > 0) {

        length -= 1;
        debug_putchar(buffer[length]);

    }

}

/// Print a 64-bit value as `0x`-prefixed, zero-padded hex - the one number format the fault diagnostics need.
pub fn debug_print_hex(value: u64) void {

    const digits = "0123456789abcdef";

    debug_print("0x");

    var shift: u6 = 60;

    while (true) : (shift -= 4) {

        const nibble: usize = @intCast((value >> shift) & 0xf);
        debug_putchar(digits[nibble]);

        if (shift == 0) {

            break;

        }

    }

}
