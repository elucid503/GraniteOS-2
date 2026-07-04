// Memory authority (06-kernel-ddd.md Section 11): hierarchical-lite budgets. A child reserves its whole slice from the parent at creation and returns it at its last close, so accounting never chases individual allocations up the tree.

const slab = @import("../memory/slab.zig");
const object = @import("../object/object.zig");

const Error = @import("../error.zig").Error;

var cache: slab.Cache(MemoryAuthority) = .{};

pub const MemoryAuthority = struct {

    header: object.Object,

    parent: ?*MemoryAuthority,
    budget_total: usize,
    budget_used: usize,

    /// The root of the budget tree, held only by Flint (04-boot-and-bootstrap.md).
    pub fn create_root(total: usize) Error!*MemoryAuthority {

        const authority = try cache.alloc();
        authority.* = .{

            .header = .{ .kind = .memory_authority },

            .parent = null,
            .budget_total = total,
            .budget_used = 0,

        };

        return authority;

    }

    /// Reserve `budget` bytes from this authority and hand them to a child authority.
    pub fn create_child(self: *MemoryAuthority, budget: usize) Error!*MemoryAuthority {

        try self.charge(budget);
        errdefer self.refund(budget);

        const child = try cache.alloc();
        child.* = .{

            .header = .{ .kind = .memory_authority },

            .parent = self,
            .budget_total = budget,
            .budget_used = 0,

        };

        self.header.retain();

        return child;

    }

    pub fn charge(self: *MemoryAuthority, bytes: usize) Error!void {

        if (self.budget_used + bytes > self.budget_total) return error.NoMemory;

        self.budget_used += bytes;

    }

    pub fn refund(self: *MemoryAuthority, bytes: usize) void {

        self.budget_used -= bytes;

    }

    /// The last close returns this authority's whole budget to its parent.
    pub fn destroy(self: *MemoryAuthority) void {

        if (self.parent) |parent| {

            parent.refund(self.budget_total);

            if (parent.header.release()) object.destroy(&parent.header);

        }

        cache.free(self);

    }

};

pub fn init() void {

    cache.init();

}

const std = @import("std");
const testing = std.testing;

const config = @import("../config.zig");
const frames = @import("../memory/frames.zig");

fn with_pool(pages: usize) []u8 {

    const pool = std.heap.page_allocator.alloc(u8, pages * config.page_size) catch unreachable;
    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    init();
    return pool;

}

test "charging past the budget fails and refunds restore headroom" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    const root = try MemoryAuthority.create_root(3 * config.page_size);
    defer root.destroy();

    try root.charge(2 * config.page_size);
    try testing.expectError(error.NoMemory, root.charge(2 * config.page_size));

    root.refund(2 * config.page_size);
    try root.charge(3 * config.page_size);

}

test "a child reserves its slice from the parent and returns it on destroy" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    const root = try MemoryAuthority.create_root(4 * config.page_size);

    const child = try root.create_child(3 * config.page_size);

    try testing.expectEqual(3 * config.page_size, root.budget_used);
    try testing.expectError(error.NoMemory, root.create_child(2 * config.page_size));

    // The child holds a reference on the parent, so destroy the child first, then the root frees on its own release.

    child.destroy();
    try testing.expectEqual(@as(usize, 0), root.budget_used);

    root.destroy();

}
