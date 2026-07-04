// Interrupt authority (06-kernel-ddd.md Section 11): gates `create(.interrupt, ...)`. Only the boot hand-off mints one, so hardware lines reach a driver only through the Startup Binary.

const config = @import("../config.zig");
const slab = @import("../memory/slab.zig");
const object = @import("../object/object.zig");

const Error = @import("../error.zig").Error;

var cache: slab.Cache(InterruptAuthority) = .{};

pub const InterruptAuthority = struct {

    header: object.Object,

    pub fn create() Error!*InterruptAuthority {

        const authority = try cache.alloc();
        authority.* = .{

            .header = .{ .kind = .interrupt_authority },

        };

        return authority;

    }

    // M4 mints only the root authority, which spans the machine; per-line sub-authorities are a later refinement.
    pub fn allows(self: *InterruptAuthority, line: u32) bool {

        _ = self;

        return line < config.max_interrupt_lines;

    }

    pub fn destroy(self: *InterruptAuthority) void {

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}
