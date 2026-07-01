// GICv2 interrupt controller (06-kernel-ddd.md Section 5): distributor + CPU interface, discovered from the DTB with board fallbacks. GICv3 arrives later as a sibling implementation.

const board = @import("../board/virt.zig");

const types = @import("../../types.zig");

// Distributor registers.

const distributor_control = 0x000; // GICD_CTLR
const set_enable_base = 0x100; // GICD_ISENABLERn

// CPU-interface registers.

const cpu_control = 0x00; // GICC_CTLR
const priority_mask = 0x04; // GICC_PMR
const acknowledge = 0x0c; // GICC_IAR
const end_of_interrupt = 0x10; // GICC_EOIR

// INTIDs 1020..1023 are special (spurious and reserved), never real lines.

const first_special_intid = 1020;

var distributor: usize = 0;
var cpu_interface: usize = 0;

fn distributor_register(offset: usize) *volatile u32 {

    return @ptrFromInt(distributor + offset);

}

fn cpu_register(offset: usize) *volatile u32 {

    return @ptrFromInt(cpu_interface + offset);

}

/// Bring the controller up on the primary core. On `virt` both windows share the seed map's device block.
pub fn init_primary(windows: ?types.IntctrlWindows) void {

    if (windows) |found| {

        distributor = found.distributor;
        cpu_interface = found.cpu_interface;

    } else {

        distributor = board.gic_distributor_base;
        cpu_interface = board.gic_cpu_interface_base;

    }

    distributor_register(distributor_control).* = 1;

    // Accept every priority, then enable signalling to this core.

    cpu_register(priority_mask).* = 0xff;
    cpu_register(cpu_control).* = 1;

}

/// Acknowledge the highest-priority pending interrupt; null when the read was spurious.
pub fn claim() ?u32 {

    const intid = cpu_register(acknowledge).* & 0x3ff;

    if (intid >= first_special_intid) return null;

    return intid;

}

pub fn complete(irq: u32) void {

    cpu_register(end_of_interrupt).* = irq;

}

pub fn enable_line(irq: u32) void {

    const word = irq / 32;
    const bit = @as(u32, 1) << @intCast(irq % 32);

    distributor_register(set_enable_base + word * 4).* = bit;

}
