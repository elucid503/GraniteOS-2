// Thread (06-kernel-ddd.md Section 7.2): a schedulable flow inside a Process. Kernel threads run at EL1 on their
// kernel stack; user threads run at EL0 on a separate mapped stack and trap back onto that same kernel stack.
// The IPC fields carry a synchronous request/reply across a rendezvous (Section 9). Multi-wait/donation are M5/M8.

const std = @import("std");

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const frames = @import("../memory/frames.zig");
const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
const scheduler = @import("../sched/scheduler.zig");
const runqueue = @import("../sched/runqueue.zig");

const Process = @import("process.zig").Process;
const Message = @import("../ipc/message.zig").Message;
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

    // IPC (Section 9). A blocking send/call/receive stages its envelope here, in kernel memory, and remembers the
    // user virtual address it must be copied back to on wake. `send_badge` is the badge the sender's endpoint handle
    // carried, reported to the receiver; `is_call` distinguishes a queued caller from a plain sender; `awaiting_reply`
    // marks a caller parked for its one-shot reply. `notify_bits` delivers a notification's bits to a woken waiter.

    staged: Message,
    message_buffer: VirtAddr,
    send_badge: u64,
    observed_badge: u64,
    is_call: bool,
    awaiting_reply: bool,
    notify_bits: u64,

    /// A suspended kernel thread (EL1) on its own kernel stack; `start` admits it to the scheduler.
    pub fn create(process: *Process, entry: VirtAddr) Error!*Thread {

        const thread = try alloc(process);
        errdefer free(thread);

        arch.init_thread_context(&thread.context, entry, kernel_stack_top(thread), 0);

        return thread;

    }

    /// A suspended user thread (EL0). It runs on `user_stack_top` in `process`'s address space and traps onto its own
    /// kernel stack; `arg` lands in the entry's first argument (03-syscall-abi.md: the init message pointer).
    pub fn create_user(process: *Process, entry: VirtAddr, user_stack_top: VirtAddr, arg: u64) Error!*Thread {

        const thread = try alloc(process);
        errdefer free(thread);

        arch.init_user_thread_context(&thread.context, entry, kernel_stack_top(thread), user_stack_top, arg);

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

fn alloc(process: *Process) Error!*Thread {

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

        .staged = undefined,
        .message_buffer = 0,
        .send_badge = 0,
        .observed_badge = 0,
        .is_call = false,
        .awaiting_reply = false,
        .notify_bits = 0,

    };

    process.threads = thread;
    process.header.retain();

    return thread;

}

fn free(thread: *Thread) void {

    frames.free_contiguous(thread.stack_base, config.thread_stack_pages);
    thread.unlink();

    if (thread.process.header.release()) object.destroy(&thread.process.header);

    cache.free(thread);

}

fn kernel_stack_top(thread: *Thread) VirtAddr {

    return thread.stack_base + config.thread_stack_pages * page_size;

}

pub fn init() void {

    cache.init();

}
