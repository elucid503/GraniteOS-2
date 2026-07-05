// The architecture boundary (06-kernel-ddd.md Section 5): the kernel core imports only `arch`; this re-exports the compile-time impl. Host `zig test` builds get the stub in host.zig so the core stays testable off-target.

const builtin = @import("builtin");

const types = @import("../types.zig");

const is_target = builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding;

comptime {

    if (!is_target and !builtin.is_test) @compileError("GraniteOS: unsupported architecture");

}

const host = @import("host.zig");

const cpu = if (is_target) @import("aarch64/cpu.zig") else host;
const mmu = if (is_target) @import("aarch64/mmu.zig") else host;
const context = if (is_target) @import("aarch64/context.zig") else host;
const timer = if (is_target) @import("aarch64/timer.zig") else host;
const gic = if (is_target) @import("aarch64/gic.zig") else host;

pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;
pub const Permissions = mmu.Permissions;

// CPU control.

pub const InterruptState = cpu.InterruptState;

pub const core_id = cpu.core_id;
pub const wait_for_event = cpu.wait_for_event;
pub const enable_interrupts = cpu.enable_interrupts;
pub const disable_interrupts = cpu.disable_interrupts;
pub const restore_interrupts = cpu.restore_interrupts;
pub const sync_instruction_cache = cpu.sync_instruction_cache;
pub const clean_invalidate_data_cache = cpu.clean_invalidate_data_cache;
pub const halt = cpu.halt;

// Thread context.

pub const Context = context.Context;

pub const switch_context = context.switch_context;
pub const init_thread_context = context.init_thread_context;
pub const init_user_thread_context = context.init_user_thread_context;

// MMU.

pub const new_table = mmu.new_table;
pub const map_page = mmu.map_page;
pub const unmap_page = mmu.unmap_page;
pub const translate = mmu.translate;
pub const activate_space = mmu.activate_space;
pub const flush_tlb_page = mmu.flush_tlb_page;
pub const free_table = mmu.free_table;
pub const map_ram = mmu.map_ram;

// Interrupt controller (GICv2 now; GICv3 is a sibling impl).

pub const intctrl_init_primary = if (is_target) gic.init_primary else host.intctrl_init_primary;
pub const intctrl_enable_line = if (is_target) gic.enable_line else host.intctrl_enable_line;
pub const intctrl_disable_line = if (is_target) gic.disable_line else host.intctrl_disable_line;

// Timer (monotonic; variable quantum for the MLFQ).

pub const timer_init = if (is_target) timer.init else host.timer_init;
pub const now_ns = timer.now_ns;
pub const arm_deadline = timer.arm_deadline;

// Loads in the boot bridge and trap entry so their exported symbols (`kernel_boot`, `kernel_trap`) link against the assembly.

comptime {

    if (is_target) {

        _ = @import("aarch64/boot.zig");
        _ = @import("aarch64/trap.zig");

    }

}
