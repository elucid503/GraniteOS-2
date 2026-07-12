// aarch64 MMU (06-kernel-ddd.md Section 5): the transient derived seed map, MMU enable, and the per-AddressSpace page-table surface.

const board = @import("../board/virt.zig");
const config = @import("../../config.zig");
const frames = @import("../../memory/frames.zig");

const types = @import("../../types.zig");
const Error = @import("../../error.zig").Error;

const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;
const page_size = config.page_size;

const entries_per_table = 512;

// Translation-table descriptor bits (4 KiB granule).

const descriptor_valid: u64 = 1 << 0;
const descriptor_table: u64 = 1 << 1; // table at this level (with valid => 0b11)
const descriptor_block: u64 = 0 << 1; // block at this level (with valid => 0b01)
const access_flag: u64 = 1 << 10;
const shareable_inner: u64 = 0b11 << 8;
const privileged_execute_never: u64 = 1 << 53; // PXN
const user_execute_never: u64 = 1 << 54; // UXN

// MAIR attribute indices, matched by the indices programmed into MAIR_EL1 below.

const attribute_device: u64 = 0 << 2;
const attribute_normal: u64 = 1 << 2;
const attribute_normal_uncached: u64 = 2 << 2;

// MAIR_EL1: attr0 = Device-nGnRnE (0x00), attr1 = Normal write-back (0xff),
// attr2 = Normal non-cacheable (0x44) for DMA buffers shared with devices.

const memory_attributes: u64 = 0x00 | (0xff << 8) | (0x44 << 16);

// TCR_EL1: 48-bit TTBR0, 4 KiB granule, write-back inner-shareable walks, TTBR1 disabled, 40-bit physical output,
// 16-bit ASIDs defined by TTBR0 (AS=1; A1=0). ASIDs let a process switch skip the full TLB flush (Stage 1.4).

const translation_control: u64 =
    16 | // T0SZ => 48-bit virtual address
    (1 << 8) | // IRGN0 write-back
    (1 << 10) | // ORGN0 write-back
    (0b11 << 12) | // SH0 inner shareable
    (0b00 << 14) | // TG0 4 KiB granule
    (1 << 23) | // EPD1: no TTBR1 walks
    (0b010 << 32) | // IPS 40-bit
    (1 << 36); // AS: 16-bit ASID (A1=0, so TTBR0.ASID is the current ASID)

// One level-1 entry maps a 1 GiB block; the seed map works at this granularity (low 512 GiB, one level-1 table).

const block_size: usize = 1 << 30;

// Linker symbols bounding the kernel image, so the map follows where we were actually loaded, not a fixed address.

extern const __kernel_start: u8;
extern const __kernel_end: u8;

var level0_table: [entries_per_table]u64 align(4096) = undefined;
var level1_table: [entries_per_table]u64 align(4096) = undefined;

/// Build the seed map and switch the MMU on; runs once on the primary core before `main`. Transient — see the file header.
pub fn enable_boot_mapping(dtb: usize) void {

    for (&level0_table) |*entry| {

        entry.* = 0;

    }

    for (&level1_table) |*entry| {

        entry.* = 0;

    }

    // One level-0 entry covers the first 512 GiB and points at the level-1 table.

    level0_table[0] = @intFromPtr(&level1_table) | descriptor_table | descriptor_valid;

    // The kernel's own image (code, data, stack), discovered from its link-time extent.

    var address = @intFromPtr(&__kernel_start) & ~(block_size - 1);
    const kernel_end = @intFromPtr(&__kernel_end);

    while (address < kernel_end) : (address += block_size) {

        map_normal(address);

    }

    // The device tree, so M1 can parse it; firmware passed its physical address in x0.

    if (dtb != 0) {

        map_normal(dtb);

    }

    // The console UART last, so the panic path keeps its device window even if a normal block above collided with it.

    map_device(board.uart_base);

    activate(@intFromPtr(&level0_table));

}

/// Switch a secondary core's MMU on over the tables the primary already built; runs before `main_secondary`.
pub fn enable_secondary() void {

    activate(@intFromPtr(&level0_table));

}

