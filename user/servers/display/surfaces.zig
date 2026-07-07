// Window surface store (M10 GUI rewrite): every shared pixel Region a client renders into is owned here, one
// slot per manager window slot. All allocation and release funnels through this table - create, resize,
// destroy, and session eviction all land on the same idempotent release path - so a crashed or misbehaving
// client can never leak a mapping or leave the compositor pointing at freed pixels. Sizes are validated and
// the byte math is overflow-checked before any Region is created.

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

        };

        slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

        /// Allocate a zeroed surface Region for `slot`; any previous surface there is released first.
        pub fn allocate(self: *Self, slot: usize, width: u32, height: u32) Error!Handle {

            self.release(slot);

            const bytes = surface_bytes(width, height) orelse return error.TooLarge;

            const region = sys.create(.region, bytes, cap.memory) catch return error.OutOfMemory;

            const base = sys.map(cap.self_space, region, 0, sys.read | sys.write) catch {

                sys.close(region) catch {};

                return error.OutOfMemory;

            };

            const pixels: [*]u8 = @ptrFromInt(base);

            @memset(pixels[0..bytes], 0);

            self.slots[slot] = .{

                .region = region,
                .base = base,

                .width = width,
                .height = height,

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

        /// The slot's pixels as a Surface - only when the stored size matches what the caller expects, so a
        /// client that lags behind a resize can never make the compositor read past its mapping.
        pub fn surface_of(self: *Self, slot: usize, width: u32, height: u32) ?draw.Surface {

            const entry = &self.slots[slot];

            if (entry.base == 0) return null;
            if (entry.width != width or entry.height != height) return null;

            return draw.Surface.from_base(entry.base, entry.width, entry.height, entry.width * 4);

        }

    };

}

pub fn surface_bytes(width: u32, height: u32) ?usize {

    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;

    const pixels = std.math.mul(usize, width, height) catch return null;

    return std.math.mul(usize, pixels, 4) catch null;

}

const testing = std.testing;

test "surface byte math rejects zero and oversized surfaces" {

    try testing.expectEqual(@as(?usize, null), surface_bytes(0, 100));
    try testing.expectEqual(@as(?usize, null), surface_bytes(100, 0));
    try testing.expectEqual(@as(?usize, null), surface_bytes(max_side + 1, 1));
    try testing.expectEqual(@as(?usize, 400), surface_bytes(10, 10));

}
