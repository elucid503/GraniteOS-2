// Program catalog and help/about output for Marble and all the bundled utilities.

const io = @import("../io/io.zig");
const stream = @import("../io/stream.zig");

pub const Entry = struct {

    name: []const u8,
    description: []const u8,

};

pub const builtins = [_]Entry{

    .{ .name = "help", .description = "List available commands" },
    .{ .name = "about", .description = "About GraniteOS" },
    .{ .name = "clear", .description = "Clear the terminal screen" },
    .{ .name = "location", .description = "Print the current directory" },
    .{ .name = "exit", .description = "Relaunch Marble" },

};

pub const common = [_]Entry{

    .{ .name = "echo", .description = "Print arguments to stdout" },
    .{ .name = "cat", .description = "Copy stdin to stdout" },
    .{ .name = "help", .description = "List available programs" },
    .{ .name = "about", .description = "About GraniteOS" },
    .{ .name = "hello", .description = "Greeting from user space" },
    .{ .name = "clear", .description = "Clear the terminal screen" },
    .{ .name = "wc", .description = "Count lines and bytes from stdin" },
    .{ .name = "cat-via-name", .description = "Resolve console through name service" },
    .{ .name = "stress", .description = "Grind worker threads across all cores" },

};

pub const location = [_]Entry{

    .{ .name = "location", .description = "Print the current directory" },

};

pub const filesystem = [_]Entry{

    .{ .name = "ls", .description = "List a directory" },
    .{ .name = "view", .description = "View a file (pager when interactive)" },
    .{ .name = "write", .description = "Edit or write a file" },
    .{ .name = "create", .description = "Create an empty file" },
    .{ .name = "mkdir", .description = "Create a directory" },
    .{ .name = "delete", .description = "Remove a file or empty directory" },
    .{ .name = "rename", .description = "Move a file or directory" },
    .{ .name = "perms", .description = "Set file write permission" },

};

pub fn write_help(out: *stream.Stream) io.Error!void {

    try io.writeln(out, "");
    try io.writeln(out, "GraniteOS - Available Programs");
    try io.writeln(out, "");

    try write_category(out, "builtins", &builtins);
    try io.writeln(out, "");
    try write_category(out, "common", &common);
    try io.writeln(out, "");
    try write_category(out, "location", &location);
    try io.writeln(out, "");
    try write_category(out, "filesystem", &filesystem);
    try io.writeln(out, "");

}

pub fn write_about(out: *stream.Stream) io.Error!void {

    try io.writeln(out, "");
    try io.writeln(out, "   ______                 _ __       ____  _____    ___ ");
    try io.writeln(out, "  / ____/________ _____  (_) /____  / __ \\/ ___/   |__ \\");
    try io.writeln(out, " / / __/ ___/ __ `/ __ \\/ / __/ _ \\/ / / /\\__ \\    __/ /");
    try io.writeln(out, "/ /_/ / /  / /_/ / / / / / /_/  __/ /_/ /___/ /   / __/ ");
    try io.writeln(out, "\\____/_/   \\__,_/_/ /_/_/\\__/\\___/\\____//____/   /____/ ");
    try io.writeln(out, "");
    try io.writeln(out, "A from-scratch microkernel OS built in Zig.");
    try io.writeln(out, "");
    try io.writeln(out, "Features:");
    try io.writeln(out, "  - Capability-based microkernel");
    try io.writeln(out, "  - Name service for endpoint discovery");
    try io.writeln(out, "  - User-space drivers and servers");
    try io.writeln(out, "  - Ring-stream pipeline support");
    try io.writeln(out, "  - Bundled ELF program loading");
    try io.writeln(out, "  - virtio-blk driver + Strata filesystem");
    try io.writeln(out, "  - SMP: work-stealing scheduler on any core count");
    try io.writeln(out, "  - FLINT startup program");
    try io.writeln(out, "  - MARBLE shell");
    try io.writeln(out, "");
    try io.writeln(out, "Type 'help' to see available commands.");
    try io.writeln(out, "");

}

fn write_category(out: *stream.Stream, title: []const u8, entries: []const Entry) io.Error!void {

    try io.writeln(out, title);

    for (entries) |entry| {

        try io.write_entry(out, entry.name, entry.description);

    }

}
