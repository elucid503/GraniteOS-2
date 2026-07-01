// aarch64 thread context (06-kernel-ddd.md Section 5): the callee-saved frame `switch.S` saves and restores.
// Caller-saved registers need no slot here: a switch always happens at a call boundary, so the AAPCS already parked them (on the stack for a voluntary switch, in the IRQ frame for a preemption).

const types = @import("../../types.zig");

const VirtAddr = types.VirtAddr;

// Field order and offsets must match `asm/switch.S`: sp at 0, x19..x28 at 8, x29 at 88, x30 at 96.

pub const Context = extern struct {

    sp: u64,
    x19_to_x28: [10]u64,
    x29: u64, // frame pointer
    x30: u64, // link register: where the next switch-in resumes

};

/// Save the current callee-saved state into `save_into` and resume `restore_from`; implemented in `asm/switch.S`.
pub extern fn switch_context(save_into: *Context, restore_from: *const Context) void;

// First landing point of a fresh thread, in `asm/switch.S`: unmask IRQs, move the argument into place, call the entry.

extern fn thread_trampoline() void;

/// Arrange for a fresh thread's first switch-in to enter `entry` with `arg`, on its own `stack`.
pub fn init_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, arg: u64) void {

    ctx.* = .{

        .sp = stack & ~@as(u64, 0xf),
        .x19_to_x28 = [_]u64{0} ** 10,
        .x29 = 0,
        .x30 = @intFromPtr(&thread_trampoline),

    };

    // The trampoline finds the entry point in x19 and the argument in x20.

    ctx.x19_to_x28[0] = entry;
    ctx.x19_to_x28[1] = arg;

}
