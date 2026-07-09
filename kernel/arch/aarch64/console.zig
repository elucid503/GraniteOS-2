// Panic-only PL011 UART for QEMU `virt` (06-kernel-ddd.md Section 14).

const board = @import("../board/virt.zig");

const data_register = 0x00;
const flag_register = 0x18;
const transmit_fifo_full = 1 << 5;

fn register(offset: usize) *volatile u32 {

    return @ptrFromInt(board.uart_base + offset);

}

pub fn debug_putchar(byte: u8) void {

    const flags = register(flag_register);

    while (flags.* & transmit_fifo_full != 0) {}

    register(data_register).* = byte;

}
