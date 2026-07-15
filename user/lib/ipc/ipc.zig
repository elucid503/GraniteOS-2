// IPC scaffolding (07-userspace-ddd.md Section 3.4): the message envelope, request building, and the canonical server loop of 05-server-protocol.md.

const std = @import("std");

const cap = @import("../cap/cap.zig");
const sys = @import("../syscall/sys.zig");

const Handle = cap.Handle;
const Error = sys.Error;

// Message envelope matching kernel/ipc/message.zig: 6 data words, 4 handle slots, reply, handle_count.

pub const HandleSlot = extern struct {

    handle: Handle,
    move: bool,

};

pub const Message = extern struct {

    data: [6]u64,
    handles: [4]HandleSlot,

    reply: Handle,
    handle_count: u32,

    pub const zeroed: Message = std.mem.zeroes(Message);

};

/// Build/call a request; negative status decodes to Error, else returns the full reply.
pub fn request(endpoint: Handle, method: u16, arguments: []const u64, handles: []const HandleSlot) Error!Message {

    if (arguments.len > message_argument_words) return error.Invalid;
    if (handles.len > message_handle_slots) return error.Invalid;

    var message = Message.zeroed;

    message.data[0] = method;

    for (arguments, 0..) |argument, index| {

        message.data[index + 1] = argument;

    }

    for (handles, 0..) |slot, index| {

        message.handles[index] = slot;

    }

    message.handle_count = @intCast(handles.len);

    try sys.call(endpoint, &message);

    return decoded(message);

}

const message_argument_words = 5;
const message_handle_slots = 4;

/// The status word of a reply already checked by `request`, for callers that kept the message around.
pub fn status_of(message: *const Message) i64 {

    return @bitCast(message.data[0]);

}

// One request handler: unpack the method from `in`, fill `out`'s result words, and return the status word.

pub const Dispatch = *const fn (badge: u64, method: u64, in: *const Message, out: *Message) i64;

/// The canonical single-threaded server loop (05-server-protocol.md): receive, dispatch, reply.
pub fn serve(endpoint: Handle, dispatch: Dispatch) noreturn {

    serve_loop(endpoint, dispatch);

}

// Worker pool: N threads receive on one endpoint; per-request reply handles need only a Lock around server state.

const worker_stack_pages = 16;
const page_size = 4096;

var pool_endpoint: Handle = 0;
var pool_dispatch: Dispatch = undefined;

/// Pooled server: spawn workers-1 threads on cap.memory stacks, then serve on this one.
pub fn serve_pool(endpoint: Handle, workers: usize, dispatch: Dispatch) noreturn {

    pool_endpoint = endpoint;
    pool_dispatch = dispatch;

    var started: usize = 1;

    while (started < workers) : (started += 1) {

        start_worker(cap.memory) catch break;

    }

    serve_loop(endpoint, dispatch);

}

fn start_worker(authority: Handle) Error!void {

    const stack = try sys.create(.region, worker_stack_pages * page_size, authority);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);

    const thread = try sys.create_thread(@intFromPtr(&worker_entry), base + worker_stack_pages * page_size);

    try sys.start(thread);

}

fn worker_entry() callconv(.c) noreturn {

    serve_loop(pool_endpoint, pool_dispatch);

}

fn serve_loop(endpoint: Handle, dispatch: Dispatch) noreturn {

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(endpoint, &in) catch continue;

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

    }

}

/// Mutual exclusion for a pooled server's own data structures (05-server-protocol.md): the shared notification-parked mutex, so contended workers park instead of yield-spinning.
pub const Lock = @import("../sync.zig").Mutex;

fn decoded(message: Message) Error!Message {

    const status = status_of(&message);

    if (status >= 0) return message;

    return switch (status) {

        -1 => error.BadHandle,
        -2 => error.WrongType,
        -3 => error.NoMemory,
        -4 => error.NotAllowed,
        -5 => error.WouldBlock,
        -6 => error.NotFound,
        -8 => error.Gone,

        else => error.Invalid,

    };

}

const testing = std.testing;

test "the envelope matches the kernel layout" {

    try testing.expectEqual(@as(usize, 88), @sizeOf(Message));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Message, "data"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(Message, "handles"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(HandleSlot));
    try testing.expectEqual(@as(usize, 80), @offsetOf(Message, "reply"));
    try testing.expectEqual(@as(usize, 84), @offsetOf(Message, "handle_count"));

}
