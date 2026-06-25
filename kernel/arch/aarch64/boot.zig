// The bridge from `start.S` into the portable kernel: finish arch bring-up (MMU on) and hand control to `main`.

const mmu = @import("mmu.zig");

export fn kernel_boot(dtb: u64) callconv(.c) noreturn {

    mmu.enable_initial_mapping();

    @import("root").main(dtb);

}
