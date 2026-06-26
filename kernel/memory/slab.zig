// Per-type object caches (06-kernel-ddd.md Section 6.2): carve frames into fixed-size objects; a wholly-empty slab returns its frame.

const std = @import("std");

const config = @import("../config.zig");
const frames = @import("frames.zig");

const Error = @import("../error.zig").Error;

const page_size = config.page_size;

// One slab is one frame: this header sits at its base, the objects follow.

const Slab = struct {

    next: ?*Slab,
    prev: ?*Slab,
    free_list: ?*FreeObject,
    used: usize,
};

const FreeObject = struct {

    next: ?*FreeObject,
};

pub fn Cache(comptime T: type) type {

    const object_align = @max(@alignOf(T), @alignOf(FreeObject));
    const object_size = std.mem.alignForward(usize, @max(@sizeOf(T), @sizeOf(FreeObject)), object_align);
    const header_size = std.mem.alignForward(usize, @sizeOf(Slab), object_align);
    const capacity = (page_size - header_size) / object_size;

    return struct {

        // Slabs with at least one free object; a full slab is found again on `free` via the object's frame.
        partial: ?*Slab = null,

        const Self = @This();

        pub fn init(self: *Self) void {

            self.partial = null;

        }

        pub fn alloc(self: *Self) Error!*T {

            if (self.partial == null) try self.grow();

            const slab = self.partial.?;
            const object = slab.free_list.?;

            slab.free_list = object.next;
            slab.used += 1;

            if (slab.free_list == null) self.unlink(slab);

            return @ptrCast(@alignCast(object));

        }

        pub fn free(self: *Self, item: *T) void {

            const slab: *Slab = @ptrFromInt(@intFromPtr(item) & ~(page_size - 1));
            const was_full = slab.free_list == null;

            const object: *FreeObject = @ptrCast(@alignCast(item));
            object.next = slab.free_list;
            slab.free_list = object;
            slab.used -= 1;

            if (was_full) self.link(slab);

            if (slab.used == 0) {

                self.unlink(slab);
                frames.free(@intFromPtr(slab));

            }

        }

        fn grow(self: *Self) Error!void {

            const frame = try frames.alloc();
            const slab: *Slab = @ptrFromInt(frame);
            slab.* = .{ .next = null, .prev = null, .free_list = null, .used = 0 };

            var offset = header_size;

            for (0..capacity) |_| {

                const object: *FreeObject = @ptrFromInt(frame + offset);
                object.next = slab.free_list;
                slab.free_list = object;
                offset += object_size;

            }

            self.link(slab);

        }

        fn link(self: *Self, slab: *Slab) void {

            slab.prev = null;
            slab.next = self.partial;

            if (self.partial) |head| head.prev = slab;

            self.partial = slab;

        }

        fn unlink(self: *Self, slab: *Slab) void {

            if (slab.prev) |prev| prev.next = slab.next else self.partial = slab.next;
            if (slab.next) |next| next.prev = slab.prev;

        }
    };

}

const testing = std.testing;

const Thing = struct {

    x: u64,
    y: u64,
};

fn with_pool(pages: usize) []u8 {

    const pool = std.heap.page_allocator.alloc(u8, pages * page_size) catch unreachable;
    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    return pool;

}

test "objects are distinct and writable across multiple slabs" {

    const pool = with_pool(256);
    defer std.heap.page_allocator.free(pool);

    var cache: Cache(Thing) = undefined;
    cache.init();

    var items: [300]*Thing = undefined;

    for (0..300) |i| {

        items[i] = try cache.alloc();
        items[i].x = i;

    }

    for (0..300) |i| {

        try testing.expectEqual(i, items[i].x);

    }

    for (0..300) |i| {

        cache.free(items[i]);

    }

}

test "emptying a cache releases its frames" {

    const pool = with_pool(256);
    defer std.heap.page_allocator.free(pool);

    var cache: Cache(Thing) = undefined;
    cache.init();

    const baseline = frames.stats().free;

    var items: [300]*Thing = undefined;
    for (0..300) |i| items[i] = try cache.alloc();

    try testing.expect(frames.stats().free < baseline);

    for (0..300) |i| cache.free(items[i]);

    try testing.expectEqual(baseline, frames.stats().free);

}
