// Thread (06-kernel-ddd.md Section 7.2): a schedulable flow inside a Process, created suspended. The IPC fields (pending reply, bound notification, donated scheduling) arrive with M3/M5/M8.

const std = @import("std");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const frames = @import("../memory/frames.zig");
const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
const scheduler = @import("../sched/scheduler.zig");
const runqueue = @import("../sched/runqueue.zig");

const Process = @import("process.zig").Process;
const Error = @import("../error.zig").Error;

const PhysAddr = arch.PhysAddr;
const VirtAddr = arch.VirtAddr;
const page_size = config.page_size;

var cache: slab.Cache(Thread) = .{};

pub const ThreadState = enum {

    ready,
    running,
    blocked_send,
    blocked_receive,
    blocked_notify,
    suspended,
    dead,

};

pub const Attribute = enum(u8) {

    scheduling_level,
    scheduling_class,
    bound_notification,

};

pub const Thread = struct {

    header: object.Object,
    process: *Process,
    context: arch.Context,
    state: ThreadState,

    scheduling: scheduler.SchedulingState,
    blocked_on: ?*object.Object,
    queue_link: runqueue.Link,

    stack_base: PhysAddr,
    next_in_process: ?*Thread,

    /// A suspended thread on a fresh kernel stack; `start` admits it to the scheduler.
    pub fn create(process: *Process, entry: VirtAddr) Error!*Thread {

        const stack_pages = config.thread_stack_pages;
        const stack_base = try frames.alloc_contiguous(stack_pages);
        errdefer frames.free_contiguous(stack_base, stack_pages);

        const thread = try cache.alloc();

        thread.* = .{

            .header = .{ .kind = .thread },
            .process = process,
            .context = undefined,
            .state = .suspended,

            .scheduling = .{},
            .blocked_on = null,
            .queue_link = .{},

            .stack_base = stack_base,
            .next_in_process = process.threads,

        };

        arch.init_thread_context(&thread.context, entry, stack_base + stack_pages * page_size, 0);

        process.threads = thread;
        process.header.retain();

        return thread;

    }

    pub fn start(self: *Thread) void {

        scheduler.admit(self);

    }

    pub fn configure(self: *Thread, attribute: Attribute, value: u64) Error!void {

        switch (attribute) {

            .scheduling_level => {

                if (value >= config.scheduling_levels) return error.Invalid;

                self.scheduling.level = @intCast(value);

            },

            .scheduling_class => {

                self.scheduling.class = std.meta.intToEnum(scheduler.Class, value) catch return error.Invalid;

            },

            // Multi-wait arrives with M5.

            .bound_notification => return error.Invalid,

        }

    }

    pub fn destroy(self: *Thread) void {

        self.unlink();

        frames.free_contiguous(self.stack_base, config.thread_stack_pages);

        if (self.process.header.release()) object.destroy(&self.process.header);

        cache.free(self);

    }

    fn unlink(self: *Thread) void {

        var link = &self.process.threads;

        while (link.*) |sibling| {

            if (sibling == self) {

                link.* = self.next_in_process;
                return;

            }

            link = &sibling.next_in_process;

        }

    }

};

pub fn init() void {

    cache.init();

}
