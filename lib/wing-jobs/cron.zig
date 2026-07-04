//! Cron expression parsing and next-trigger math (std-only, unit-testable).
//!
//! Five fields (minute hour day-of-month month day-of-week) plus `@hourly`,
//! `@daily`, `@weekly`, `@monthly`, `@yearly` aliases. `compile` runs the
//! parser at comptime, so a typo in a schedule is a build error, not a
//! runtime surprise. All evaluation is UTC at minute granularity.

const std = @import("std");
const clock = @import("clock.zig");

pub const ParseError = error{
    UnknownAlias,
    WrongFieldCount,
    BadNumber,
    BadRange,
    BadStep,
    ValueOutOfRange,
    EmptyField,
};

/// Parsed cron expression: one bitmask per field. `dom`/`dow` keep their
/// "restricted" flag because vixie-cron ORs the two when both are given.
pub const Expr = struct {
    minutes: u64, // bits 0-59
    hours: u32, // bits 0-23
    dom: u32, // bits 1-31
    months: u16, // bits 1-12
    dow: u8, // bits 0-6, 0 = Sunday
    dom_restricted: bool,
    dow_restricted: bool,

    fn dayMatches(self: Expr, c: clock.Civil) bool {
        const dom_hit = self.dom & (@as(u32, 1) << @intCast(c.day)) != 0;
        const dow_hit = self.dow & (@as(u8, 1) << @intCast(clock.dayOfWeek(c.year, c.month, c.day))) != 0;
        if (self.dom_restricted and self.dow_restricted) return dom_hit or dow_hit;
        if (self.dom_restricted) return dom_hit;
        if (self.dow_restricted) return dow_hit;
        return true;
    }
};

/// Compiled schedule spec: a cron expression or a fixed interval. Intervals
/// fire on epoch-aligned multiples, so every node computes identical trigger
/// instants without coordination.
pub const Compiled = union(enum) {
    cron: Expr,
    every_ms: i64,

    /// First trigger instant strictly after `after_ms`, or null when the
    /// expression can never match (e.g. `0 0 30 2 *`).
    pub fn nextAfter(self: Compiled, after_ms: i64) ?i64 {
        switch (self) {
            .every_ms => |p| return @divFloor(after_ms, p) * p + p,
            .cron => |e| return nextCron(e, after_ms),
        }
    }
};

fn nextCron(e: Expr, after_ms: i64) ?i64 {
    // Start at the next whole minute strictly after `after_ms`.
    var t: i64 = @divFloor(after_ms, 60_000) * 60_000 + 60_000;
    // A date-restricted expression matches within 4 years if it matches at
    // all (leap-day worst case); 8 covers it with slack.
    const deadline = t + 8 * 366 * 86_400_000;
    while (t < deadline) {
        const c = clock.civilFromEpochMs(t);
        if (e.months & (@as(u16, 1) << @intCast(c.month)) == 0) {
            // Jump to the 1st of the next month, 00:00.
            const ny: i32 = if (c.month == 12) c.year + 1 else c.year;
            const nm: u8 = if (c.month == 12) 1 else c.month + 1;
            t = clock.daysFromCivil(ny, nm, 1) * 86_400_000;
            continue;
        }
        if (!e.dayMatches(c)) {
            t = (clock.daysFromCivil(c.year, c.month, c.day) + 1) * 86_400_000;
            continue;
        }
        if (e.hours & (@as(u32, 1) << @intCast(c.hour)) == 0) {
            t += (60 - @as(i64, c.minute)) * 60_000;
            continue;
        }
        if (e.minutes & (@as(u64, 1) << @intCast(c.minute)) == 0) {
            t += 60_000;
            continue;
        }
        return t;
    }
    return null;
}

/// Comptime front-end: a malformed expression fails the build.
pub fn compile(comptime src: []const u8) Expr {
    const parsed = comptime parse(src) catch |err|
        @compileError("invalid cron expression \"" ++ src ++ "\": " ++ @errorName(err));
    return parsed;
}

