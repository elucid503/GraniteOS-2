// Buddy physical-frame allocator (06-kernel-ddd.md Section 6.1). Single-page alloc/free go through a per-core
// magazine that refills and drains the buddy pool in batches, so the hot path never touches the global lock;
// contiguous/DMA allocations and the batch transfers take it.

const std = @import("std");

const config = @import("../config.zig");
const types = @import("../types.zig");
const arch = @import("../arch/arch.zig");
const spinlock = @import("../sync/spinlock.zig");

const Error = @import("../error.zig").Error;

const PhysAddr = types.PhysAddr;
const page_size = config.page_size;
const max_order = config.frame_max_order;
const magazine_capacity = config.frame_magazine;

pub const MemoryRange = struct {

    base: PhysAddr,
    length: usize,

};

const FreeNode = struct {

    next: ?*FreeNode,
    prev: ?*FreeNode,

};

const Magazine = struct {

    entries: [magazine_capacity]PhysAddr,
    count: usize,

};

var base: PhysAddr = 0;
var frame_count: usize = 0;

var total_frames: usize = 0;
var free_frames: usize = 0;

var free_lists: [max_order + 1]?*FreeNode = [_]?*FreeNode{null} ** (max_order + 1);
var free_bits: [max_order + 1][]u8 = undefined;

var metadata_base: PhysAddr = 0;
var metadata_pages: usize = 0;

// The global buddy-pool lock; magazines are per-core and touched only with interrupts off.

var pool_lock: spinlock.SpinLock = .{};

var magazines: [config.max_cores]Magazine = undefined;

/// Take ownership of the RAM `ranges`, minus any `reserved` spans (the kernel image, the DTB) and the allocator's own metadata.
pub fn init(ranges: []const MemoryRange, reserved: []const MemoryRange) void {

    for (&free_lists) |*head| {

        head.* = null;

    }

    for (&magazines) |*magazine| {

        magazine.count = 0;

    }

    pool_lock = .{};

    base = std.mem.alignBackward(PhysAddr, range_low(ranges), page_size);
    const top = std.mem.alignForward(PhysAddr, range_high(ranges), page_size);
    frame_count = (top - base) / page_size;

    var metadata_bytes: usize = 0;

    for (0..max_order + 1) |order| {

        metadata_bytes += bitmap_bytes(order);

    }

    metadata_pages = std.mem.alignForward(usize, metadata_bytes, page_size) / page_size;
    metadata_base = frame_addr(find_metadata_slot(metadata_pages, ranges, reserved));

    var offset: usize = 0;

    for (0..max_order + 1) |order| {

        const bytes = bitmap_bytes(order);
        const slice: [*]u8 = @ptrFromInt(metadata_base + offset);

        free_bits[order] = slice[0..bytes];
        @memset(free_bits[order], 0);

        offset += bytes;

    }

    total_frames = 0;
    free_frames = 0;

    for (0..frame_count) |index| {

        const addr = frame_addr(index);

        if (!contains(ranges, addr)) continue;
        if (contains(reserved, addr)) continue;
        if (addr >= metadata_base and addr < metadata_base + metadata_pages * page_size) continue;

        merge_and_insert(addr, 0);
        total_frames += 1;
        free_frames += 1;

    }

}

/// One page, from this core's magazine (refilled from the buddy pool in batches).
pub fn alloc() Error!PhysAddr {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const magazine = &magazines[arch.core_id()];

    if (magazine.count == 0) refill(magazine);
    if (magazine.count == 0) return error.NoMemory;

    magazine.count -= 1;

    return magazine.entries[magazine.count];

}

/// A physically contiguous, power-of-two-rounded run of `pages`; always straight from the buddy pool.
pub fn alloc_contiguous(pages: usize) Error!PhysAddr {

    const order = order_for(pages);

    if (order > max_order) return error.NoMemory;

    const saved = pool_lock.acquire();
    defer pool_lock.release(saved);

    const addr = try split_off(order);
    free_frames -= @as(usize, 1) << @intCast(order);
    return addr;

}

