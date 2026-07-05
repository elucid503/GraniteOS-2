// The kernel-wide IPC/object lock (06-kernel-ddd.md Section 15): guards endpoint and notification wait queues, thread
// IPC state, and the per-process thread lists. Always ordered before the per-core runqueue and handle-table locks;
// never held across a context switch - blockers queue themselves, release, then call into the scheduler.

const spinlock = @import("spinlock.zig");

pub var lock: spinlock.SpinLock = .{};
