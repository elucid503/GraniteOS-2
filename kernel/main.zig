// Kernel entry: discover the machine, bring up memory, interrupts, objects, and the scheduler, then hand off to user space.

const std = @import("std");
const builtin = @import("builtin");

const arch = @import("arch/arch.zig");
const config = @import("config.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

const machine_module = @import("boot/machine.zig");
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

/// Portable entry: `boot_info` is an FDT on aarch64, or a Multiboot2 info pointer on x86_64 (parsed by the arch boot bridge into a Machine before this is called).
pub fn main(machine: machine_module.Machine) noreturn {

    if (comptime builtin.cpu.arch == .x86_64) {

        console.debug_print("GraniteOS-2 (x86_64 pc)\n\n");

    } else {

        console.debug_print("GraniteOS-2 (aarch64 virt)\n\n");

    }

    report_machine(machine);

    arch.map_ram(machine.memory);
    frames.init(machine.memory, &reserved(machine));
    region.init();
    address_space.init();

    report_memory();

    arch.intctrl_init_primary(machine.intctrl);
    arch.timer_init();

    console.debug_print("Interrupts: controller and timer ... Loaded\n");

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

    console.debug_print("Kernel image ");
    console.debug_print_hex(@intFromPtr(&__kernel_start));
    console.debug_print("..");
    console.debug_print_hex(@intFromPtr(&__kernel_end));
    console.debug_print("\n");

    if (machine.initrd) |initrd| {

        console.debug_print("Handoff: create space\n");
        handoff.start(initrd, machine.discovery, machine.discovery_length) catch {

            panic_path.panic("boot hand-off failed", null);

        };

        console.debug_print("Flint: hand-off ... Loaded\n");

    } else {

        console.debug_print("Flint: no initrd, halting\n");
        arch.halt();

    }

    scheduler.idle();

}

/// Secondary-core entry after arch boot bridge (MMU already on).
pub fn main_secondary(core_id: u32) noreturn {

    arch.intctrl_init_secondary();
    arch.timer_init_secondary();

    scheduler.register_core(core_id);
    scheduler.idle();

}

fn reserved(machine: machine_module.Machine) [3]frames.MemoryRange {

    const kernel_base = std.mem.alignBackward(usize, @intFromPtr(&__kernel_start), page_size);
    const kernel_top = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), page_size);

    const discovery_base = std.mem.alignBackward(usize, machine.discovery, page_size);
    const discovery_top = std.mem.alignForward(usize, machine.discovery + machine.discovery_length, page_size);

    var spans = [3]frames.MemoryRange{

        .{ .base = kernel_base, .length = kernel_top - kernel_base },
        .{ .base = discovery_base, .length = discovery_top - discovery_base },
        .{ .base = 0, .length = 0 },

    };

    if (machine.initrd) |modules| {

        const modules_base = std.mem.alignBackward(usize, modules.base, page_size);
        const modules_top = std.mem.alignForward(usize, modules.base + modules.length, page_size);

        spans[2] = .{ .base = modules_base, .length = modules_top - modules_base };

    }

    return spans;

}

fn report_machine(machine: machine_module.Machine) void {

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
