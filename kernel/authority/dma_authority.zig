// DMA authority (06-kernel-ddd.md Section 16.3): gates `create(.dma_region, ...)`. Only the boot hand-off mints one, so a driver can fill device descriptors with physical addresses only if Flint granted it that trust.

const slab = @import("../memory/slab.zig");
const object = @import("../object/object.zig");

const Error = @import("../error.zig").Error;

var cache: slab.Cache(DmaAuthority) = .{};

pub const DmaAuthority = struct {

    header: object.Object,

    pub fn create() Error!*DmaAuthority {

        const authority = try cache.alloc();
        authority.* = .{

            .header = .{ .kind = .dma_authority },

        };

        return authority;

    }

    // Holders are trusted until an IOMMU/SMMU confines transfers (06-kernel-ddd.md Section 18); the root spans RAM.
    pub fn allows(self: *DmaAuthority, pages: usize) bool {

        _ = self;

        return pages != 0;

    }

    pub fn destroy(self: *DmaAuthority) void {

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
