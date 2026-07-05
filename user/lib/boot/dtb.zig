// User-space device-tree reader (07-userspace-ddd.md Section 3): hardware discovery lives above the kernel now. The
// walker collects every node matching a `compatible` string, so the same scan finds the PL011 (M4) and the
// virtio-mmio transports (M7); it grows with the drivers.

const std = @import("std");

pub const Device = struct {

    base: usize,
    interrupt_line: u32, // GIC INTID, ready for create(.interrupt)

};

pub const Uart = Device;

const magic = 0xd00dfeed;

const token_begin_node = 1;
const token_end_node = 2;
const token_prop = 3;
const token_nop = 4;
const token_end = 9;

const max_depth = 32;

// A GIC interrupt specifier is <kind number flags>; kind 0 is a shared line (SPI, INTID 32+), kind 1 per-core (PPI, INTID 16+).

const interrupt_kind_shared = 0;

/// Count `cpu@` nodes under `/cpus`, matching the kernel's DTB walk.
pub fn core_count(dtb: usize) usize {

    if (read_u32(dtb, 0) != magic) return 0;

    const struct_offset = read_u32(dtb, 8);

    var names: [max_depth][]const u8 = undefined;
    names[0] = "";

    var depth: usize = 0;
    var count: usize = 0;
    var position: usize = struct_offset;

    while (true) {

        const token = read_u32(dtb, position);
        position += 4;

        switch (token) {

            token_begin_node => {

                const name = cstring(dtb, position);
                position += align4(name.len + 1);

                depth += 1;
                names[depth] = name;

                if (starts_with(name, "cpu@") and equals(names[depth - 1], "cpus")) {

                    count += 1;

                }

            },

            token_end_node => {

                depth -= 1;

            },

            token_prop => {

                const length = read_u32(dtb, position);
                position += 8 + align4(length);

            },

            token_nop => {},

            else => return count,

        }

    }

}

/// Find the PL011 UART: its MMIO base from `reg` and its GIC INTID from `interrupts`.
pub fn find_uart(dtb: usize) ?Uart {

    var found: [1]Device = undefined;

    if (find_compatible(dtb, "arm,pl011", &found) == 0) return null;

    return found[0];

}

/// Collect every node whose `compatible` list contains `wanted`, in tree order; returns how many were written.
pub fn find_compatible(dtb: usize, wanted: []const u8, out: []Device) usize {

    if (read_u32(dtb, 0) != magic) return 0;

    const struct_offset = read_u32(dtb, 8);
    const strings_offset = read_u32(dtb, 12);

    var address_cells: [max_depth]u32 = undefined;
    address_cells[0] = 2;

    // A node's properties may arrive in any order, so remember where they were and decode on node exit.

    var reg_offset: [max_depth]?usize = undefined;
    var interrupts_offset: [max_depth]?usize = undefined;
    var matched: [max_depth]bool = undefined;

    var found: usize = 0;
    var depth: usize = 0;
    var position: usize = struct_offset;

    while (found < out.len) {

        const token = read_u32(dtb, position);
        position += 4;

        switch (token) {

            token_begin_node => {

                const name = cstring(dtb, position);
                position += align4(name.len + 1);

                depth += 1;
                address_cells[depth] = address_cells[depth - 1];
                reg_offset[depth] = null;
                interrupts_offset[depth] = null;
                matched[depth] = false;

            },

            token_end_node => {

                if (matched[depth]) {

                    if (decode_device(dtb, reg_offset[depth], interrupts_offset[depth], address_cells[depth - 1])) |device| {

                        out[found] = device;
                        found += 1;

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

                } else if (equals(property, "reg")) {

                    reg_offset[depth] = value;

                } else if (equals(property, "interrupts")) {

                    interrupts_offset[depth] = value;

                } else if (equals(property, "compatible") and compatible_lists(dtb, value, length, wanted)) {

                    matched[depth] = true;

                }

            },

            token_nop => {},

            else => return found,

        }

    }

    return found;

}

fn decode_device(dtb: usize, reg: ?usize, interrupts: ?usize, addr_cells: u32) ?Device {

    const reg_at = reg orelse return null;
    const interrupts_at = interrupts orelse return null;

    const kind = read_u32(dtb, interrupts_at);
    const number = read_u32(dtb, interrupts_at + 4);

    const line = if (kind == interrupt_kind_shared) number + 32 else number + 16;

    return .{

        .base = @intCast(read_cells(dtb, reg_at, addr_cells)),
        .interrupt_line = line,

    };

}

fn compatible_lists(dtb: usize, value: usize, length: u32, wanted: []const u8) bool {

    var offset: usize = 0;

    while (offset < length) {

        const entry = cstring(dtb, value + offset);

        if (equals(entry, wanted)) return true;

        offset += entry.len + 1;

    }

    return false;

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

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}

fn starts_with(haystack: []const u8, needle: []const u8) bool {

    return std.mem.startsWith(u8, haystack, needle);

}

const testing = std.testing;

const fixture = @embedFile("virt.dtb"); // The same QEMU `virt` tree the kernel parser is tested against.

test "counts the cpu nodes on QEMU virt" {

    try testing.expectEqual(@as(usize, 4), core_count(@intFromPtr(fixture)));

}

test "finds the PL011 window and its GIC line on QEMU virt" {

    const uart = find_uart(@intFromPtr(fixture)).?;

    try testing.expectEqual(@as(usize, 0x0900_0000), uart.base);
    try testing.expectEqual(@as(u32, 33), uart.interrupt_line);

}

test "collects the virtio-mmio transports on QEMU virt" {

    var devices: [64]Device = undefined;
    const count = find_compatible(@intFromPtr(fixture), "virtio,mmio", &devices);

    try testing.expectEqual(@as(usize, 32), count);

    // QEMU places the transports at 0xa000000 + 0x200 * n with SPIs 16 + n (INTID 48 + n), in some tree order.

    var seen_first = false;

    for (devices[0..count]) |device| {

        if (device.base == 0xa00_0000) {

            try testing.expectEqual(@as(u32, 48), device.interrupt_line);
            seen_first = true;

        }

    }

    try testing.expect(seen_first);

}

test "reports nothing on a tree without the magic" {

    var bytes = [_]u8{0} ** 64;

    try testing.expectEqual(@as(?Uart, null), find_uart(@intFromPtr(&bytes)));

}
