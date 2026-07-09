// x86_64 trap entry: IRQ -> scheduler / Interrupt objects; syscall -> dispatch.

const panic = @import("../../debug/panic.zig");
const cpu = @import("cpu.zig");
const apic = @import("apic.zig");
const timer = @import("timer.zig");
const interrupt_module = @import("../../object/interrupt.zig");
const scheduler = @import("../../sched/scheduler.zig");
const syscall = @import("../../syscall/syscall.zig");

/// Interrupt stack frame laid by isr.S before calling kernel_trap / kernel_irq.
pub const TrapFrame = extern struct {

    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rbp: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

};

/// Syscall frame laid by syscall_entry: number in rax, args in rdi/rsi/rdx/r10/r8.
pub const SyscallFrame = extern struct {

    rax: u64,
    rbx: u64,
    rdx: u64,
    rbp: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,

    // x86_64 ABI: number in rax, args in rdi,rsi,rdx,r10,r8, result in rax (DMA phys in rdx).

    pub fn number(self: *const SyscallFrame) u64 {

        return self.rax;

    }

    pub fn arg(self: *const SyscallFrame, index: usize) u64 {

        return switch (index) {

            0 => self.rdi,
            1 => self.rsi,
            2 => self.rdx,
            3 => self.r10,
            4 => self.r8,
            else => 0,

        };

    }

    pub fn set_result(self: *SyscallFrame, value: u64) void {

        self.rax = value;

    }

    pub fn set_extra(self: *SyscallFrame, value: u64) void {

        self.rdx = value;

    }

};

export fn kernel_irq(frame: *TrapFrame) callconv(.c) void {

    const vector: u32 = @intCast(frame.vector);

    if (vector == apic.vector_timer) {

        timer.stop();
        apic.eoi();
        scheduler.tick();
        return;

    }

    if (vector == apic.vector_halt) {

        apic.eoi();
        cpu.park();

    }

    if (vector == apic.vector_reschedule) {

        apic.eoi();
        scheduler.tick();
        return;

    }

    if (apic.vector_to_line(vector)) |line| {

        if (interrupt_module.find(line)) |device| {

            device.fire();
            apic.eoi();
            scheduler.tick();
            return;

        }

    }

    apic.eoi();

}

export fn kernel_syscall(frame: *SyscallFrame) callconv(.c) void {

    syscall.dispatch(frame);

}

export fn kernel_trap(frame: *const TrapFrame) callconv(.c) noreturn {

    panic.fault("unhandled exception", .{

        .esr = frame.vector,
        .elr = frame.rip,
        .far = frame.error_code,
        .spsr = frame.rflags,

    });

}
