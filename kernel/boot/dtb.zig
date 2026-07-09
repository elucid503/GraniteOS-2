// Flattened device-tree reader (06-kernel-ddd.md Section 3): the runtime source of truth for the memory banks, the core count, and the interrupt-controller windows.

const std = @import("std");

const frames = @import("../memory/frames.zig");
const machine_module = @import("machine.zig");

const types = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub const MemoryRange = frames.MemoryRange;
pub const IntctrlWindows = types.IntctrlWindows;
pub const Machine = machine_module.Machine;

const magic = 0xd00dfeed;

/// The total byte span of the tree (header field), so the boot path can reserve it from the frame allocator.
pub fn total_size(dtb: usize) usize {

    return read_u32(dtb, 4);

}

const token_begin_node = 1;
const token_end_node = 2;
const token_prop = 3;
const token_nop = 4;
const token_end = 9;

const max_depth = 32;

/// Walk the device tree at `dtb`, filling `memory_out` with the RAM banks and `cpu_out` with each core's MPIDR. Big-endian throughout.
pub fn parse(dtb: usize, memory_out: []MemoryRange, cpu_out: []u64) Error!Machine {

    if (read_u32(dtb, 0) != magic) return error.Invalid;

    const struct_offset = read_u32(dtb, 8);
    const strings_offset = read_u32(dtb, 12);

    // address/size cells a node declares for its children; index by depth. Root's parent defaults to 2/2 on this class of board.
    var address_cells: [max_depth]u32 = undefined;
    var size_cells: [max_depth]u32 = undefined;
    address_cells[0] = 2;
    size_cells[0] = 2;

    var names: [max_depth][]const u8 = undefined;
    names[0] = "";

    // A node's `reg` may precede or follow its `compatible`, so remember where it was and decode on node exit.
    var reg_offset: [max_depth]?usize = undefined;
    var is_gic: [max_depth]bool = undefined;

    var depth: usize = 0;
    var memory_count: usize = 0;
    var core_count: usize = 0;
    var intctrl: ?IntctrlWindows = null;
    var power: ?types.PowerMethod = null;
    var initrd_start: u64 = 0;
    var initrd_end: u64 = 0;

    var position: usize = struct_offset;

    while (true) {

        const token = read_u32(dtb, position);
        position += 4;

        switch (token) {

            token_begin_node => {

                const name = cstring(dtb, position);
                position += align4(name.len + 1);

                depth += 1;
                address_cells[depth] = address_cells[depth - 1];
                size_cells[depth] = size_cells[depth - 1];
                names[depth] = name;
                reg_offset[depth] = null;
                is_gic[depth] = false;

                if (starts_with(name, "cpu@") and equals(names[depth - 1], "cpus")) {

                    core_count += 1;

                }

            },

            token_end_node => {

                if (is_gic[depth] and intctrl == null) {

                    if (reg_offset[depth]) |offset| {

                        intctrl = read_intctrl(dtb, offset, address_cells[depth - 1], size_cells[depth - 1]);

                    }

                }

                depth -= 1;

            },

            token_prop => {

                const length = read_u32(dtb, position);
                const name_offset = read_u32(dtb, position + 4);
                const value = position + 8;
                position += 8 + align4(length);

                const property = cstring(dtb, strings_offset + name_offset);

                if (equals(property, "#address-cells")) {

                    address_cells[depth] = read_u32(dtb, value);

                } else if (equals(property, "#size-cells")) {

                    size_cells[depth] = read_u32(dtb, value);

                } else if (equals(property, "reg") and is_memory(names[depth])) {

                    memory_count += read_memory(dtb, value, length, address_cells[depth - 1], size_cells[depth - 1], memory_out[memory_count..]);

                } else if (equals(property, "reg") and starts_with(names[depth], "cpu@") and equals(names[depth - 1], "cpus")) {

                    if (core_count <= cpu_out.len and core_count > 0) {

                        cpu_out[core_count - 1] = read_cells(dtb, value, address_cells[depth - 1]);

                    }

                } else if (equals(property, "reg")) {

                    reg_offset[depth] = value;

                } else if (equals(property, "compatible") and compatible_lists(dtb, value, length, "arm,gic-v3")) {

                    is_gic[depth] = true;

                } else if (equals(property, "method") and equals(names[depth], "psci")) {

                    power = if (equals(cstring(dtb, value), "smc")) .smc else .hvc;

                } else if (equals(property, "linux,initrd-start") and equals(names[depth], "chosen")) {

                    initrd_start = read_sized(dtb, value, length);

                } else if (equals(property, "linux,initrd-end") and equals(names[depth], "chosen")) {

                    initrd_end = read_sized(dtb, value, length);

                }

            },

            token_nop => {},

            token_end => break,

            else => return error.Invalid,
        }

    }

    const initrd: ?MemoryRange = if (initrd_end > initrd_start and initrd_start != 0) .{

        .base = @intCast(initrd_start),
        .length = @intCast(initrd_end - initrd_start),

    } else null;

    return .{

        .memory = memory_out[0..memory_count],
        .core_count = core_count,
        .intctrl = intctrl,
        .initrd = initrd,

        .cpus = cpu_out[0..@min(core_count, cpu_out.len)],
        .power = power,

        .discovery = dtb,
        .discovery_length = total_size(dtb),

    };

}

// The /chosen initrd properties are sized to their value: one cell on small machines, two above 4 GiB.

fn read_sized(dtb: usize, value: usize, length: u32) u64 {

    if (length == 8) return read_cells(dtb, value, 2);

    return read_u32(dtb, value);

}

// A GICv3 `reg` lists distributor first, then the redistributor region (one 128 KiB frame per core on `virt`).

const redistributor_stride = 0x2_0000;

