// Window surface store (part of the M10 GUI rewrite)

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const draw = lib.draw;
const sys = lib.sys;

const Handle = cap.Handle;

pub const max_side: u32 = 8192;

pub const Error = error{
    TooLarge,
    OutOfMemory,
};

pub fn Store(comptime capacity: usize) type {

    return struct {

        const Self = @This();

        const Slot = struct {

            region: Handle = 0,
            base: usize = 0,

            width: u32 = 0,
            height: u32 = 0,
            capacity: usize = 0,
            format: draw.Format = .xrgb,

            pending_width: u32 = 0,
            pending_height: u32 = 0,

        };

        slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

        /// Allocate a size-classed surface, preserving a fitting buffer until the client presents its new layout.
        pub fn allocate(self: *Self, slot: usize, width: u32, height: u32, format: draw.Format) Error!Handle {

            const bytes = surface_bytes(width, height, format) orelse return error.TooLarge;

            if (self.slots[slot].region != 0 and bytes <= self.slots[slot].capacity) {

                self.slots[slot].pending_width = width;
                self.slots[slot].pending_height = height;
                self.slots[slot].format = format;

                return self.slots[slot].region;

            }

            self.release(slot);

            const allocation_size = std.math.ceilPowerOfTwo(usize, bytes) catch return error.TooLarge;

            const region = sys.create(.region, allocation_size, cap.memory) catch return error.OutOfMemory;

            const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch {

                sys.close(region) catch {};

                return error.OutOfMemory;

            };

            const pixel_count = std.math.mul(usize, width, height) catch return error.TooLarge;
            const pixels: [*]u32 = @ptrFromInt(base);

            @memset(pixels[0..pixel_count], if (format == .alpha) draw.transparent else 0);

            if (format == .alpha) {

                const effect: [*]u8 = @ptrFromInt(base + pixel_count * @sizeOf(u32));

                @memset(effect[0 .. pixel_count * 2], 0);

            }

            self.slots[slot] = .{

                .region = region,
                .base = base,

                .width = width,
                .height = height,
                .capacity = allocation_size,
                .format = format,

                .pending_width = 0,
                .pending_height = 0,

            };

            return region;

        }

        /// Unmap and close `slot`'s surface; safe to call on an empty slot, and always leaves it empty.
        pub fn release(self: *Self, slot: usize) void {

            const entry = &self.slots[slot];

            if (entry.base != 0) sys.unmap(cap.self_space, entry.base) catch {};
            if (entry.region != 0) sys.close(entry.region) catch {};

            entry.* = .{};

        }

        pub fn release_all(self: *Self) void {

            for (0..capacity) |slot| {

                self.release(slot);

            }

        }

        pub fn region_of(self: *Self, slot: usize) Handle {

            return self.slots[slot].region;

        }

        /// Publish the pending geometry only after the client presents pixels rendered with its new stride.
        pub fn commit(self: *Self, slot: usize) void {

            const entry = &self.slots[slot];

            if (entry.pending_width == 0 or entry.pending_height == 0) return;

            entry.width = entry.pending_width;
            entry.height = entry.pending_height;
            entry.pending_width = 0;
            entry.pending_height = 0;

        }

        pub fn surface_of(self: *Self, slot: usize) ?draw.Surface {

            const entry = &self.slots[slot];

            if (entry.base == 0) return null;

            if (entry.format == .alpha) {

                const effect_base = entry.base + @as(usize, entry.width) * entry.height * @sizeOf(u32);

                return draw.Surface.from_base_effect(entry.base, entry.width, entry.height, entry.width * 4, effect_base, entry.width * 2);

            }

            return draw.Surface.from_base_format(entry.base, entry.width, entry.height, entry.width * 4, entry.format);

        }

        pub fn covers(self: *Self, slot: usize, content: draw.Rect, region: draw.Rect) bool {

            const entry = &self.slots[slot];

            if (entry.base == 0) return false;

            const pixels = draw.Rect{

                .x = content.x,
                .y = content.y,
                .w = @intCast(entry.width),
                .h = @intCast(entry.height),

            };

            return pixels.x <= region.x and pixels.y <= region.y and pixels.x + pixels.w >= region.x + region.w and pixels.y + pixels.h >= region.y + region.h;

        }

    };

}

pub fn surface_bytes(width: u32, height: u32, format: draw.Format) ?usize {

    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;

    const pixels = std.math.mul(usize, width, height) catch return null;

    const pixel_bytes = std.math.mul(usize, pixels, @sizeOf(u32)) catch return null;

    return if (format == .alpha)
        std.math.add(usize, pixel_bytes, std.math.mul(usize, pixels, 2) catch return null) catch null
    else
        pixel_bytes;

}

const testing = std.testing;

test "surface byte math rejects zero and oversized surfaces" {

    try testing.expectEqual(@as(?usize, null), surface_bytes(0, 100, .xrgb));
    try testing.expectEqual(@as(?usize, null), surface_bytes(100, 0, .xrgb));
    try testing.expectEqual(@as(?usize, null), surface_bytes(max_side + 1, 1, .xrgb));
    try testing.expectEqual(@as(?usize, 400), surface_bytes(10, 10, .xrgb));
    try testing.expectEqual(@as(?usize, 600), surface_bytes(10, 10, .alpha));

}
