// aarch64 thread context (06-kernel-ddd.md Section 5): the callee-saved frame `switch.S` saves and restores.

const types = @import("../../types.zig");

const VirtAddr = types.VirtAddr;

// Field order and offsets must match `asm/switch.S`: sp at 0, x19..x28 at 8, x29 at 88, x30 at 96, sp_el0 at 104,
// used_fp at 112, fp_v (V0..V31) at 128, fpcr at 640, fpsr at 648.

pub const Context = extern struct {

    sp: u64,
    x19_to_x28: [10]u64,
    x29: u64, // frame pointer
    x30: u64, // link register: where the next switch-in resumes
    sp_el0: u64, // user stack pointer while the thread is in EL1

    // Lazy FP/SIMD state (06-kernel-ddd.md Section 5): saved and restored by `switch.S` only for threads that
    // trapped into FP. `used_fp` gates that work; `_fp_pad` lands `fp_v` on a 16-byte offset so the `stp q` form's
    // scaled immediate is legal.

    used_fp: u64,
    _fp_pad: u64,
    fp_v: [64]u64, // V0..V31, 128 bits each
    fpcr: u64,
    fpsr: u64,

};

/// Save the current callee-saved state into `save_into` and resume `restore_from`; implemented in `asm/switch.S`.
pub extern fn switch_context(save_into: *Context, restore_from: *const Context) void;

// First landing points of a fresh thread, in `asm/switch.S`: reap any exited predecessor, then enter the thread.

extern fn thread_trampoline() void;
extern fn user_trampoline() void;

/// Arrange for a fresh kernel thread's first switch-in to enter `entry` with `arg`, on its own kernel `stack` (EL1).
pub fn init_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, arg: u64) void {

    ctx.* = .{

        .sp = stack & ~@as(u64, 0xf),
        .x19_to_x28 = [_]u64{0} ** 10,
        .x29 = 0,
        .x30 = @intFromPtr(&thread_trampoline),
        .sp_el0 = 0,

        .used_fp = 0,
        ._fp_pad = 0,
        .fp_v = [_]u64{0} ** 64,
        .fpcr = 0,
        .fpsr = 0,

    };

    // The trampoline finds the entry point in x19 and the argument in x20.

    ctx.x19_to_x28[0] = entry;
    ctx.x19_to_x28[1] = arg;

}

/// Arrange for a fresh user thread's first switch-in to `eret` to `entry` at EL0 on `user_stack`.
pub fn init_user_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, user_stack: VirtAddr, arg: u64) void {

    ctx.* = .{

        .sp = stack & ~@as(u64, 0xf),
        .x19_to_x28 = [_]u64{0} ** 10,
        .x29 = 0,
        .x30 = @intFromPtr(&user_trampoline),
        .sp_el0 = user_stack & ~@as(u64, 0xf),

        .used_fp = 0,
        ._fp_pad = 0,
        .fp_v = [_]u64{0} ** 64,
        .fpcr = 0,
        .fpsr = 0,

    };

    // The user trampoline finds the entry in x19, the user stack in x20, and the argument in x21.

    ctx.x19_to_x28[0] = entry;
    ctx.x19_to_x28[1] = user_stack & ~@as(u64, 0xf);
    ctx.x19_to_x28[2] = arg;

}
