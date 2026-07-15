// Marble: the GraniteOS interactive shell. Launches bundled programs and runs pipelines over Ring streams.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const name = "marble";
const root_dir = "/";

// The default filesystem layout (07-userspace-ddd.md Section 8): programs live under one directory, the shell opens in another.

const programs_dir = "/root/programs";
const home_dir = "/root/user";

const max_line = 256;
const max_stages = 4;
const max_args = 8;
const max_path = 512;

// A whole ELF image is loaded before the loader picks out its segments; sized comfortably above the largest program.

const max_program = 1024 * 1024;
// Image (~0.3 MiB) + largest typical media buffer + FS/audio session regions must fit under this.
const child_budget = 4 * 1024 * 1024;
const pipe_capacity = 4096;

const Stage = struct {

    argv: [max_args][]const u8 = undefined,
    argc: usize = 0,

    fn args(self: *const Stage) []const []const u8 {

        return self.argv[0..self.argc];

    }

};

const Pipeline = struct {

    stages: [max_stages]Stage = undefined,
    count: usize = 0,

};

var bundle: lib.bundle.Bundle = undefined;
var supervisor: cap.Handle = 0;
var machine_core_count: u64 = 1;

// The filesystem, connected once at startup, or null when no disk is present (the shell still runs, from the bundle).
var files: ?lib.fs.Client = null;

var cwd_storage: [max_path]u8 = undefined;
var cwd: []const u8 = root_dir;

// A missing program is loaded from disk into this scratch image before spawning; spawn_program copies it out synchronously, so one buffer serves every stage in turn.
var load_buffer: [max_program]u8 = undefined;

// How the shell locates a command: an installed file on the search path, or a module baked into the boot bundle.
const Resolved = union(enum) {

    disk: []const u8,
    bundled: []const u8,

};

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        const err = lib.start.stdout() catch return 1;

        lib.io.write(err, name) catch {};
        lib.io.write(err, ": fatal ") catch {};
        lib.io.write(err, @errorName(failure)) catch {};
        lib.io.write(err, "\n") catch {};

        return 1;

    };

    return 0;

}

fn run() !void {

    const bundle_base = try sys.map(cap.self_space, cap.marble.bundle, 0, sys.read);

    bundle = try lib.bundle.Bundle.open(bundle_base + @as(usize, @intCast(lib.start.word(4))), @intCast(lib.start.word(3)));
    machine_core_count = @max(1, lib.start.word(proto.init.core_count_word));
    supervisor = try sys.create(.endpoint, 0, 0);

    var input = try lib.start.stdin();
    const out = try lib.start.stdout();

    var line: [max_line]u8 = undefined;

    if (lib.fs.Client.connect(cap.memory)) |client| {

        files = client;

        ensure_layout();
        install_programs(out);

        set_cwd(lib.start.cwd());

    } else |_| {}

    try write_banner(out);

    while (true) {

        const length = try lib.line.read(&input, out, &line, .{

            .shell = name,
            .cwd = cwd,
            .files = if (files) |*client| client else null,

        });

        const pipeline = parse(line[0..length]) catch |failure| {

            try report_parse_error(out, failure);
            continue;

        };

        if (pipeline.count == 0) continue;

        if (pipeline.count == 1) {

            if (run_builtin(&pipeline.stages[0], out) catch continue) continue;

        }

        // A failed command reports and returns to the prompt; the shell never tears down over one bad line.

        run_pipeline(&pipeline) catch |failure| {

            report_command_error(out, failure);

        };

    }

}

// Create the default directory layout, tolerating the common case where a previous boot already made it.

fn ensure_layout() void {

    if (files) |*client| {

        client.mkdir("/root") catch {};
        client.mkdir(programs_dir) catch {};
        client.mkdir(home_dir) catch {};

    }

}

// Install bundled programs into the search path once; only a fresh disk pays the copy cost.

fn install_programs(out: *lib.stream.Stream) void {

    const catalog_bytes = bundle.find("app-catalog") orelse return;
    const catalog = lib.app_catalog.Catalog.open(catalog_bytes) catch return;

    var installed: usize = 0;
    var index: usize = 0;

    while (index < catalog.program_count) : (index += 1) {

        const entry = catalog.program(index) orelse continue;

        installed += @intFromBool(install_program(entry.name));

    }

    if (installed != 0) {

        lib.io.print(out, "MARBLE: installed {d} programs into {s}\n", .{ installed, programs_dir }) catch {};

    }

}

fn install_program(program: []const u8) bool {

    const client = if (files) |*handle| handle else return false;
    const image = bundle.find(program) orelse return false;

    var path_buffer: [max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ programs_dir, program }) catch return false;

    // Already installed from an earlier boot: leave the on-disk copy untouched.

    if (client.stat(path)) |_| {

        return false;

    } else |failure| {

        if (failure != error.NotFound) return false;

    }

    write_program(client, path, image) catch return false;

    return true;

}

