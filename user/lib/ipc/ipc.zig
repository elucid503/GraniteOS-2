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

// Reply status words (05-server-protocol.md). Servers returned these as bare literals; `status` maps an Error onto them.

pub const status_bad_handle: i64 = -1;
pub const status_wrong_type: i64 = -2;
pub const status_no_memory: i64 = -3;
pub const status_not_allowed: i64 = -4;
pub const status_would_block: i64 = -5;
pub const status_not_found: i64 = -6;
pub const status_invalid: i64 = -7;
pub const status_gone: i64 = -8;

/// The exact inverse of `decoded`: report the real failure instead of flattening everything to Invalid.
pub fn status_for(err: Error) i64 {

    return switch (err) {

        error.BadHandle => status_bad_handle,
        error.WrongType => status_wrong_type,
        error.NoMemory => status_no_memory,
        error.NotAllowed => status_not_allowed,
        error.WouldBlock => status_would_block,
        error.NotFound => status_not_found,
        error.Gone => status_gone,

        else => status_invalid,

    };

}

/// The `proto.identify` reply every server and driver returns: interface id and version in words 1 and 2.
pub fn identify(out: *Message, interface_id: u64, version: u64) i64 {

    out.data[1] = interface_id;
    out.data[2] = version;

    return 0;

}

// One request handler: unpack the method from `in`, fill `out`'s result words, and return the status word.

pub const Dispatch = *const fn (badge: u64, method: u64, in: *const Message, out: *Message) i64;

/// Hooks for servers that share their endpoint with a bound notification.
pub const ServeOptions = struct {

    /// Run when the endpoint delivers an interrupt/notification wake instead of a request.
    on_wake: ?*const fn () void = null,

    /// Run after each reply; sweeps for work a wake may have raced past.
    after_reply: ?*const fn () void = null,

};

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

    try spawn_thread(&worker_entry, authority, worker_stack_pages);

}

/// Spawn a thread on its own freshly mapped stack of `pages` pages, and start it.
/// The region handle is closed once mapped: the mapping keeps the memory alive.
/// `pages` is the caller's, not a shared default — TLS workers need far more stack than a reaper.
pub fn spawn_thread(entry: *const fn () callconv(.c) noreturn, authority: Handle, pages: usize) Error!void {

    const bytes = pages * page_size;

    const stack = try sys.create(.region, bytes, authority);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);

    const thread = try sys.create_thread(@intFromPtr(entry), base + bytes);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker_entry() callconv(.c) noreturn {

    serve_loop(pool_endpoint, pool_dispatch);

}

fn serve_loop(endpoint: Handle, dispatch: Dispatch) noreturn {

    serve_with(endpoint, dispatch, .{});

}

/// `serve` plus the wake and post-reply hooks drivers and stateful servers need.
pub fn serve_with(endpoint: Handle, dispatch: Dispatch, options: ServeOptions) noreturn {

    var in = Message.zeroed;

    while (true) {

        const badge = sys.receive(endpoint, &in) catch continue;

        if (badge == cap.notification_wake) {

            if (options.on_wake) |wake| wake();

            continue;

        }

        var out = Message.zeroed;
        out.data[0] = @bitCast(dispatch(badge, in.data[0], &in, &out));

        sys.reply(in.reply, &out) catch {};

        if (options.after_reply) |sweep| sweep();

    }

}

/// Mutual exclusion for a pooled server's own data structures (05-server-protocol.md): the shared notification-parked mutex, so contended workers park instead of yield-spinning.
pub const Lock = @import("../sync.zig").Mutex;

fn decoded(message: Message) Error!Message {

    const code = status_of(&message);

    if (code >= 0) return message;

    return switch (code) {

        status_bad_handle => error.BadHandle,
        status_wrong_type => error.WrongType,
        status_no_memory => error.NoMemory,
        status_not_allowed => error.NotAllowed,
        status_would_block => error.WouldBlock,
        status_not_found => error.NotFound,
        status_gone => error.Gone,

        else => error.Invalid,

    };

}

const testing = std.testing;

test "status is the exact inverse of decoded" {

    const cases = [_]struct { code: i64, err: Error }{

        .{ .code = -1, .err = error.BadHandle },
        .{ .code = -2, .err = error.WrongType },
        .{ .code = -3, .err = error.NoMemory },
        .{ .code = -4, .err = error.NotAllowed },
        .{ .code = -5, .err = error.WouldBlock },
        .{ .code = -6, .err = error.NotFound },
        .{ .code = -7, .err = error.Invalid },
        .{ .code = -8, .err = error.Gone },

    };

    for (cases) |case| {

        var message = Message.zeroed;
        message.data[0] = @bitCast(case.code);

        try testing.expectError(case.err, decoded(message));
        try testing.expectEqual(case.code, status_for(case.err));

    }

}

test "identify fills the interface words and succeeds" {

    var out = Message.zeroed;

    try testing.expectEqual(@as(i64, 0), identify(&out, 7, 3));
    try testing.expectEqual(@as(u64, 7), out.data[1]);
    try testing.expectEqual(@as(u64, 3), out.data[2]);

}

test "the envelope matches the kernel layout" {

    try testing.expectEqual(@as(usize, 88), @sizeOf(Message));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Message, "data"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(Message, "handles"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(HandleSlot));
    try testing.expectEqual(@as(usize, 80), @offsetOf(Message, "reply"));
    try testing.expectEqual(@as(usize, 84), @offsetOf(Message, "handle_count"));

}
