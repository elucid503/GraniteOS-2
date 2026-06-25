// aarch64 MMU enable: the M0 "initial mapping" (06-kernel-ddd.md Section 3/Section 5) - identity over the low 4 GiB, MMU on.

const entries_per_table = 512;

// Translation-table descriptor bits (4 KiB granule).

const descriptor_valid: u64 = 1 << 0;
const descriptor_table: u64 = 1 << 1; // table at this level (with valid => 0b11)
const descriptor_block: u64 = 0 << 1; // block at this level (with valid => 0b01)
const access_flag: u64 = 1 << 10;
const shareable_inner: u64 = 0b11 << 8;
const not_executable: u64 = (1 << 53) | (1 << 54); // PXN | UXN

// MAIR attribute indices, matched by the indices programmed into MAIR_EL1 below.

const attribute_device: u64 = 0 << 2;
const attribute_normal: u64 = 1 << 2;

// MAIR_EL1: attr0 = Device-nGnRnE (0x00), attr1 = Normal write-back (0xff).

const memory_attributes: u64 = 0x00 | (0xff << 8);

// TCR_EL1: 48-bit TTBR0, 4 KiB granule, write-back inner-shareable walks, TTBR1 disabled, 40-bit physical output.

const translation_control: u64 =
    16 | // T0SZ => 48-bit virtual address
    (1 << 8) | // IRGN0 write-back
    (1 << 10) | // ORGN0 write-back
    (0b11 << 12) | // SH0 inner shareable
    (0b00 << 14) | // TG0 4 KiB granule
    (1 << 23) | // EPD1: no TTBR1 walks
    (0b010 << 32); // IPS 40-bit

// A 1 GiB identity block at translation level 1.

const block_size: usize = 1 << 30;

var level0_table: [entries_per_table]u64 align(4096) = undefined;
var level1_table: [entries_per_table]u64 align(4096) = undefined;

/// Build the identity map and switch the MMU on; runs once on the primary core before `main`.
pub fn enable_initial_mapping() void {

    for (&level0_table) |*entry| {

        entry.* = 0;

    }

    for (&level1_table) |*entry| {

        entry.* = 0;

    }

    // One level-0 entry covers the first 512 GiB and points at the level-1 table.

    level0_table[0] = @intFromPtr(&level1_table) | descriptor_table | descriptor_valid;

    // Block 0 (0x0..0x4000_0000) is the device window: UART, GIC, virtio.

    level1_table[0] = (0 * block_size) | descriptor_block | descriptor_valid | attribute_device | access_flag | not_executable;

    // Blocks 1..3 are the RAM window as normal cacheable memory, executable at EL1 (the kernel runs here; UXN keeps EL0 out).
    var block: usize = 1;

    while (block < 4) : (block += 1) {

        level1_table[block] = (block * block_size) | descriptor_block | descriptor_valid | attribute_normal | access_flag | shareable_inner | (1 << 54); // UXN only

    }

    activate(@intFromPtr(&level0_table));

}

fn activate(level0_physical: usize) void {

    // Publish the freshly written tables before the walker can read them.

    asm volatile (
        \\ dsb ish
        \\ msr mair_el1, %[mair]
        \\ msr tcr_el1, %[tcr]
        \\ msr ttbr0_el1, %[ttbr0]
        \\ isb
        \\ tlbi vmalle1
        \\ dsb ish
        \\ ic iallu
        \\ dsb ish
        \\ isb
        :
        : [mair] "r" (memory_attributes),
          [tcr] "r" (translation_control),
          [ttbr0] "r" (level0_physical),
        : .{ .memory = true });

    // Turn on the MMU, data cache, and instruction cache, preserving the rest of SCTLR_EL1.

    var system_control = asm volatile ("mrs %[out], sctlr_el1"

        : [out] "=r" (-> u64),

    );

    system_control |= (1 << 0) | (1 << 2) | (1 << 12); // M | C | I

    asm volatile (
        \\ msr sctlr_el1, %[value]
        \\ isb
        :
        : [value] "r" (system_control),
        : .{ .memory = true }
    );

}
