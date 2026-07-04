// IPC transfer (06-kernel-ddd.md Section 9): the synchronous rendezvous behind send/receive/call/reply.

const object = @import("../object/object.zig");
const arch = @import("../arch/arch.zig");
const scheduler = @import("../sched/scheduler.zig");

const Thread = @import("../object/thread.zig").Thread;
const Endpoint = @import("../object/endpoint.zig").Endpoint;
const Handle = @import("../cap/handle.zig").Handle;
const Error = @import("../error.zig").Error;

const notification_wake = @import("message.zig").notification_wake;

const no_handle: Handle = @bitCast(@as(u32, 0xffff_ffff));

/// Synchronous send: block until a receiver takes the message (no reply). `from.staged` is already filled.
pub fn send(from: *Thread, endpoint: *Endpoint) Error!void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = scheduler.current_core();

    if (endpoint.receivers.pop()) |receiver| {

        try deliver(from, receiver, false);
        receiver.observed_badge = from.send_badge;
        scheduler.unblock(core, receiver);

        return;

    }

    from.is_call = false;
    from.ipc_aborted = false;
    from.state = .blocked_send;
    endpoint.senders.push(from);

    scheduler.block(core, from, &endpoint.header);

    if (from.ipc_aborted) {

        from.ipc_aborted = false;
        return error.Gone;

    }

}

/// Call: send and block for the reply. Direct hand-off to an already-waiting server; otherwise queue and wait.
pub fn call(from: *Thread, endpoint: *Endpoint) Error!void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = scheduler.current_core();

    from.is_call = true;
    from.awaiting_reply = true;
    from.ipc_aborted = false;

    if (endpoint.receivers.pop()) |receiver| {

        try deliver(from, receiver, true);
        receiver.observed_badge = from.send_badge;

        from.state = .blocked_receive;
        from.blocked_on = &endpoint.header;

        scheduler.hand_off(from, receiver);

    } else {

        from.state = .blocked_send;
        endpoint.senders.push(from);

        scheduler.block(core, from, &endpoint.header);

    }

    // The server (or the endpoint) died while we blocked: the call cannot complete (06-kernel-ddd.md Section 9).

    if (from.ipc_aborted) {

        from.ipc_aborted = false;
        from.awaiting_reply = false;
        return error.Gone;

    }

}

/// Receive: take a waiting sender's message, block until one arrives, or wake on the bound notification (multi-wait).
/// Returns the sender's badge, or `notification_wake` with the event bits staged in `into.notify_bits`.
pub fn receive(into: *Thread, endpoint: *Endpoint) Error!u64 {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const core = scheduler.current_core();

    // The first receive on an endpoint registers the thread as one of its servers (06-kernel-ddd.md Section 9).

    if (into.serving == null) {

        into.serving = endpoint;
        endpoint.join();

    }

    if (endpoint.senders.pop()) |sender| {

        try deliver(sender, into, sender.is_call);
        into.observed_badge = sender.send_badge;

        // A plain sender completes once its message is taken; a caller stays blocked for its reply.

        if (!sender.is_call) scheduler.unblock(core, sender);

        return into.observed_badge;

    }

    // Multi-wait: an event already pending on the bound notification wakes us without blocking.

    if (into.bound_notification) |notification| {

        if (notification.take_pending()) |bits| {

            into.notify_bits = bits;
            return notification_wake;

        }

    }

    into.woke_on_notification = false;
    into.state = .blocked_receive;
    endpoint.receivers.push(into);

    scheduler.block(core, into, &endpoint.header);

    if (into.woke_on_notification) {

        into.woke_on_notification = false;
        return notification_wake;

    }

    return into.observed_badge;

}

/// Reply: answer the caller named by the one-shot `reply_handle`, then wake it. `from.staged` holds the reply.
pub fn reply(from: *Thread, reply_handle: Handle) Error!void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const caller = try from.process.handles.resolve_as(reply_handle, .thread);

    if (!caller.awaiting_reply) return error.Invalid;

    try deliver(from, caller, false);

    caller.awaiting_reply = false;
    from.owes_reply_to = null;
    from.process.handles.close(reply_handle) catch {};

    scheduler.unblock(scheduler.current_core(), caller);

}

