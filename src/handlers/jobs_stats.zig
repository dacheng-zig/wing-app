//! GET /internal/jobs/stats — queue health for monitoring.
//!
//! Per-state counts, head-of-queue latency (how long the oldest runnable job
//! has been waiting — the O(1) backlog signal), and each schedule's
//! next/last firing. Deeper digging happens straight in SQL: the `jobs`
//! table is the audit log.

const wing = @import("wing");

const Ctx = @import("../state.zig").Ctx;
const Database = @import("../db/database.zig").Database;
const jobs = @import("wing_jobs");

pub const ScheduleInfo = struct {
    key: []const u8,
    next_run_at: []const u8,
    last_run_at: ?[]const u8,
};

pub const Response = struct {
    available: u64,
    running: u64,
    retryable: u64,
    completed: u64,
    cancelled: u64,
    discarded: u64,
    /// Seconds the oldest due `available` job has waited; null = empty queue.
    oldest_available_s: ?i64,
    schedules: []const ScheduleInfo,
};

pub fn handle(ctx: *Ctx, db: *Database) anyerror!wing.respond.Json(Response) {
    // Long-lived gpa, NOT ctx.arena: query scratch ends up in the
    // connection's statement cache, which outlives this request.
    var repo = jobs.Repository.init(db.gpa, db.pool);
    const stats = try repo.queueStats();
    const schedule_rows = try repo.scheduleStats(ctx.arena);

    const schedules = try ctx.arena.alloc(ScheduleInfo, schedule_rows.len);
    for (schedule_rows, schedules) |row, *dst| {
        dst.* = .{ .key = row.key, .next_run_at = row.next_run_at, .last_run_at = row.last_run_at };
    }
    return .{ .value = .{
        .available = stats.counts.get(.available),
        .running = stats.counts.get(.running),
        .retryable = stats.counts.get(.retryable),
        .completed = stats.counts.get(.completed),
        .cancelled = stats.counts.get(.cancelled),
        .discarded = stats.counts.get(.discarded),
        .oldest_available_s = stats.oldest_available_s,
        .schedules = schedules,
    } };
}
