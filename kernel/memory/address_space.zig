// AddressSpace (06-kernel-ddd.md Section 6.3): the page-table container with map/unmap/activate; COW and a full VMA tree are deferred.

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const slab = @import("slab.zig");
const object = @import("../object/object.zig");

const Region = @import("region.zig").Region;
const Error = @import("../error.zig").Error;

const VirtAddr = arch.VirtAddr;
const PhysAddr = arch.PhysAddr;
const Permissions = arch.Permissions;
const page_size = config.page_size;

const max_mappings = 8;

// Kernel-chosen mappings land in the user window (config.user_space_base): above 512 GiB, clear of the kernel's
// block-mapped identity range that every process root shares (06-kernel-ddd.md Section 6.3; arch/aarch64/mmu.zig).
const default_base: VirtAddr = config.user_space_base;

var cache: slab.Cache(AddressSpace) = .{};

const Mapping = struct {

    base: VirtAddr,
    pages: usize,
    active: bool,

};

pub const AddressSpace = struct {

    header: object.Object,
    root: PhysAddr,
    next_base: VirtAddr,
    mappings: [max_mappings]Mapping,

    pub fn create() Error!*AddressSpace {

        const root = try arch.new_table();
        errdefer arch.free_table(root);

        const space = try cache.alloc();
        space.* = .{

            .header = .{ .kind = .address_space },
            .root = root,
            .next_base = default_base,
            .mappings = undefined,
        };

        for (&space.mappings) |*mapping| {

            mapping.active = false;

        }

        return space;

    }

    /// Place `region` at `at` (or a kernel-chosen address when null), returning the base virtual address.
    pub fn map(self: *AddressSpace, region: *Region, at: ?VirtAddr, perms: Permissions) Error!VirtAddr {

        const slot = self.free_slot() orelse return error.NoMemory;
        const base = at orelse self.next_base;

        // A device window carries its memory type with it; callers only choose access rights.

        var effective = perms;
        effective.device = region.device;

        for (0..region.pages) |index| {

            try arch.map_page(self.root, base + index * page_size, region.frame(index), effective);

        }

        slot.* = .{ .base = base, .pages = region.pages, .active = true };

        const end = base + region.pages * page_size;

        if (end > self.next_base) self.next_base = end;

        return base;

    }

    pub fn unmap(self: *AddressSpace, at: VirtAddr) Error!void {

        const slot = self.find(at) orelse return error.NotFound;

        for (0..slot.pages) |index| {

            arch.unmap_page(self.root, at + index * page_size);

        }

        slot.active = false;

    }

    pub fn activate(self: *AddressSpace) void {

        arch.activate_space(self.root);

    }

    pub fn destroy(self: *AddressSpace) void {

        arch.free_table(self.root);
        cache.free(self);

    }

    fn free_slot(self: *AddressSpace) ?*Mapping {

        for (&self.mappings) |*mapping| {

            if (!mapping.active) return mapping;

        }

        return null;

    }

    fn find(self: *AddressSpace, base: VirtAddr) ?*Mapping {

        for (&self.mappings) |*mapping| {

            if (mapping.active and mapping.base == base) return mapping;

        }

        return null;

    }
};

pub fn init() void {

    cache.init();

}
