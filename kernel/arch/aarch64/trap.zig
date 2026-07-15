// aarch64 trap entry: kernel-level IRQs feed the scheduler tick; any other exception is still unexpected, so report it and halt (06-kernel-ddd.md Section 12 grows this into syscall dispatch).

const panic = @import("../../debug/panic.zig");

const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const context = @import("context.zig");
const interrupt_module = @import("../../object/interrupt.zig");
const scheduler = @import("../../sched/scheduler.zig");
const syscall = @import("../../syscall/syscall.zig");

/// The register frame `trap_common` lays on the stack; field order and the trailing pad word must match the assembly.
pub const TrapFrame = extern struct {

    registers: [31]u64, // x0..x30
    reserved: u64,
    elr: u64, // faulting instruction address
    spsr: u64,
    esr: u64, // exception syndrome
    far: u64, // faulting virtual address

};

/// The register frame `svc_common` lays on the stack for an EL0 system call; field order must match the assembly.
pub const SyscallFrame = extern struct {

    registers: [31]u64, // x0..x30
    elr: u64, // instruction after the svc
    spsr: u64,
    reserved: u64,

};

// Kernel IRQ flow (06-kernel-ddd.md Section 7.4): claim, quiet the source, end-of-interrupt, then act.

export fn kernel_irq() callconv(.c) void {

    const irq = gic.claim() orelse return;

    if (irq == timer.interrupt_line) {

        timer.stop();
        gic.complete(irq);
        scheduler.tick();

    } else if (irq < gic.first_sgi_boundary) {

        gic.complete(irq);

        // Halt IPI parks this core after a peer panic; reschedule IPI runs `tick` to pick up fresh or stealable work.

        if (irq == gic.sgi_halt) cpu.park();

        scheduler.tick();

    } else if (interrupt_module.find(irq)) |device| {

        // Mask before EOI so level-triggered lines cannot storm; driver IRQ only owes driver-band preemption, not a full MLFQ tick.

        device.fire();
        gic.complete(irq);
        scheduler.driver_preempt();

    } else {

        gic.complete(irq);

    }

}

// EL0 system-call entry (06-kernel-ddd.md Section 12): hand the saved frame to the arch-independent dispatch, which unpacks the verb and arguments and writes the result back into the frame.

export fn kernel_syscall(frame: *SyscallFrame) callconv(.c) void {

    syscall.dispatch(frame);

}

// First EL0 FP/SIMD use: flag the thread, open CPACR, return its context so `fp_common` can load the vector file and retry.

export fn kernel_fp_trap() callconv(.c) *context.Context {

    const thread = scheduler.current_core().current.?;

    thread.context.used_fp = 1;
    cpu.enable_fp_el0();

    return &thread.context;

}

export fn kernel_trap(frame: *const TrapFrame) callconv(.c) noreturn {

    // A userspace fault retires only its thread; EL1 faults still expose kernel corruption.
    if (frame.spsr & 0xf == 0) scheduler.exit_current();

    panic.fault("unhandled exception", .{

        .esr = frame.esr,
        .elr = frame.elr,
        .far = frame.far,
        .spsr = frame.spsr,

    });

}
