// Fallback constants for the QEMU `virt` board (06-kernel-ddd.md Section 16.1); the DTB is the source of truth where it can be.

pub const uart_base: usize = 0x0900_0000; // PL011 UART0 on QEMU `virt`.

// GICv3 windows, used only when the DTB does not describe the interrupt controller.

pub const gic_distributor_base: usize = 0x0800_0000;
pub const gic_redistributor_base: usize = 0x080a_0000;
pub const redistributor_stride: usize = 0x2_0000;