pub fn free(addr: PhysAddr) void {

    const saved = arch.disable_interrupts();
    defer arch.restore_interrupts(saved);

    const magazine = &magazines[arch.core_id()];

    if (magazine.count == magazine_capacity) drain(magazine);

    magazine.entries[magazine.count] = addr;
    magazine.count += 1;

}

pub fn free_contiguous(addr: PhysAddr, pages: usize) void {

    const order = order_for(pages);

    const saved = pool_lock.acquire();
    defer pool_lock.release(saved);

    merge_and_insert(addr, order);
    free_frames += @as(usize, 1) << @intCast(order);

}

pub fn stats() struct { total: usize, free: usize } {

    var cached: usize = 0;

    for (&magazines) |*magazine| {

        cached += magazine.count;

    }

    return .{ .total = total_frames, .free = free_frames + cached };

}

// Pull half a magazine's worth of pages from the buddy pool in one lock hold (or whatever remains).

fn refill(magazine: *Magazine) void {

    pool_lock.lock();
    defer pool_lock.unlock();

    while (magazine.count < magazine_capacity / 2) {

        const addr = split_off(0) catch break;

        free_frames -= 1;
        magazine.entries[magazine.count] = addr;
        magazine.count += 1;

    }

}

// Return half the magazine to the buddy pool in one lock hold, where blocks can coalesce again.

fn drain(magazine: *Magazine) void {

    pool_lock.lock();
    defer pool_lock.unlock();

    while (magazine.count > magazine_capacity / 2) {

        magazine.count -= 1;
        merge_and_insert(magazine.entries[magazine.count], 0);
        free_frames += 1;

    }

}

// Find the smallest block at or above `order`, split it down, and return its base.

fn split_off(order: usize) Error!PhysAddr {

    var level = order;

    while (level <= max_order and free_lists[level] == null) : (level += 1) {}

    if (level > max_order) return error.NoMemory;

    const addr = list_pop(level);
    bit_clear(level, addr);

    while (level > order) {

        level -= 1;
        const buddy = addr + (@as(usize, 1) << @intCast(level)) * page_size;
        bit_set(level, buddy);
        list_push(level, buddy);

    }

    return addr;

}

// Free a block, coalescing with its buddy upward as far as both halves are free.

fn merge_and_insert(addr_in: PhysAddr, order_in: usize) void {

    var addr = addr_in;
    var order = order_in;

    while (order < max_order) {

        const buddy_index = frame_index(addr) ^ (@as(usize, 1) << @intCast(order));

        if (buddy_index >= frame_count) break;
        if (!bit_test(order, frame_addr(buddy_index))) break;

        const buddy = frame_addr(buddy_index);
        bit_clear(order, buddy);
        list_remove(order, buddy);

        if (buddy < addr) addr = buddy;
        order += 1;

    }

    bit_set(order, addr);
    list_push(order, addr);

}

fn frame_index(addr: PhysAddr) usize {

    return (addr - base) / page_size;

}

fn frame_addr(index: usize) PhysAddr {

    return base + index * page_size;

}

fn node_at(addr: PhysAddr) *FreeNode {

    return @ptrFromInt(addr);

}

fn list_push(order: usize, addr: PhysAddr) void {

    const node = node_at(addr);
    node.prev = null;
    node.next = free_lists[order];

    if (free_lists[order]) |head| head.prev = node;

    free_lists[order] = node;

}

fn list_remove(order: usize, addr: PhysAddr) void {

    const node = node_at(addr);

    if (node.prev) |prev| prev.next = node.next else free_lists[order] = node.next;
    if (node.next) |next| next.prev = node.prev;

}

fn list_pop(order: usize) PhysAddr {

    const node = free_lists[order].?;
    free_lists[order] = node.next;

    if (node.next) |next| next.prev = null;

    return @intFromPtr(node);

}

fn bitmap_bytes(order: usize) usize {

    const blocks = (frame_count >> @intCast(order)) + 1;
    return (blocks + 7) / 8;

}

fn block_bit(order: usize, addr: PhysAddr) usize {

    return frame_index(addr) >> @intCast(order);

}

fn bit_test(order: usize, addr: PhysAddr) bool {

    const bit = block_bit(order, addr);
    return free_bits[order][bit >> 3] & (@as(u8, 1) << @intCast(bit & 7)) != 0;

}

