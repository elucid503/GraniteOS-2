// Host tool `qemu-run <command> [args...]`: runs an interactive subprocess with inherited stdio and always exits 0.
// QEMU's SDL window reports a non-zero status on normal close; zig build should not treat that as failure.

const std = @import("std");

pub fn main() !void {

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len < 2) {

        std.debug.print("usage: qemu-run <command> [args...]\n", .{});
        return error.BadUsage;

    }

    var child = std.process.Child.init(args[1..], arena);

    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    _ = try child.wait();

}