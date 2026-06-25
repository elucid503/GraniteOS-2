// The architecture boundary (06-kernel-ddd.md Section 5): the kernel core imports only `arch`; this re-exports the compile-time impl.

const builtin = @import("builtin");

pub const PhysAddr = usize;
pub const VirtAddr = usize;

const impl = switch (builtin.cpu.arch) {

    .aarch64 => @import("aarch64/cpu.zig"),
    else => @compileError("GraniteOS: unsupported architecture"),

};

pub const core_id = impl.core_id;
pub const wait_for_event = impl.wait_for_event;
pub const enable_interrupts = impl.enable_interrupts;
pub const disable_interrupts = impl.disable_interrupts;
pub const halt = impl.halt;

// Loads in the boot bridge and trap entry so their exported symbols (`kernel_boot`, `kernel_trap`) link against the assembly.

comptime {

    if (builtin.cpu.arch == .aarch64) {

        _ = @import("aarch64/boot.zig");
        _ = @import("aarch64/trap.zig");

    }

}
