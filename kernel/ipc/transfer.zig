// IPC transfer (06-kernel-ddd.md Section 9): the synchronous rendezvous behind send/receive/call/reply.

const object = @import("../object/object.zig");
const scheduler = @import("../sched/scheduler.zig");

const Thread = @import("../object/thread.zig").Thread;
const Endpoint = @import("../object/endpoint.zig").Endpoint;
const Handle = @import("../cap/handle.zig").Handle;
const Error = @import("../error.zig").Error;

const no_handle: Handle = @bitCast(@as(u32, 0));

/// Synchronous send: block until a receiver takes the message (no reply). `from.staged` is already filled.
pub fn send(from: *Thread, endpoint: *Endpoint) Error!void {

    const core = scheduler.current_core();

    if (endpoint.receivers.pop()) |receiver| {

        try deliver(from, receiver, false);
        receiver.observed_badge = from.send_badge;
        scheduler.unblock(core, receiver);

        return;

    }

    from.is_call = false;
    from.state = .blocked_send;
    endpoint.senders.push(from);

    scheduler.block(core, from, &endpoint.header);

}

/// Call: send and block for the reply. Direct hand-off to an already-waiting server; otherwise queue and wait.
pub fn call(from: *Thread, endpoint: *Endpoint) Error!void {

    const core = scheduler.current_core();

    from.is_call = true;
    from.awaiting_reply = true;

    if (endpoint.receivers.pop()) |receiver| {

        try deliver(from, receiver, true);
        receiver.observed_badge = from.send_badge;

        from.state = .blocked_receive;
        from.blocked_on = &endpoint.header;

        scheduler.hand_off(from, receiver);

        return;

    }

    from.state = .blocked_send;
    endpoint.senders.push(from);

    scheduler.block(core, from, &endpoint.header);

}

/// Receive: take a waiting sender's message, or block until one arrives. Returns the sender's badge.
pub fn receive(into: *Thread, endpoint: *Endpoint) Error!u64 {

    const core = scheduler.current_core();

    if (endpoint.senders.pop()) |sender| {

        try deliver(sender, into, sender.is_call);
        into.observed_badge = sender.send_badge;

        // A plain sender completes once its message is taken; a caller stays blocked for its reply.

        if (!sender.is_call) scheduler.unblock(core, sender);

        return into.observed_badge;

    }

    into.state = .blocked_receive;
    endpoint.receivers.push(into);

    scheduler.block(core, into, &endpoint.header);

    return into.observed_badge;

}

/// Reply: answer the caller named by the one-shot `reply_handle`, then wake it. `from.staged` holds the reply.
pub fn reply(from: *Thread, reply_handle: Handle) Error!void {

    const caller = try from.process.handles.resolve_as(reply_handle, .thread);

    if (!caller.awaiting_reply) return error.Invalid;

    try deliver(from, caller, false);

    caller.awaiting_reply = false;
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

        dest.staged.handles[index] = transfer_slot(source, dest, source.staged.handles[index]);

    }

    if (is_call) {

        dest.staged.reply = try dest.process.handles.insert(&source.header);

    } else {

        dest.staged.reply = no_handle;

    }

}

fn transfer_slot(source: *Thread, dest: *Thread, slot: @import("message.zig").HandleSlot) @import("message.zig").HandleSlot {

    const target = source.process.handles.resolve(slot.handle) catch return .{ .handle = no_handle, .move = false };
    const copied = dest.process.handles.insert(target) catch return .{ .handle = no_handle, .move = false };

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
