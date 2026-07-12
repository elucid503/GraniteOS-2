// Process (06-kernel-ddd.md Section 7.2): the resource container - one AddressSpace, a HandleTable, and its threads. The memory-authority budget (hierarchical-lite, Section 11) arrives with M4.

const inspect = @import("../inspect.zig");
const slab = @import("../memory/slab.zig");
const object = @import("object.zig");
const spinlock = @import("../sync/spinlock.zig");

const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const HandleTable = @import("../cap/handle_table.zig").HandleTable;
const Thread = @import("thread.zig").Thread;
const Error = @import("../error.zig").Error;

const VirtAddr = @import("../types.zig").VirtAddr;

var cache: slab.Cache(Process) = .{};
var list_lock: spinlock.SpinLock = .{};
var list_head: ?*Process = null;
var next_pid: u32 = 1;

// One pre-placed capability: the object plus the badge it should carry in the child's table, so a
// badged endpoint survives the grant (the child cannot mint its own badge before it exists).

pub const Grant = struct {

    object: *object.Object,
    badge: u64 = 0,

};

pub const Process = struct {

    header: object.Object,
    pid: u32,
    name_len: u8,
    name: [inspect.process_name_bytes]u8,

    address_space: *AddressSpace,
    handles: HandleTable,
    thread_lock: spinlock.SpinLock,
    threads: ?*Thread,
    thread_count: u32,

    next_global: ?*Process,

    pub fn create(space: *AddressSpace) Error!*Process {

        const process = try cache.alloc();
        errdefer cache.free(process);

        process.* = .{

            .header = .{ .kind = .process },
            .pid = @atomicRmw(u32, &next_pid, .Add, 1, .monotonic),
            .name_len = 0,
            .name = [_]u8{0} ** inspect.process_name_bytes,

            .address_space = space,
            .handles = undefined,
            .thread_lock = .{},
            .threads = null,
            .thread_count = 0,

            .next_global = null,

        };

        try process.handles.init();

        space.header.retain();

        link_global(process);

        return process;

    }

    /// The capability-passing replacement for fork+exec (03-syscall-abi.md spawn): build a process over a prepared
    /// `space`, pre-load its handle table with the `grants`, then create and start its first user thread at `entry`.
    /// `arg` reaches that thread as its first argument (the init-message pointer). Callers hand `Grant`s (object plus
    /// badge); the syscall layer resolves the grant *handles* from the parent's table before calling in.
    pub fn spawn(space: *AddressSpace, entry: VirtAddr, user_stack: VirtAddr, grants: []const Grant, arg: u64) Error!*Process {

        const process = try create(space);
        errdefer process.destroy();

        for (grants) |granted| {

            _ = try process.handles.insert_badged(granted.object, granted.badge);

        }

        const thread = try Thread.create_user(process, entry, user_stack, arg);
        thread.start();

        return process;

    }

    pub fn destroy(self: *Process) void {

        unlink_global(self);

        // Drop mappings before closing handles so Region teardown runs while its MemoryAuthority is still reachable.
        if (self.address_space.header.release()) self.address_space.destroy();

        self.handles.deinit();

        cache.free(self);

    }

    pub fn set_name(self: *Process, name: []const u8) void {

        const length = @min(name.len, inspect.process_name_bytes);

        const saved = list_lock.acquire();
        defer list_lock.release(saved);

        self.name = [_]u8{0} ** inspect.process_name_bytes;
        @memcpy(self.name[0..length], name[0..length]);
        self.name_len = @intCast(length);

    }

};

pub fn note_thread_created(process: *Process) void {

    _ = @atomicRmw(u32, &process.thread_count, .Add, 1, .monotonic);

}

pub fn note_thread_destroyed(process: *Process) void {

    _ = @atomicRmw(u32, &process.thread_count, .Sub, 1, .monotonic);

}

pub fn snapshot(out: *inspect.ProcessSnapshot) void {

    out.* = .{

        .count = 0,
        .capacity = @intCast(inspect.max_processes),
        .total_threads = 0,
        .total_handles = 0,

        .processes = [_]inspect.ProcessInfo{empty_process_info()} ** inspect.max_processes,

    };

    // Collect a retained snapshot of the process list under the lock, then compute per-process handle stats after
    // releasing it: `stats`/`memory_usage` each take a process's own handle-table lock, which must never nest under
    // the global list lock (06-kernel-ddd.md Section 15 lock order). The retain keeps each process alive across the gap.

    var collected: [inspect.max_processes]*Process = undefined;
    var collected_count: usize = 0;

    {

        const saved = list_lock.acquire();
        defer list_lock.release(saved);

        var cursor = list_head;

        while (cursor) |process| : (cursor = process.next_global) {

            if (collected_count < inspect.max_processes) {

                process.header.retain();
                collected[collected_count] = process;
                collected_count += 1;

            }

            out.count += 1;

        }

    }

    for (collected[0..collected_count], 0..) |process, index| {

        var by_kind: [inspect.object_kind_slots]u32 = undefined;
        const handles = process.handles.stats(&by_kind);
        const memory_bytes = process.handles.memory_usage();
        const threads = @atomicLoad(u32, &process.thread_count, .monotonic);

        out.total_threads += threads;
        out.total_handles += handles;

        out.processes[index] = .{

            .pid = process.pid,
            .name_len = @intCast(process.name_len),
            .thread_count = threads,
            .handle_count = handles,

            .memory_bytes = memory_bytes,

            .name = process.name,
            .handles_by_kind = by_kind,

        };

        if (process.header.release()) object.destroy(&process.header);

    }

}

fn link_global(process: *Process) void {

    const saved = list_lock.acquire();
    defer list_lock.release(saved);

    process.next_global = list_head;
    list_head = process;

}

fn unlink_global(process: *Process) void {

    const saved = list_lock.acquire();
    defer list_lock.release(saved);

    var link = &list_head;

    while (link.*) |candidate| {

        if (candidate == process) {

            link.* = process.next_global;
            process.next_global = null;
            return;

        }

        link = &candidate.next_global;

    }

}

fn empty_process_info() inspect.ProcessInfo {

    return .{

        .pid = 0,
        .name_len = 0,
        .thread_count = 0,
        .handle_count = 0,

        .memory_bytes = 0,

        .name = [_]u8{0} ** inspect.process_name_bytes,
        .handles_by_kind = [_]u32{0} ** inspect.object_kind_slots,

    };

}

pub fn init() void {

    cache.init();
    list_lock = .{};
    list_head = null;
    next_pid = 1;

}
