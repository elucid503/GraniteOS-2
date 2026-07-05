// Host tool `flatten <image.elf> <out.bin>`: writes a load-faithful boot image, placing each PT_LOAD segment at its load offset.

const std = @import("std");

// ELF64 field offsets, read directly so this stays independent of std.elf shape changes across Zig versions.

const e_phoff = 0x20;
const e_phentsize = 0x36;
const e_phnum = 0x38;

const p_type = 0x00;
const p_offset = 0x08;
const p_paddr = 0x18;
const p_filesz = 0x20;
const p_memsz = 0x28;

const pt_load = 1;

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len != 3) {

        std.debug.print("usage: flatten <kernel.elf> <out.bin>\n", .{});
        return error.BadUsage;

    }

    const elf = try std.fs.cwd().readFileAlloc(arena, args[1], 64 * 1024 * 1024);

    const program_header_offset = read_u64(elf, e_phoff);
    const program_header_size = read_u16(elf, e_phentsize);
    const program_header_count = read_u16(elf, e_phnum);

    // First pass: lowest load address is the image base, highest in-memory end is the image length.

    var base: u64 = std.math.maxInt(u64);
    var end: u64 = 0;

    for (0..program_header_count) |index| {

        const header = program_header_offset + index * program_header_size;

        if (read_u32(elf, header + p_type) != pt_load) {

            continue;

        }

        const load_address = read_u64(elf, header + p_paddr);
        const memory_size = read_u64(elf, header + p_memsz);

        if (memory_size == 0) {

            continue;

        }

        base = @min(base, load_address);
        end = @max(end, load_address + memory_size);

    }

    if (end <= base) {

        return error.NoLoadableSegments;

    }

    const image = try arena.alloc(u8, end - base);
    @memset(image, 0);

    // Second pass: place each segment's bytes at its offset from the base.

    for (0..program_header_count) |index| {

        const header = program_header_offset + index * program_header_size;

        if (read_u32(elf, header + p_type) != pt_load) {

            continue;

        }

        const load_address = read_u64(elf, header + p_paddr);
        const source_offset = read_u64(elf, header + p_offset);
        const file_size = read_u64(elf, header + p_filesz);

        if (file_size == 0) {

            continue;

        }

        const destination = load_address - base;
        @memcpy(image[destination .. destination + file_size], elf[source_offset .. source_offset + file_size]);

    }

    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = image });

}

fn read_u16(bytes: []const u8, offset: usize) u16 {

    return std.mem.readInt(u16, bytes[offset..][0..2], .little);

}

fn read_u32(bytes: []const u8, offset: usize) u32 {

    return std.mem.readInt(u32, bytes[offset..][0..4], .little);

}

fn read_u64(bytes: []const u8, offset: usize) u64 {

    return std.mem.readInt(u64, bytes[offset..][0..8], .little);

}
