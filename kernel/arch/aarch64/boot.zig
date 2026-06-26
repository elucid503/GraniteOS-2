// The bridge from `start.S` into the portable kernel: finish arch bring-up (MMU on) and hand control to `main`.

const mmu = @import("mmu.zig");

export fn kernel_boot(dtb: u64) callconv(.c) noreturn {

    mmu.enable_boot_mapping(dtb);

    @import("root").main(dtb);

}
