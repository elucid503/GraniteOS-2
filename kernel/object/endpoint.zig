// Endpoint (06-kernel-ddd.md Section 7.3, Section 9): a synchronous IPC rendezvous.

const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
const scheduler = @import("../sched/scheduler.zig");
const runqueue = @import("../sched/runqueue.zig");

const Error = @import("../error.zig").Error;

var cache: slab.Cache(Endpoint) = .{};

pub const Endpoint = struct {

    header: object.Object,

    senders: runqueue.RunQueue,
    receivers: runqueue.RunQueue,

    // Live threads serving here; reaching zero breaks the endpoint (M5).

    server_threads: u32,

    pub fn create() Error!*Endpoint {

        const endpoint = try cache.alloc();
        endpoint.* = .{

            .header = .{ .kind = .endpoint },

            .senders = .{},
            .receivers = .{},

            .server_threads = 0,

        };

        return endpoint;

    }

    /// A thread registers as a server here (retains the endpoint for the thread that will hold it in `serving`).
    pub fn join(self: *Endpoint) void {

        self.server_threads += 1;
        self.header.retain();

    }

    /// A server thread leaves (on death); the last one out wakes every blocked client with `Gone`.
    pub fn leave(self: *Endpoint) void {

        self.server_threads -= 1;

        if (self.server_threads == 0) self.break_endpoint();

    }

    /// Wake all threads blocked in send/call toward here with `Gone`: a server that vanished must not hang its clients.
    pub fn break_endpoint(self: *Endpoint) void {

        while (self.senders.pop()) |sender| {

            scheduler.abort_ipc(sender);

        }

    }

    pub fn destroy(self: *Endpoint) void {

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
