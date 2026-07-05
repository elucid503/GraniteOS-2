// Host-test stand-in for the arch boundary: enough surface for the core's `zig test` runs, no hardware. The kernel core only ever sees `arch.zig`, which selects this file when building for the host.

const frames = @import("../memory/frames.zig");

const types = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub const PhysAddr = types.PhysAddr;
pub const VirtAddr = types.VirtAddr;

pub const Permissions = packed struct(u8) {

    read: bool = false,
    write: bool = false,
    execute: bool = false,
    user: bool = true,
    device: bool = false,
    uncached: bool = false,
    _pad: u2 = 0,

};

pub const InterruptState = usize;

pub const Context = extern struct {

    entry: u64 = 0,
    stack: u64 = 0,
    user_stack: u64 = 0,
    arg: u64 = 0,

};

pub fn core_id() u32 {

    return 0;

}

pub fn wait_for_event() void {}

pub fn enable_interrupts() void {}

pub fn disable_interrupts() InterruptState {

    return 0;

}

pub fn restore_interrupts(state: InterruptState) void {

    _ = state;

}

pub fn sync_instruction_cache() void {}

pub fn clean_invalidate_data_cache(base: usize, length: usize) void {

    _ = base;
    _ = length;

}

pub fn halt() noreturn {

    unreachable;

}

pub fn switch_context(save_into: *Context, restore_from: *const Context) void {

    _ = save_into;
    _ = restore_from;

}

pub fn init_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, arg: u64) void {

    ctx.* = .{ .entry = entry, .stack = stack, .arg = arg };

}

pub fn init_user_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, user_stack: VirtAddr, arg: u64) void {

    ctx.* = .{ .entry = entry, .stack = stack, .user_stack = user_stack, .arg = arg };

}

// The page-table surface backs onto the test frame pool so create/destroy stays balanced.

pub fn new_table() Error!PhysAddr {

    return frames.alloc();

}

pub fn free_table(root: PhysAddr) void {

    frames.free(root);

}

pub fn map_page(root: PhysAddr, va: VirtAddr, pa: PhysAddr, perms: Permissions) Error!void {

    _ = root;
    _ = va;
    _ = pa;
    _ = perms;

}

pub fn unmap_page(root: PhysAddr, va: VirtAddr) void {

    _ = root;
    _ = va;

}

pub fn translate(root: PhysAddr, va: VirtAddr) ?PhysAddr {

    _ = root;
    _ = va;
    return null;

}

pub fn activate_space(root: PhysAddr) void {

    _ = root;

}

pub fn flush_tlb_page(va: VirtAddr) void {

    _ = va;

}

pub fn map_ram(ranges: []const frames.MemoryRange) void {

    _ = ranges;

}

// Tests drive scheduler policy through `on_tick(core, now)` directly, so wall time never advances here.

pub fn now_ns() u64 {

    return 0;

}

pub fn arm_deadline(ns_from_now: u64) void {

    _ = ns_from_now;

}

pub fn intctrl_init_primary(windows: ?types.IntctrlWindows) void {

    _ = windows;

}

pub fn intctrl_enable_line(irq: u32) void {

    _ = irq;

}

pub fn intctrl_disable_line(irq: u32) void {

    _ = irq;

}

pub fn timer_init() void {}
