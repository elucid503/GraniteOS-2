// Syscall dispatch (06-kernel-ddd.md Section 12; 03-syscall-abi.md): the one entry from the EL0 trap path.

const arch = @import("../arch/arch.zig");
const config = @import("../config.zig");
const err = @import("../error.zig");
const object = @import("../object/object.zig");
const scheduler = @import("../sched/scheduler.zig");
const transfer = @import("../ipc/transfer.zig");

const handle_module = @import("../cap/handle.zig");
const Handle = handle_module.Handle;
const SyscallFrame = @import("../arch/aarch64/trap.zig").SyscallFrame;

const thread_module = @import("../object/thread.zig");
const Thread = thread_module.Thread;
const Process = @import("../object/process.zig").Process;
const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const Region = @import("../memory/region.zig").Region;
const Endpoint = @import("../object/endpoint.zig").Endpoint;
const Notification = @import("../object/notification.zig").Notification;
const Message = @import("../ipc/message.zig").Message;

const Error = err.Error;
const VirtAddr = arch.VirtAddr;
const page_size = config.page_size;

pub const Number = enum(u64) {

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

// `create` kinds, in this ABI's own numbering (03-syscall-abi.md appendix). Interrupt/DMA regions arrive with M4/M7.

pub const CreateKind = enum(u64) {

    endpoint = 1,
    notification,
    address_space,
    region,

};

/// Trap entry: decode the verb in x8, run its handler, and write the signed ABI result back into x0.
pub fn dispatch(frame: *SyscallFrame) void {

    const result = run(frame);

    frame.registers[0] = @bitCast(err.to_abi(result));

}

fn run(frame: *SyscallFrame) Error!u64 {

    const number = std.meta.intToEnum(Number, frame.registers[8]) catch return error.Invalid;

    const a0 = frame.registers[0];
    const a1 = frame.registers[1];
    const a2 = frame.registers[2];
    const a3 = frame.registers[3];
    const a4 = frame.registers[4];

    return switch (number) {

        .create => create(a0, a1, a2),
        .spawn => spawn(a0, a1, a2, a3, a4),
        .close => close(a0),
        .start => start(a0),
        .yield => yield(),
        .configure => configure(a0, a1, a2),
        .map => map(a0, a1, a2, a3),
        .unmap => unmap(a0, a1),
        .send => send(a0, a1),
        .receive => receive(a0, a1),
        .call => call(a0, a1),
        .reply => reply(a0, a1),
        .notify => notify(a0, a1),
        .wait => wait(a0),
        .copy => copy(a0, a1),

        // Interrupt binding is gated by an InterruptAuthority (M4).

        .bind, .acknowledge => error.NotAllowed,

    };

}

// Lifecycle

fn create(kind_raw: u64, arg_a: u64, arg_b: u64) Error!u64 {

    _ = arg_b;

    const kind = std.meta.intToEnum(CreateKind, kind_raw) catch return error.Invalid;

    const created: *object.Object = switch (kind) {

        .endpoint => &(try Endpoint.create()).header,
        .notification => &(try Notification.create()).header,
        .address_space => &(try AddressSpace.create()).header,
        .region => &(try Region.create(arg_a)).header,

    };

    // The table takes its own reference on insert, so drop the creation reference either way.

    errdefer if (created.release()) object.destroy(created);

    const handle = try current_process().handles.insert(created);

    _ = created.release();

    return handle_word(handle);

}

fn spawn(space_raw: u64, entry: u64, stack: u64, grant_ptr: u64, grant_count: u64) Error!u64 {

    const space = try resolve_space(space_raw);

    if (grant_count > max_grants) return error.Invalid;

    var grants: [max_grants]*object.Object = undefined;
    const count: usize = @intCast(grant_count);

    var index: usize = 0;

    while (index < count) : (index += 1) {

        var word: u32 = 0;
        try copy_from_user(grant_ptr + index * @sizeOf(u32), std.mem.asBytes(&word));

        grants[index] = try current_process().handles.resolve(handle_from(word));

    }

    const child = try Process.spawn(space, entry, stack, grants[0..count], 0);

    errdefer child.destroy();

    return handle_word(try current_process().handles.insert(&child.header));

}

fn close(raw: u64) Error!u64 {

    // Exit falls out of the refcount model (03-syscall-abi.md): closing self ends the thread.

    if (raw == handle_module.self_thread or raw == handle_module.self_process) scheduler.exit_current();

    try current_process().handles.close(handle_from(@truncate(raw)));

    return 0;

}

fn start(raw: u64) Error!u64 {

    const thread = try current_process().handles.resolve_as(handle_from(@truncate(raw)), .thread);

    thread.start();

    return 0;

}

fn yield() Error!u64 {

    scheduler.yield();

    return 0;

}

fn configure(thread_raw: u64, attribute: u64, value: u64) Error!u64 {

    const thread = try resolve_thread(thread_raw);
    const which = std.meta.intToEnum(thread_module.Attribute, @as(u8, @truncate(attribute))) catch return error.Invalid;

    try thread.configure(which, value);

    return 0;

}

// Memory

fn map(space_raw: u64, region_raw: u64, address: u64, permissions: u64) Error!u64 {

    const space = try resolve_space(space_raw);
    const region = try current_process().handles.resolve_as(handle_from(@truncate(region_raw)), .region);

    const at: ?VirtAddr = if (address == 0) null else address;

    const mapped = try space.map(region, at, decode_permissions(permissions));

    return mapped;

}

fn unmap(space_raw: u64, address: u64) Error!u64 {

    const space = try resolve_space(space_raw);

    try space.unmap(address);

    return 0;

}

// IPC

fn send(endpoint_raw: u64, message_ptr: u64) Error!u64 {

    const handle = handle_from(@truncate(endpoint_raw));
    const endpoint = try current_process().handles.resolve_as(handle, .endpoint);

    const caller = current_thread();
    caller.send_badge = try current_process().handles.badge_of(handle);
    caller.message_buffer = message_ptr;

    try read_message(caller, message_ptr);
    try transfer.send(caller, endpoint);

    return 0;

}

fn receive(endpoint_raw: u64, message_ptr: u64) Error!u64 {

    const endpoint = try current_process().handles.resolve_as(handle_from(@truncate(endpoint_raw)), .endpoint);

    const server = current_thread();
    server.message_buffer = message_ptr;

    const badge = try transfer.receive(server, endpoint);

    try write_message(server, message_ptr);

    return badge;

}

fn call(endpoint_raw: u64, message_ptr: u64) Error!u64 {

    const handle = handle_from(@truncate(endpoint_raw));
    const endpoint = try current_process().handles.resolve_as(handle, .endpoint);

    const caller = current_thread();
    caller.send_badge = try current_process().handles.badge_of(handle);
    caller.message_buffer = message_ptr;

    try read_message(caller, message_ptr);
    try transfer.call(caller, endpoint);

    // The reply landed in the caller's staged envelope while it was blocked; hand it back to user space.

    try write_message(caller, message_ptr);

    return 0;

}

fn reply(reply_raw: u64, message_ptr: u64) Error!u64 {

    const server = current_thread();

    try read_message(server, message_ptr);
    try transfer.reply(server, handle_from(@truncate(reply_raw)));

    return 0;

}

fn notify(notification_raw: u64, bits: u64) Error!u64 {

    const notification = try current_process().handles.resolve_as(handle_from(@truncate(notification_raw)), .notification);

    notification.signal(bits);

    return 0;

}

fn wait(notification_raw: u64) Error!u64 {

    const notification = try current_process().handles.resolve_as(handle_from(@truncate(notification_raw)), .notification);

    const waiter = current_thread();

    if (notification.poll_or_block(waiter)) |bits| return bits;

    scheduler.block(scheduler.current_core(), waiter, &notification.header);

    return waiter.notify_bits;

}

// Handles

fn copy(handle_raw: u64, badge: u64) Error!u64 {

    return handle_word(try current_process().handles.copy(handle_from(@truncate(handle_raw)), badge));

}

// Context

fn current_thread() *Thread {

    return scheduler.current_core().current.?;

}

fn current_process() *Process {

    return current_thread().process;

}

// Handles

const max_grants = 16;

fn handle_from(raw: u32) Handle {

    return @bitCast(raw);

}

fn handle_word(handle: Handle) u64 {

    return @as(u32, @bitCast(handle));

}

fn resolve_space(raw: u64) Error!*AddressSpace {

    if (raw == handle_module.self_space) return current_process().address_space;

    return current_process().handles.resolve_as(handle_from(@truncate(raw)), .address_space);

}

fn resolve_thread(raw: u64) Error!*Thread {

    if (raw == handle_module.self_thread) return current_thread();

    return current_process().handles.resolve_as(handle_from(@truncate(raw)), .thread);

}

// permissions: bit0 read, bit1 write, bit2 execute (03-syscall-abi.md Memory). User mappings are always EL0-visible.

fn decode_permissions(bits: u64) arch.Permissions {

    return .{

        .read = bits & 0b001 != 0,
        .write = bits & 0b010 != 0,
        .execute = bits & 0b100 != 0,
        .user = true,

    };

}

// User-memory copies

// The envelope is copied through the process's page tables (arch.translate), so it works with any TTBR0 loaded and tolerates a buffer that straddles a page boundary (a Message on the user stack need not be page-aligned).

fn read_message(into: *Thread, message_ptr: VirtAddr) Error!void {

    try copy_from_user_of(into, message_ptr, std.mem.asBytes(&into.staged));

}

fn write_message(from: *Thread, message_ptr: VirtAddr) Error!void {

    try copy_to_user_of(from, message_ptr, std.mem.asBytes(&from.staged));

}

fn copy_from_user(va: VirtAddr, dest: []u8) Error!void {

    try copy_from_user_of(current_thread(), va, dest);

}

fn copy_from_user_of(owner: *Thread, va: VirtAddr, dest: []u8) Error!void {

    const root = owner.process.address_space.root;

    var offset: usize = 0;

    while (offset < dest.len) {

        const user = va + offset;
        const physical = arch.translate(root, user & ~(page_size - 1)) orelse return error.Invalid;

        const in_page = user & (page_size - 1);
        const chunk = @min(page_size - in_page, dest.len - offset);

        const source: [*]const u8 = @ptrFromInt(physical + in_page);
        @memcpy(dest[offset .. offset + chunk], source[0..chunk]);

        offset += chunk;

    }

}

fn copy_to_user_of(owner: *Thread, va: VirtAddr, source: []const u8) Error!void {

    const root = owner.process.address_space.root;

    var offset: usize = 0;

    while (offset < source.len) {

        const user = va + offset;
        const physical = arch.translate(root, user & ~(page_size - 1)) orelse return error.Invalid;

        const in_page = user & (page_size - 1);
        const chunk = @min(page_size - in_page, source.len - offset);

        const destination: [*]u8 = @ptrFromInt(physical + in_page);
        @memcpy(destination[0..chunk], source[offset .. offset + chunk]);

        offset += chunk;

    }

}

const std = @import("std");
