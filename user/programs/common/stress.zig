// Scheduler stress (M8): spin up worker threads that grind in parallel, so a multicore boot can be
// pushed hard from the shell. Usage: `stress [workers]`.

const std = @import("std");

const lib = @import("lib");

const sys = lib.sys;
const cap = lib.cap;

comptime {

    _ = lib.start;

}

const page_size = 4096;
const stack_pages = 4;
const max_workers = 32;
const default_workers = 4;
const grind_rounds = 3_000_000;

var done: u64 = 0;
var work_notification: cap.Handle = 0;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    var workers: usize = default_workers;

    if (args.len > 1) {

        workers = parse_count(args[1]) orelse default_workers;

    }

    if (workers > max_workers) workers = max_workers;
    if (workers == 0) workers = 1;

    work_notification = sys.create(.notification, 0, 0) catch return 1;

    var started: usize = 0;

    while (started < workers) : (started += 1) {

        start_worker() catch break;

    }

    if (started == 0) {

        lib.io.write(out, "stress: could not start workers\n") catch {};
        return 1;

    }

    while (@atomicLoad(u64, &done, .acquire) < started) {

        _ = sys.wait(work_notification) catch break;

    }

    lib.io.write(out, "stress: ") catch return 1;
    write_count(out, started) catch return 1;
    lib.io.write(out, " workers done\n") catch return 1;

    return 0;

}

fn start_worker() sys.Error!void {

    const stack = try sys.create(.region, stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);

    const thread = try sys.create_thread(@intFromPtr(&worker_entry), base + stack_pages * page_size);

    try sys.start(thread);

}

fn worker_entry() callconv(.c) noreturn {

    grind();

    _ = @atomicRmw(u64, &done, .Add, 1, .acq_rel);
    sys.notify(work_notification, 1) catch {};

    lib.start.exit();

}

// A pure ALU treadmill; xorshift keeps the optimizer from folding the loop away.

fn grind() void {

    var state: u64 = 0x9e37_79b9_7f4a_7c15;
    var round: u64 = 0;

    while (round < grind_rounds) : (round += 1) {

        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;

    }

    std.mem.doNotOptimizeAway(state);

}

fn parse_count(text: []const u8) ?usize {

    var value: usize = 0;

    for (text) |byte| {

        if (byte < '0' or byte > '9') return null;

        value = value * 10 + (byte - '0');

    }

    return value;

}

fn write_count(out: anytype, value: usize) lib.io.Error!void {

    var buffer: [20]u8 = undefined;
    var length: usize = 0;
    var remaining = value;

    if (remaining == 0) {

        return lib.io.write(out, "0");

    }

    while (remaining > 0) {

        buffer[length] = @intCast('0' + remaining % 10);
        length += 1;
        remaining /= 10;

    }

    std.mem.reverse(u8, buffer[0..length]);

    try lib.io.write(out, buffer[0..length]);

}
