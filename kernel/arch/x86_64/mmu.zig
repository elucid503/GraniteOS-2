// x86_64 MMU: 4-level long-mode page tables with the same map/unmap surface as aarch64.

const board = @import("../board/pc.zig");
const config = @import("../../config.zig");
const frames = @import("../../memory/frames.zig");
const cpu = @import("cpu.zig");

const types = @import("../../types.zig");
const Error = @import("../../error.zig").Error;

const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;
const page_size = config.page_size;

const entries_per_table = 512;

const present: u64 = 1 << 0;
const writable: u64 = 1 << 1;
const user: u64 = 1 << 2;
const write_through: u64 = 1 << 3;
const cache_disable: u64 = 1 << 4;
const huge: u64 = 1 << 7;
const no_execute: u64 = 1 << 63;

const output_mask: u64 = 0x000f_ffff_ffff_f000;

pub const Permissions = packed struct(u8) {

    read: bool = false,
    write: bool = false,
    execute: bool = false,
    user: bool = true,
    device: bool = false,
    uncached: bool = false,
    _pad: u2 = 0,

};

/// Boot already identity-mapped low memory; keep the early console reachable and ensure NXE is on.
pub fn enable_boot_mapping() void {

    // Enable NXE in EFER so no-execute bits are honored.
    const efer = cpu.read_msr(0xC0000080);
    cpu.write_msr(0xC0000080, efer | (1 << 11));

    _ = board;

}

pub fn new_table() Error!PhysAddr {

    const frame = try frames.alloc();
    zero_table(frame);

    // Share the live kernel identity map (PML4 slot 0) so ring0 keeps low physical access.
    const root: *[entries_per_table]u64 = @ptrFromInt(frame);
    const current: *const [entries_per_table]u64 = @ptrFromInt(cpu.read_cr3() & output_mask);
    root[0] = current[0];

    return frame;

}

pub fn map_page(root: PhysAddr, va: VirtAddr, pa: PhysAddr, perms: Permissions) Error!void {

    var table = root;

    for (0..3) |level| {

        const entry: *u64 = @ptrFromInt(table + table_index(va, level) * 8);

        if (entry.* & present == 0) {

            const next = try frames.alloc();
            zero_table(next);
            entry.* = next | present | writable | user;

        }

        table = entry.* & output_mask;

    }

    const leaf: *u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    leaf.* = (pa & output_mask) | leaf_attributes(perms);
    flush_tlb_page(va);

}

pub fn unmap_page(root: PhysAddr, va: VirtAddr) void {

    var table = root;

    for (0..3) |level| {

        const entry: *const u64 = @ptrFromInt(table + table_index(va, level) * 8);
        if (entry.* & present == 0) return;
        table = entry.* & output_mask;

    }

    const leaf: *u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    leaf.* = 0;
    flush_tlb_page(va);

}

pub fn translate(root: PhysAddr, va: VirtAddr) ?PhysAddr {

    var table = root;

    for (0..3) |level| {

        const entry: *const u64 = @ptrFromInt(table + table_index(va, level) * 8);
        if (entry.* & present == 0) return null;
        table = entry.* & output_mask;

    }

    const leaf: *const u64 = @ptrFromInt(table + table_index(va, 3) * 8);
    if (leaf.* & present == 0) return null;
    return (leaf.* & output_mask) | (va & (page_size - 1));

}

pub fn activate_space(root: PhysAddr) void {

    cpu.write_cr3(root);

}

pub fn flush_tlb_page(va: VirtAddr) void {

    // Reload CR3 to flush; precise invlpg can land with the rest of the TLB helpers.
    _ = va;
    cpu.write_cr3(cpu.read_cr3());

}

pub fn map_ram(ranges: []const frames.MemoryRange) void {

    // Boot identity map already covers the first 4 GiB; extend with 2 MiB pages if needed later.
    _ = ranges;

}

pub fn free_table(root: PhysAddr) void {

    const entries: *const [entries_per_table]u64 = @ptrFromInt(root);

    for (entries[1..]) |entry| {

        if (entry & present == 0) continue;
        free_level(entry & output_mask, 1);

    }

    frames.free(root);

}

fn free_level(table: PhysAddr, level: usize) void {

    const entries: *const [entries_per_table]u64 = @ptrFromInt(table);

    if (level < 3) {

        for (entries) |entry| {

            if (entry & present == 0) continue;
            if (entry & huge != 0) continue;
            free_level(entry & output_mask, level + 1);

        }

    }

    frames.free(table);

}

fn leaf_attributes(perms: Permissions) u64 {

    var bits: u64 = present;

    if (perms.write) bits |= writable;
    if (perms.user) bits |= user;
    if (!perms.execute) bits |= no_execute;

    if (perms.device or perms.uncached) {

        bits |= cache_disable | write_through;

    }

    return bits;

}

fn table_index(va: VirtAddr, level: usize) usize {

    const shift: u6 = @intCast(39 - level * 9);
    return (va >> shift) & 0x1ff;

}

fn zero_table(frame: PhysAddr) void {

    const bytes: [*]u8 = @ptrFromInt(frame);
    @memset(bytes[0..page_size], 0);

}
