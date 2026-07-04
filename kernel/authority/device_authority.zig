// Device authority (06-kernel-ddd.md Section 11): gates device/MMIO Region creation, so a driver can be handed exactly its own hardware window and nothing else.

const slab = @import("../memory/slab.zig");
const object = @import("../object/object.zig");

const types = @import("../types.zig");
const Error = @import("../error.zig").Error;

const PhysAddr = types.PhysAddr;

var cache: slab.Cache(DeviceAuthority) = .{};

pub const DeviceAuthority = struct {

    header: object.Object,

    pub fn create() Error!*DeviceAuthority {

        const authority = try cache.alloc();
        authority.* = .{

            .header = .{ .kind = .device_authority },

        };

        return authority;

    }

    // M4 mints only the root authority, which spans the machine; per-window sub-authorities are a later refinement.
    pub fn allows(self: *DeviceAuthority, base: PhysAddr, length: usize) bool {

        _ = self;
        _ = base;

        return length != 0;

    }

    pub fn destroy(self: *DeviceAuthority) void {

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
