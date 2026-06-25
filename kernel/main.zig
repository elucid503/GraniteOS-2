// Kernel entry, reached after the arch layer enables the MMU (06-kernel-ddd.md Section 3): M0 prints a banner then faults on purpose.

const std = @import("std");

const arch = @import("arch/arch.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

// Route language-level panics through the kernel panic path.
pub const panic = std.debug.FullPanic(panic_path.at);

const banner = "GraniteOS-2 (aarch64 virt)";

pub fn main(dtb: arch.PhysAddr) noreturn {

    console.debug_print(banner);

    console.debug_print("device tree at ");
    console.debug_print_hex(dtb);
    console.debug_print("\nboot core ");
    console.debug_print_hex(arch.core_id());
    console.debug_putchar('\n');

    // debug for M0. can be removed, obviously

    console.debug_print("\nM0: triggering a fault to test the trap path...\n");
    trigger_deliberate_fault();

}

// Write through a pointer above the identity-mapped 4 GiB: an absent address, so the MMU raises a translation fault.
fn trigger_deliberate_fault() noreturn {

    const unmapped: *volatile u64 = @ptrFromInt(0x0000_ffff_dead_0000);
    unmapped.* = 0;

    unreachable;

}
