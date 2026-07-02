// Endpoint (06-kernel-ddd.md Section 7.3, Section 9): a synchronous IPC rendezvous.

const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
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

    pub fn destroy(self: *Endpoint) void {

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
