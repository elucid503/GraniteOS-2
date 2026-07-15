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

const max_mappings = 64;

// Kernel-chosen mappings start above 512 GiB, clear of the shared kernel identity block in every process root.
const default_base: VirtAddr = config.user_space_base;

var cache: slab.Cache(AddressSpace) = .{};

const Mapping = struct {

    base: VirtAddr,
    pages: usize,
    active: bool,
    region: ?*Region,

};

pub const AddressSpace = struct {

    header: object.Object,
    root: PhysAddr,
    next_base: VirtAddr,
    mappings: [max_mappings]Mapping,

    // ASID tagging (Stage 1.4): assigned lazily on first activation, re-derived after a generation rollover.
    asid: u16,
    asid_generation: u64,

    pub fn create() Error!*AddressSpace {

        const root = try arch.new_table();
        errdefer arch.free_table(root);

        const space = try cache.alloc();
        space.* = .{

            .header = .{ .kind = .address_space },
            .root = root,
            .next_base = default_base,
            .mappings = undefined,

            .asid = 0,
            .asid_generation = 0,
        };

        for (&space.mappings) |*mapping| {

            mapping.* = .{

                .base = 0,
                .pages = 0,
                .active = false,
                .region = null,

            };

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
        effective.uncached = region.uncached;

        // Contiguous Region frames map in one batched `map_range` with a single TLB flush.

        try arch.map_range(self.root, base, region.frame(0), region.pages, effective);

        region.header.retain();

        slot.* = .{

            .base = base,
            .pages = region.pages,
            .active = true,
            .region = region,

        };

        const end = base + region.pages * page_size;

        if (end > self.next_base) self.next_base = end;

        return base;

    }

    pub fn unmap(self: *AddressSpace, at: VirtAddr) Error!void {

        const slot = self.find(at) orelse return error.NotFound;

        self.release_mapping(slot);

    }

    fn release_mapping(self: *AddressSpace, slot: *Mapping) void {

        arch.unmap_range(self.root, slot.base, slot.pages);

        slot.active = false;
        slot.base = 0;
        slot.pages = 0;

        if (slot.region) |region| {

            slot.region = null;

            if (region.header.release()) object.destroy(&region.header);

        }

    }

    /// The ASID for this space, allocated (or re-derived after a rollover) on demand.
    pub fn ensure_asid(self: *AddressSpace) u16 {

        return arch.ensure_space_asid(&self.asid, &self.asid_generation);

    }

    /// The TTBR0 value to load for this space: the page-table root with the ASID in bits [63:48].
    pub fn ttbr(self: *AddressSpace) u64 {

        return self.root | (@as(u64, self.ensure_asid()) << 48);

    }

    pub fn activate(self: *AddressSpace) void {

        arch.activate_space(self.ttbr());

    }

    pub fn destroy(self: *AddressSpace) void {

        for (&self.mappings) |*mapping| {

            if (mapping.active) self.release_mapping(mapping);

        }

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