fn write_program(client: *lib.fs.Client, path: []const u8, image: []const u8) !void {

    const file = try client.open_path(path, proto.filesystem.open_create | proto.filesystem.open_truncate);
    defer client.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < image.len) {

        const chunk = @min(image.len - offset, lib.fs.payload_capacity);
        const written = try client.write(file, offset, image[offset .. offset + chunk]);

        if (written == 0) return error.Invalid;

        offset += written;

    }

}

fn set_cwd(path: []const u8) void {

    @memcpy(cwd_storage[0..path.len], path);
    cwd = cwd_storage[0..path.len];

    if (files) |*client| client.cwd = cwd;

}

fn write_banner(out: *lib.stream.Stream) !void {

    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "MARBLE ......... Ready");
    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "Type 'help' for available commands, 'exit' to relaunch.");
    try lib.io.writeln(out, "");

}

fn report_parse_error(out: *lib.stream.Stream, failure: anyerror) !void {

    const message = switch (failure) {

        error.TooManyStages => "marble: too many pipe stages",
        error.EmptyStage => "marble: empty command in pipeline",
        else => "marble: invalid command line",

    };

    try lib.io.writeln(out, message);

}

fn report_command_error(out: *lib.stream.Stream, failure: anyerror) void {

    const message = switch (failure) {

        error.NotFound => "command not found",
        error.NoMemory => "out of memory",
        error.Gone => "service unavailable",

        else => "command failed",

    };

    lib.io.write(out, name) catch {};
    lib.io.write(out, ": ") catch {};
    lib.io.write(out, message) catch {};
    lib.io.write(out, "\n") catch {};

}

fn parse(line: []u8) !Pipeline {

    var pipeline = Pipeline{};
    var cursor: usize = 0;

    while (cursor < line.len) {

        while (cursor < line.len and is_space(line[cursor])) {

            cursor += 1;

        }

        if (cursor >= line.len) break;
        if (pipeline.count >= max_stages) return error.TooManyStages;

        var stage = Stage{};

        while (cursor < line.len and line[cursor] != '|') {

            while (cursor < line.len and is_space(line[cursor])) {

                cursor += 1;

            }

            if (cursor >= line.len or line[cursor] == '|') break;
            if (stage.argc >= max_args) return error.Invalid;

            const start = cursor;

            while (cursor < line.len and !is_space(line[cursor]) and line[cursor] != '|') {

                cursor += 1;

            }

            stage.argv[stage.argc] = line[start..cursor];
            stage.argc += 1;

        }

        if (stage.argc == 0) return error.EmptyStage;

        pipeline.stages[pipeline.count] = stage;
        pipeline.count += 1;

        if (cursor < line.len and line[cursor] == '|') cursor += 1;

    }

    return pipeline;

}

fn run_builtin(stage: *const Stage, out: *lib.stream.Stream) !bool {

    const command = stage.argv[0];

    if (equals(command, "help")) {

        try lib.catalog.write_help(out);

        return true;

    }

    if (equals(command, "about")) {

        try lib.catalog.write_about(out);

        return true;

    }

    if (equals(command, "clear")) {

        try lib.term.clear_screen(out);

        return true;

    }

    if (equals(command, "cd")) {

        try change_directory(stage, out);

        return true;

    }

    if (equals(command, "location")) {

        try lib.io.writeln(out, cwd);

        return true;

    }

    if (equals(command, "exit")) {

        try lib.io.writeln(out, "Exiting MARBLE...");
        lib.start.exit_with(0);

    }

    return false;

}

// cd resolves its target against the current directory, then confirms it is a directory before adopting it.

fn change_directory(stage: *const Stage, out: *lib.stream.Stream) !void {

    const target = if (stage.argc > 1) stage.argv[1] else home_dir;

    const client = if (files) |*handle| handle else {

        try lib.io.writeln(out, "cd: filesystem unavailable");
        return;

    };

    var buffer: [max_path]u8 = undefined;

    const absolute = lib.fs.canonicalize(cwd, target, &buffer) catch {

        try lib.io.print(out, "cd: {s}: invalid path\n", .{target});
        return;

    };

    const info = client.stat(absolute) catch |failure| {

        try lib.io.print(out, "cd: {s}: {s}\n", .{ target, lib.fs.describe(failure) });
        return;

    };

    if (info.kind != proto.filesystem.kind_directory) {

        try lib.io.print(out, "cd: {s}: not a directory\n", .{target});
        return;

    }

    set_cwd(absolute);

}

