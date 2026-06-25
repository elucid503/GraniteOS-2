// aarch64 trap entry: for M0 any exception is unexpected, so report it and halt (06-kernel-ddd.md Section 12 grows this later).

const panic = @import("../../debug/panic.zig");

/// The register frame `trap_common` lays on the stack; field order and the trailing pad word must match the assembly.
pub const TrapFrame = extern struct {

    registers: [31]u64, // x0..x30
    reserved: u64,
    elr: u64, // faulting instruction address
    spsr: u64,
    esr: u64, // exception syndrome
    far: u64, // faulting virtual address

};

export fn kernel_trap(frame: *const TrapFrame) callconv(.c) noreturn {

    panic.fault("unhandled exception", .{

        .esr = frame.esr,
        .elr = frame.elr,
        .far = frame.far,
        .spsr = frame.spsr,

    });

}
