// Lazy FP/SIMD verification (Stage 1.1): spin up worker threads that each grind a bank of chaotic double-precision
// recurrences concurrently, then check every worker reproduced the single-threaded golden result bit-for-bit. A
// context switch that failed to save or restore a thread's vector file would perturb one of the live accumulators and
// the logistic map's sensitivity turns that into a diverging, mismatched checksum. Usage: `neon [workers]`.

const std = @import("std");

const lib = @import("lib");

const sys = lib.sys;
const cap = lib.cap;
const proto = lib.proto;

comptime {

    _ = lib.start;

}

const page_size = 4096;
const stack_pages = 4;
const max_workers = 16;

// Enough rounds that each worker runs for several scheduler quanta, so preemption interleaves live FP state across
// threads many times over.
const rounds = 400_000;
const lanes = 8;

var done: u64 = 0;
var passed: u64 = 0;
var golden: u64 = 0;
var work_notification: cap.Handle = 0;

pub fn main(args: []const []const u8) u8 {

    const out = lib.start.stdout() catch return 1;

    var workers: usize = @intCast(@max(1, lib.start.word(proto.init.core_count_word)));

    if (args.len > 1) {

        workers = parse_count(args[1]) orelse workers;

    }

    if (workers > max_workers) workers = max_workers;
    if (workers == 0) workers = 1;

    // Compute the reference result single-threaded, before any concurrency can touch the vector file.

    golden = compute();

    work_notification = sys.create(.notification, 0, 0) catch return 1;

    var started: usize = 0;

    while (started < workers) : (started += 1) {

        start_worker() catch break;

    }

    if (started == 0) {

        lib.io.write(out, "neon: could not start workers\n") catch {};
        return 1;

    }

    while (@atomicLoad(u64, &done, .acquire) < started) {

        _ = sys.wait(work_notification) catch break;

    }

    const ok = @atomicLoad(u64, &passed, .acquire);

    if (ok == started) {

        lib.io.write(out, "neon: ") catch return 1;
        write_count(out, started) catch return 1;
        lib.io.write(out, " workers ok\n") catch return 1;

        return 0;

    }

    lib.io.write(out, "neon: FAIL (") catch return 1;
    write_count(out, ok) catch return 1;
    lib.io.write(out, "/") catch return 1;
    write_count(out, started) catch return 1;
    lib.io.write(out, " workers matched)\n") catch return 1;

    return 1;

}

fn start_worker() sys.Error!void {

    const stack = try sys.create(.region, stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);

    const thread = try sys.create_thread(@intFromPtr(&worker_entry), base + stack_pages * page_size);

    try sys.start(thread);

}

fn worker_entry() callconv(.c) noreturn {

    const result = compute();

    if (result == @atomicLoad(u64, &golden, .acquire)) {

        _ = @atomicRmw(u64, &passed, .Add, 1, .acq_rel);

    }

    _ = @atomicRmw(u64, &done, .Add, 1, .acq_rel);
    sys.notify(work_notification, 1) catch {};

    lib.start.exit();

}

// A bank of independent logistic maps (r = 3.9, chaotic and bounded to (0,1)) advanced in lock-step. Interleaving the
// lanes keeps several distinct double values live in vector registers across each round, and a periodic yield forces
// switches while they are live. The final states are folded into one integer checksum.

fn compute() u64 {

    var x = [_]f64{ 0.11, 0.22, 0.33, 0.44, 0.55, 0.66, 0.77, 0.88 };

    var round: usize = 0;

    while (round < rounds) : (round += 1) {

        inline for (0..lanes) |lane| {

            x[lane] = 3.9 * x[lane] * (1.0 - x[lane]);

        }

        if (round & 0x3ff == 0) sys.yield();

    }

    var checksum: u64 = 0;

    inline for (0..lanes) |lane| {

        checksum ^= @as(u64, @bitCast(x[lane]));
        checksum = (checksum << 7) | (checksum >> 57);

    }

    return checksum;

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