fn run_pipeline(pipeline: *const Pipeline) !void {

    // Resolve all stages before spawning so a missing program aborts cleanly with no half-wired pipeline.

    var resolved: [max_stages]Resolved = undefined;
    var path_storage: [max_stages][max_path]u8 = undefined;

    for (0..pipeline.count) |index| {

        resolved[index] = resolve(pipeline.stages[index].argv[0], &path_storage[index]) orelse {

            const out = try lib.start.stdout();

            try lib.io.print(out, "{s}: {s}: command not found\n", .{ name, pipeline.stages[index].argv[0] });

            return;

        };

    }

    var rings: [max_stages - 1]lib.stream.Ring.Pair = undefined;

    if (pipeline.count > 1) {

        for (0..pipeline.count - 1) |index| {

            rings[index] = try lib.stream.Ring.create(cap.memory, pipe_capacity);

        }

    }

    for (0..pipeline.count) |index| {

        try spawn_stage(&pipeline.stages[index], resolved[index], index, pipeline.count, &rings);

    }

    var received: usize = 0;
    var message = ipc.Message.zeroed;

    while (received < pipeline.count) {

        const badge = try sys.receive(supervisor, &message);

        if (badge >= 1 and badge <= @as(u64, @intCast(pipeline.count)) and message.data[0] == proto.supervisor.death) {

            received += 1;

        }

    }

}

// Resolve commands: slash paths relative to cwd, bare names under programs_dir, else boot bundle.

fn resolve(command: []const u8, path_buffer: *[max_path]u8) ?Resolved {

    if (has_slash(command)) {

        const client = if (files) |*handle| handle else return null;
        const absolute = lib.fs.canonicalize(cwd, command, path_buffer) catch return null;

        if (is_program_file(client, absolute)) return .{ .disk = absolute };

        return null;

    }

    if (files) |*client| {

        const path = std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ programs_dir, command }) catch return null;

        if (is_program_file(client, path)) return .{ .disk = path };

    }

    if (bundle.find(command)) |image| return .{ .bundled = image };

    return null;

}

fn is_program_file(client: *lib.fs.Client, path: []const u8) bool {

    const info = client.stat(path) catch return false;

    return info.kind == proto.filesystem.kind_file;

}

// Read an installed executable off the search path into the shared image buffer, ready to hand to the loader.

fn load_from_disk(path: []const u8) ![]const u8 {

    const client = if (files) |*handle| handle else return error.Gone;

    const info = try client.stat(path);
    const length: usize = @intCast(info.length);

    if (length > load_buffer.len) return error.NoMemory;

    const file = try client.open_path(path, 0);
    defer client.close_file(file) catch {};

    var offset: usize = 0;

    while (offset < length) {

        const read = try client.read(file, offset, load_buffer[offset..length]);

        if (read == 0) break;

        offset += read;

    }

    return load_buffer[0..offset];

}

fn spawn_stage(stage: *const Stage, source: Resolved, index: usize, count: usize, rings: *[max_stages - 1]lib.stream.Ring.Pair) !void {

    const image = switch (source) {

        .disk => |path| try load_from_disk(path),
        .bundled => |bytes| bytes,

    };

    const memory = try sys.create(.memory_authority, child_budget, cap.memory);
    errdefer sys.close(memory) catch {};

    const init_endpoint = try sys.create(.endpoint, 0, 0);
    errdefer sys.close(init_endpoint) catch {};

    const report = try sys.copy(supervisor, @intCast(index + 1));
    errdefer sys.close(report) catch {};

    const console = try sys.copy(cap.stdout, @intCast(2 + index));
    errdefer sys.close(console) catch {};

    var grants = [_]cap.Handle{cap.stdin} ** 9;
    var grant_count: usize = cap.reserved_grants;
    var flags: u64 = 0;

    grants[cap.stdin] = console;
    grants[cap.stdout] = console;
    grants[cap.stderr] = console;
    grants[cap.name_service] = cap.name_service;
    grants[cap.memory] = memory;
    grants[cap.startup_endpoint] = init_endpoint;
    grants[cap.supervisor] = report;

    if (index > 0) {

        grants[cap.stdin] = rings[index - 1].region;
        grants[cap.ring_stdin_ready] = rings[index - 1].ready;
        grant_count = @max(grant_count, cap.ring_stdin_ready + 1);
        flags |= proto.init.stdin_ring;

    }

    if (index + 1 < count) {

        grants[cap.stdout] = rings[index].region;
        grants[cap.ring_stdout_ready] = rings[index].ready;
        grant_count = @max(grant_count, cap.ring_stdout_ready + 1);
        flags |= proto.init.stdout_ring;

    }

    const child = try lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = stage.args(),
        .grants = grants[0..grant_count],
        .flags = flags,
        .data5 = machine_core_count,
        .cwd = cwd,

    });

    sys.close(child) catch {};
    sys.close(memory) catch {};
    sys.close(init_endpoint) catch {};
    sys.close(report) catch {};
    sys.close(console) catch {};

}

fn has_slash(command: []const u8) bool {

    return std.mem.indexOfScalar(u8, command, '/') != null;

}

fn is_space(byte: u8) bool {

    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}
