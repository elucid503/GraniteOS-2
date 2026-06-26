// Kernel entry (06-kernel-ddd.md Section 3): M1 discovers the machine from the DTB, takes ownership of RAM, and proves alloc/map/free leak-free.

const std = @import("std");

const arch = @import("arch/arch.zig");
const config = @import("config.zig");
const console = @import("debug/console.zig");
const panic_path = @import("debug/panic.zig");

const dtb = @import("boot/dtb.zig");
const frames = @import("memory/frames.zig");
const region = @import("memory/region.zig");
const address_space = @import("memory/address_space.zig");

const Region = region.Region;
const AddressSpace = address_space.AddressSpace;

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

    console.debug_print("M1: memory foundation up; idling.\n");
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
