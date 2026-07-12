// Syscall dispatch (06-kernel-ddd.md Section 12; 03-syscall-abi.md): the one entry from the EL0 trap path.

const build_options = @import("build_options");

const arch = @import("../arch/arch.zig");
const config = @import("../config.zig");
const err = @import("../error.zig");
const inspect = @import("../inspect.zig");
const object = @import("../object/object.zig");
const scheduler = @import("../sched/scheduler.zig");
const transfer = @import("../ipc/transfer.zig");

const handle_module = @import("../cap/handle.zig");
const Handle = handle_module.Handle;
const SyscallFrame = @import("../arch/aarch64/trap.zig").SyscallFrame;

const thread_module = @import("../object/thread.zig");
const process_module = @import("../object/process.zig");
const Thread = thread_module.Thread;
const Process = process_module.Process;
const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const Region = @import("../memory/region.zig").Region;
const Endpoint = @import("../object/endpoint.zig").Endpoint;
const Notification = @import("../object/notification.zig").Notification;
const Interrupt = @import("../object/interrupt.zig").Interrupt;
const MemoryAuthority = @import("../authority/memory_authority.zig").MemoryAuthority;
const message_module = @import("../ipc/message.zig");
const Message = message_module.Message;
const notification_wake = message_module.notification_wake;

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
    inspect,
    set_name,
    sleep,

};

// `create` kinds, in this ABI's own numbering (03-syscall-abi.md appendix); the numbers are append-only. The gated
// kinds carry the granting authority's handle as their last argument.

pub const CreateKind = enum(u64) {

    endpoint = 1,
    notification,
    address_space,
    region, // x1 = length, x2 = MemoryAuthority handle
    interrupt, // x1 = line, x2 = InterruptAuthority handle
    memory_authority, // x1 = budget bytes, x2 = parent MemoryAuthority handle
    device_region, // x1 = physical base, x2 = length, x3 = DeviceAuthority handle
    dma_region, // x1 = length, x2 = DmaAuthority handle; returns the physical base in x1
    thread, // x1 = AddressSpace handle (the caller's own), x2 = entry VA, x3 = stack top VA

};

pub var debug_last_number: u64 = 0;
pub var debug_last_arg0: u64 = 0;
pub var debug_last_arg1: u64 = 0;

/// Trap entry: decode the verb in x8, run its handler, and write the signed ABI result back into x0.
pub fn dispatch(frame: *SyscallFrame) void {

    // These per-syscall stores are only read by the panic path; gate them off the hot path unless asked for
    // (build with -Ddebug-syscall-trace).

    if (build_options.debug_syscall_trace) {

        debug_last_number = frame.registers[8];
        debug_last_arg0 = frame.registers[0];
        debug_last_arg1 = frame.registers[1];

    }

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

        .create => create(frame, a0, a1, a2, a3),
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
        .bind => bind(a0, a1, a2),
        .acknowledge => acknowledge(a0),
        .copy => copy(a0, a1),
        .inspect => inspect_call(a0, a1, a2),
        .set_name => set_name(a0, a1),
        .sleep => sleep(a0),

    };

}

// Lifecycle

fn create(frame: *SyscallFrame, kind_raw: u64, arg_a: u64, arg_b: u64, arg_c: u64) Error!u64 {

    const kind = std.meta.intToEnum(CreateKind, kind_raw) catch return error.Invalid;

    const created: *object.Object = switch (kind) {

        .endpoint => &(try Endpoint.create()).header,
        .notification => &(try Notification.create()).header,
        .address_space => &(try AddressSpace.create()).header,
        .region => &(try create_region(arg_a, arg_b)).header,
        .interrupt => &(try create_interrupt(arg_a, arg_b)).header,
        .memory_authority => &(try create_memory_authority(arg_a, arg_b)).header,
        .device_region => &(try create_device_region(arg_a, arg_b, arg_c)).header,
        .dma_region => &(try create_dma_region(frame, arg_a, arg_b)).header,
        .thread => &(try create_thread(arg_a, arg_b, arg_c)).header,

    };

    // The table takes its own reference on insert, so drop the creation reference either way.

    errdefer if (created.release()) object.destroy(created);

    const handle = try current_process().handles.insert(created);

    _ = created.release();

    return handle_word(handle);

}

// A user Region is always charged against a MemoryAuthority (04-boot-and-bootstrap.md: no ambient authority).

fn create_region(length: u64, authority_raw: u64) Error!*Region {

    const authority = try resolve_as(authority_raw, .memory_authority);

    const bytes = std.mem.alignForward(u64, length, page_size);

    try authority.charge(bytes);
    errdefer authority.refund(bytes);

    const region = try Region.create(length);

    region.charge_to(authority);

    return region;

}

