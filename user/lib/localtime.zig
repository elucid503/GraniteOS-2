// Wall-clock time. Accurate as long as boot follows build promptly..

const build_options = @import("build_options");

const time = @import("time.zig");

pub const LocalTime = struct {

    year: i64,
    month: u32,
    day: u32,

    hour: u32,
    minute: u32,

};

/// Current local wall time: the build-time epoch, plus elapsed monotonic time since boot, plus `tz_offset_minutes` (see `lib.prefs.tz_offset_minutes`).
pub fn now(tz_offset_minutes: i32) LocalTime {

    const elapsed_s: i64 = @intCast(time.now_ms() / 1000);
    const tz_offset_s: i64 = @as(i64, tz_offset_minutes) * 60;

    return civil_time(build_options.build_epoch_s + elapsed_s + tz_offset_s);

}

fn civil_time(total_seconds: i64) LocalTime {

    const days = @divFloor(total_seconds, 86400);
    const secs_of_day = total_seconds - days * 86400;

    const hour: u32 = @intCast(@divFloor(secs_of_day, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(secs_of_day, 3600), 60));

    const civil = civil_from_days(days);

    return .{ .year = civil.year, .month = civil.month, .day = civil.day, .hour = hour, .minute = minute };

}

const Civil = struct {

    year: i64,
    month: u32,
    day: u32,

};

/// Days-since-epoch to proleptic Gregorian (year, month, day); Howard Hinnant's integer-only algorithm.
fn civil_from_days(days_since_epoch: i64) Civil {

    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);

    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };

}

const std = @import("std");
const testing = std.testing;

test "civil_from_days matches known dates" {

    try testing.expectEqual(Civil{ .year = 1970, .month = 1, .day = 1 }, civil_from_days(0)); // 1970-01-01 is day 0.

    try testing.expectEqual(Civil{ .year = 2026, .month = 7, .day = 13 }, civil_from_days(20647)); // 2026-07-13 - checked against a reference proleptic Gregorian calculator.

    try testing.expectEqual(Civil{ .year = 2024, .month = 2, .day = 29 }, civil_from_days(19782)); // A leap day.

}

test "civil_time splits seconds into hour and minute" {

    const t = civil_time(20647 * 86400 + 23 * 3600 + 30 * 60 + 5);

    try testing.expectEqual(@as(i64, 2026), t.year);
    try testing.expectEqual(@as(u32, 7), t.month);
    try testing.expectEqual(@as(u32, 13), t.day);
    try testing.expectEqual(@as(u32, 23), t.hour);
    try testing.expectEqual(@as(u32, 30), t.minute);

}
