// LAPIC + IOAPIC interrupt controller for PC-class machines.

const board = @import("../board/pc.zig");
const cpu = @import("cpu.zig");

const types = @import("../../types.zig");

pub const vector_timer: u32 = 48;
pub const vector_reschedule: u32 = 49;
pub const vector_halt: u32 = 50;

const lapic_id = 0x020;
const lapic_eoi = 0x0b0;
const lapic_svr = 0x0f0;
const lapic_icr_low = 0x300;
const lapic_icr_high = 0x310;
const lapic_lvt_timer = 0x320;
const lapic_timer_init = 0x380;
const lapic_timer_div = 0x3e0;

const ioapic_regsel = 0x00;
const ioapic_window = 0x10;

var lapic: usize = board.lapic_base;
var ioapic: usize = board.ioapic_base;

fn lapic_reg(offset: usize) *volatile u32 {

    return @ptrFromInt(lapic + offset);

}

fn ioapic_write(index: u32, value: u32) void {

    const sel: *volatile u32 = @ptrFromInt(ioapic + ioapic_regsel);
    const win: *volatile u32 = @ptrFromInt(ioapic + ioapic_window);
    sel.* = index;
    win.* = value;

}

fn ioapic_read(index: u32) u32 {

    const sel: *volatile u32 = @ptrFromInt(ioapic + ioapic_regsel);
    const win: *volatile u32 = @ptrFromInt(ioapic + ioapic_window);
    sel.* = index;
    return win.*;

}

pub fn init_primary(windows: ?types.IntctrlWindows) void {

    if (windows) |found| {

        lapic = found.distributor;
        ioapic = found.redistributor;

    }

    // Disable legacy PIC.
    cpu.port_out(1, 0xa1, 0xff);
    cpu.port_out(1, 0x21, 0xff);

    // Enable APIC (IA32_APIC_BASE bit 11).
    const apic_base = cpu.read_msr(0x1b);
    cpu.write_msr(0x1b, apic_base | (1 << 11));

    lapic_reg(lapic_svr).* = 0x1ff; // enable + spurious vector 0xff
    lapic_reg(lapic_timer_div).* = 0x3; // divide by 16
    lapic_reg(lapic_lvt_timer).* = vector_timer; // one-shot, unmasked

    // Route COM1 (IRQ 4) to vector 36 (32 + 4).
    route_gsi(board.com1_irq, 32 + board.com1_irq);

}

pub fn init_secondary() void {

    lapic_reg(lapic_svr).* = 0x1ff;
    lapic_reg(lapic_timer_div).* = 0x3;
    lapic_reg(lapic_lvt_timer).* = vector_timer;

}

fn route_gsi(gsi: u32, vector: u32) void {

    const index = 0x10 + gsi * 2;
    const high = @as(u32, @truncate(lapic_reg(lapic_id).* & 0xff000000));
    ioapic_write(index + 1, high);
    ioapic_write(index, vector); // edge, active-high, fixed, unmasked

}

pub fn enable_line(irq: u32) void {

    // IRQ numbers below 16 are ISA GSIs; map to IOAPIC.
    if (irq < 24) {

        const index = 0x10 + irq * 2;
        const low = ioapic_read(index);
        ioapic_write(index, low & ~@as(u32, 1 << 16));

    }

}

pub fn disable_line(irq: u32) void {

    if (irq < 24) {

        const index = 0x10 + irq * 2;
        const low = ioapic_read(index);
        ioapic_write(index, low | (1 << 16));

    }

}

pub fn eoi() void {

    lapic_reg(lapic_eoi).* = 0;

}

pub fn arm_timer(ticks: u32) void {

    lapic_reg(lapic_timer_init).* = @max(ticks, 1);

}

pub fn stop_timer() void {

    lapic_reg(lapic_timer_init).* = 0;

}

pub fn send_ipi(target_core: u32, vector: u32) void {

    _ = target_core;
    lapic_reg(lapic_icr_high).* = 0;
    lapic_reg(lapic_icr_low).* = vector | (1 << 14); // assert, fixed

}

pub fn send_ipi_others(vector: u32) void {

    lapic_reg(lapic_icr_high).* = 0;
    lapic_reg(lapic_icr_low).* = vector | (0b11 << 18) | (1 << 14); // all excluding self

}

pub fn vector_to_line(vector: u32) ?u32 {

    if (vector >= 32 and vector < 48) return vector - 32;
    return null;

}
