// Fallback constants for the QEMU `virt` board (06-kernel-ddd.md Section 16.1); for M0 just the panic UART, needed before DTB parsing.

pub const uart_base: usize = 0x0900_0000; // PL011 UART0 on QEMU `virt`.