pub fn parse(src: []const u8) ParseError!Expr {
    const expanded = if (src.len > 0 and src[0] == '@') try alias(src) else src;
    var it = std.mem.tokenizeAny(u8, expanded, " \t");
    const f_min = it.next() orelse return error.WrongFieldCount;
    const f_hour = it.next() orelse return error.WrongFieldCount;
    const f_dom = it.next() orelse return error.WrongFieldCount;
    const f_mon = it.next() orelse return error.WrongFieldCount;
    const f_dow = it.next() orelse return error.WrongFieldCount;
    if (it.next() != null) return error.WrongFieldCount;

    return .{
        .minutes = @truncate(try field(f_min, 0, 59, null, 0)),
        .hours = @truncate(try field(f_hour, 0, 23, null, 0)),
        .dom = @truncate(try field(f_dom, 1, 31, null, 0)),
        .months = @truncate(try field(f_mon, 1, 12, &month_names, 1)),
        .dow = @truncate(try dowField(f_dow)),
        .dom_restricted = !std.mem.eql(u8, f_dom, "*"),
        .dow_restricted = !std.mem.eql(u8, f_dow, "*"),
    };
}

fn alias(src: []const u8) ParseError![]const u8 {
    const map = .{
        .{ "@hourly", "0 * * * *" },
        .{ "@daily", "0 0 * * *" },
        .{ "@midnight", "0 0 * * *" },
        .{ "@weekly", "0 0 * * 0" },
        .{ "@monthly", "0 0 1 * *" },
        .{ "@yearly", "0 0 1 1 *" },
        .{ "@annually", "0 0 1 1 *" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, src, entry[0])) return entry[1];
    }
    return error.UnknownAlias;
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const dow_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

/// Day-of-week accepts 0-7 (7 = Sunday) and 3-letter names; normalized to bits 0-6.
fn dowField(src: []const u8) ParseError!u64 {
    var bits = try field(src, 0, 7, &dow_names, 0);
    if (bits & (1 << 7) != 0) bits = (bits & 0x7f) | 1;
    return bits;
}

/// Parse one field (comma list of `*`, `N`, `N-M`, each with optional `/step`
/// and optional names) into a bitmask over [lo, hi]. `name_base` is the
/// numeric value of the first name in `names`.
fn field(src: []const u8, lo: u6, hi: u6, names: ?[]const []const u8, name_base: u6) ParseError!u64 {
    if (src.len == 0) return error.EmptyField;
    var bits: u64 = 0;
    var parts = std.mem.splitScalar(u8, src, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.EmptyField;
        var range = part;
        var step: u6 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            range = part[0..slash];
            const s = std.fmt.parseInt(u6, part[slash + 1 ..], 10) catch return error.BadStep;
            if (s == 0) return error.BadStep;
            step = s;
        }
        var start: u6 = lo;
        var end: u6 = hi;
        if (!std.mem.eql(u8, range, "*")) {
            if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
                start = try value(range[0..dash], names, name_base);
                end = try value(range[dash + 1 ..], names, name_base);
                if (start > end) return error.BadRange;
            } else {
                start = try value(range, names, name_base);
                // A bare value with a step (`5/15`) extends to the max.
                end = if (step > 1) hi else start;
            }
        }
        if (start < lo or end > hi) return error.ValueOutOfRange;
        var v: u7 = start;
        while (v <= end) : (v += step) bits |= @as(u64, 1) << @intCast(v);
    }
    return bits;
}

fn value(src: []const u8, names: ?[]const []const u8, name_base: u6) ParseError!u6 {
    if (std.fmt.parseInt(u6, src, 10)) |n| return n else |_| {}
    if (names) |table| {
        var lower_buf: [3]u8 = undefined;
        if (src.len == 3) {
            const lower = std.ascii.lowerString(&lower_buf, src);
            for (table, 0..) |name, i| {
                if (std.mem.eql(u8, lower, name)) return @intCast(i + name_base);
            }
        }
    }
    return error.BadNumber;
}

