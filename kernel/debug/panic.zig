// The kernel panic path (06-kernel-ddd.md Section 14): print a diagnostic over the debug console and stop the machine — no recovery.

const console = @import("console.zig");
const arch = @import("../arch/arch.zig");

/// What the trap path knows about a hardware fault. `null` for a software panic.
pub const FaultInfo = struct {

    esr: u64, // exception syndrome (cause + details)
    elr: u64, // address of the faulting instruction
    far: u64, // faulting virtual address (for aborts)
    spsr: u64, // saved processor state

};

/// The core panic. Prints the message, optional fault registers, and halts.
pub fn panic(message: []const u8, fault_info: ?FaultInfo) noreturn {

    console.debug_print("\n\n*** KERNEL PANIC ***\n");
    console.debug_print(message);
    console.debug_putchar('\n');

    if (fault_info) |info| {

        console.debug_print("  ESR_EL1  = ");
        console.debug_print_hex(info.esr);
        console.debug_print("\n  ELR_EL1  = ");
        console.debug_print_hex(info.elr);
        console.debug_print("\n  FAR_EL1  = ");
        console.debug_print_hex(info.far);
        console.debug_print("\n  SPSR_EL1 = ");
        console.debug_print_hex(info.spsr);
        console.debug_putchar('\n');

    }

    console.debug_print("halted.\n");

    arch.halt();

}

/// Convenience wrapper for the trap path; keeps the `?FaultInfo` argument tidy.
pub fn fault(message: []const u8, info: FaultInfo) noreturn {

    panic(message, info);

}

/// The signature `std.debug.FullPanic` calls for language-level panics (bounds checks, reached-unreachable, and friends).
pub fn at(message: []const u8, _: ?usize) noreturn {

    panic(message, null);

}