// Map the 1 GiB block holding `address` as normal cacheable memory, executable at EL1 (UXN keeps EL0 out).

fn map_normal(address: usize) void {

    const index = address / block_size;
    level1_table[index] = (index * block_size) | descriptor_block | descriptor_valid | attribute_normal | access_flag | shareable_inner | user_execute_never;

}

// Map the 1 GiB block holding `address` as device memory: non-cacheable and never executable.

fn map_device(address: usize) void {

    const index = address / block_size;
    level1_table[index] = (index * block_size) | descriptor_block | descriptor_valid | attribute_device | access_flag | privileged_execute_never | user_execute_never;

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
        : .{ .memory = true });

}

// --- General page-table surface (06-kernel-ddd.md Section 5): per-AddressSpace 4 KiB mappings ---

pub const Permissions = packed struct(u8) {

    read: bool = false,
    write: bool = false,
    execute: bool = false,
    user: bool = true,

    // Device/MMIO mapping: non-cacheable, non-gathering, never executable (06-kernel-ddd.md Section 16.3).
    device: bool = false,

    // RAM used for DMA rings/buffers: normal memory, but non-cacheable so device writes and CPU writes are visible
    // without explicit cache maintenance.
    uncached: bool = false,

    _pad: u2 = 0,
};

const page_descriptor: u64 = descriptor_valid | (1 << 1);
const output_mask: u64 = 0x0000_ffff_ffff_f000;

/// Allocate a fresh top-level (level-0) table for a user address space. Slot 0 is shared with the kernel's own
/// level-0 entry, so the kernel's identity/device/RAM mappings (all privileged, EL0 has no access) remain reachable
/// at EL1 once this root is loaded in TTBR0; user mappings go above 512 GiB (slot 1+), clear of that shared block.
pub fn new_table() Error!PhysAddr {

    const frame = try frames.alloc();
    zero_table(frame);

    const root: *[entries_per_table]u64 = @ptrFromInt(frame);
    root[0] = level0_table[0];

    return frame;

}

// Write one leaf descriptor (allocating intermediate tables as needed) without any TLB maintenance; the caller
// batches that. `map_page` and `map_range` share it so single and bulk mappings agree on the walk.

fn write_leaf(root: PhysAddr, va: VirtAddr, pa: PhysAddr, perms: Permissions) Error!void {

    var table = root;

    for (0..3) |level| {

        const entry: *u64 = @ptrFromInt(table + table_index(va, level) * 8);

        if (entry.* & descriptor_valid == 0) {

            const next = try frames.alloc();
            zero_table(next);
            entry.* = next | descriptor_table | descriptor_valid;

        }

        table = entry.* & output_mask;

    }

    const leaf: *u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    leaf.* = (pa & output_mask) | page_descriptor | leaf_attributes(perms);

}

fn clear_leaf(root: PhysAddr, va: VirtAddr) void {

    var table = root;

    for (0..3) |level| {

        const entry: *const u64 = @ptrFromInt(table + table_index(va, level) * 8);
        if (entry.* & descriptor_valid == 0) return;
        table = entry.* & output_mask;

    }

    const leaf: *u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    leaf.* = 0;

}

pub fn map_page(root: PhysAddr, va: VirtAddr, pa: PhysAddr, perms: Permissions) Error!void {

    try write_leaf(root, va, pa, perms);
    flush_tlb_page(va);

}

pub fn unmap_page(root: PhysAddr, va: VirtAddr) void {

    clear_leaf(root, va);
    flush_tlb_page(va);

}

// Past this many pages, a per-VA TLBI loop costs more than one shot that drops the whole range's stale entries; the
// range flush then broadcasts a single all-address invalidate instead (still inner-shareable, so cross-core).
const tlb_range_threshold: usize = 64;

/// Map `pages` contiguous frames from `pa` at `va`, deferring all TLB maintenance to a single batched flush at the
/// end (Stage 1.4). On failure the partial run is rolled back. `pa` is contiguous because a Region's frames are.
pub fn map_range(root: PhysAddr, va: VirtAddr, pa: PhysAddr, pages: usize, perms: Permissions) Error!void {

    var mapped: usize = 0;

    while (mapped < pages) : (mapped += 1) {

        write_leaf(root, va + mapped * page_size, pa + mapped * page_size, perms) catch |failure| {

            while (mapped > 0) {

                mapped -= 1;
                clear_leaf(root, va + mapped * page_size);

            }

            flush_tlb_range(va, pages);
            return failure;

        };

    }

    flush_tlb_range(va, pages);

}

