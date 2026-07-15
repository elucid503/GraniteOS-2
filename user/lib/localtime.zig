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

/// Full English month name for 1..=12; empty string outside that range.
pub fn month_name(month: u32) []const u8 {

    return switch (month) {

        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "",

    };

}

/// Days in the civil month for a proleptic Gregorian year.
pub fn days_in_month(year: i64, month: u32) u32 {

    return switch (month) {

        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (is_leap(year)) 29 else 28,
        else => 0,

    };

}

/// Weekday of a civil date: 0 = Sunday … 6 = Saturday.
pub fn weekday(year: i64, month: u32, day: u32) u32 {

    const days = days_from_civil(year, month, day);
    const shifted = days + 4; // 1970-01-01 is Thursday → index 4 when Sunday is 0.

    return @intCast(@mod(shifted, 7));

}

fn is_leap(year: i64) bool {

    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;

    return @mod(year, 4) == 0;

}

fn civil_time(total_seconds: i64) LocalTime {

    const days = @divFloor(total_seconds, 86400);
    const secs_of_day = total_seconds - days * 86400;

    const hour: u32 = @intCast(@divFloor(secs_of_day, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(secs_of_day, 3600), 60));

    const civil = civil_from_days(days);

    return .{ .year = civil.year, .month = civil.month, .day = civil.day, .hour = hour, .minute = minute };

}

/// Howard Hinnant days-from-civil: civil (y, m, d) → days since Unix epoch.
fn days_from_civil(year: i64, month: u32, day: u32) i64 {

    var y = year;

    if (month <= 2) y -= 1;

    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const mp: u64 = if (month > 2) month - 3 else month + 9;
    const doy: u64 = (153 * mp + 2) / 5 + day - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;

    return era * 146097 + @as(i64, @intCast(doe)) - 719468;

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

test "weekday of known dates" {

    try testing.expectEqual(@as(u32, 4), weekday(1970, 1, 1)); // Thursday
    try testing.expectEqual(@as(u32, 1), weekday(2026, 7, 13)); // Monday

}

test "days_in_month handles leap Februaries" {

    try testing.expectEqual(@as(u32, 29), days_in_month(2024, 2));
    try testing.expectEqual(@as(u32, 28), days_in_month(2025, 2));
    try testing.expectEqual(@as(u32, 31), days_in_month(2026, 7));

}
