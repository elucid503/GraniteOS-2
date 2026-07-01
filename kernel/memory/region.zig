// Region (06-kernel-ddd.md Section 6.4): a contiguous run of RAM frames mapped into an AddressSpace; device/COW/authority deferred.

const std = @import("std");

const config = @import("../config.zig");
const frames = @import("frames.zig");
const slab = @import("slab.zig");
const object = @import("../object/object.zig");

const types = @import("../types.zig");
const Error = @import("../error.zig").Error;

const PhysAddr = types.PhysAddr;
const page_size = config.page_size;

var cache: slab.Cache(Region) = .{};

pub const Region = struct {

    header: object.Object,
    base: PhysAddr,

    pages: usize,
    length: usize,

    copy_on_write: bool,
    device: bool,

    /// A RAM region large enough to hold `length` bytes (06-kernel-ddd.md Section 6.4; authority gating arrives with M3).
    pub fn create(length: usize) Error!*Region {

        const pages = (length + page_size - 1) / page_size;
        const base = try frames.alloc_contiguous(pages);
        errdefer frames.free_contiguous(base, pages);

        const region = try cache.alloc();
        region.* = .{

            .header = .{ .kind = .region },
            .base = base,

            .pages = pages,
            .length = length,

            .copy_on_write = false,
            .device = false,

        };

        return region;

    }

    pub fn destroy(self: *Region) void {

        frames.free_contiguous(self.base, self.pages);
        cache.free(self);

    }

    pub fn frame(self: *const Region, index: usize) PhysAddr {

        return self.base + index * page_size;

    }

};

pub fn init() void {

    cache.init();

}

const testing = std.testing;

test "a region claims and returns its frames" {

    const pool = std.heap.page_allocator.alloc(u8, 256 * page_size) catch unreachable;
    defer std.heap.page_allocator.free(pool);

    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    init();

    const baseline = frames.stats().free;

    const region = try Region.create(3 * page_size);

    try testing.expectEqual(@as(usize, 3), region.pages);
    try testing.expect(frames.stats().free < baseline);

    region.destroy();
    try testing.expectEqual(baseline, frames.stats().free);

}