/// Missed-trigger policy: fire the most recent missed instant once (within
/// `grace`), or skip everything and just re-arm.
pub const CatchUp = enum { coalesce, skip };

pub const Resolution = struct {
    /// Trigger instant to fire now, or null when policy says skip.
    fire_ms: ?i64,
    /// New `next_run_at`, strictly in the future.
    next_ms: i64,
};

/// Decide what to do with a due schedule row (`next_run_ms <= now_ms`):
/// which missed instant (if any) to fire, and where to re-arm.
pub fn resolve(
    spec: Compiled,
    next_run_ms: i64,
    now_ms: i64,
    catch_up: CatchUp,
    grace_ms: i64,
) error{Unsatisfiable}!Resolution {
    // Latest theoretical trigger <= now; the row's own next_run_at is the first.
    var latest = next_run_ms;
    switch (spec) {
        // O(1): intervals are epoch-aligned, no need to walk each missed
        // trigger of a long outage (this loop runs on the shared executor).
        .every_ms => |p| latest = @max(latest, @divFloor(now_ms, p) * p),
        .cron => while (true) {
            const n = spec.nextAfter(latest) orelse return error.Unsatisfiable;
            if (n > now_ms) break;
            latest = n;
        },
    }
    const next = spec.nextAfter(latest) orelse return error.Unsatisfiable;
    const fire: ?i64 = switch (catch_up) {
        .skip => null,
        .coalesce => if (now_ms - latest <= grace_ms) latest else null,
    };
    return .{ .fire_ms = fire, .next_ms = next };
}

const testing = std.testing;

fn ts(y: i32, mo: u8, d: u8, h: u8, mi: u8) i64 {
    return clock.epochMsFromCivil(.{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = 0 });
}

test "parse basics and aliases" {
    const daily = try parse("@daily");
    try testing.expectEqual(@as(u64, 1), daily.minutes);
    try testing.expectEqual(@as(u32, 1), daily.hours);
    try testing.expect(!daily.dom_restricted and !daily.dow_restricted);

    const e = try parse("*/15 9-17 1,15 * mon-fri");
    try testing.expectEqual(@as(u64, 0b1000000000000001000000000000001000000000000001), e.minutes);
    try testing.expect(e.hours & (1 << 9) != 0 and e.hours & (1 << 17) != 0 and e.hours & (1 << 8) == 0);
    try testing.expect(e.dom & (1 << 1) != 0 and e.dom & (1 << 15) != 0 and e.dom & (1 << 2) == 0);
    try testing.expect(e.dow == 0b0111110);

    // dow 7 normalizes to Sunday.
    const sun = try parse("0 0 * * 7");
    try testing.expectEqual(@as(u8, 1), sun.dow);

    try testing.expectError(error.WrongFieldCount, parse("0 0 * *"));
    try testing.expectError(error.ValueOutOfRange, parse("61 * * * *"));
    try testing.expectError(error.BadRange, parse("0 5-2 * * *"));
    try testing.expectError(error.UnknownAlias, parse("@fortnightly"));
    try testing.expectError(error.BadStep, parse("*/0 * * * *"));
}

test "nextAfter: daily at 03:00" {
    const spec: Compiled = .{ .cron = compile("0 3 * * *") };
    try testing.expectEqual(ts(2026, 7, 3, 3, 0), spec.nextAfter(ts(2026, 7, 3, 2, 59)).?);
    try testing.expectEqual(ts(2026, 7, 4, 3, 0), spec.nextAfter(ts(2026, 7, 3, 3, 0)).?);
}

