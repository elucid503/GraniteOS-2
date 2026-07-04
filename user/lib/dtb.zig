// User-space device-tree reader (07-userspace-ddd.md Section 3): hardware discovery lives above the kernel now. M4 needs exactly one answer - where the PL011 lives and which line it raises - so this reads just that; the general parser grows with the drivers (M6+).

const std = @import("std");

pub const Uart = struct {

    base: usize,
    interrupt_line: u32, // GIC INTID, ready for create(.interrupt)

};

const magic = 0xd00dfeed;

const token_begin_node = 1;
const token_end_node = 2;
const token_prop = 3;
const token_nop = 4;
const token_end = 9;

const max_depth = 32;

// A GIC interrupt specifier is <kind number flags>; kind 0 is a shared line (SPI, INTID 32+), kind 1 per-core (PPI, INTID 16+).

const interrupt_kind_shared = 0;

/// Find the PL011 UART: its MMIO base from `reg` and its GIC INTID from `interrupts`.
pub fn find_uart(dtb: usize) ?Uart {

    if (read_u32(dtb, 0) != magic) return null;

    const struct_offset = read_u32(dtb, 8);
    const strings_offset = read_u32(dtb, 12);

    var address_cells: [max_depth]u32 = undefined;
    address_cells[0] = 2;

    // A node's properties may arrive in any order, so remember where they were and decode on node exit.

    var reg_offset: [max_depth]?usize = undefined;
    var interrupts_offset: [max_depth]?usize = undefined;
    var is_uart: [max_depth]bool = undefined;

    var depth: usize = 0;
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
                reg_offset[depth] = null;
                interrupts_offset[depth] = null;
                is_uart[depth] = false;

            },

            token_end_node => {

                if (is_uart[depth]) {

                    if (decode_uart(dtb, reg_offset[depth], interrupts_offset[depth], address_cells[depth - 1])) |uart| {

                        return uart;

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

                } else if (equals(property, "compatible") and compatible_lists(dtb, value, length, "arm,pl011")) {

                    is_uart[depth] = true;

                }

            },

            token_nop => {},

            else => return null,

        }

    }

}

fn decode_uart(dtb: usize, reg: ?usize, interrupts: ?usize, addr_cells: u32) ?Uart {

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

const testing = std.testing;

const fixture = @embedFile("virt.dtb"); // The same QEMU `virt` tree the kernel parser is tested against.

test "finds the PL011 window and its GIC line on QEMU virt" {

    const uart = find_uart(@intFromPtr(fixture)).?;

    try testing.expectEqual(@as(usize, 0x0900_0000), uart.base);
    try testing.expectEqual(@as(u32, 33), uart.interrupt_line);

}

test "reports nothing on a tree without the magic" {

    var bytes = [_]u8{0} ** 64;

    try testing.expectEqual(@as(?Uart, null), find_uart(@intFromPtr(&bytes)));

}
