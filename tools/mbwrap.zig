// Host tool `mbwrap <kernel.elf> <flat.bin> <out.bin>`: prepend a Multiboot1 AOUT-kludge header so QEMU `-kernel`
// finds the magic in the first 8 KiB while the flat payload still lands at its linked address.

const std = @import("std");

const mb_magic: u32 = 0x1BADB002;
const mb_flags: u32 = 1 << 16;

const e_entry = 0x18;
const e_phoff = 0x20;
const e_phentsize = 0x36;
const e_phnum = 0x38;

const p_type = 0x00;
const p_paddr = 0x18;
const p_memsz = 0x28;

const pt_load = 1;
const header_size: u32 = 4096;

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len != 4) {

        std.debug.print("usage: mbwrap <kernel.elf> <flat.bin> <out.bin>\n", .{});
        return error.BadUsage;

    }

    const elf = try std.fs.cwd().readFileAlloc(arena, args[1], 64 * 1024 * 1024);
    const payload = try std.fs.cwd().readFileAlloc(arena, args[2], 64 * 1024 * 1024);

    const entry: u32 = @truncate(read_u64(elf, e_entry));
    const base: u32 = @truncate(try lowest_load(elf));

    // Multiboot AOUT-kludge: ask the bootloader to zero through the ELF BSS/stack footprint.
    // `load_end` is the file bytes; `bss_end` extends to the highest PT_LOAD mem end.
    const load_addr = base - header_size;
    const load_end = base + @as(u32, @intCast(payload.len));
    const bss_end: u32 = @truncate(try highest_load_end(elf));
    const checksum: u32 = 0 -% (mb_magic +% mb_flags);

    var header = [_]u8{0} ** header_size;

    write_u32(&header, 0, mb_magic);
    write_u32(&header, 4, mb_flags);
    write_u32(&header, 8, checksum);
    write_u32(&header, 12, load_addr); // header_addr
    write_u32(&header, 16, load_addr); // load_addr
    write_u32(&header, 20, load_end); // load_end
    write_u32(&header, 24, bss_end); // bss_end
    write_u32(&header, 28, entry); // entry_addr

    const out = try std.fs.cwd().createFile(args[3], .{});
    defer out.close();

    try out.writeAll(&header);
    try out.writeAll(payload);

}

fn lowest_load(elf: []const u8) !u64 {

    const phoff = read_u64(elf, e_phoff);
    const phentsize = read_u16(elf, e_phentsize);
    const phnum = read_u16(elf, e_phnum);

    var base: u64 = std.math.maxInt(u64);
    var found = false;

    for (0..phnum) |index| {

        const header = phoff + index * phentsize;

        if (read_u32(elf, header + p_type) != pt_load) continue;

        const paddr = read_u64(elf, header + p_paddr);
        const memsz = read_u64(elf, header + p_memsz);

        if (memsz == 0) continue;

        base = @min(base, paddr);
        found = true;

    }

    if (!found) return error.NoLoadableSegments;

    return base;

}

fn highest_load_end(elf: []const u8) !u64 {

    const phoff = read_u64(elf, e_phoff);
    const phentsize = read_u16(elf, e_phentsize);
    const phnum = read_u16(elf, e_phnum);

    var end: u64 = 0;
    var found = false;

    for (0..phnum) |index| {

        const header = phoff + index * phentsize;

        if (read_u32(elf, header + p_type) != pt_load) continue;

        const paddr = read_u64(elf, header + p_paddr);
        const memsz = read_u64(elf, header + p_memsz);

        if (memsz == 0) continue;

        end = @max(end, paddr + memsz);
        found = true;

    }

    if (!found) return error.NoLoadableSegments;

    return end;

}

fn read_u16(bytes: []const u8, offset: u64) u16 {

    return std.mem.readInt(u16, bytes[@intCast(offset)..][0..2], .little);

}

fn read_u32(bytes: []const u8, offset: u64) u32 {

    return std.mem.readInt(u32, bytes[@intCast(offset)..][0..4], .little);

}

fn read_u64(bytes: []const u8, offset: u64) u64 {

    return std.mem.readInt(u64, bytes[@intCast(offset)..][0..8], .little);

}

fn write_u32(bytes: []u8, offset: usize, value: u32) void {

    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);

}
