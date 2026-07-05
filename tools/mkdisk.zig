// Host tool: ensure the QEMU disk image exists. An existing image is never touched - persistence across reboots is the point of M7 - so this only creates (and zero-fills) a missing file.

const std = @import("std");

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);

    if (args.len != 3) {

        std.debug.print("usage: mkdisk <path> <size-bytes>\n", .{});
        return error.Usage;

    }

    const path = args[1];
    const size = try std.fmt.parseInt(u64, args[2], 10);

    const file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |failure| {

        if (failure == error.PathAlreadyExists) return;

        return failure;

    };

    defer file.close();

    try file.setEndPos(size);

}