// Copy the staged envelope from `source` to `dest`: the inline data words verbatim, and each handle slot transferred between the two tables per its move/copy flag.
fn deliver(source: *Thread, dest: *Thread, is_call: bool) Error!void {

    dest.staged.data = source.staged.data;

    const count = source.staged.handle_count;
    dest.staged.handle_count = count;

    var index: usize = 0;

    while (index < count) : (index += 1) {

        dest.staged.handles[index] = try transfer_slot(source, dest, source.staged.handles[index]);

    }

    if (is_call) {

        dest.staged.reply = try dest.process.handles.insert(&source.header);

        // The receiver now owes this caller a reply; if it dies first, teardown wakes the caller with `Gone`.

        dest.owes_reply_to = source;

    } else {

        dest.staged.reply = no_handle;

    }

}

fn transfer_slot(source: *Thread, dest: *Thread, slot: @import("message.zig").HandleSlot) Error!@import("message.zig").HandleSlot {

    const target = try source.process.handles.resolve(slot.handle);
    const copied = try dest.process.handles.insert(target);

    if (slot.move) source.process.handles.close(slot.handle) catch {};

    return .{ .handle = copied, .move = false };

}

const std = @import("std");
const testing = std.testing;

const config = @import("../config.zig");
const frames = @import("../memory/frames.zig");
const region_module = @import("../memory/region.zig");
const address_space = @import("../memory/address_space.zig");
const process_module = @import("../object/process.zig");

const Message = @import("message.zig").Message;
const Region = region_module.Region;
const Process = process_module.Process;

fn host_pool(pages: usize) []u8 {

    const pool = std.heap.page_allocator.alloc(u8, pages * config.page_size) catch unreachable;
    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    region_module.init();
    address_space.init();
    process_module.init();
    return pool;

}

// A minimal Thread just for exercising deliver: only its process (for the handle table) and staged envelope matter.
fn bare_thread(process: *Process) Thread {

    var thread: Thread = undefined;

    thread.header = .{ .kind = .thread };
    thread.process = process;
    thread.staged = Message.zeroed;

    return thread;

}

test "deliver moves a handle across processes and copies the data words" {

    const pool = host_pool(128);
    defer std.heap.page_allocator.free(pool);

    const sender_process = try Process.create(try address_space.AddressSpace.create());
    const receiver_process = try Process.create(try address_space.AddressSpace.create());

    const region = try Region.create(config.page_size);
    const sender_handle = try sender_process.handles.insert(&region.header);

    var sender = bare_thread(sender_process);
    var receiver = bare_thread(receiver_process);

    sender.staged.data[0] = 0xC0FFEE;
    sender.staged.handles[0] = .{ .handle = sender_handle, .move = true };
    sender.staged.handle_count = 1;

    try deliver(&sender, &receiver, false);

    try testing.expectEqual(@as(u64, 0xC0FFEE), receiver.staged.data[0]);
    try testing.expectEqual(@as(u32, 1), receiver.staged.handle_count);

    // The region now resolves in the receiver and no longer in the sender (it was moved).

    try testing.expectEqual(region, try receiver_process.handles.resolve_as(receiver.staged.handles[0].handle, .region));
    try testing.expectError(error.BadHandle, sender_process.handles.resolve(sender_handle));

}

test "a call delivery mints a one-shot reply handle to the caller" {

    const pool = host_pool(128);
    defer std.heap.page_allocator.free(pool);

    const caller_process = try Process.create(try address_space.AddressSpace.create());
    const server_process = try Process.create(try address_space.AddressSpace.create());

    var caller = bare_thread(caller_process);
    var server = bare_thread(server_process);

    caller.staged.data[0] = 7;
    caller.staged.handle_count = 0;

    try deliver(&caller, &server, true);

    // The server's reply slot resolves back to the caller thread, so it can answer exactly this caller.

    const replied = try server_process.handles.resolve_as(server.staged.reply, .thread);
    try testing.expectEqual(&caller, replied);

}

// M5: multi-wait and fault-aware teardown.

