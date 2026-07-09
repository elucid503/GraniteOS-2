// Fallback constants for the QEMU `q35`/`pc` board (06-kernel-ddd.md Section 16.1).

pub const com1_port: u16 = 0x3f8;
pub const com1_irq: u32 = 4;

// Default Local APIC and I/O APIC windows on PC-class machines (overridden when discovery provides them).

pub const lapic_base: usize = 0xfee0_0000;
pub const ioapic_base: usize = 0xfec0_0000;