fn read_intctrl(dtb: usize, offset: usize, addr_cells: u32, size_cells: u32) ?IntctrlWindows {

    const entry_words = addr_cells + size_cells;

    if (entry_words == 0) return null;

    const distributor = read_cells(dtb, offset, addr_cells);
    const redistributor = read_cells(dtb, offset + entry_words * 4, addr_cells);

    return .{

        .distributor = @intCast(distributor),
        .redistributor = @intCast(redistributor),
        .redistributor_stride = redistributor_stride,

    };

}

// `compatible` is a list of nul-terminated strings; report whether any of them is `wanted`.

fn compatible_lists(dtb: usize, value: usize, length: u32, wanted: []const u8) bool {

    var offset: usize = 0;

    while (offset < length) {

        const entry = cstring(dtb, value + offset);

        if (equals(entry, wanted)) return true;

        offset += entry.len + 1;

    }

    return false;

}

// A memory node's `reg` is a list of (address, size) entries, each `addr_cells`/`size_cells` 32-bit words wide.

fn read_memory(dtb: usize, value: usize, length: u32, addr_cells: u32, size_cells: u32, out: []MemoryRange) usize {

    const entry_words = addr_cells + size_cells;

    if (entry_words == 0) return 0;

    const entries = (length / 4) / entry_words;

    var written: usize = 0;
    var offset = value;

    for (0..entries) |_| {

        if (written >= out.len) break;

        const address = read_cells(dtb, offset, addr_cells);
        const size = read_cells(dtb, offset + addr_cells * 4, size_cells);
        offset += entry_words * 4;

        out[written] = .{ .base = @intCast(address), .length = @intCast(size) };
        written += 1;

    }

    return written;

}

fn read_cells(dtb: usize, offset: usize, cells: u32) u64 {

    var value: u64 = 0;
    var index: u32 = 0;

    while (index < cells) : (index += 1) {

        value = (value << 32) | read_u32(dtb, offset + index * 4);

    }

    return value;

}

fn read_u32(dtb: usize, offset: usize) u32 {

    const bytes: [*]const u8 = @ptrFromInt(dtb + offset);
    return std.mem.readInt(u32, bytes[0..4], .big);

}

fn cstring(dtb: usize, offset: usize) []const u8 {

    const bytes: [*]const u8 = @ptrFromInt(dtb + offset);
    var length: usize = 0;

    while (bytes[length] != 0) : (length += 1) {}

    return bytes[0..length];

}

fn align4(value: usize) usize {

    return (value + 3) & ~@as(usize, 3);

}

fn is_memory(name: []const u8) bool {

    return equals(name, "memory") or starts_with(name, "memory@");

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}

fn starts_with(haystack: []const u8, needle: []const u8) bool {

    return std.mem.startsWith(u8, haystack, needle);

}

const testing = std.testing;

const fixture = @embedFile("virt.dtb"); // A real QEMU `virt` tree dumped with `gic-version=3 -smp 4 -m 256M`.

test "parses the QEMU virt memory bank and core count" {

    var memory: [8]MemoryRange = undefined;
    var cpus: [8]u64 = undefined;
    const machine = try parse(@intFromPtr(fixture), &memory, &cpus);

    try testing.expectEqual(@as(usize, 4), machine.core_count);
    try testing.expectEqual(@as(usize, 1), machine.memory.len);
    try testing.expectEqual(@as(usize, 0x4000_0000), machine.memory[0].base);
    try testing.expectEqual(@as(usize, 0x1000_0000), machine.memory[0].length);

}

test "discovers the GICv3 windows" {

    var memory: [8]MemoryRange = undefined;
    var cpus: [8]u64 = undefined;
    const machine = try parse(@intFromPtr(fixture), &memory, &cpus);

    const intctrl = machine.intctrl.?;

    try testing.expectEqual(@as(usize, 0x0800_0000), intctrl.distributor);
    try testing.expectEqual(@as(usize, 0x080a_0000), intctrl.redistributor);
    try testing.expectEqual(@as(usize, 0x2_0000), intctrl.redistributor_stride);

}

const fixture_sixteen = @embedFile("virt-16.dtb");

test "discovers the GICv3 windows on QEMU virt with sixteen cores" {

    var memory: [8]MemoryRange = undefined;
    var cpus: [16]u64 = undefined;
    const machine = try parse(@intFromPtr(fixture_sixteen), &memory, &cpus);

    try testing.expectEqual(@as(usize, 16), machine.core_count);

    const intctrl = machine.intctrl.?;

    try testing.expectEqual(@as(usize, 0x0800_0000), intctrl.distributor);
    try testing.expectEqual(@as(usize, 0x080a_0000), intctrl.redistributor);

}

test "collects each CPU's MPIDR and the PSCI conduit" {

    var memory: [8]MemoryRange = undefined;
    var cpus: [8]u64 = undefined;
    const machine = try parse(@intFromPtr(fixture), &memory, &cpus);

    try testing.expectEqual(@as(usize, 4), machine.cpus.len);

    for (machine.cpus, 0..) |mpidr, index| {

        try testing.expectEqual(@as(u64, index), mpidr);

    }

    try testing.expectEqual(types.PowerMethod.hvc, machine.power.?);

}

test "a tree without /chosen initrd properties reports no initrd" {

    var memory: [8]MemoryRange = undefined;
    var cpus: [8]u64 = undefined;
    const machine = try parse(@intFromPtr(fixture), &memory, &cpus);

    try testing.expectEqual(@as(?MemoryRange, null), machine.initrd);

}

test "rejects a tree without the magic" {

    var bytes = [_]u8{0} ** 64;
    var memory: [4]MemoryRange = undefined;
    var cpus: [4]u64 = undefined;

    try testing.expectError(error.Invalid, parse(@intFromPtr(&bytes), &memory, &cpus));

}