test "nextAfter: month-end and leap-year boundaries" {
    // 1st of month crosses year end.
    const monthly: Compiled = .{ .cron = compile("0 0 1 * *") };
    try testing.expectEqual(ts(2027, 1, 1, 0, 0), monthly.nextAfter(ts(2026, 12, 15, 0, 0)).?);
    // 31st only fires in 31-day months (skips Feb/Apr).
    const d31: Compiled = .{ .cron = compile("0 0 31 * *") };
    try testing.expectEqual(ts(2026, 3, 31, 0, 0), d31.nextAfter(ts(2026, 1, 31, 0, 0)).?);
    // Feb 29 waits for the next leap year.
    const leap: Compiled = .{ .cron = compile("0 0 29 2 *") };
    try testing.expectEqual(ts(2028, 2, 29, 0, 0), leap.nextAfter(ts(2026, 1, 1, 0, 0)).?);
    // Feb 30 never fires.
    const never: Compiled = .{ .cron = compile("0 0 30 2 *") };
    try testing.expectEqual(@as(?i64, null), never.nextAfter(ts(2026, 1, 1, 0, 0)));
}

test "nextAfter: dom/dow OR semantics" {
    // "the 13th or any Friday" (both restricted -> OR, vixie rule).
    const spec: Compiled = .{ .cron = compile("0 0 13 * fri") };
    // 2026-07-03 is a Friday.
    try testing.expectEqual(ts(2026, 7, 3, 0, 0), spec.nextAfter(ts(2026, 7, 2, 12, 0)).?);
    // From the 11th (Sat): the 13th (Mon) beats next Friday the 17th.
    try testing.expectEqual(ts(2026, 7, 13, 0, 0), spec.nextAfter(ts(2026, 7, 11, 0, 0)).?);
}

test "nextAfter: every-interval epoch alignment" {
    const spec: Compiled = .{ .every_ms = 300_000 }; // 5m
    try testing.expectEqual(@as(i64, 600_000), spec.nextAfter(300_000).?);
    try testing.expectEqual(@as(i64, 600_000), spec.nextAfter(400_000).?);
    try testing.expectEqual(@as(i64, 900_000), spec.nextAfter(600_000).?);
}

test "misfire resolution" {
    const hourly: Compiled = .{ .cron = compile("0 * * * *") };
    const due = ts(2026, 7, 3, 1, 0);

    // On time (within grace): fire the due instant, re-arm next hour.
    var r = try resolve(hourly, due, ts(2026, 7, 3, 1, 0), .coalesce, 3_600_000);
    try testing.expectEqual(due, r.fire_ms.?);
    try testing.expectEqual(ts(2026, 7, 3, 2, 0), r.next_ms);

    // Down for 5h: coalesce fires only the latest missed (06:00).
    r = try resolve(hourly, due, ts(2026, 7, 3, 6, 10), .coalesce, 3_600_000);
    try testing.expectEqual(ts(2026, 7, 3, 6, 0), r.fire_ms.?);
    try testing.expectEqual(ts(2026, 7, 3, 7, 0), r.next_ms);

    // Latest missed is older than grace: skip.
    r = try resolve(hourly, due, ts(2026, 7, 3, 1, 0), .coalesce, 60_000);
    try testing.expectEqual(due, r.fire_ms.?); // exactly on time is within grace
    r = try resolve(hourly, due, ts(2026, 7, 3, 1, 2), .coalesce, 60_000);
    try testing.expectEqual(@as(?i64, null), r.fire_ms);

    // skip policy never fires, only re-arms.
    r = try resolve(hourly, due, ts(2026, 7, 3, 6, 10), .skip, 3_600_000);
    try testing.expectEqual(@as(?i64, null), r.fire_ms);
    try testing.expectEqual(ts(2026, 7, 3, 7, 0), r.next_ms);
}

test "misfire resolution: every-interval fast path" {
    const every5m: Compiled = .{ .every_ms = 300_000 };
    // Down across many periods: latest missed multiple fires, re-arm follows.
    var r = try resolve(every5m, 300_000, 2_000_000, .coalesce, 3_600_000);
    try testing.expectEqual(@as(i64, 1_800_000), r.fire_ms.?);
    try testing.expectEqual(@as(i64, 2_100_000), r.next_ms);
    // Exactly on time.
    r = try resolve(every5m, 600_000, 600_000, .coalesce, 60_000);
    try testing.expectEqual(@as(i64, 600_000), r.fire_ms.?);
    try testing.expectEqual(@as(i64, 900_000), r.next_ms);
}
