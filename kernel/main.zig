// Kernel entry (06-kernel-ddd.md Section 3): discover the machine, take ownership of RAM (M1), then bring up the interrupt controller, timer, objects, and scheduler, and prove two kernel threads time-slice, demote, boost, and yield (M2).

const std = @import("std");

const arch = @import("arch/arch.zig");
const config = @import("config.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

const dtb = @import("boot/dtb.zig");
const frames = @import("memory/frames.zig");
const region = @import("memory/region.zig");
const address_space = @import("memory/address_space.zig");
const process_module = @import("object/process.zig");
const thread_module = @import("object/thread.zig");
const scheduler = @import("sched/scheduler.zig");

const Region = region.Region;
const AddressSpace = address_space.AddressSpace;
const Process = process_module.Process;
const Thread = thread_module.Thread;

// Route language-level panics through the kernel panic path.
pub const panic = std.debug.FullPanic(panic_path.at);

const page_size = config.page_size;

// The kernel image extent, reserved from the frame allocator so it never hands out memory we are running from.
extern const __kernel_start: u8;
extern const __kernel_end: u8;

pub fn main(dtb_address: arch.PhysAddr) noreturn {

    console.debug_print("GraniteOS-2 (aarch64 virt)\n");

    var memory_banks: [8]dtb.MemoryRange = undefined;
    const machine = dtb.parse(dtb_address, &memory_banks) catch {

        panic_path.panic("dtb: could not parse the device tree", null);

    };

    report_machine(machine);

    // Make every discovered RAM bank reachable by its physical address, then take ownership of all of it bar what we occupy.

    arch.map_ram(machine.memory);
    frames.init(machine.memory, &reserved(dtb_address));
    region.init();
    address_space.init();

    report_frames();
    stress();

    console.debug_print("M1: memory foundation up.\n");

    arch.intctrl_init_primary(machine.intctrl);
    arch.timer_init();

    process_module.init();
    thread_module.init();
    scheduler.init();

    start_demo_threads();

    console.debug_print("M2: scheduler up; two threads admitted.\n");
    scheduler.idle();

}

// The M2 exit criterion: two kernel-mode threads time-slice under the timer, demote and boost correctly, and yield works. Thread A runs the checks against thread B, a plain spinner.

var demo_counter: u64 = 0;
var demo_checker: *Thread = undefined;

fn start_demo_threads() void {

    const space = AddressSpace.create() catch oom();
    const kernel_process = Process.create(space) catch oom();

    const spinner = Thread.create(kernel_process, @intFromPtr(&spin)) catch oom();
    demo_checker = Thread.create(kernel_process, @intFromPtr(&run_checks)) catch oom();

    spinner.start();
    demo_checker.start();

}

fn spin(_: u64) callconv(.c) void {

    const counter: *volatile u64 = &demo_counter;

    while (true) {

        counter.* +%= 1;

    }

}

fn run_checks(_: u64) callconv(.c) void {

    const counter: *volatile u64 = &demo_counter;
    const level: *volatile u8 = &demo_checker.scheduling.level;

    // Time-slicing: the spinner never yields, so its progress proves preemption reached us both.

    const preempted = counter.*;

    while (counter.* < preempted + 100_000) {}

    console.debug_print("M2: time-slice OK\n");

    // Yield: hand over the core and confirm the spinner ran while we were off it.

    const before_yield = counter.*;

    while (counter.* == before_yield) {

        scheduler.yield();

    }

    console.debug_print("M2: yield OK\n");

    // Demotion: burning whole quanta must walk us down to the bottom level.

    while (level.* != config.scheduling_levels - 1) {}

    console.debug_print("M2: demote OK\n");

    // Boost: the periodic anti-starvation boost must lift us back to level 0.

    while (level.* != 0) {}

    console.debug_print("M2: boost OK\n");

    console.debug_print("M2: OK objects and scheduler up\n");
    arch.halt();

}

// The spans the frame allocator must not hand out: the kernel image and the device tree.
fn reserved(dtb_address: arch.PhysAddr) [2]frames.MemoryRange {

    const kernel_base = std.mem.alignBackward(usize, @intFromPtr(&__kernel_start), page_size);
    const kernel_top = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), page_size);

    const dtb_base = std.mem.alignBackward(usize, dtb_address, page_size);
    const dtb_top = std.mem.alignForward(usize, dtb_address + dtb.total_size(dtb_address), page_size);

    return .{

        .{ .base = kernel_base, .length = kernel_top - kernel_base },
        .{ .base = dtb_base, .length = dtb_top - dtb_base },
    };

}

fn report_machine(machine: dtb.Machine) void {

    console.debug_print("cores ");
    console.debug_print_hex(machine.core_count);

    for (machine.memory) |bank| {

        console.debug_print("\nram ");
        console.debug_print_hex(bank.base);
        console.debug_print(" + ");
        console.debug_print_hex(bank.length);

    }

    console.debug_putchar('\n');

}

fn report_frames() void {

    const counts = frames.stats();
    console.debug_print("frames total ");
    console.debug_print_hex(counts.total);
    console.debug_print(" free ");
    console.debug_print_hex(counts.free);
    console.debug_putchar('\n');

}

// The M1 exit criterion: allocate, map, verify, unmap, and free frames and regions in a loop, and prove nothing leaked.
fn stress() void {

    const writable = arch.Permissions{ .read = true, .write = true, .user = true };
    const baseline = frames.stats().free;
    const iterations = 1000;

    for (0..iterations) |_| {

        const space = AddressSpace.create() catch oom();
        const memory = Region.create(2 * page_size) catch oom();

        const at = space.map(memory, null, writable) catch oom();

        if (arch.translate(space.root, at) != memory.frame(0)) {

            panic_path.panic("stress: mapping did not resolve to the region", null);

        }

        space.unmap(at) catch unreachable;

        if (arch.translate(space.root, at) != null) {

            panic_path.panic("stress: mapping survived unmap", null);

        }

        memory.destroy();
        space.destroy();

    }

    const after = frames.stats().free;

    console.debug_print("M1 stress ");
    console.debug_print_hex(iterations);
    console.debug_print(" rounds, free ");
    console.debug_print_hex(after);
    console.debug_putchar('\n');

    if (after != baseline) {

        panic_path.panic("stress: frames leaked", null);

    }

    console.debug_print("M1: OK no leaks\n");

}

fn oom() noreturn {

    panic_path.panic("out of memory during the M1 stress loop", null);

}
