// Shared fixed-point animation timing (no float in userspace): progress and
// easing operate in 0..=1000, so callers stay integer end to end.

const std = @import("std");

pub const unit: i32 = 1000;

/// Linear progress in 0..=1000 for `elapsed` of `duration`.
pub fn progress(elapsed: u64, duration: u64) i32 {

    if (duration == 0 or elapsed >= duration) return unit;

    return @intCast(@divTrunc(elapsed * unit, duration));

}

/// Decelerating cubic: fast start, soft landing.
pub fn ease_out(t: i32) i32 {

    const inv = unit - t;

    return unit - @divTrunc(inv * inv * inv, unit * unit);

}

/// Accelerating cubic: soft start, fast exit.
pub fn ease_in(t: i32) i32 {

    return @divTrunc(t * t * t, unit * unit);

}

/// Interpolate `from` toward `to` by eased progress `t` (0..=1000).
pub fn lerp(from: i32, to: i32, t: i32) i32 {

    return from + @divTrunc((to - from) * t, unit);

}

const testing = std.testing;

test "easing stays inside the unit range and hits both endpoints" {

    try testing.expectEqual(@as(i32, 0), ease_out(0));
    try testing.expectEqual(@as(i32, unit), ease_out(unit));
    try testing.expectEqual(@as(i32, 0), ease_in(0));
    try testing.expectEqual(@as(i32, unit), ease_in(unit));

    try testing.expectEqual(@as(i32, unit), progress(50, 50));
    try testing.expectEqual(@as(i32, 500), progress(25, 50));

    try testing.expectEqual(@as(i32, 10), lerp(10, 90, 0));
    try testing.expectEqual(@as(i32, 90), lerp(10, 90, unit));
    try testing.expectEqual(@as(i32, 30), lerp(90, 10, 750));

}
