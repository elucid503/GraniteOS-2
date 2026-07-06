// Monotonic time for user programs. The kernel enables EL0 access to the ARM generic timer counters
// (kernel/arch/aarch64/timer.zig sets CNTKCTL_EL1.EL0PCTEN|EL0VCTEN), so a program reads wall-clock time with no
// syscall - which is what lets the GUI drive realtime charts and periodic refreshes without a timer interrupt.

const builtin = @import("builtin");

const sys = @import("syscall/sys.zig");

/// Nanoseconds since boot, from the physical counter (CNTPCT_EL0) scaled by its frequency (CNTFRQ_EL0).
pub fn now_ns() u64 {

    if (comptime builtin.target.cpu.arch != .aarch64) return 0;

    const frequency = asm volatile ("mrs %[out], cntfrq_el0"
        : [out] "=r" (-> u64),
    );

    const ticks = asm volatile (
        \\ isb
        \\ mrs %[out], cntpct_el0
        : [out] "=r" (-> u64),
    );

    if (frequency == 0) return 0;

    return @intCast(@as(u128, ticks) * 1_000_000_000 / frequency);

}

pub fn now_ms() u64 {

    return now_ns() / 1_000_000;

}

/// Block this thread for `duration_ms`, consuming no CPU (the kernel wakes it off the generic timer). Use it to pace
/// periodic work - a chart ticker, a respawn backoff - on a dedicated worker thread.
pub fn sleep_ms(duration_ms: u64) void {

    sys.sleep(duration_ms * 1_000_000);

}