const thread_module = @import("../object/thread.zig");
const endpoint_module = @import("../object/endpoint.zig");
const notification_module = @import("../object/notification.zig");

const Notification = @import("../object/notification.zig").Notification;
const ThreadState = thread_module.ThreadState;

// A full host stage: the object caches and the scheduler, so real threads can block, wake, and be enqueued.
fn ipc_pool(pages: usize) []u8 {

    const pool = host_pool(pages);

    thread_module.init();
    endpoint_module.init();
    notification_module.init();
    scheduler.init();

    return pool;

}

test "a dying server wakes the caller it still owes a reply with Gone" {

    const pool = ipc_pool(256);
    defer std.heap.page_allocator.free(pool);

    const process = try Process.create(try address_space.AddressSpace.create());

    const caller = try Thread.create(process, 0x1000);
    const server = try Thread.create(process, 0x2000);

    // The state left behind once the server received the caller's call but has not yet replied.

    caller.awaiting_reply = true;
    caller.state = .blocked_receive;
    server.owes_reply_to = caller;

    server.release_ipc();

    try testing.expectEqual(true, caller.ipc_aborted);
    try testing.expectEqual(false, caller.awaiting_reply);
    try testing.expectEqual(@as(?*Thread, null), server.owes_reply_to);
    try testing.expectEqual(ThreadState.ready, caller.state);

}

test "the last server leaving breaks the endpoint and wakes queued senders with Gone" {

    const pool = ipc_pool(256);
    defer std.heap.page_allocator.free(pool);

    const process = try Process.create(try address_space.AddressSpace.create());

    const endpoint = try Endpoint.create();

    endpoint.join();
    endpoint.join();

    const sender = try Thread.create(process, 0x1000);
    sender.state = .blocked_send;
    endpoint.senders.push(sender);

    endpoint.leave();
    try testing.expectEqual(false, sender.ipc_aborted);

    endpoint.leave();
    try testing.expectEqual(true, sender.ipc_aborted);
    try testing.expectEqual(ThreadState.ready, sender.state);

}

test "a signal wakes a bound thread out of receive with the event bits" {

    const pool = ipc_pool(256);
    defer std.heap.page_allocator.free(pool);

    const process = try Process.create(try address_space.AddressSpace.create());

    const endpoint = try Endpoint.create();
    const notification = try Notification.create();

    const server = try Thread.create(process, 0x1000);

    notification.bound_to = server;
    server.bound_notification = notification;

    server.state = .blocked_receive;
    server.blocked_on = &endpoint.header;
    endpoint.receivers.push(server);

    notification.signal(0b101);

    try testing.expectEqual(true, server.woke_on_notification);
    try testing.expectEqual(@as(u64, 0b101), server.notify_bits);
    try testing.expectEqual(@as(u64, 0), notification.bits);
    try testing.expectEqual(ThreadState.ready, server.state);
    try testing.expect(endpoint.receivers.is_empty());

}

test "a caller awaiting its reply is not mistaken for a bound receiver" {

    const pool = ipc_pool(256);
    defer std.heap.page_allocator.free(pool);

    const process = try Process.create(try address_space.AddressSpace.create());

    const notification = try Notification.create();
    const caller = try Thread.create(process, 0x1000);

    notification.bound_to = caller;
    caller.bound_notification = notification;

    // Blocked awaiting a reply (also `.blocked_receive`) - a signal must not steal it out of the reply wait.

    caller.state = .blocked_receive;
    caller.awaiting_reply = true;

    notification.signal(0b1);

    try testing.expectEqual(false, caller.woke_on_notification);
    try testing.expectEqual(@as(u64, 0b1), notification.bits);

}

test "take_pending returns the accumulated bits once and clears them" {

    const pool = ipc_pool(64);
    defer std.heap.page_allocator.free(pool);

    const notification = try Notification.create();

    try testing.expectEqual(@as(?u64, null), notification.take_pending());

    notification.bits = 0b11;

    try testing.expectEqual(@as(?u64, 0b11), notification.take_pending());
    try testing.expectEqual(@as(u64, 0), notification.bits);

}
