// ARM generic timer (06-kernel-ddd.md Section 5, Section 16.5): monotonic time and the variable MLFQ deadline. Timer interrupts never become an `Interrupt` object; the trap path routes them straight to the scheduler.

const gic = @import("gic.zig");

// The EL1 physical timer is PPI 14, so its GIC INTID is 16 + 14 (architectural, not board-specific).

pub const interrupt_line: u32 = 30;

var frequency: u64 = 0;

pub fn init() void {

    frequency = asm volatile ("mrs %[out], cntfrq_el0"

        : [out] "=r" (-> u64),

    );

    // Let EL0 read the physical and virtual counters (CNTKCTL_EL1.EL0PCTEN | EL0VCTEN), so user code can time itself
    // (the IPC micro-benchmark) without a syscall. The timer *interrupt* stays kernel-only.

    asm volatile ("msr cntkctl_el1, %[bits]"
        :
        : [bits] "r" (@as(u64, 0b11)),
    );

    gic.enable_line(interrupt_line);

}

pub fn now_ns() u64 {

    const ticks = asm volatile (

        \\ isb
        \\ mrs %[out], cntpct_el0

        : [out] "=r" (-> u64),

    );

    return @intCast(@as(u128, ticks) * 1_000_000_000 / frequency);

}

/// Arm a one-shot deadline; the resulting IRQ is the scheduler tick.
pub fn arm_deadline(ns_from_now: u64) void {

    const ticks: u64 = @intCast(@as(u128, ns_from_now) * frequency / 1_000_000_000);

    asm volatile (

        \\ msr cntp_tval_el0, %[ticks]
        \\ msr cntp_ctl_el0, %[enable]
        \\ isb
        :
        : [ticks] "r" (@max(ticks, 1)),
          [enable] "r" (@as(u64, 1)),

    );

}

/// Silence the (level-triggered) timer so its line drops before the GIC end-of-interrupt.
pub fn stop() void {

    asm volatile (

        \\ msr cntp_ctl_el0, %[disable]
        \\ isb
        :
        : [disable] "r" (@as(u64, 0)),

    );

}
