// Per-process handle table (06-kernel-ddd.md Section 8): slots of {object, badge, generation} backed by a frame. A stale handle fails its generation check instead of reaching a recycled slot.

const config = @import("../config.zig");
const frames = @import("../memory/frames.zig");
const inspect = @import("../inspect.zig");
const object = @import("../object/object.zig");
const spinlock = @import("../sync/spinlock.zig");

const Handle = @import("handle.zig").Handle;
const Error = @import("../error.zig").Error;

const page_size = config.page_size;

const Entry = struct {

    target: ?*object.Object,
    badge: u64,
    generation: u12,

};

pub const HandleTable = struct {

    entries: []Entry,

    // Worker threads of one process share this table, so every operation takes its lock (06-kernel-ddd.md Section 15).
    lock: spinlock.SpinLock,

    pub fn init(self: *HandleTable) Error!void {

        const frame = try frames.alloc();
        const backing: [*]Entry = @ptrFromInt(frame);

        self.entries = backing[0 .. page_size / @sizeOf(Entry)];
        self.lock = .{};

        for (self.entries) |*entry| {

            entry.* = .{ .target = null, .badge = 0, .generation = 0 };

        }

    }

    /// Close every live handle, then return the backing frame. Runs at the process's last release, so no lock races it.
    pub fn deinit(self: *HandleTable) void {

        for (self.entries) |*entry| {

            if (entry.target) |target| {

                if (target.release()) object.destroy(target);

            }

        }

        frames.free(@intFromPtr(self.entries.ptr));

    }

    /// Take a reference on `target` and hand back a fresh handle for it.
    pub fn insert(self: *HandleTable, target: *object.Object) Error!Handle {

        return self.insert_with_badge(target, 0);

    }

    /// Insert with a badge already attached - the kernel's way to hand a process a badged endpoint at bootstrap,
    /// before that process exists to `copy` one for itself (04-boot-and-bootstrap.md).
    pub fn insert_badged(self: *HandleTable, target: *object.Object, badge: u64) Error!Handle {

        return self.insert_with_badge(target, badge);

    }

    pub fn resolve(self: *HandleTable, handle: Handle) Error!*object.Object {

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        const entry = try self.entry_of(handle);
        return entry.target.?;

    }

    /// Resolve and check the kind, yielding the concrete object type.
    pub fn resolve_as(self: *HandleTable, handle: Handle, comptime kind: object.Kind) Error!*object.TypeOf(kind) {

        const target = try self.resolve(handle);

        if (target.kind != kind) return error.WrongType;

        return object.container(object.TypeOf(kind), target);

    }

    pub fn badge_of(self: *HandleTable, handle: Handle) Error!u64 {

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        const entry = try self.entry_of(handle);
        return entry.badge;

    }

    /// Duplicate a handle; a non-zero badge mints a badged endpoint copy (03-syscall-abi.md Handles).
    pub fn copy(self: *HandleTable, handle: Handle, badge: u64) Error!Handle {

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        const entry = try self.entry_of(handle);
        const target = entry.target.?;

        if (badge != 0 and target.kind != .endpoint) return error.Invalid;

        return self.insert_locked(target, badge);

    }

    /// Drop this table's reference; the object is freed at its last close.
    pub fn close(self: *HandleTable, handle: Handle) Error!void {

        const target = blk: {

            const saved = self.lock.acquire();
            defer self.lock.release(saved);

            const entry = try self.entry_of(handle);
            const held = entry.target.?;

            entry.target = null;
            entry.badge = 0;
            entry.generation +%= 1;

            break :blk held;

        };

        // The release (and a possible destroy chain) runs outside the lock, so teardown can close other handles.

        if (target.release()) object.destroy(target);

    }

    pub fn memory_usage(self: *HandleTable) u64 {

        const MemoryAuthority = @import("../authority/memory_authority.zig").MemoryAuthority;

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        var total: u64 = 0;

        for (self.entries) |*entry| {

            const target = entry.target orelse continue;

            if (target.kind != .memory_authority) continue;

            const authority = object.container(MemoryAuthority, target);

            total += @atomicLoad(usize, &authority.budget_used, .monotonic);

        }

        return total;

    }

    pub fn stats(self: *HandleTable, by_kind: *[inspect.object_kind_slots]u32) u32 {

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        by_kind.* = [_]u32{0} ** inspect.object_kind_slots;

        var total: u32 = 0;

        for (self.entries) |*entry| {

            const target = entry.target orelse continue;
            const kind: usize = @intFromEnum(target.kind);

            if (kind < by_kind.len) by_kind[kind] += 1;

            total += 1;

        }

        return total;

    }

    fn insert_with_badge(self: *HandleTable, target: *object.Object, badge: u64) Error!Handle {

        const saved = self.lock.acquire();
        defer self.lock.release(saved);

        return self.insert_locked(target, badge);

    }

    fn insert_locked(self: *HandleTable, target: *object.Object, badge: u64) Error!Handle {

        for (self.entries, 0..) |*entry, index| {

            if (entry.target != null) continue;

            entry.target = target;
            entry.badge = badge;
            target.retain();

            return .{ .index = @intCast(index), .generation = entry.generation };

        }

        return error.NoMemory;

    }

    fn entry_of(self: *HandleTable, handle: Handle) Error!*Entry {

        if (handle.index >= self.entries.len) return error.BadHandle;

        const entry = &self.entries[handle.index];

        if (entry.target == null) return error.BadHandle;
        if (entry.generation != handle.generation) return error.BadHandle;

        return entry;

    }

};

