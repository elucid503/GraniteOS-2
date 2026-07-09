// Panic-only 16550 UART over COM1 for QEMU `pc`/`q35`.

const board = @import("../board/pc.zig");
const cpu = @import("cpu.zig");

const line_status = 5;
const transmit_empty: u8 = 1 << 5;

pub fn debug_putchar(byte: u8) void {

    while (cpu.port_in(1, board.com1_port + line_status) & transmit_empty == 0) {}

    cpu.port_out(1, board.com1_port, byte);

}

pub fn init() void {

    // 115200 baud, 8N1, FIFO on - enough for QEMU's chardev.
    cpu.port_out(1, board.com1_port + 1, 0x00);
    cpu.port_out(1, board.com1_port + 3, 0x80);
    cpu.port_out(1, board.com1_port + 0, 0x01);
    cpu.port_out(1, board.com1_port + 1, 0x00);
    cpu.port_out(1, board.com1_port + 3, 0x03);
    cpu.port_out(1, board.com1_port + 2, 0xc7);
    cpu.port_out(1, board.com1_port + 4, 0x0b);
    cpu.port_out(1, board.com1_port + 1, 0x01);

}
