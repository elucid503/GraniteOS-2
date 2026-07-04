// M6 shell: builtins plus external program launch from the boot bundle, with simple pipelines over Ring streams.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;

comptime {

    _ = lib.start;

}

const max_line = 256;
const max_stages = 4;
const max_args = 8;
const child_budget = 1 * 1024 * 1024;
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

pub fn main(_: []const []const u8) u8 {

    run() catch |failure| {

        const err = lib.start.stdout() catch return 1;
        lib.io.write(err, "shell: fatal ") catch {};
        lib.io.write(err, @errorName(failure)) catch {};
        lib.io.write(err, "\n") catch {};

        return 1;

    };

    return 0;

}

fn run() !void {

    const bundle_base = try sys.map(cap.self_space, cap.shell.bundle, 0, sys.read);
    bundle = try lib.bundle.Bundle.open(bundle_base + @as(usize, @intCast(lib.start.word(4))), @intCast(lib.start.word(3)));
    supervisor = try sys.create(.endpoint, 0, 0);

    var input = try lib.start.stdin();
    const out = try lib.start.stdout();
    var line: [max_line]u8 = undefined;

    try lib.io.write(out, "\nGraniteOS (temp) shell - run 'help'\n");

    while (true) {

        try lib.io.write(out, "granite> ");

        const length = try input.read(&line);
        var pipeline = try parse(line[0..length]);

        if (pipeline.count == 0) continue;

        if (pipeline.count == 1) {

            if (try run_builtin(&pipeline.stages[0], out)) continue;

        }

        try run_pipeline(&pipeline, out);

    }

}

fn parse(line: []u8) !Pipeline {

    var pipeline = Pipeline{};
    var cursor: usize = 0;

    while (cursor < line.len) {

        while (cursor < line.len and is_space(line[cursor])) {

            cursor += 1;

        }

        if (cursor >= line.len) break;
        if (pipeline.count >= max_stages) return error.Invalid;

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

        if (stage.argc == 0) return error.Invalid;

        pipeline.stages[pipeline.count] = stage;
        pipeline.count += 1;

        if (cursor < line.len and line[cursor] == '|') cursor += 1;

    }

    return pipeline;

}

fn run_builtin(stage: *const Stage, out: *lib.stream.Stream) !bool {

    const command = stage.argv[0];

    if (equals(command, "help")) {

        try lib.io.write(out, "builtins:\n  help   list builtins and bundled programs\n  about  describe this system\n  exit   quit; the supervisor restarts the shell\nprograms:\n  echo\n  cat\n  help\n  cat-via-name\n");
        return true;

    }

    if (equals(command, "about")) {

        try lib.io.write(out, "GraniteOS-2: bundled ELF programs, name service, and peer-to-peer pipes.\n");
        return true;

    }

    if (equals(command, "exit")) {

        try lib.io.write(out, "bye - the supervisor will bring the shell back.\n");
        lib.start.exit_with(0);

    }

    return false;

}

fn run_pipeline(pipeline: *Pipeline, out: *lib.stream.Stream) !void {

    var rings: [max_stages - 1]lib.stream.Ring.Pair = undefined;
    var statuses: [max_stages]u64 = [_]u64{255} ** max_stages;

    if (pipeline.count > 1) {

        for (0..pipeline.count - 1) |index| {

            rings[index] = try lib.stream.Ring.create(cap.memory, pipe_capacity);

        }

    }

    for (0..pipeline.count) |index| {

        _ = try spawn_stage(&pipeline.stages[index], index, pipeline.count, &rings);

    }

    var received: usize = 0;
    var message = ipc.Message.zeroed;

    while (received < pipeline.count) {

        const badge = try sys.receive(supervisor, &message);

        if (badge >= 1 and badge <= @as(u64, @intCast(pipeline.count))) {

            statuses[@intCast(badge - 1)] = message.data[1];
            received += 1;

        }

    }

    if (pipeline.count == 1) {

        try lib.io.print(out, "[done] {s}={d}\n", .{ pipeline.stages[0].argv[0], statuses[0] });

    } else {

        try lib.io.write(out, "[done]");

        for (0..pipeline.count) |index| {

            try lib.io.print(out, " {s}={d}", .{ pipeline.stages[index].argv[0], statuses[index] });

        }

        try lib.io.write(out, "\n");

    }

}

fn spawn_stage(stage: *const Stage, index: usize, count: usize, rings: *[max_stages - 1]lib.stream.Ring.Pair) !cap.Handle {

    const image = bundle.find(stage.argv[0]) orelse return unknown(stage.argv[0]);
    const memory = try sys.create(.memory_authority, child_budget, cap.memory);
    const startup = try sys.create(.endpoint, 0, 0);
    const report = try sys.copy(supervisor, @intCast(index + 1));
    const console = try sys.copy(cap.stdout, @intCast(2 + index));

    var grants = [_]cap.Handle{cap.stdin} ** 9;
    var grant_count: usize = cap.reserved_grants;
    var flags: u64 = 0;

    grants[cap.stdin] = console;
    grants[cap.stdout] = console;
    grants[cap.stderr] = console;
    grants[cap.name_service] = cap.name_service;
    grants[cap.memory] = memory;
    grants[cap.startup_endpoint] = startup;
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

    return lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = stage.args(),
        .grants = grants[0..grant_count],
        .flags = flags,

    });

}

fn unknown(command: []const u8) error{NotFound} {

    const out = lib.start.stdout() catch return error.NotFound;

    lib.io.write(out, "unknown command: '") catch {};
    lib.io.write(out, command) catch {};
    lib.io.write(out, "' - try 'help'.\n") catch {};

    return error.NotFound;

}

fn is_space(byte: u8) bool {

    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}
