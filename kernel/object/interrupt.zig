// Interrupt (06-kernel-ddd.md Section 7.4): a hardware line as a capability. A driver binds it to a Notification and just waits; the kernel IRQ path fires it and masks the line until the driver acknowledges.

const config = @import("../config.zig");
const arch = @import("../arch/arch.zig");
const slab = @import("../memory/slab.zig");
const object = @import("object.zig");

const Notification = @import("notification.zig").Notification;
const Error = @import("../error.zig").Error;

var cache: slab.Cache(Interrupt) = .{};

// The kernel IRQ path's line-to-object map; one owner per line.

var lines: [config.max_interrupt_lines]?*Interrupt = [_]?*Interrupt{null} ** config.max_interrupt_lines;

pub const Interrupt = struct {

    header: object.Object,

    line: u32,
    target: ?*Notification,
    bits: u64,

    /// Claim `line`; the syscall layer has already checked the caller's InterruptAuthority.
    pub fn create(line: u32) Error!*Interrupt {

        if (line >= config.max_interrupt_lines) return error.Invalid;
        if (lines[line] != null) return error.NotAllowed;

        const interrupt = try cache.alloc();
        interrupt.* = .{

            .header = .{ .kind = .interrupt },

            .line = line,
            .target = null,
            .bits = 0,

        };

        lines[line] = interrupt;

        return interrupt;

    }

    /// Route the line to `target` and unmask it; from here the driver's loop is bind-wait-acknowledge.
    pub fn bind(self: *Interrupt, target: *Notification, bits: u64) Error!void {

        if (self.target) |old| {

            if (old.header.release()) object.destroy(&old.header);

        }

        target.header.retain();

        self.target = target;
        self.bits = bits;

        arch.intctrl_enable_line(self.line);

    }

    /// Re-arm the line after the driver has serviced (and quieted) its device.
    pub fn acknowledge(self: *Interrupt) Error!void {

        if (self.target == null) return error.Invalid;

        arch.intctrl_enable_line(self.line);

    }

    /// Kernel IRQ path: mask the (level-triggered) line so it cannot storm, then wake the driver.
    pub fn fire(self: *Interrupt) void {

        arch.intctrl_disable_line(self.line);

        if (self.target) |target| {

            target.signal(self.bits);

        }

    }

    pub fn destroy(self: *Interrupt) void {

        arch.intctrl_disable_line(self.line);
        lines[self.line] = null;

        if (self.target) |target| {

            if (target.header.release()) object.destroy(&target.header);

        }

        cache.free(self);

    }

};

/// The Interrupt claiming `line`, if any (the trap path's lookup).
pub fn find(line: u32) ?*Interrupt {

    if (line >= config.max_interrupt_lines) return null;

    return lines[line];

}

pub fn init() void {

    cache.init();

    for (&lines) |*line| {

        line.* = null;

    }

}

const std = @import("std");
const testing = std.testing;

const frames = @import("../memory/frames.zig");
const notification_module = @import("notification.zig");
const scheduler = @import("../sched/scheduler.zig");

fn with_pool(pages: usize) []u8 {

    const pool = std.heap.page_allocator.alloc(u8, pages * config.page_size) catch unreachable;
    frames.init(&.{.{ .base = @intFromPtr(pool.ptr), .length = pool.len }}, &.{});
    notification_module.init();
    scheduler.init(1);
    init();
    return pool;

}

test "a line can only be claimed once" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    const interrupt = try Interrupt.create(33);
    defer interrupt.destroy();

    try testing.expectEqual(interrupt, find(33).?);
    try testing.expectError(error.NotAllowed, Interrupt.create(33));
    try testing.expectError(error.Invalid, Interrupt.create(config.max_interrupt_lines));

}

test "fire signals the bound notification with the bound bits" {

    const pool = with_pool(64);
    defer std.heap.page_allocator.free(pool);

    const interrupt = try Interrupt.create(33);
    defer interrupt.destroy();

    const notification = try Notification.create();

    try testing.expectError(error.Invalid, interrupt.acknowledge());

    try interrupt.bind(notification, 0b100);
    interrupt.fire();

    try testing.expectEqual(@as(u64, 0b100), notification.bits);
    try interrupt.acknowledge();

}
