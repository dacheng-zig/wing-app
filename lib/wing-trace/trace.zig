//! Trace-context value type + log field formatting (std-only, unit-tested).
//!
//! Kept free of any zio dependency so it can be unit tested without a runtime.
//! The task-local binding that carries a `Context` across a task lives in
//! `context.zig`; the logFn reads it from there.

const std = @import("std");

pub const Context = struct {
    trace_id: []const u8,
};

/// Format `total_ms` (ms since Unix epoch) as ISO-8601 UTC, e.g.
/// `2026-06-25T12:00:00.123Z`. `buf` must be >= 24 bytes.
pub fn formatTimestamp(buf: []u8, total_ms: i64) []const u8 {
    const ms: u64 = if (total_ms < 0) 0 else @intCast(total_ms);
    const secs: u64 = ms / 1000;
    const millis: u64 = ms % 1000;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            yd.year,
            md.month.numeric(),
            @as(u9, md.day_index) + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
            millis,
        },
    ) catch buf[0..0];
}

pub fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
}

test "formatTimestamp epoch zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatTimestamp(&buf, 0));
}

test "formatTimestamp known value" {
    var buf: [32]u8 = undefined;
    // 1_700_000_000_123 ms since epoch = 2023-11-14T22:13:20.123Z
    try std.testing.expectEqualStrings(
        "2023-11-14T22:13:20.123Z",
        formatTimestamp(&buf, 1_700_000_000_123),
    );
}

test "levelText" {
    try std.testing.expectEqualStrings("INFO", levelText(.info));
    try std.testing.expectEqualStrings("ERROR", levelText(.err));
    try std.testing.expectEqualStrings("WARN", levelText(.warn));
    try std.testing.expectEqualStrings("DEBUG", levelText(.debug));
}
