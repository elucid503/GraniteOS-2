// The bridge from `start.S` into the portable kernel: finish arch bring-up (MMU on) and hand control to `main`.

const mmu = @import("mmu.zig");
const dtb = @import("../../boot/dtb.zig");
const config = @import("../../config.zig");

const types = @import("../../types.zig");

export fn kernel_boot(dtb_address: u64) callconv(.c) noreturn {

    mmu.enable_boot_mapping(dtb_address);

    var memory_banks: [8]dtb.MemoryRange = undefined;
    var cpu_ids: [config.max_cores]u64 = undefined;
    const machine = dtb.parse(dtb_address, &memory_banks, &cpu_ids) catch {

        @import("../../debug/panic.zig").panic("dtb: could not parse the device tree", null);

    };

    @import("root").main(machine);

}

export fn kernel_boot_secondary(record: *const types.BootRecord) callconv(.c) noreturn {

    mmu.enable_secondary();

    @import("root").main_secondary(@intCast(record.core_id));

}
