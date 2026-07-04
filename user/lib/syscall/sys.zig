// Typed wrappers for the 17 kernel verbs (07-userspace-ddd.md Section 3.1; 03-syscall-abi.md): number in x8, arguments in x0-x5, signed result in x0.

const builtin = @import("builtin");

const cap = @import("../cap/cap.zig");
const ipc = @import("../ipc/ipc.zig");

const Handle = cap.Handle;
const Message = ipc.Message;

// The shared error set, decoded from the negative ABI codes (03-syscall-abi.md).

pub const Error = error{

    BadHandle,
    WrongType,
    NoMemory,
    NotAllowed,
    WouldBlock,
    NotFound,
    Invalid,
    Gone,

};

const Number = enum(u64) {

    create = 1,
    spawn,
    close,
    start,
    yield,
    configure,
    map,
    unmap,
    send,
    receive,
    call,
    reply,
    notify,
    wait,
    bind,
    acknowledge,
    copy,

};

// `create` kinds, mirroring the kernel's numbering (kernel/syscall/syscall.zig). Gated kinds carry the granting authority's handle as their last argument.

pub const CreateKind = enum(u64) {

    endpoint = 1,
    notification,
    address_space,
    region, // arg_a = length, arg_b = MemoryAuthority handle
    interrupt, // arg_a = line, arg_b = InterruptAuthority handle
    memory_authority, // arg_a = budget bytes, arg_b = parent MemoryAuthority handle
    device_region, // arg_a = physical base, arg_b = length, arg_c = DeviceAuthority handle

};

// `map` permission bits (03-syscall-abi.md Memory).

pub const read: u64 = 0b001;
pub const write: u64 = 0b010;
pub const execute: u64 = 0b100;

// Lifecycle

pub fn create(kind: CreateKind, arg_a: u64, arg_b: u64) Error!Handle {

    return handle(invoke(.create, @intFromEnum(kind), arg_a, arg_b, 0, 0));

}

/// The one four-argument create: a device/MMIO window, gated by a DeviceAuthority.
pub fn create_device_region(base: u64, length: u64, authority: Handle) Error!Handle {

    return handle(invoke(.create, @intFromEnum(CreateKind.device_region), base, length, authority, 0));

}

pub fn spawn(space: Handle, entry: usize, stack: usize, grants: []const Handle) Error!Handle {

    return handle(invoke(.spawn, space, entry, stack, @intFromPtr(grants.ptr), grants.len));

}

pub fn close(target: Handle) Error!void {

    _ = try check(invoke(.close, target, 0, 0, 0, 0));

}

pub fn start(thread: Handle) Error!void {

    _ = try check(invoke(.start, thread, 0, 0, 0, 0));

}

pub fn yield() void {

    _ = invoke(.yield, 0, 0, 0, 0, 0);

}

pub fn configure(thread: Handle, attribute: cap.Attribute, value: u64) Error!void {

    _ = try check(invoke(.configure, thread, @intFromEnum(attribute), value, 0, 0));

}

// Memory

/// Map `region` into `space` at `at` (0 lets the kernel choose); returns the mapped base.
pub fn map(space: Handle, region: Handle, at: usize, permissions: u64) Error!usize {

    return @intCast(try check(invoke(.map, space, region, at, permissions, 0)));

}

pub fn unmap(space: Handle, at: usize) Error!void {

    _ = try check(invoke(.unmap, space, at, 0, 0, 0));

}

// IPC

pub fn send(endpoint: Handle, message: *const Message) Error!void {

    _ = try check(invoke(.send, endpoint, @intFromPtr(message), 0, 0, 0));

}

/// Blocks for the next request; returns the sender's badge.
pub fn receive(endpoint: Handle, message: *Message) Error!u64 {

    return check(invoke(.receive, endpoint, @intFromPtr(message), 0, 0, 0));

}

/// The RPC hot path: request out, reply back in the same `message`.
pub fn call(endpoint: Handle, message: *Message) Error!void {

    _ = try check(invoke(.call, endpoint, @intFromPtr(message), 0, 0, 0));

}

pub fn reply(reply_handle: Handle, message: *const Message) Error!void {

    _ = try check(invoke(.reply, reply_handle, @intFromPtr(message), 0, 0, 0));

}

pub fn notify(notification: Handle, bits: u64) Error!void {

    _ = try check(invoke(.notify, notification, bits, 0, 0, 0));

}

pub fn wait(notification: Handle) Error!u64 {

    return check(invoke(.wait, notification, 0, 0, 0, 0));

}

// Interrupts

pub fn bind(interrupt: Handle, notification: Handle, bits: u64) Error!void {

    _ = try check(invoke(.bind, interrupt, notification, bits, 0, 0));

}

pub fn acknowledge(interrupt: Handle) Error!void {

    _ = try check(invoke(.acknowledge, interrupt, 0, 0, 0, 0));

}

// Handles

/// Duplicate a handle; a non-zero badge mints a badged endpoint copy.
pub fn copy(target: Handle, badge: u64) Error!Handle {

    return handle(invoke(.copy, target, badge, 0, 0, 0));

}

// The raw trap. The kernel's svc path saves and restores the whole register frame, so only x0 (the result) changes.

fn invoke(number: Number, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) i64 {

    if (comptime builtin.target.cpu.arch != .aarch64) {

        @panic("user syscalls are target-only");

    }

    return asm volatile ("svc #0"
        : [result] "={x0}" (-> i64),
        : [number] "{x8}" (@intFromEnum(number)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
        : .{ .memory = true });

}

fn check(result: i64) Error!u64 {

    if (result >= 0) return @intCast(result);

    return switch (result) {

        -1 => error.BadHandle,
        -2 => error.WrongType,
        -3 => error.NoMemory,
        -4 => error.NotAllowed,
        -5 => error.WouldBlock,
        -6 => error.NotFound,
        -7 => error.Invalid,
        -8 => error.Gone,

        else => error.Invalid,

    };

}

fn handle(result: i64) Error!Handle {

    return @truncate(try check(result));

}
