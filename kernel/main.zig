// Kernel entry: discover the machine, bring up memory, interrupts, objects, and the scheduler, then hand off to user space.

const std = @import("std");

const arch = @import("arch/arch.zig");
const config = @import("config.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

const dtb = @import("boot/dtb.zig");
const handoff = @import("boot/handoff.zig");
const smp = @import("boot/smp.zig");
const frames = @import("memory/frames.zig");
const region = @import("memory/region.zig");
const address_space = @import("memory/address_space.zig");
const process_module = @import("object/process.zig");
const thread_module = @import("object/thread.zig");
const endpoint_module = @import("object/endpoint.zig");
const notification_module = @import("object/notification.zig");
const interrupt_module = @import("object/interrupt.zig");
const memory_authority = @import("authority/memory_authority.zig");
const interrupt_authority = @import("authority/interrupt_authority.zig");
const device_authority = @import("authority/device_authority.zig");
const dma_authority = @import("authority/dma_authority.zig");
const scheduler = @import("sched/scheduler.zig");

pub const panic = std.debug.FullPanic(panic_path.at);

const page_size = config.page_size;
const bytes_per_mib: u64 = 1024 * 1024;

extern const __kernel_start: u8;
extern const __kernel_end: u8;

pub fn main(dtb_address: arch.PhysAddr) noreturn {

    console.debug_print("GraniteOS-2 (aarch64 virt)\n\n");

    var memory_banks: [8]dtb.MemoryRange = undefined;
    var cpu_ids: [config.max_cores]u64 = undefined;
    const machine = dtb.parse(dtb_address, &memory_banks, &cpu_ids) catch {

        panic_path.panic("dtb: could not parse the device tree", null);

    };

    report_machine(machine);

    arch.map_ram(machine.memory);
    frames.init(machine.memory, &reserved(dtb_address, machine.initrd));
    region.init();
    address_space.init();

    report_memory();

    arch.intctrl_init_primary(machine.intctrl);
    arch.timer_init();

    console.debug_print("Interrupts: GIC and timer ... Loaded\n");

    process_module.init();
    thread_module.init();
    endpoint_module.init();
    notification_module.init();
    interrupt_module.init();
    memory_authority.init();
    interrupt_authority.init();
    device_authority.init();
    dma_authority.init();
    scheduler.init(machine.core_count);

    console.debug_print("Scheduler: objects and runqueues ... Loaded\n");

    report_smp(smp.start(machine));

    if (machine.initrd) |initrd| {

        handoff.start(initrd, dtb_address) catch {

            panic_path.panic("boot hand-off failed", null);

        };

        console.debug_print("Flint: hand-off ... Loaded\n");

    } else {

        console.debug_print("Flint: no initrd, halting\n");
        arch.halt();

    }

    scheduler.idle();

}

/// Secondary-core entry after `start.S` and the arch boot bridge (MMU already on).
pub fn main_secondary(core_id: u32) noreturn {

    arch.intctrl_init_secondary();
    arch.timer_init_secondary();

    scheduler.register_core(core_id);
    scheduler.idle();

}

fn reserved(dtb_address: arch.PhysAddr, initrd: ?dtb.MemoryRange) [3]frames.MemoryRange {

    const kernel_base = std.mem.alignBackward(usize, @intFromPtr(&__kernel_start), page_size);
    const kernel_top = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), page_size);

    const dtb_base = std.mem.alignBackward(usize, dtb_address, page_size);
    const dtb_top = std.mem.alignForward(usize, dtb_address + dtb.total_size(dtb_address), page_size);

    var spans = [3]frames.MemoryRange{

        .{ .base = kernel_base, .length = kernel_top - kernel_base },
        .{ .base = dtb_base, .length = dtb_top - dtb_base },
        .{ .base = 0, .length = 0 },

    };

    if (initrd) |modules| {

        const modules_base = std.mem.alignBackward(usize, modules.base, page_size);
        const modules_top = std.mem.alignForward(usize, modules.base + modules.length, page_size);

        spans[2] = .{ .base = modules_base, .length = modules_top - modules_base };

    }

    return spans;

}

fn report_machine(machine: dtb.Machine) void {

    var total_ram: u64 = 0;

    for (machine.memory) |bank| {

        total_ram += bank.length;

    }

    console.debug_print("Machine: ");
    console.debug_print_dec(machine.core_count);

    if (machine.core_count == 1) {

        console.debug_print(" core, ");

    } else {

        console.debug_print(" cores, ");

    }

    print_byte_count(total_ram);
    console.debug_print(" RAM ... Loaded\n");

}

fn report_smp(online: usize) void {

    console.debug_print("SMP: ");
    console.debug_print_dec(online);

    if (online == 1) {

        console.debug_print(" core online ... Loaded\n");

    } else {

        console.debug_print(" cores online ... Loaded\n");

    }

}

fn report_memory() void {

    const counts = frames.stats();

    console.debug_print("Memory: ");
    console.debug_print_dec(counts.total);
    console.debug_print(" frames, ");
    console.debug_print_dec(counts.free);
    console.debug_print(" free ... Loaded\n");

}

fn print_byte_count(bytes: u64) void {

    if (bytes >= bytes_per_mib and bytes % bytes_per_mib == 0) {

        console.debug_print_dec(bytes / bytes_per_mib);
        console.debug_print(" MiB");

        return;

    }

    console.debug_print_dec(bytes);
    console.debug_print(" bytes");

}
