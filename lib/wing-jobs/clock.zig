//! UTC civil-time math for the jobs module (std-only, unit-testable).
//!
//! The database's `UTC_TIMESTAMP(3)` is the single clock source; DATETIME
//! values cross the wire as strings so no session-timezone conversion can
//! creep in. This module converts those strings to/from epoch milliseconds
//! and provides the calendar arithmetic cron evaluation needs.

const std = @import("std");

pub const Civil = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16 = 0,
};

/// Days from 1970-01-01 to year-month-day (proleptic Gregorian).
/// Howard Hinnant's days_from_civil.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400); // [0, 399]
    const m: u64 = month;
    const doy: u64 = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1; // [0, 365]
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

/// Inverse of `daysFromCivil` (returns year/month/day; time fields zero).
pub fn civilFromDays(days: i64) Civil {
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097); // [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // [0, 11]
    const day: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1); // [1, 31]
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    return .{
        .year = @intCast(y + @intFromBool(month <= 2)),
        .month = month,
        .day = day,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
}

pub fn epochMsFromCivil(c: Civil) i64 {
    const days = daysFromCivil(c.year, c.month, c.day);
    const secs = days * 86_400 + @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + c.second;
    return secs * 1000 + c.millisecond;
}

pub fn civilFromEpochMs(ms: i64) Civil {
    const days = @divFloor(ms, 86_400_000);
    const rem: u64 = @intCast(ms - days * 86_400_000);
    var c = civilFromDays(days);
    c.hour = @intCast(rem / 3_600_000);
    c.minute = @intCast(rem / 60_000 % 60);
    c.second = @intCast(rem / 1000 % 60);
    c.millisecond = @intCast(rem % 1000);
    return c;
}

pub fn isLeapYear(year: i32) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

/// Day of week for a civil date: 0 = Sunday .. 6 = Saturday (cron convention).
pub fn dayOfWeek(year: i32, month: u8, day: u8) u8 {
    // 1970-01-01 was a Thursday (4).
    return @intCast(@mod(daysFromCivil(year, month, day) + 4, 7));
}

/// MySQL DATETIME string length with millisecond precision.
pub const datetime_len = "YYYY-MM-DD HH:MM:SS.mmm".len;

/// Format epoch milliseconds as `YYYY-MM-DD HH:MM:SS.mmm` (MySQL DATETIME(3)).
pub fn formatDateTime(buf: *[datetime_len]u8, ms: i64) []const u8 {
    const c = civilFromEpochMs(ms);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, c.millisecond,
    }) catch unreachable;
}

pub const ParseError = error{InvalidDateTime};

/// Parse `YYYY-MM-DD HH:MM:SS[.f...]` (what `CAST(dt AS CHAR)` yields) to
/// epoch milliseconds. Fractional digits beyond 3 are truncated.
pub fn parseDateTime(s: []const u8) ParseError!i64 {
    if (s.len < "YYYY-MM-DD HH:MM:SS".len) return error.InvalidDateTime;
    if (s[4] != '-' or s[7] != '-' or s[10] != ' ' or s[13] != ':' or s[16] != ':')
        return error.InvalidDateTime;
    const num = struct {
        fn int(comptime T: type, slice: []const u8) ParseError!T {
            return std.fmt.parseInt(T, slice, 10) catch error.InvalidDateTime;
        }
    };
    var c: Civil = .{
        .year = try num.int(i32, s[0..4]),
        .month = try num.int(u8, s[5..7]),
        .day = try num.int(u8, s[8..10]),
        .hour = try num.int(u8, s[11..13]),
        .minute = try num.int(u8, s[14..16]),
        .second = try num.int(u8, s[17..19]),
    };
    if (c.month < 1 or c.month > 12 or c.day < 1 or c.day > 31) return error.InvalidDateTime;
    if (c.hour > 23 or c.minute > 59 or c.second > 59) return error.InvalidDateTime;
    if (s.len > 19) {
        if (s[19] != '.' or s.len < 21) return error.InvalidDateTime;
        var frac: u16 = 0;
        var scale: u16 = 100;
        for (s[20..], 0..) |ch, i| {
            if (ch < '0' or ch > '9') return error.InvalidDateTime;
            if (i < 3) {
                frac += @as(u16, ch - '0') * scale;
                scale /= 10;
            }
        }
        c.millisecond = frac;
    }
    return epochMsFromCivil(c);
}

test "civil round-trip across leap boundaries" {
    const cases = [_]Civil{
        .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 },
        .{ .year = 2000, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 59, .millisecond = 999 },
        .{ .year = 2024, .month = 2, .day = 29, .hour = 12, .minute = 30, .second = 15 },
        .{ .year = 2026, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 0 },
        .{ .year = 2100, .month = 2, .day = 28, .hour = 0, .minute = 0, .second = 0 },
    };
    for (cases) |c| {
        const ms = epochMsFromCivil(c);
        const back = civilFromEpochMs(ms);
        try std.testing.expectEqualDeep(c, back);
    }
}

test "known epoch values" {
    // 2026-07-03 00:00:00 UTC
    try std.testing.expectEqual(
        @as(i64, 1783036800000),
        epochMsFromCivil(.{ .year = 2026, .month = 7, .day = 3, .hour = 0, .minute = 0, .second = 0 }),
    );
    try std.testing.expectEqual(@as(i64, 0), epochMsFromCivil(.{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }));
}

test "dayOfWeek" {
    try std.testing.expectEqual(@as(u8, 4), dayOfWeek(1970, 1, 1)); // Thursday
    try std.testing.expectEqual(@as(u8, 0), dayOfWeek(2026, 6, 28)); // Sunday
    try std.testing.expectEqual(@as(u8, 5), dayOfWeek(2026, 7, 3)); // Friday
}

test "format and parse datetime" {
    var buf: [datetime_len]u8 = undefined;
    const ms = epochMsFromCivil(.{ .year = 2026, .month = 7, .day = 3, .hour = 8, .minute = 5, .second = 9, .millisecond = 42 });
    const s = formatDateTime(&buf, ms);
    try std.testing.expectEqualStrings("2026-07-03 08:05:09.042", s);
    try std.testing.expectEqual(ms, try parseDateTime(s));
    // Seconds-only form (DATETIME(0) cast) parses too.
    try std.testing.expectEqual(ms - 42, try parseDateTime("2026-07-03 08:05:09"));
    // MySQL DATETIME(3) casts can carry 6 fractional digits.
    try std.testing.expectEqual(ms, try parseDateTime("2026-07-03 08:05:09.042000"));
    try std.testing.expectError(error.InvalidDateTime, parseDateTime("2026-07-03T08:05:09"));
    try std.testing.expectError(error.InvalidDateTime, parseDateTime("garbage"));
}

test "daysInMonth" {
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2100, 2));
    try std.testing.expectEqual(@as(u8, 31), daysInMonth(2026, 7));
}
