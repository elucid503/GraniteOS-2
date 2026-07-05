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
var machine_core_count: u64 = 1;

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

    try write_banner(out);

    while (true) {

        try write_prompt(out);

        const length = try input.read(&line);

        const pipeline = parse(line[0..length]) catch |failure| {

            try report_parse_error(out, failure);
            continue;

        };

        if (pipeline.count == 0) continue;

        if (pipeline.count == 1) {

            if (try run_builtin(&pipeline.stages[0], out)) continue;

        }

        try run_pipeline(&pipeline);

    }

}

fn write_banner(out: *lib.stream.Stream) !void {

    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "MARBLE ......... Ready");
    try lib.io.writeln(out, "");
    try lib.io.writeln(out, "Type 'help' for available commands, 'exit' to relaunch.");
    try lib.io.writeln(out, "");

}

fn write_prompt(out: *lib.stream.Stream) !void {

    try lib.io.write(out, name);
    try lib.io.write(out, " [");
    try lib.io.write(out, root_dir);
    try lib.io.write(out, "] > ");

}

fn report_parse_error(out: *lib.stream.Stream, failure: anyerror) !void {

    const message = switch (failure) {

        error.TooManyStages => "marble: too many pipe stages",
        error.EmptyStage => "marble: empty command in pipeline",
        else => "marble: invalid command line",

    };

    try lib.io.writeln(out, message);

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

    if (equals(command, "location")) {

        try lib.io.writeln(out, root_dir);

        return true;

    }

    if (equals(command, "exit")) {

        try lib.io.writeln(out, "Exiting MARBLE...");
        lib.start.exit_with(0);

    }

    return false;

}

fn run_pipeline(pipeline: *const Pipeline) !void {

    var rings: [max_stages - 1]lib.stream.Ring.Pair = undefined;

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

        if (badge >= 1 and badge <= @as(u64, @intCast(pipeline.count)) and message.data[0] == proto.supervisor.death) {

            received += 1;

        }

    }

}

fn spawn_stage(stage: *const Stage, index: usize, count: usize, rings: *[max_stages - 1]lib.stream.Ring.Pair) !cap.Handle {

    const image = bundle.find(stage.argv[0]) orelse return unknown(stage.argv[0]);
    const memory = try sys.create(.memory_authority, child_budget, cap.memory);
    const init_endpoint = try sys.create(.endpoint, 0, 0);
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

    return lib.elf.spawn_program(.{

        .image = image,
        .authority = memory,
        .args = stage.args(),
        .grants = grants[0..grant_count],
        .flags = flags,
        .data5 = machine_core_count,

    });

}

fn unknown(command: []const u8) error{NotFound} {

    const out = lib.start.stdout() catch return error.NotFound;

    lib.io.write(out, name) catch {};
    lib.io.write(out, ": unknown command: ") catch {};
    lib.io.write(out, command) catch {};
    lib.io.write(out, "\n") catch {};

    return error.NotFound;

}

fn is_space(byte: u8) bool {

    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';

}

fn equals(a: []const u8, b: []const u8) bool {

    return std.mem.eql(u8, a, b);

}
