// LAPIC timer + TSC for monotonic time and the MLFQ deadline.

const std = @import("std");

const apic = @import("apic.zig");
const cpu = @import("cpu.zig");

var ticks_per_ns: u64 = 2;

pub fn init() void {

    calibrate();
    init_secondary();

}

pub fn init_secondary() void {

    apic.stop_timer();

}

fn calibrate() void {

    const leaf = cpu.cpuid(0x15, 0);
    var tsc_hz: u64 = 2_000_000_000;

    if (leaf.eax != 0 and leaf.ebx != 0 and leaf.ecx != 0) {

        tsc_hz = @as(u64, leaf.ecx) * @as(u64, leaf.ebx) / leaf.eax;

    }

    ticks_per_ns = @max(tsc_hz / 1_000_000_000, 1);

}

pub fn now_ns() u64 {

    return cpu.rdtsc() / ticks_per_ns;

}

pub fn arm_deadline(ns_from_now: u64) void {

    const ticks: u32 = @intCast(@min(ns_from_now / 1000, std.math.maxInt(u32)));
    apic.arm_timer(@max(ticks, 1));

}

pub fn stop() void {

    apic.stop_timer();

}
