// The architecture boundary (06-kernel-ddd.md Section 5): the kernel core imports only `arch`; this re-exports the compile-time impl. Host `zig test` builds get the stub in host.zig so the core stays testable off-target.

const builtin = @import("builtin");

const types = @import("../types.zig");
const Error = @import("../error.zig").Error;

const is_aarch64 = builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding;
const is_x86_64 = builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding;
const is_target = is_aarch64 or is_x86_64;

comptime {

    if (!is_target and !builtin.is_test) @compileError("GraniteOS: unsupported architecture");

}

const host = @import("host.zig");

const cpu = if (is_aarch64) @import("aarch64/cpu.zig") else if (is_x86_64) @import("x86_64/cpu.zig") else host;
const mmu = if (is_aarch64) @import("aarch64/mmu.zig") else if (is_x86_64) @import("x86_64/mmu.zig") else host;
const context = if (is_aarch64) @import("aarch64/context.zig") else if (is_x86_64) @import("x86_64/context.zig") else host;
const timer = if (is_aarch64) @import("aarch64/timer.zig") else if (is_x86_64) @import("x86_64/timer.zig") else host;
const intctrl = if (is_aarch64) @import("aarch64/gic.zig") else if (is_x86_64) @import("x86_64/apic.zig") else host;
const smp = if (is_aarch64) @import("aarch64/psci.zig") else if (is_x86_64) @import("x86_64/smp.zig") else host;
const trap = if (is_aarch64) @import("aarch64/trap.zig") else if (is_x86_64) @import("x86_64/trap.zig") else host;
const console_arch = if (is_aarch64) @import("aarch64/console.zig") else if (is_x86_64) @import("x86_64/console.zig") else host;

pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;
pub const Permissions = mmu.Permissions;
pub const SyscallFrame = if (is_target) trap.SyscallFrame else host.SyscallFrame;

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
pub const debug_putchar = console_arch.debug_putchar;

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

// Interrupt controller.

pub const intctrl_init_primary = if (is_target) intctrl.init_primary else host.intctrl_init_primary;
pub const intctrl_init_secondary = if (is_target) intctrl.init_secondary else host.intctrl_init_secondary;
pub const intctrl_enable_line = if (is_target) intctrl.enable_line else host.intctrl_enable_line;
pub const intctrl_disable_line = if (is_target) intctrl.disable_line else host.intctrl_disable_line;

// Timer (monotonic; variable quantum for the MLFQ).

pub const timer_init = if (is_target) timer.init else host.timer_init;
pub const timer_init_secondary = if (is_target) timer.init_secondary else host.timer_init_secondary;
pub const now_ns = timer.now_ns;
pub const arm_deadline = timer.arm_deadline;
pub const disarm_deadline = timer.stop;

// Port I/O (x86 only; aarch64 returns NotAllowed).

pub fn port_in(width: u8, port: u16) Error!u32 {

    if (!is_x86_64) return error.NotAllowed;

    return cpu.port_in(width, port);

}

pub fn port_out(width: u8, port: u16, value: u32) Error!void {

    if (!is_x86_64) return error.NotAllowed;

    cpu.port_out(width, port, value);

}

// SMP (06-kernel-ddd.md Section 16.2): secondary bring-up and cross-core pokes.

pub const Ipi = enum {

    reschedule,
    halt,

};

pub const start_core = if (is_target) smp.start_core else host.start_core;

pub fn send_ipi(target_core: u32, kind: Ipi) void {

    if (!is_target) return host.send_ipi(target_core, kind);

    if (is_aarch64) {

        const gic = @import("aarch64/gic.zig");

        switch (kind) {

            .reschedule => gic.send_sgi(target_core, gic.sgi_reschedule),
            .halt => gic.send_sgi(target_core, gic.sgi_halt),

        }

        return;

    }

    const apic = @import("x86_64/apic.zig");

    switch (kind) {

        .reschedule => apic.send_ipi(target_core, apic.vector_reschedule),
        .halt => apic.send_ipi(target_core, apic.vector_halt),

    }

}

/// Stop every other core (the panic path); a no-op before the interrupt controller is up.
pub fn halt_others() void {

    if (!is_target) return host.halt_others();

    if (is_aarch64) {

        @import("aarch64/gic.zig").send_sgi_others(@import("aarch64/gic.zig").sgi_halt);
        return;

    }

    @import("x86_64/apic.zig").send_ipi_others(@import("x86_64/apic.zig").vector_halt);

}

// Loads in the boot bridge and trap entry so their exported symbols link against the assembly.

comptime {

    if (is_aarch64) {

        _ = @import("aarch64/boot.zig");
        _ = @import("aarch64/trap.zig");

    } else if (is_x86_64) {

        _ = @import("x86_64/boot.zig");
        _ = @import("x86_64/trap.zig");

    }

}
