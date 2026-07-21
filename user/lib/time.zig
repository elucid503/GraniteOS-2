// Monotonic time for user programs, plus freestanding wall clock for PKI.

const builtin = @import("builtin");
const std = @import("std");

const sys = @import("syscall/sys.zig");
const ipc = @import("ipc/ipc.zig");
const proto = @import("ipc/proto.zig");
const stream = @import("io/stream.zig");
const cap = @import("cap/cap.zig");

/// NTP / external correction applied on top of build-epoch + uptime (seconds).
var wall_offset_s: i64 = 0;
var wall_offset_pulled: bool = false;

/// Nanoseconds since boot, from the physical counter (CNTPCT_EL0) scaled by its frequency (CNTFRQ_EL0).
pub fn now_ns() u64 {

    if (comptime builtin.target.cpu.arch != .aarch64) return 0;

    const frequency = asm volatile ("mrs %[out], cntfrq_el0"
        : [out] "=r" (-> u64),
    );

    const ticks = asm volatile (
        \\ isb
        \\ mrs %[out], cntpct_el0
        : [out] "=r" (-> u64),
    );

    if (frequency == 0) return 0;

    return @intCast(@as(u128, ticks) * 1_000_000_000 / frequency);

}

pub fn now_ms() u64 {

    return now_ns() / 1_000_000;

}

/// UTC unix seconds for PKI: build-time epoch + monotonic uptime + optional NTP offset.
pub fn wall_sec() i64 {

    const build_options = @import("build_options");
    const elapsed_s: i64 = @intCast(now_ms() / 1000);

    return build_options.build_epoch_s + elapsed_s + wall_offset_s;

}

pub fn set_wall_offset(offset_s: i64) void {

    wall_offset_s = offset_s;

}

pub fn wall_offset() i64 {

    return wall_offset_s;

}

/// Best-effort: ask netstack for its NTP-derived wall offset (once per process).
pub fn try_pull_wall_offset() void {

    if (builtin.os.tag != .freestanding) return;
    if (wall_offset_pulled) return;

    wall_offset_pulled = true;

    const endpoint = stream.lookup_endpoint("netstack") catch return;
    defer sys.close(endpoint) catch {};

    // Attach is required for a session badge, but wall_offset is session-less in the server;
    // open a minimal attach with a throwaway buffer so badge is established.
    const buffer = sys.create(.region, 4096, cap.memory) catch return;
    defer sys.close(buffer) catch {};

    const readiness = sys.create(.notification, 0, 0) catch return;
    defer sys.close(readiness) catch {};

    _ = ipc.request(endpoint, proto.socket.attach, &.{4096}, &.{

        .{ .handle = buffer, .move = false },
        .{ .handle = readiness, .move = false },

    }) catch return;

    const reply = ipc.request(endpoint, proto.socket.wall_offset, &.{}, &.{}) catch return;

    // data[1] holds signed offset via bitcast.
    const offset: i64 = @bitCast(reply.data[1]);

    wall_offset_s = offset;

    _ = ipc.request(endpoint, proto.socket.detach, &.{}, &.{}) catch {};

}

/// Block this thread for `duration_ms`, consuming no CPU (the kernel wakes it off the generic timer).
pub fn sleep_ms(duration_ms: u64) void {

    sys.sleep(duration_ms * 1_000_000);

}

const testing = std.testing;

test "wall_sec respects offset" {

    const before = wall_sec();

    set_wall_offset(3600);

    defer set_wall_offset(0);

    try testing.expect(wall_sec() == before + 3600);

}
