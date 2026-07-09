// x86_64 thread context: callee-saved frame `switch.S` saves and restores.

const types = @import("../../types.zig");

const VirtAddr = types.VirtAddr;

// Field order must match asm/switch.S: rsp, rbx, rbp, r12, r13, r14, r15.

pub const Context = extern struct {

    rsp: u64,
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

};

pub extern fn switch_context(save_into: *Context, restore_from: *const Context) void;

extern fn thread_trampoline() void;
extern fn user_trampoline() void;

pub fn init_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, arg: u64) void {

    const aligned = stack & ~@as(u64, 0xf);
    const frame: [*]u64 = @ptrFromInt(aligned - 8);

    frame[0] = @intFromPtr(&thread_trampoline);

    ctx.* = .{

        .rsp = @intFromPtr(frame),
        .rbx = 0,
        .rbp = 0,
        .r12 = entry,
        .r13 = arg,
        .r14 = 0,
        .r15 = 0,

    };

}

pub fn init_user_thread_context(ctx: *Context, entry: VirtAddr, stack: VirtAddr, user_stack: VirtAddr, arg: u64) void {

    const aligned = stack & ~@as(u64, 0xf);
    const frame: [*]u64 = @ptrFromInt(aligned - 8);

    frame[0] = @intFromPtr(&user_trampoline);

    ctx.* = .{

        .rsp = @intFromPtr(frame),
        .rbx = 0,
        .rbp = 0,
        .r12 = entry,
        .r13 = user_stack & ~@as(u64, 0xf),
        .r14 = arg,
        .r15 = 0,

    };

}
