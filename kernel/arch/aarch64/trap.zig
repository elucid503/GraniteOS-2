// aarch64 trap entry: kernel-level IRQs feed the scheduler tick; any other exception is still unexpected, so report it and halt (06-kernel-ddd.md Section 12 grows this into syscall dispatch).

const panic = @import("../../debug/panic.zig");

const gic = @import("gic.zig");
const timer = @import("timer.zig");
const scheduler = @import("../../sched/scheduler.zig");

/// The register frame `trap_common` lays on the stack; field order and the trailing pad word must match the assembly.
pub const TrapFrame = extern struct {

    registers: [31]u64, // x0..x30
    reserved: u64,
    elr: u64, // faulting instruction address
    spsr: u64,
    esr: u64, // exception syndrome
    far: u64, // faulting virtual address

};

// Kernel IRQ flow (06-kernel-ddd.md Section 7.4): claim, quiet the source, end-of-interrupt, then act.
// The timer never becomes an `Interrupt` object - it goes straight to the scheduler, which may switch contexts here; the end-of-interrupt must land first so the next tick can be delivered.

export fn kernel_irq() callconv(.c) void {

    const irq = gic.claim() orelse return;

    if (irq == timer.interrupt_line) {

        timer.stop();
        gic.complete(irq);
        scheduler.tick();

    } else {

        gic.complete(irq);

    }

}

export fn kernel_trap(frame: *const TrapFrame) callconv(.c) noreturn {

    panic.fault("unhandled exception", .{

        .esr = frame.esr,
        .elr = frame.elr,
        .far = frame.far,
        .spsr = frame.spsr,

    });

}