fn create_interrupt(line: u64, authority_raw: u64) Error!*Interrupt {

    const authority = try resolve_as(authority_raw, .interrupt_authority);

    if (line > std.math.maxInt(u32)) return error.Invalid;
    if (!authority.allows(@intCast(line))) return error.NotAllowed;

    return Interrupt.create(@intCast(line));

}

fn create_memory_authority(budget: u64, parent_raw: u64) Error!*MemoryAuthority {

    const parent = try resolve_as(parent_raw, .memory_authority);

    return parent.create_child(budget);

}

fn create_device_region(base: u64, length: u64, authority_raw: u64) Error!*Region {

    const authority = try resolve_as(authority_raw, .device_authority);

    if (!authority.allows(base, length)) return error.NotAllowed;

    return Region.create_device(base, length);

}

// A DMA buffer is contiguous RAM whose physical base the driver must know (06-kernel-ddd.md Section 16.3): the one
// place a syscall uses a second return register, keeping the core ABI small.

fn create_dma_region(frame: *SyscallFrame, length: u64, authority_raw: u64) Error!*Region {

    const authority = try resolve_as(authority_raw, .dma_authority);

    const pages = (length + page_size - 1) / page_size;

    if (!authority.allows(pages)) return error.NotAllowed;

    const region = try Region.create_dma(length);

    frame.registers[1] = region.base;

    return region;

}

// A worker thread for a server pool (05-server-protocol.md): it lives in the calling process, begins suspended, and
// `start` admits it. The space handle must name the caller's own AddressSpace.

fn create_thread(space_raw: u64, entry: u64, stack_top: u64) Error!*Thread {

    const space = try resolve_space(space_raw);

    if (space != current_process().address_space) return error.NotAllowed;
    if (entry == 0 or stack_top == 0) return error.Invalid;

    return Thread.create_user(current_process(), entry, stack_top, 0);

}

