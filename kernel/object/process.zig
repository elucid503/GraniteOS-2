// Process (06-kernel-ddd.md Section 7.2): the resource container - one AddressSpace, a HandleTable, and its threads. The memory-authority budget (hierarchical-lite, Section 11) arrives with M4.

const config = @import("../config.zig");
const slab = @import("../memory/slab.zig");
const object = @import("object.zig");

const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const HandleTable = @import("../cap/handle_table.zig").HandleTable;
const Thread = @import("thread.zig").Thread;
const Error = @import("../error.zig").Error;

const VirtAddr = @import("../types.zig").VirtAddr;

var cache: slab.Cache(Process) = .{};

pub const Process = struct {

    header: object.Object,
    address_space: *AddressSpace,
    handles: HandleTable,
    threads: ?*Thread,

    pub fn create(space: *AddressSpace) Error!*Process {

        const process = try cache.alloc();
        errdefer cache.free(process);

        process.* = .{

            .header = .{ .kind = .process },
            .address_space = space,
            .handles = undefined,
            .threads = null,

        };

        try process.handles.init();

        space.header.retain();

        return process;

    }

    /// The capability-passing replacement for fork+exec (03-syscall-abi.md spawn): build a process over a prepared
    /// `space`, pre-load its handle table with the `grants`, then create and start its first user thread at `entry`.
    /// `arg` reaches that thread as its first argument (the init-message pointer). Callers hand raw object pointers;
    /// the syscall layer resolves the grant *handles* from the parent's table before calling in.
    pub fn spawn(space: *AddressSpace, entry: VirtAddr, user_stack: VirtAddr, grants: []const *object.Object, arg: u64) Error!*Process {

        const process = try create(space);
        errdefer process.destroy();

        for (grants) |granted| {

            _ = try process.handles.insert(granted);

        }

        const thread = try Thread.create_user(process, entry, user_stack, arg);
        thread.start();

        return process;

    }

    pub fn destroy(self: *Process) void {

        self.handles.deinit();

        if (self.address_space.header.release()) self.address_space.destroy();

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