/// Unmap `pages` contiguous pages at `va` with one batched flush.
pub fn unmap_range(root: PhysAddr, va: VirtAddr, pages: usize) void {

    for (0..pages) |index| {

        clear_leaf(root, va + index * page_size);

    }

    flush_tlb_range(va, pages);

}

/// One batched TLB invalidate over `[va, va + pages*page_size)`: a per-VA loop under one barrier pair, or a single
/// all-address shootdown past the threshold. Inner-shareable, so it reaches every core with no IPI (Section 16.2).
pub fn flush_tlb_range(va: VirtAddr, pages: usize) void {

    if (pages == 0) return;

    asm volatile ("dsb ishst" ::: .{ .memory = true });

    if (pages > tlb_range_threshold) {

        asm volatile ("tlbi vmalle1is" ::: .{ .memory = true });

    } else {

        var index: usize = 0;

        while (index < pages) : (index += 1) {

            asm volatile ("tlbi vaae1is, %[page]"
                :
                : [page] "r" ((va + index * page_size) >> 12),
                : .{ .memory = true });

        }

    }

    asm volatile (
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });

}

pub fn translate(root: PhysAddr, va: VirtAddr) ?PhysAddr {

    var table = root;

    for (0..3) |level| {

        const entry: *const u64 = @ptrFromInt(table + table_index(va, level) * 8);
        if (entry.* & descriptor_valid == 0) return null;
        table = entry.* & output_mask;

    }

    const leaf: *const u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    if (leaf.* & descriptor_valid == 0) return null;
    return (leaf.* & output_mask) | (va & (page_size - 1));

}

// --- ASIDs (Stage 1.4) ---
//
// Each AddressSpace holds a 16-bit ASID drawn from a monotonic counter within a generation. TTBR0 carries the ASID,
// so a process switch just rewrites TTBR0 (no TLB flush) and TLB entries of different spaces cannot alias. When the
// counter wraps, the generation bumps; every space re-derives a fresh ASID on its next activation, and each core
// does one local full flush the first time it switches under the new generation (see `scheduler.activate_space`),
// which is what keeps a reused ASID value from matching stale entries a core still holds.

const asid_max: u32 = 0xffff;

var asid_lock: @import("../../sync/spinlock.zig").SpinLock = .{};
var asid_next: u32 = 1; // ASID 0 is reserved (global/kernel)
var asid_generation_value: u64 = 1;

pub fn asid_generation() u64 {

    return @atomicLoad(u64, &asid_generation_value, .acquire);

}

/// Return the ASID for a space, allocating one when the space's recorded generation is stale. The fast path is a
/// lockless generation compare; only a first activation (or a post-rollover one) takes the lock. Two cores racing the
/// same space converge on one ASID because the second sees the generation already current.
pub fn ensure_space_asid(asid_ptr: *u16, generation_ptr: *u64) u16 {

    if (@atomicLoad(u64, generation_ptr, .acquire) == asid_generation()) {

        return @atomicLoad(u16, asid_ptr, .acquire);

    }

    const saved = asid_lock.acquire();
    defer asid_lock.release(saved);

    if (generation_ptr.* != asid_generation_value) {

        if (asid_next > asid_max) {

            asid_next = 1;
            @atomicStore(u64, &asid_generation_value, asid_generation_value + 1, .release);

        }

        @atomicStore(u16, asid_ptr, @intCast(asid_next), .release);
        asid_next += 1;
        @atomicStore(u64, generation_ptr, asid_generation_value, .release);

    }

    return @atomicLoad(u16, asid_ptr, .acquire);

}

/// Full TLB flush local to this core (used once per generation on the switch path after an ASID rollover).
pub fn tlb_flush_local() void {

    asm volatile (
        \\ dsb ish
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });

}

