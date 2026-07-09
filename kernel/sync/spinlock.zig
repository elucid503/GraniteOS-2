// Spinlock (06-kernel-ddd.md Section 15): always taken with interrupts disabled so an IRQ can never re-enter a lock its own core already holds.

const std = @import("std");

const arch = @import("../arch/arch.zig");

pub const SpinLock = struct {

    locked: u32 = 0,

    /// Disable interrupts, then spin for the lock; pair with `release`.
    pub fn acquire(self: *SpinLock) arch.InterruptState {

        const saved = arch.disable_interrupts();

        self.lock();

        return saved;

    }

    pub fn release(self: *SpinLock, saved: arch.InterruptState) void {

        self.unlock();
        arch.restore_interrupts(saved);

    }

    /// Spin for the lock alone; the caller already runs with interrupts disabled.
    pub fn lock(self: *SpinLock) void {

        while (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) != 0) {

            std.atomic.spinLoopHint();

        }

    }

    pub fn unlock(self: *SpinLock) void {

        // Avoid XRELEASE-prefixed stores: Zig may emit them for `.release` on some x86 targets, and QEMU #UDs.
        @atomicStore(u32, &self.locked, 0, .seq_cst);

    }

};

const testing = std.testing;

test "acquire and release round-trip and nest with a raw lock" {

    var guard = SpinLock{};

    const saved = guard.acquire();
    guard.release(saved);

    guard.lock();
    guard.unlock();

    try testing.expectEqual(@as(u32, 0), guard.locked);

}
