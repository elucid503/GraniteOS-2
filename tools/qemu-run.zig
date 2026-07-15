// Run subprocess with inherited stdio; always exit 0 so QEMU SDL close does not fail the build.

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