fn bit_set(order: usize, addr: PhysAddr) void {

    const bit = block_bit(order, addr);
    free_bits[order][bit >> 3] |= @as(u8, 1) << @intCast(bit & 7);

}

fn bit_clear(order: usize, addr: PhysAddr) void {

    const bit = block_bit(order, addr);
    free_bits[order][bit >> 3] &= ~(@as(u8, 1) << @intCast(bit & 7));

}

fn order_for(pages: usize) usize {

    if (pages <= 1) return 0;
    return std.math.log2_int_ceil(usize, pages);

}

fn contains(ranges: []const MemoryRange, addr: PhysAddr) bool {

    for (ranges) |range| {

        if (addr >= range.base and addr < range.base + range.length) return true;

    }

    return false;

}

fn range_low(ranges: []const MemoryRange) PhysAddr {

    var low = ranges[0].base;

    for (ranges) |range| {

        if (range.base < low) low = range.base;

    }

    return low;

}

fn range_high(ranges: []const MemoryRange) PhysAddr {

    var high: PhysAddr = 0;

    for (ranges) |range| {

        if (range.base + range.length > high) high = range.base + range.length;

    }

    return high;

}

fn find_metadata_slot(pages: usize, ranges: []const MemoryRange, reserved: []const MemoryRange) usize {

    var run_start: ?usize = null;

    for (0..frame_count) |index| {

        const addr = frame_addr(index);
        const usable = contains(ranges, addr) and !contains(reserved, addr);

        if (usable) {

            if (run_start == null) run_start = index;
            if (index - run_start.? + 1 >= pages) return run_start.?;

        } else {

            run_start = null;

        }

    }

    @panic("frames: no contiguous room for allocator metadata");

}

const testing = std.testing;

// page_allocator hands back page-aligned memory, so frame addresses line up as they would in real RAM.
fn host_pool(pages: usize) []u8 {

    return std.heap.page_allocator.alloc(u8, pages * page_size) catch unreachable;

}

test "alloc and free a single frame returns to baseline" {

    const pool = host_pool(256);
    defer std.heap.page_allocator.free(pool);

    init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});

    const baseline = stats().free;
    try testing.expect(baseline > 0);

    const frame = try alloc();
    try testing.expectEqual(baseline - 1, stats().free);

    free(frame);
    try testing.expectEqual(baseline, stats().free);

}

test "draining and refilling the pool leaks nothing" {

    const pool = host_pool(512);
    defer std.heap.page_allocator.free(pool);

    init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});

    const baseline = stats().free;

    var taken: [512]PhysAddr = undefined;
    var count: usize = 0;

    while (alloc()) |frame| {

        taken[count] = frame;
        count += 1;

    } else |err| {

        try testing.expectEqual(Error.NoMemory, err);

    }

    try testing.expectEqual(baseline, count);
    try testing.expectEqual(@as(usize, 0), stats().free);

    for (taken[0..count]) |frame| {

        free(frame);

    }

    try testing.expectEqual(baseline, stats().free);

}

test "contiguous allocation is power-of-two and coalesces back" {

    const pool = host_pool(256);
    defer std.heap.page_allocator.free(pool);

    init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});

    const baseline = stats().free;

    const run = try alloc_contiguous(5);
    try testing.expectEqual(@as(PhysAddr, 0), run % (8 * page_size));
    try testing.expectEqual(baseline - 8, stats().free);

    free_contiguous(run, 5);
    try testing.expectEqual(baseline, stats().free);

}

test "reserved spans are never handed out" {

    const pool = host_pool(256);
    defer std.heap.page_allocator.free(pool);

    const pool_base = @intFromPtr(pool.ptr);
    const reserved_base = pool_base + 64 * page_size;
    const reserved_len = 32 * page_size;

    init(
        &.{.{ .base = pool_base, .length = pool.len }},
        &.{.{ .base = reserved_base, .length = reserved_len }},
    );

    while (alloc()) |frame| {

        try testing.expect(frame < reserved_base or frame >= reserved_base + reserved_len);

    } else |_| {}

}