/// Load a TTBR0 value (page-table root ORed with the ASID in bits [63:48]) with no TLB flush: the ASID tag keeps a
/// stale space's entries from ever matching. Callers handle the rare post-rollover local flush.
pub fn activate_space(ttbr0: u64) void {

    asm volatile (
        \\ msr ttbr0_el1, %[ttbr0]
        \\ isb
        :
        : [ttbr0] "r" (ttbr0),
        : .{ .memory = true });

}

// The inner-shareable (`is`) TLBI broadcasts to every core, so an unmap on one core is the cross-core
// TLB shootdown (06-kernel-ddd.md Section 16.2) with no IPI round-trip.

pub fn flush_tlb_page(va: VirtAddr) void {

    asm volatile (
        \\ dsb ishst
        \\ tlbi vaae1is, %[page]
        \\ dsb ish
        \\ isb
        :
        : [page] "r" (va >> 12),
        : .{ .memory = true });

}

/// Extend the seed map to cover the discovered RAM banks so every frame is reachable by its physical address.
pub fn map_ram(ranges: []const frames.MemoryRange) void {

    for (ranges) |range| {

        var addr = range.base & ~(block_size - 1);
        const end = range.base + range.length;

        while (addr < end) : (addr += block_size) {

            map_normal(addr);

        }

    }

    asm volatile (
        \\ dsb ish
        \\ tlbi vmalle1is
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });

}

/// Free every table frame a user root owns (the leaf page frames belong to Regions and are left alone). Slot 0 is the
/// shared kernel entry (new_table) and its subtree is the kernel's, never this space's, so it is skipped.
pub fn free_table(root: PhysAddr) void {

    const entries: *const [entries_per_table]u64 = @ptrFromInt(root);

    for (entries[1..]) |entry| {

        if (entry & descriptor_valid != 0 and entry & descriptor_table != 0) {

            free_table_level(entry & output_mask, 1);

        }

    }

    frames.free(root);

}

fn free_table_level(table: PhysAddr, level: usize) void {

    if (level < 3) {

        const entries: *const [entries_per_table]u64 = @ptrFromInt(table);

        for (entries) |entry| {

            if (entry & descriptor_valid != 0 and entry & (1 << 1) != 0) {

                free_table_level(entry & output_mask, level + 1);

            }

        }

    }

    frames.free(table);

}

fn table_index(va: VirtAddr, level: usize) usize {

    const shift: u6 = @intCast(12 + (3 - level) * 9);
    return (va >> shift) & 0x1ff;

}

fn zero_table(frame: PhysAddr) void {

    const table: *[entries_per_table]u64 = @ptrFromInt(frame);

    // The pointer-array memset path faulted when clearing recycled kernel stack pages.

    var index: usize = 0;

    while (index < entries_per_table) : (index += 1) {

        table[index] = 0;

    }

}

// Translate the capability bits into AP[2:1] and the execute-never bits for a leaf descriptor.

fn leaf_attributes(perms: Permissions) u64 {

    if (perms.device) {

        return access_flag | attribute_device | privileged_execute_never | user_execute_never | device_access(perms);

    }

    var attributes = access_flag | shareable_inner | (if (perms.uncached) attribute_normal_uncached else attribute_normal);

    if (perms.user) {

        attributes |= if (perms.write) @as(u64, 0b01) << 6 else @as(u64, 0b11) << 6;

    } else {

        attributes |= if (perms.write) @as(u64, 0b00) << 6 else @as(u64, 0b10) << 6;

    }

    if (!perms.execute) {

        attributes |= privileged_execute_never | user_execute_never;

    } else if (perms.user) {

        attributes |= privileged_execute_never;

    } else {

        attributes |= user_execute_never;

    }

    return attributes;

}

// AP[2:1] for a device leaf; same encoding as the normal-memory path, without the execute choices.

fn device_access(perms: Permissions) u64 {

    if (perms.user) {

        return if (perms.write) @as(u64, 0b01) << 6 else @as(u64, 0b11) << 6;

    }

    return if (perms.write) @as(u64, 0b00) << 6 else @as(u64, 0b10) << 6;

}
