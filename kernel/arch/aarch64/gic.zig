// GICv3 interrupt controller (06-kernel-ddd.md Section 5): MMIO distributor + per-core redistributors, with the CPU interface in EL1 system registers.

const std = @import("std");

const board = @import("../board/virt.zig");
const config = @import("../../config.zig");
const cpu = @import("cpu.zig");

const types = @import("../../types.zig");

// Distributor registers.

const distributor_control = 0x000; // GICD_CTLR
const group_base = 0x080; // GICD_IGROUPRn
const set_enable_base = 0x100; // GICD_ISENABLERn
const clear_enable_base = 0x180; // GICD_ICENABLERn
const router_base = 0x6000; // GICD_IROUTERn

// Redistributor registers (offsets from each core's RD_base).

const redistributor_control = 0x0000; // GICR_CTLR
const redistributor_waker = 0x0014; // GICR_WAKER
const sgi_frame_offset = 0x1_0000;
const sgi_group_base = 0x0080; // GICR_IGROUPR0
const sgi_set_enable_base = 0x0100; // GICR_ISENABLER0
const sgi_clear_enable_base = 0x0180; // GICR_ICENABLER0

const first_shared_line = 32;
const first_special_intid = 1020;

const enable_group1_ns: u32 = 1 << 1;
const affinity_routing_ns: u32 = 1 << 4;

// Kernel-internal SGI assignments (06-kernel-ddd.md Section 16.4): software interrupts never reach user space.

pub const sgi_reschedule: u32 = 0;
pub const sgi_halt: u32 = 1;

// SGI ids occupy INTIDs 0..15.

pub const first_sgi_boundary: u32 = 16;

var distributor: usize = 0;
var redistributor: usize = 0;
var redistributor_stride: usize = board.redistributor_stride;

fn distributor_register(offset: usize) *volatile u32 {

    return @ptrFromInt(distributor + offset);

}

fn redistributor_base(core_id: u32) usize {

    return redistributor + @as(usize, core_id) * redistributor_stride;

}

fn sgi_register(core_id: u32, offset: usize) *volatile u32 {

    return @ptrFromInt(redistributor_base(core_id) + sgi_frame_offset + offset);

}

/// Bring the controller up on the primary core.
pub fn init_primary(windows: ?types.IntctrlWindows) void {

    if (windows) |found| {

        distributor = found.distributor;
        redistributor = found.redistributor;
        redistributor_stride = found.redistributor_stride;

    } else {

        distributor = board.gic_distributor_base;
        redistributor = board.gic_redistributor_base;
        redistributor_stride = board.redistributor_stride;

    }

    wake_redistributor(cpu.core_id());
    route_local_lines_to_group1(cpu.core_id());

    distributor_register(distributor_control).* = enable_group1_ns | affinity_routing_ns;
    wait_distributor_rwp();

    route_shared_lines_to_group1();

    enable_system_registers();

}

/// Bring up this core's redistributor and CPU interface.
pub fn init_secondary() void {

    wake_redistributor(cpu.core_id());
    route_local_lines_to_group1(cpu.core_id());
    enable_system_registers();

}

fn wake_redistributor(core_id: u32) void {

    const base = redistributor_base(core_id);
    const control: *volatile u32 = @ptrFromInt(base + redistributor_control);
    const waker: *volatile u32 = @ptrFromInt(base + redistributor_waker);

    control.* &= ~@as(u32, 1 << 1);

    waker.* &= ~@as(u32, 0b100);

    var spins: u32 = 0;

    while (waker.* & 0b10 != 0) : (spins += 1) {

        if (spins > 1_000_000) return;

        std.atomic.spinLoopHint();

    }

}

fn route_local_lines_to_group1(core_id: u32) void {

    sgi_register(core_id, sgi_group_base).* = 0xffff_ffff;

}

// SPIs default to Group 0; the CPU interface only enables Group 1, so device lines would never assert.

fn route_shared_lines_to_group1() void {

    const first_register = first_shared_line / 32;
    const last_register = (config.max_interrupt_lines + 31) / 32;

    for (first_register..last_register) |index| {

        distributor_register(group_base + index * 4).* = 0xffff_ffff;

    }

}

fn wait_distributor_rwp() void {

    var spins: u32 = 0;

    while (distributor_register(distributor_control).* & (1 << 31) != 0) : (spins += 1) {

        if (spins > 1_000_000) return;

        std.atomic.spinLoopHint();

    }

}

fn enable_system_registers() void {

    write_icc_sre(0b111);

    asm volatile ("isb" ::: .{ .memory = true });

    write_icc_pmr(0xff);
    write_icc_grpen1(1);

    asm volatile ("isb" ::: .{ .memory = true });

}

pub fn send_sgi(target_core: u32, id: u32) void {

    if (target_core >= config.max_cores) return;

    asm volatile ("dsb ishst" ::: .{ .memory = true });

    const value = (@as(u64, id) << 24) | (@as(u64, 1) << @intCast(target_core));

    write_icc_sgi1r(value);

    asm volatile ("isb" ::: .{ .memory = true });

}

pub fn send_sgi_others(id: u32) void {

    asm volatile ("dsb ishst" ::: .{ .memory = true });

    const value = (@as(u64, id) << 24) | (@as(u64, 1) << 40);

    write_icc_sgi1r(value);

    asm volatile ("isb" ::: .{ .memory = true });

}

pub fn claim() ?u32 {

    const intid = read_icc_iar1() & 0x3ff;

    if (intid >= first_special_intid) return null;

    return intid;

}

pub fn complete(irq: u32) void {

    write_icc_eoir1(irq);

}

pub fn enable_line(irq: u32) void {

    if (irq >= first_shared_line) {

        const router: *volatile u64 = @ptrFromInt(distributor + router_base + @as(usize, irq) * 8);
        router.* = 0;

        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);

        distributor_register(set_enable_base + word * 4).* = bit;

        return;

    }

    const word = irq / 32;
    const bit = @as(u32, 1) << @intCast(irq % 32);

    sgi_register(cpu.core_id(), sgi_set_enable_base + word * 4).* = bit;

}

pub fn disable_line(irq: u32) void {

    if (irq >= first_shared_line) {

        const word = irq / 32;
        const bit = @as(u32, 1) << @intCast(irq % 32);

        distributor_register(clear_enable_base + word * 4).* = bit;

        return;

    }

    const word = irq / 32;
    const bit = @as(u32, 1) << @intCast(irq % 32);

    sgi_register(cpu.core_id(), sgi_clear_enable_base + word * 4).* = bit;

}

fn write_icc_sre(value: u64) void {

    asm volatile ("msr icc_sre_el1, %[value]"
        :
        : [value] "r" (value),
    );

}

fn write_icc_pmr(value: u32) void {

    asm volatile ("msr icc_pmr_el1, %[value]"
        :
        : [value] "r" (value),
    );

}

fn write_icc_grpen1(value: u32) void {

    asm volatile ("msr icc_igrpen1_el1, %[value]"
        :
        : [value] "r" (value),
    );

}

fn read_icc_iar1() u32 {

    return asm volatile ("mrs %[out], icc_iar1_el1"
        : [out] "=r" (-> u32),
    );

}

fn write_icc_eoir1(irq: u32) void {

    asm volatile ("msr icc_eoir1_el1, %[value]"
        :
        : [value] "r" (irq),
    );

}

fn write_icc_sgi1r(value: u64) void {

    asm volatile ("msr icc_sgi1r_el1, %[value]"
        :
        : [value] "r" (value),
    );

}
