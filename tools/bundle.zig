// Pack user module bundle; Flint is flat, other images are verbatim ELF.

const std = @import("std");

const magic: u32 = 0x444e_4247;
const version: u32 = 1;
const name_bytes = 24;
const image_alignment = 16;

const Header = extern struct {

    magic: u32,
    version: u32,
    count: u32,
    reserved: u32,

};

const Entry = extern struct {

    name: [name_bytes]u8,
    offset: u32,
    length: u32,

};

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len < 4 or args.len % 2 != 0) {

        std.debug.print("usage: bundle <out.img> <name> <image>...\n", .{});
        return error.BadUsage;

    }

    const count = (args.len - 2) / 2;
    const entries = try arena.alloc(Entry, count);
    const images = try arena.alloc([]const u8, count);

    var cursor = align_up(@sizeOf(Header) + count * @sizeOf(Entry), image_alignment);

    for (0..count) |index| {

        const name = args[2 + index * 2];
        const path = args[3 + index * 2];
        const image = try std.fs.cwd().readFileAlloc(arena, path, 64 * 1024 * 1024);

        if (name.len == 0 or name.len >= name_bytes) return error.NameTooLong;
        if (cursor > std.math.maxInt(u32)) return error.ImageTooLarge;
        if (image.len > std.math.maxInt(u32)) return error.ImageTooLarge;

        var stored_name = [_]u8{0} ** name_bytes;
        @memcpy(stored_name[0..name.len], name);

        entries[index] = .{

            .name = stored_name,
            .offset = @intCast(cursor),
            .length = @intCast(image.len),

        };

        images[index] = image;
        cursor = align_up(cursor + image.len, image_alignment);

    }

    const output = try arena.alloc(u8, cursor);
    @memset(output, 0);

    std.mem.writeInt(u32, output[0..4], magic, .little);
    std.mem.writeInt(u32, output[4..8], version, .little);
    std.mem.writeInt(u32, output[8..12], @intCast(count), .little);
    std.mem.writeInt(u32, output[12..16], 0, .little);

    var table_offset: usize = @sizeOf(Header);

    for (entries) |entry| {

        @memcpy(output[table_offset .. table_offset + name_bytes], entry.name[0..]);
        std.mem.writeInt(u32, output[table_offset + 24 ..][0..4], entry.offset, .little);
        std.mem.writeInt(u32, output[table_offset + 28 ..][0..4], entry.length, .little);

        table_offset += @sizeOf(Entry);

    }

    for (entries, images) |entry, image| {

        const offset: usize = entry.offset;
        @memcpy(output[offset .. offset + image.len], image);

    }

    try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = output });

}

fn align_up(value: usize, alignment: usize) usize {

    return (value + alignment - 1) & ~(alignment - 1);

}
