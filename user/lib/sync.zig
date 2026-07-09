// Thread synchronization for user programs: a notification-parked mutex. Uncontended acquire is one atomic;
// under contention a thread spins briefly, then parks in `wait` so it consumes no CPU until the holder releases.

const cap = @import("cap/cap.zig");
const sys = @import("syscall/sys.zig");

const Handle = cap.Handle;

const spin_limit = 40;

pub const Mutex = struct {

    // 0 = unlocked, 1 = locked, 2 = locked with a (possible) parked waiter.
    state: u32 = 0,

    // The parking notification is created on first contention; 0/1/2 = none/creating/ready.
    guard: u32 = 0,
    parking: Handle = 0,

    pub fn acquire(self: *Mutex) void {

        if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;

        self.ensure_parking();

        var spins: u32 = 0;

        while (true) {

            // Grab marking the lock contended, so the eventual release signals the parking notification.

            if (@atomicRmw(u32, &self.state, .Xchg, 2, .acquire) == 0) return;

            if (spins < spin_limit) {

                spins += 1;
                sys.yield();

                continue;

            }

            _ = sys.wait(self.parking) catch sys.yield();

        }

    }

    pub fn release(self: *Mutex) void {

        if (@atomicRmw(u32, &self.state, .Xchg, 0, .release) == 2) {

            sys.notify(self.parking, 1) catch {};

        }

    }

    // If the notification cannot be created the mutex degrades to a yield lock (wait on handle 0 fails into the
    // catch above), so acquire never gets stuck on an allocation failure.

    fn ensure_parking(self: *Mutex) void {

        if (@atomicLoad(u32, &self.guard, .acquire) == 2) return;

        if (@cmpxchgStrong(u32, &self.guard, 0, 1, .acquire, .monotonic) == null) {

            self.parking = sys.create(.notification, 0, 0) catch 0;

            @atomicStore(u32, &self.guard, 2, .release);

            return;

        }

        while (@atomicLoad(u32, &self.guard, .acquire) != 2) sys.yield();

    }

};
