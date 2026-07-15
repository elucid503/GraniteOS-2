// PSCI firmware bring-up; hvc vs smc comes from the DTB so one kernel works at EL1 or EL2.

const types = @import("../../types.zig");

const Error = @import("../../error.zig").Error;

// SMCCC function id for the 64-bit CPU_ON call.

const cpu_on_function: u64 = 0xc400_0003;

// The secondary entry point in asm/start.S; PSCI starts the core there with the MMU off.

extern fn secondary_start() callconv(.c) void;

/// Power on `target_mpidr` at the arch's secondary entry, handing it `record` in x0.
pub fn start_core(method: types.PowerMethod, target_mpidr: u64, record: *const types.BootRecord) Error!void {

    const result = call(method, cpu_on_function, target_mpidr, @intFromPtr(&secondary_start), @intFromPtr(record));

    if (result != 0) return error.Invalid;

}

// SMCCC call: x1-x3 are outputs because firmware may clobber them.

fn call(method: types.PowerMethod, function: u64, a1: u64, a2: u64, a3: u64) i64 {

    var result: i64 = undefined;
    var scratch1: u64 = undefined;
    var scratch2: u64 = undefined;
    var scratch3: u64 = undefined;

    switch (method) {

        .hvc => asm volatile ("hvc #0"
            : [result] "={x0}" (result),
              [scratch1] "={x1}" (scratch1),
              [scratch2] "={x2}" (scratch2),
              [scratch3] "={x3}" (scratch3),
            : [function] "{x0}" (function),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [a3] "{x3}" (a3),
            : .{ .memory = true }),

        .smc => asm volatile ("smc #0"
            : [result] "={x0}" (result),
              [scratch1] "={x1}" (scratch1),
              [scratch2] "={x2}" (scratch2),
              [scratch3] "={x3}" (scratch3),
            : [function] "{x0}" (function),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [a3] "{x3}" (a3),
            : .{ .memory = true }),

    }

    return result;

}