fn spawn(space_raw: u64, entry: u64, stack: u64, grant_ptr: u64, grant_count: u64) Error!u64 {

    const space = try resolve_space(space_raw);

    if (grant_count > max_grants) return error.Invalid;

    var grants: [max_grants]process_module.Grant = undefined;
    const count: usize = @intCast(grant_count);

    var index: usize = 0;

    while (index < count) : (index += 1) {

        var word: u32 = 0;
        try copy_from_user(grant_ptr + index * @sizeOf(u32), std.mem.asBytes(&word));

        const handle = handle_from(word);

        // The badge travels with the grant, so a badged endpoint copy lands badged in the child.

        grants[index] = .{

            .object = try current_process().handles.resolve(handle),
            .badge = try current_process().handles.badge_of(handle),

        };

    }

    const child = try Process.spawn(space, entry, stack, grants[0..count], 0);

    const child_handle = try current_process().handles.insert(&child.header);
    _ = child.header.release();

    return handle_word(child_handle);

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

fn sleep(ns: u64) Error!u64 {

    scheduler.sleep(ns);

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

    const perms = decode_permissions(permissions);
    const mapped = try space.map(region, at, perms);

    // The caller filled these pages through another (data) mapping; make the writes visible to instruction fetch.

    if (perms.execute) arch.sync_instruction_cache();

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

    // A bound-notification wake carries no request: hand back only the event bits (03-syscall-abi.md Multi-wait).

    if (badge == notification_wake) {

        server.staged = Message.zeroed;
        server.staged.data[0] = server.notify_bits;

    }

    try write_message(server, server.message_buffer);

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

    try write_message(caller, caller.message_buffer);

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

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const notification = try current_process().handles.resolve_as(handle_from(@truncate(notification_raw)), .notification);

    const waiter = current_thread();

    if (notification.poll_or_block(waiter)) |bits| return bits;

    scheduler.block(scheduler.current_core(), waiter);

    return waiter.notify_bits;

}

// Interrupts

fn bind(interrupt_raw: u64, notification_raw: u64, bits: u64) Error!u64 {

    const interrupt = try resolve_as(interrupt_raw, .interrupt);
    const notification = try resolve_as(notification_raw, .notification);

    try interrupt.bind(notification, bits);

    return 0;

}

fn acknowledge(interrupt_raw: u64) Error!u64 {

    const interrupt = try resolve_as(interrupt_raw, .interrupt);

    try interrupt.acknowledge();

    return 0;

}

// Handles

fn copy(handle_raw: u64, badge: u64) Error!u64 {

    return handle_word(try current_process().handles.copy(handle_from(@truncate(handle_raw)), badge));

}

// Inspection

fn inspect_call(kind_raw: u64, out_ptr: u64, capacity: u64) Error!u64 {

    const kind = std.meta.intToEnum(inspect.Kind, kind_raw) catch return error.Invalid;

    return switch (kind) {

        .scheduler => write_snapshot(inspect.SchedulerSnapshot, out_ptr, capacity, scheduler.scheduler_snapshot),
        .processes => write_snapshot(inspect.ProcessSnapshot, out_ptr, capacity, process_module.snapshot),
        .cpu => write_snapshot(inspect.CpuSnapshot, out_ptr, capacity, scheduler.cpu_snapshot),
        .memory => write_snapshot(inspect.MemorySnapshot, out_ptr, capacity, inspect.memory_snapshot),

    };

}

fn write_snapshot(comptime T: type, out_ptr: u64, capacity: u64, fill: *const fn (*T) void) Error!u64 {

    if (capacity < @sizeOf(T)) return error.Invalid;

    var snapshot: T = undefined;

    fill(&snapshot);
    try copy_to_user(@intCast(out_ptr), std.mem.asBytes(&snapshot));

    return @intCast(@sizeOf(T));

}

fn set_name(name_ptr: u64, length_raw: u64) Error!u64 {

    var name: [inspect.process_name_bytes]u8 = undefined;
    const amount: usize = @intCast(@min(length_raw, @as(u64, inspect.process_name_bytes)));

    try copy_from_user(@intCast(name_ptr), name[0..amount]);

    current_process().set_name(name[0..amount]);

    return 0;

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

fn resolve_as(raw: u64, comptime kind: object.Kind) Error!*object.TypeOf(kind) {

    return current_process().handles.resolve_as(handle_from(@truncate(raw)), kind);

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
    if (into.staged.handle_count > config.message_handle_slots) return error.Invalid;

}

fn write_message(from: *Thread, message_ptr: VirtAddr) Error!void {

    try copy_to_user_of(from, message_ptr, std.mem.asBytes(&from.staged));

}

fn copy_from_user(va: VirtAddr, dest: []u8) Error!void {

    try copy_from_user_of(current_thread(), va, dest);

}

fn copy_to_user(va: VirtAddr, source: []const u8) Error!void {

    try copy_to_user_of(current_thread(), va, source);

}

fn copy_from_user_of(owner: *Thread, va: VirtAddr, dest: []u8) Error!void {

    if (dest.len == 0) return;

    const root = owner.process.address_space.root;

    // Fast path (the common case): the whole buffer sits in one page, so one translate and one memcpy suffice.

    if (va & ~(page_size - 1) == (va + dest.len - 1) & ~(page_size - 1)) {

        const physical = arch.translate(root, va & ~(page_size - 1)) orelse return error.Invalid;

        const source: [*]const u8 = @ptrFromInt(physical + (va & (page_size - 1)));
        @memcpy(dest, source[0..dest.len]);

        return;

    }

    // Straddling buffer: walk it page by page, reusing the last translation while chunks stay in the same page.

    var offset: usize = 0;
    var cached_page: VirtAddr = 0;
    var cached_phys: arch.PhysAddr = 0;
    var have_cache = false;

    while (offset < dest.len) {

        const user = va + offset;
        const page = user & ~(page_size - 1);

        if (!have_cache or page != cached_page) {

            cached_phys = arch.translate(root, page) orelse return error.Invalid;
            cached_page = page;
            have_cache = true;

        }

        const in_page = user & (page_size - 1);
        const chunk = @min(page_size - in_page, dest.len - offset);

        const source: [*]const u8 = @ptrFromInt(cached_phys + in_page);
        @memcpy(dest[offset .. offset + chunk], source[0..chunk]);

        offset += chunk;

    }

}

fn copy_to_user_of(owner: *Thread, va: VirtAddr, source: []const u8) Error!void {

    if (source.len == 0) return;

    const root = owner.process.address_space.root;

    if (va & ~(page_size - 1) == (va + source.len - 1) & ~(page_size - 1)) {

        const physical = arch.translate(root, va & ~(page_size - 1)) orelse return error.Invalid;

        const destination: [*]u8 = @ptrFromInt(physical + (va & (page_size - 1)));
        @memcpy(destination[0..source.len], source);

        return;

    }

    var offset: usize = 0;
    var cached_page: VirtAddr = 0;
    var cached_phys: arch.PhysAddr = 0;
    var have_cache = false;

    while (offset < source.len) {

        const user = va + offset;
        const page = user & ~(page_size - 1);

        if (!have_cache or page != cached_page) {

            cached_phys = arch.translate(root, page) orelse return error.Invalid;
            cached_page = page;
            have_cache = true;

        }

        const in_page = user & (page_size - 1);
        const chunk = @min(page_size - in_page, source.len - offset);

        const destination: [*]u8 = @ptrFromInt(cached_phys + in_page);
        @memcpy(destination[0..chunk], source[offset .. offset + chunk]);

        offset += chunk;

    }

}

const std = @import("std");