const std = @import("std");
const testing = std.testing;

const Region = @import("../memory/region.zig").Region;
const region_module = @import("../memory/region.zig");

fn with_pool(pages: usize) []u8 {

    const pool = std.heap.page_allocator.alloc(u8, pages * page_size) catch unreachable;
    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    region_module.init();
    return pool;

}

test "insert, resolve, and close round-trip a real object" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    var table: HandleTable = undefined;
    try table.init();
    defer frames.free(@intFromPtr(table.entries.ptr));

    const region = try Region.create(page_size);
    const handle = try table.insert(&region.header);

    try testing.expectEqual(@as(u32, 2), region.header.references);
    try testing.expectEqual(&region.header, try table.resolve(handle));
    try testing.expectEqual(region, try table.resolve_as(handle, .region));
    try testing.expectError(error.WrongType, table.resolve_as(handle, .thread));

    // Our own reference plus the table's: close the table's, then release ours to free it.

    try table.close(handle);
    try testing.expectError(error.BadHandle, table.resolve(handle));

    if (region.header.release()) object.destroy(&region.header);

}

test "a stale handle fails the generation check after slot reuse" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    var table: HandleTable = undefined;
    try table.init();
    defer table.deinit();

    const region = try Region.create(page_size);
    defer {

        if (region.header.release()) object.destroy(&region.header);

    }

    const stale = try table.insert(&region.header);
    try table.close(stale);

    const fresh = try table.insert(&region.header);

    try testing.expectEqual(stale.index, fresh.index);
    try testing.expectError(error.BadHandle, table.resolve(stale));
    try testing.expectEqual(&region.header, try table.resolve(fresh));

}

test "copy duplicates a handle and refuses a badge on a non-endpoint" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    var table: HandleTable = undefined;
    try table.init();
    defer table.deinit();

    const region = try Region.create(page_size);
    defer {

        if (region.header.release()) object.destroy(&region.header);

    }

    const handle = try table.insert(&region.header);
    const duplicate = try table.copy(handle, 0);

    try testing.expectEqual(&region.header, try table.resolve(duplicate));
    try testing.expectEqual(@as(u32, 3), region.header.references);
    try testing.expectError(error.Invalid, table.copy(handle, 42));

    try table.close(duplicate);
    try testing.expectEqual(@as(u32, 2), region.header.references);

}

test "the table's last close frees the object" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    var table: HandleTable = undefined;
    try table.init();
    defer table.deinit();

    const baseline = frames.stats().free;

    const region = try Region.create(page_size);
    const handle = try table.insert(&region.header);

    // Hand the table our creation reference too, so its close is the last one.

    _ = region.header.release();

    try table.close(handle);
    try testing.expectEqual(baseline, frames.stats().free);

}
