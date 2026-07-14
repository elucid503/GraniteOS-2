// Monotonic time for user programs.

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

/// Block this thread for `duration_ms`, consuming no CPU (the kernel wakes it off the generic timer).
pub fn sleep_ms(duration_ms: u64) void {

    sys.sleep(duration_ms * 1_000_000);

}
