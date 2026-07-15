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
const psci = if (is_target) @import("aarch64/psci.zig") else host;

pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;
pub const Permissions = mmu.Permissions;

// CPU control.

pub const InterruptState = cpu.InterruptState;

pub const core_id = cpu.core_id;
pub const wait_for_event = cpu.wait_for_event;
pub const wait_for_interrupt = cpu.wait_for_interrupt;
pub const send_event = cpu.send_event;
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
pub const map_range = mmu.map_range;
pub const unmap_range = mmu.unmap_range;
pub const translate = mmu.translate;
pub const activate_space = mmu.activate_space;
pub const flush_tlb_page = mmu.flush_tlb_page;
pub const free_table = mmu.free_table;
pub const map_ram = mmu.map_ram;

// ASIDs (Stage 1.4): per-AddressSpace tags so a process switch skips the full TLB flush.

pub const ensure_space_asid = if (is_target) mmu.ensure_space_asid else host.ensure_space_asid;
pub const asid_generation = if (is_target) mmu.asid_generation else host.asid_generation;
pub const tlb_flush_local = if (is_target) mmu.tlb_flush_local else host.tlb_flush_local;

// Interrupt controller (GICv3).

pub const intctrl_init_primary = if (is_target) gic.init_primary else host.intctrl_init_primary;
pub const intctrl_init_secondary = if (is_target) gic.init_secondary else host.intctrl_init_secondary;
pub const intctrl_enable_line = if (is_target) gic.enable_line else host.intctrl_enable_line;
pub const intctrl_disable_line = if (is_target) gic.disable_line else host.intctrl_disable_line;

// Timer (monotonic; variable quantum for the MLFQ).

pub const timer_init = if (is_target) timer.init else host.timer_init;
pub const timer_init_secondary = if (is_target) timer.init_secondary else host.timer_init_secondary;
pub const now_ns = timer.now_ns;
pub const arm_deadline = timer.arm_deadline;
pub const disarm_deadline = timer.stop;

// SMP bring-up and IPIs; cross-core TLB shootdown needs no call here because aarch64 TLBI is inner-shareable.

pub const Ipi = enum {

    reschedule,
    halt,

};

pub const start_core = if (is_target) psci.start_core else host.start_core;

pub fn send_ipi(target_core: u32, kind: Ipi) void {

    if (!is_target) return host.send_ipi(target_core, kind);

    switch (kind) {

        .reschedule => gic.send_sgi(target_core, gic.sgi_reschedule),
        .halt => gic.send_sgi(target_core, gic.sgi_halt),

    }

}

/// Stop every other core (the panic path); a no-op before the interrupt controller is up.
pub fn halt_others() void {

    if (!is_target) return host.halt_others();

    gic.send_sgi_others(gic.sgi_halt);

}

// Loads in the boot bridge and trap entry so their exported symbols (`kernel_boot`, `kernel_trap`) link against the assembly.

comptime {

    if (is_target) {

        _ = @import("aarch64/boot.zig");
        _ = @import("aarch64/trap.zig");

    }

}
