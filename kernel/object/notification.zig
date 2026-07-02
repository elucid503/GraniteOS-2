// Notification (06-kernel-ddd.md Section 7.3): an asynchronous wakeup carrying a word of flag bits. `notify` ORs bits
// and wakes a waiter; `wait` returns and clears the accumulated bits. Binding to a thread for multi-wait is M5.

const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
const scheduler = @import("../sched/scheduler.zig");
const runqueue = @import("../sched/runqueue.zig");

const Thread = @import("thread.zig").Thread;
const Error = @import("../error.zig").Error;

var cache: slab.Cache(Notification) = .{};

pub const Notification = struct {

    header: object.Object,

    bits: u64,
    waiters: runqueue.RunQueue,

    // Multi-wait (M5): a notification bound to a thread also wakes it out of receive.
    bound_to: ?*Thread,

    pub fn create() Error!*Notification {

        const notification = try cache.alloc();
        notification.* = .{

            .header = .{ .kind = .notification },

            .bits = 0,
            .waiters = .{},

            .bound_to = null,

        };

        return notification;

    }

    pub fn destroy(self: *Notification) void {

        cache.free(self);

    }

    /// Signal: accumulate `bits` and wake one waiter with the whole set (never blocks).
    pub fn signal(self: *Notification, bits: u64) void {

        self.bits |= bits;

        if (self.waiters.pop()) |waiter| {

            waiter.notify_bits = self.bits;
            self.bits = 0;

            scheduler.unblock(scheduler.current_core(), waiter);

        }

    }

    /// Wait: take the accumulated bits if any, otherwise park `by` on this notification and return null.
    pub fn poll_or_block(self: *Notification, by: *Thread) ?u64 {

        if (self.bits != 0) {

            const bits = self.bits;
            self.bits = 0;
            return bits;

        }

        by.state = .blocked_notify;
        self.waiters.push(by);

        return null;

    }

};

pub fn init() void {

    cache.init();

}
