// Region (06-kernel-ddd.md Section 6.4): a contiguous run of RAM frames or a device/MMIO window mapped into an AddressSpace; COW deferred.

const std = @import("std");

const arch = @import("../arch/arch.zig");
const config = @import("../config.zig");
const frames = @import("frames.zig");
const slab = @import("slab.zig");
const object = @import("../object/object.zig");

const MemoryAuthority = @import("../authority/memory_authority.zig").MemoryAuthority;
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
    uncached: bool,

    // RAM regions own their frames; device windows and wrapped boot spans only view physical memory.
    owns_frames: bool,

    // The budget this region was charged against (syscall path only); refunded at the last close.
    authority: ?*MemoryAuthority,

    /// A RAM region large enough to hold `length` bytes. Kernel-internal callers are unbudgeted; the syscall layer charges an authority and records it via `charge_to`.
    pub fn create(length: usize) Error!*Region {

        const pages = page_count(length);
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
            .uncached = false,

            .owns_frames = true,
            .authority = null,

        };

        return region;

    }

    /// A RAM region intended for device DMA.
    pub fn create_dma(length: usize) Error!*Region {

        const region = try create(length);
        arch.clean_invalidate_data_cache(region.base, region.pages * page_size);
        region.uncached = true;

        return region;

    }

    /// A device/MMIO window over `[base, base+length)`; the syscall layer has already checked the caller's DeviceAuthority. Mapped with device-memory attributes and never freed back to the frame pool.
    pub fn create_device(base: PhysAddr, length: usize) Error!*Region {

        if (base % page_size != 0 or length == 0) return error.Invalid;

        const region = try cache.alloc();
        region.* = .{

            .header = .{ .kind = .region },
            .base = base,

            .pages = page_count(length),
            .length = length,

            .copy_on_write = false,
            .device = true,
            .uncached = false,

            .owns_frames = false,
            .authority = null,

        };

        return region;

    }

    /// A read-only view over RAM the kernel already owns and has reserved (the DTB, a boot module); the frames outlive the region.
    pub fn wrap(base: PhysAddr, length: usize) Error!*Region {

        if (base % page_size != 0 or length == 0) return error.Invalid;

        const region = try cache.alloc();
        region.* = .{

            .header = .{ .kind = .region },
            .base = base,

            .pages = page_count(length),
            .length = length,

            .copy_on_write = false,
            .device = false,
            .uncached = false,

            .owns_frames = false,
            .authority = null,

        };

        return region;

    }

    /// Record the budget this region was charged against; the last close refunds it (06-kernel-ddd.md Section 11).
    pub fn charge_to(self: *Region, authority: *MemoryAuthority) void {

        authority.header.retain();
        self.authority = authority;

    }

    pub fn charged_bytes(self: *const Region) usize {

        return self.pages * page_size;

    }

    pub fn destroy(self: *Region) void {

        if (self.authority) |authority| {

            authority.refund(self.charged_bytes());

            if (authority.header.release()) object.destroy(&authority.header);

        }

        if (self.owns_frames) {

            frames.free_contiguous(self.base, self.pages);

        }

        cache.free(self);

    }

    pub fn frame(self: *const Region, index: usize) PhysAddr {

        return self.base + index * page_size;

    }

};

fn page_count(length: usize) usize {

    return (length + page_size - 1) / page_size;

}

pub fn init() void {

    cache.init();

}

const testing = std.testing;

const memory_authority = @import("../authority/memory_authority.zig");

test "a region claims and returns its frames" {

    const pool = std.heap.page_allocator.alloc(u8, 256 * config.page_size) catch unreachable;
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

test "a device window never touches the frame pool and rejects an unaligned base" {

    const pool = std.heap.page_allocator.alloc(u8, 64 * config.page_size) catch unreachable;
    defer std.heap.page_allocator.free(pool);

    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    init();

    // A live region keeps the slab's backing frame resident so it does not skew the pool accounting below.

    const keeper = try Region.create(page_size);
    defer keeper.destroy();

    const baseline = frames.stats().free;

    try testing.expectError(error.Invalid, Region.create_device(0x0900_0004, page_size));

    const window = try Region.create_device(0x0900_0000, page_size);

    try testing.expect(window.device);
    try testing.expectEqual(baseline, frames.stats().free);

    window.destroy();
    try testing.expectEqual(baseline, frames.stats().free);

}

test "a charged region refunds its authority at destroy" {

    const pool = std.heap.page_allocator.alloc(u8, 64 * config.page_size) catch unreachable;
    defer std.heap.page_allocator.free(pool);

    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    init();
    memory_authority.init();

    const authority = try memory_authority.MemoryAuthority.create_root(8 * page_size);
    defer authority.destroy();

    const region = try Region.create(2 * page_size);

    try authority.charge(region.charged_bytes());
    region.charge_to(authority);

    try testing.expectEqual(2 * page_size, authority.budget_used);

    region.destroy();
    try testing.expectEqual(@as(usize, 0), authority.budget_used);

}
