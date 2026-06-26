// The architecture boundary (06-kernel-ddd.md Section 5): the kernel core imports only `arch`; this re-exports the compile-time impl.

const builtin = @import("builtin");

const types = @import("../types.zig");

comptime {

    if (builtin.cpu.arch != .aarch64) @compileError("GraniteOS: unsupported architecture");

}

const cpu = @import("aarch64/cpu.zig");
const mmu = @import("aarch64/mmu.zig");

pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;
pub const Permissions = mmu.Permissions;

pub const core_id = cpu.core_id;
pub const wait_for_event = cpu.wait_for_event;
pub const enable_interrupts = cpu.enable_interrupts;
pub const disable_interrupts = cpu.disable_interrupts;
pub const halt = cpu.halt;

pub const new_table = mmu.new_table;
pub const map_page = mmu.map_page;
pub const unmap_page = mmu.unmap_page;
pub const translate = mmu.translate;
pub const activate_space = mmu.activate_space;
pub const flush_tlb_page = mmu.flush_tlb_page;
pub const free_table = mmu.free_table;
pub const map_ram = mmu.map_ram;

// Loads in the boot bridge and trap entry so their exported symbols (`kernel_boot`, `kernel_trap`) link against the assembly.

comptime {

    _ = @import("aarch64/boot.zig");
    _ = @import("aarch64/trap.zig");

}
