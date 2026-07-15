// Lock pairs by address; never hold object locks across a context switch.

const spinlock = @import("spinlock.zig");

pub fn lock_pair(a: *spinlock.SpinLock, b: *spinlock.SpinLock) void {

    if (a == b) {

        a.lock();
        return;

    }

    if (@intFromPtr(a) < @intFromPtr(b)) {

        a.lock();
        b.lock();

    } else {

        b.lock();
        a.lock();

    }

}

pub fn unlock_pair(a: *spinlock.SpinLock, b: *spinlock.SpinLock) void {

    if (a == b) {

        a.unlock();
        return;

    }

    if (@intFromPtr(a) < @intFromPtr(b)) {

        b.unlock();
        a.unlock();

    } else {

        a.unlock();
        b.unlock();

    }

}
