// The normalized input/window event record and the single-producer single-consumer ring it rides in
// (07-userspace-ddd.md Section 10.8, Section 3.5). The same record shape flows on both hops: input server to
// compositor (window 0, pointer normalized to proto.input.pointer_range) and compositor to client (window set,
// pointer in window-content coordinates).

const std = @import("std");
const builtin = @import("builtin");

/// One fixed-size event record; a packed run of these fills the shared ring Region.
pub const Event = extern struct {

    kind: u16,
    code: u16,
    window: u32,

    x: i32,
    y: i32,

    value: i64,

};

pub const kind_key_down: u16 = 1;
pub const kind_key_up: u16 = 2;
pub const kind_pointer_move: u16 = 3;
pub const kind_button_down: u16 = 4;
pub const kind_button_up: u16 = 5;
pub const kind_scroll: u16 = 6;

pub const kind_window_close: u16 = 16;
pub const kind_window_resize: u16 = 17; // x,y carry the new content width,height
pub const kind_window_focus: u16 = 18;
pub const kind_window_blur: u16 = 19;

pub const button_left: u16 = 1;
pub const button_right: u16 = 2;
pub const button_middle: u16 = 3;

const Header = extern struct {

    head: u32,
    tail: u32,

    capacity: u32,
    reserved: u32,

};

/// Bytes a ring of `capacity` events needs in its shared Region.
pub fn ring_bytes(capacity: u32) usize {

    return @sizeOf(Header) + @as(usize, capacity) * @sizeOf(Event);

}

// Monotonic head/tail (the stream Ring's arithmetic): the producer owns tail, the consumer owns head, and
// wrap-around subtraction gives the fill level without a shared lock.

pub const Ring = struct {

    header: *volatile Header,
    slots: [*]volatile Event,

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

    /// Producer: append one event, dropping it when the ring is full (input is lossy by design; the
    /// consumer coalesces pointer motion anyway).
    pub fn push(self: Ring, event: Event) bool {

        const capacity = self.header.capacity;

        if (capacity == 0 or self.fill() >= capacity) return false;

        self.slots[self.header.tail % capacity] = event;

        fence();

        self.header.tail +%= 1;

        return true;

    }

    /// Consumer: take the oldest event, or null when the ring is empty.
    pub fn pop(self: Ring) ?Event {

        if (self.fill() == 0) return null;

        const capacity = self.header.capacity;
        const event = self.slots[self.header.head % capacity];

        fence();

        self.header.head +%= 1;

        return event;

    }

    pub fn fill(self: Ring) u32 {

        return self.header.tail -% self.header.head;

    }

};

// Publish order across cores: the record write must land before the index moves (M8 SMP).

fn fence() void {

    if (comptime builtin.target.cpu.arch == .aarch64) {

        asm volatile ("dmb ish" ::: .{ .memory = true });

    }

}

const testing = std.testing;

test "the event record is 24 bytes and starts with kind" {

    try testing.expectEqual(@as(usize, 24), @sizeOf(Event));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Event, "kind"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Event, "x"));

}

test "ring push and pop round-trip and preserve order" {

    var storage: [64]u8 align(8) = undefined;
    const ring = Ring.init(@intFromPtr(&storage), 2);

    try testing.expect(ring.push(.{ .kind = kind_key_down, .code = 30, .window = 0, .x = 0, .y = 0, .value = 1 }));
    try testing.expect(ring.push(.{ .kind = kind_key_up, .code = 30, .window = 0, .x = 0, .y = 0, .value = 0 }));

    // Full: the third push drops.

    try testing.expect(!ring.push(.{ .kind = kind_scroll, .code = 0, .window = 0, .x = 0, .y = 0, .value = -1 }));

    try testing.expectEqual(kind_key_down, ring.pop().?.kind);
    try testing.expectEqual(kind_key_up, ring.pop().?.kind);
    try testing.expectEqual(@as(?Event, null), ring.pop());

}

test "ring indices survive wrap-around" {

    var storage: [64]u8 align(8) = undefined;
    const ring = Ring.init(@intFromPtr(&storage), 2);

    ring.header.head = 0xffff_ffff;
    ring.header.tail = 0xffff_ffff;

    try testing.expect(ring.push(.{ .kind = kind_pointer_move, .code = 0, .window = 0, .x = 5, .y = 6, .value = 0 }));
    try testing.expectEqual(@as(u32, 1), ring.fill());

    const event = ring.pop().?;

    try testing.expectEqual(@as(i32, 5), event.x);
    try testing.expectEqual(@as(u32, 0), ring.fill());

}
