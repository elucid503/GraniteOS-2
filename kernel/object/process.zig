// Process (06-kernel-ddd.md Section 7.2): the resource container - one AddressSpace, a HandleTable, and its threads. `spawn` and the memory-authority budget arrive with M3.

const slab = @import("../memory/slab.zig");
const object = @import("object.zig");

const AddressSpace = @import("../memory/address_space.zig").AddressSpace;
const HandleTable = @import("../cap/handle_table.zig").HandleTable;
const Thread = @import("thread.zig").Thread;
const Error = @import("../error.zig").Error;

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

    pub fn destroy(self: *Process) void {

        self.handles.deinit();

        if (self.address_space.header.release()) self.address_space.destroy();

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
