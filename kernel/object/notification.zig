// Notification (06-kernel-ddd.md Section 7.3): an asynchronous wakeup carrying a word of flag bits. `notify` ORs bits and wakes a waiter; `wait` returns and clears the accumulated bits.

const slab = @import("../memory/slab.zig");
const arch = @import("../arch/arch.zig");
const object = @import("object.zig");
const scheduler = @import("../sched/scheduler.zig");
const runqueue = @import("../sched/runqueue.zig");

const Thread = @import("thread.zig").Thread;
const Endpoint = @import("endpoint.zig").Endpoint;
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

        const saved = arch.disable_interrupts();
        defer arch.restore_interrupts(saved);

        self.bits |= bits;

        // A thread parked in `wait` takes the bits directly.

        if (self.waiters.pop()) |waiter| {

            waiter.notify_bits = self.bits;
            self.bits = 0;

            scheduler.unblock(scheduler.current_core(), waiter);

            return;

        }

        // Multi-wait (M5): a bound thread blocked in `receive` wakes with NOTIFICATION_WAKE. `awaiting_reply` rules out
        // a caller that is merely blocked awaiting its reply (also `.blocked_receive`, but not a queued receiver).

        if (self.bound_to) |thread| {

            if (thread.state == .blocked_receive and !thread.awaiting_reply) {

                if (thread.blocked_on) |blocked_on| {

                    if (blocked_on.kind == .endpoint) object.container(Endpoint, blocked_on).receivers.remove(thread);

                }

                thread.notify_bits = self.bits;
                self.bits = 0;
                thread.woke_on_notification = true;

                scheduler.unblock(scheduler.current_core(), thread);

            }

        }

    }

    /// Take and clear any accumulated bits (for a bound receiver polling before it blocks); null when none are pending.
    pub fn take_pending(self: *Notification) ?u64 {

        if (self.bits == 0) return null;

        const bits = self.bits;
        self.bits = 0;

        return bits;

    }

    /// Wait: take the accumulated bits if any, otherwise park `by` on this notification and return null.
    pub fn poll_or_block(self: *Notification, by: *Thread) ?u64 {

        const saved = arch.disable_interrupts();
        defer arch.restore_interrupts(saved);

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
