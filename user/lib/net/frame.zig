// The single-producer single-consumer frame ring between the virtio-net driver and the netstack server

const std = @import("std");
const builtin = @import("builtin");

pub const max_frame: usize = 1528; // headroom over the 1514-byte max Ethernet frame (14-byte header + 1500 MTU)

const Header = extern struct {

    head: u32,
    tail: u32,

    capacity: u32,
    reserved: u32,

};

const Slot = extern struct {

    length: u32,
    reserved: u32,

    data: [max_frame]u8,

};

/// Bytes a ring of `capacity` frames needs in its shared Region.
pub fn ring_bytes(capacity: u32) usize {

    return @sizeOf(Header) + @as(usize, capacity) * @sizeOf(Slot);

}

pub const Ring = struct {

    header: *volatile Header,
    slots: [*]volatile Slot,

    /// Producer side over a fresh mapped Region: writes the header, so call it exactly once per ring.
    pub fn init(base: usize, capacity: u32) Ring {

        const ring = open(base);

        ring.header.* = .{

            .head = 0,
            .tail = 0,

            .capacity = capacity,
            .reserved = 0,

        };

        return ring;

    }

    /// Either side over an already-initialized mapped Region.
    pub fn open(base: usize) Ring {

        return .{

            .header = @ptrFromInt(base),
            .slots = @ptrFromInt(base + @sizeOf(Header)),

        };

    }

    /// Producer: append one frame, dropping it when the ring is full or oversized.
    pub fn push(self: Ring, frame: []const u8) bool {

        const capacity = self.header.capacity;

        if (capacity == 0 or frame.len == 0 or frame.len > max_frame) return false;
        if (self.fill() >= capacity) return false;

        const slot = &self.slots[self.header.tail % capacity];

        for (frame, 0..) |byte, index| slot.data[index] = byte;

        slot.length = @intCast(frame.len);

        fence();

        self.header.tail +%= 1;

        return true;

    }

    /// Consumer: copy the oldest frame into `out`, or null when the ring is empty.
    pub fn pop(self: Ring, out: []u8) ?usize {

        if (self.fill() == 0) return null;

        const capacity = self.header.capacity;
        const slot = &self.slots[self.header.head % capacity];
        const length = @min(@as(usize, slot.length), out.len);

        for (0..length) |index| out[index] = slot.data[index];

        fence();

        self.header.head +%= 1;

        return length;

    }

    pub fn fill(self: Ring) u32 {

        return self.header.tail -% self.header.head;

    }

};

// Publish order across processes: the record write must land before the index moves (matches events.zig / M8 SMP).

fn fence() void {

    if (comptime builtin.target.cpu.arch == .aarch64) {

        asm volatile ("dmb ish" ::: .{ .memory = true });

    }

}

const testing = std.testing;

test "ring push and pop round-trip and preserve order" {

    var storage: [4096]u8 align(8) = undefined;
    const ring = Ring.init(@intFromPtr(&storage), 2);

    var out: [max_frame]u8 = undefined;

    try testing.expect(ring.push(&.{ 1, 2, 3 }));
    try testing.expect(ring.push(&.{ 4, 5 }));

    // Full: the third push drops.
    try testing.expect(!ring.push(&.{6}));

    try testing.expectEqual(@as(usize, 3), ring.pop(&out).?);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, out[0..3]);

    try testing.expectEqual(@as(usize, 2), ring.pop(&out).?);
    try testing.expectEqualSlices(u8, &.{ 4, 5 }, out[0..2]);

    try testing.expectEqual(@as(?usize, null), ring.pop(&out));

}

test "ring indices survive wrap-around" {

    var storage: [4096]u8 align(8) = undefined;
    const ring = Ring.init(@intFromPtr(&storage), 2);

    ring.header.head = 0xffff_ffff;
    ring.header.tail = 0xffff_ffff;

    var out: [max_frame]u8 = undefined;

    try testing.expect(ring.push(&.{ 9, 8, 7 }));
    try testing.expectEqual(@as(u32, 1), ring.fill());
    try testing.expectEqual(@as(usize, 3), ring.pop(&out).?);
    try testing.expectEqual(@as(u32, 0), ring.fill());

}
