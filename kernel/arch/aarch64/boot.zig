// The bridge from `start.S` into the portable kernel: finish arch bring-up (MMU on) and hand control to `main`.

const mmu = @import("mmu.zig");

const types = @import("../../types.zig");

pub fn kernel_boot(dtb: u64) callconv(.c) noreturn {

    mmu.enable_boot_mapping(dtb);

    @import("root").main(dtb);

}

pub fn kernel_boot_secondary(record: *const types.BootRecord) callconv(.c) noreturn {

    mmu.enable_secondary();

    @import("root").main_secondary(@intCast(record.core_id));

}
