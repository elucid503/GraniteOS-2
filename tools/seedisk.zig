// Host tool: create the persistent QEMU disk if missing, format Strata, and seed bundled programs.

const std = @import("std");

const format = @import("format");

const block_size = format.block_size;

const FileDevice = struct {

    file: std.fs.File,
    blocks: u32,

    pub fn read_block(self: *FileDevice, index: u32, out: *[block_size]u8) !void {

        const offset = @as(u64, index) * block_size;

        try self.file.seekTo(offset);

        const read = try self.file.readAll(out);

        if (read < block_size) @memset(out[read..], 0);

    }

    pub fn write_block(self: *FileDevice, index: u32, data: *const [block_size]u8) !void {

        const offset = @as(u64, index) * block_size;

        try self.file.seekTo(offset);
        try self.file.writeAll(data);

    }

    pub fn block_count(self: *FileDevice) u32 {

        return self.blocks;

    }

};

const Volume = format.Volume(FileDevice);

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);

    if (args.len < 3 or (args.len - 3) % 2 != 0) {

        std.debug.print("usage: seedisk <path> <size-bytes> [<name> <elf-path>]...\n", .{});
        return error.Usage;

    }

    const path = args[1];
    const size = try std.fmt.parseInt(u64, args[2], 10);

    if (size < block_size or size % block_size != 0) return error.InvalidSize;

    const file = std.fs.cwd().createFile(path, .{ .read = true, .exclusive = true }) catch |failure| {

        if (failure == error.PathAlreadyExists) return;

        return failure;

    };

    defer file.close();

    try file.setEndPos(size);

    var device = FileDevice{

        .file = file,
        .blocks = @intCast(size / block_size),

    };

    var volume = try Volume.format(&device);

    _ = try volume.create("/root", .directory);
    _ = try volume.create("/root/programs", .directory);
    _ = try volume.create("/root/user", .directory);

    var index: usize = 3;

    while (index + 1 < args.len) : (index += 2) {

        const name = args[index];
        const elf_path = args[index + 1];
        const image = try std.fs.cwd().readFileAlloc(arena, elf_path, 64 * 1024 * 1024);

        var path_buffer: [format.max_name + 32]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buffer, "/root/programs/{s}", .{name});

        const inode = try volume.create(file_path, .file);

        var offset: usize = 0;

        while (offset < image.len) {

            const written = try volume.write(inode, offset, image[offset..]);

            if (written == 0) return error.ShortWrite;

            offset += written;

        }

    }

}
