//! All SQL for the jobs module, in one place.
//!
//! `UTC_TIMESTAMP(3)` is the only clock: every time comparison and every
//! stored timestamp is computed server-side, so nodes with skewed clocks
//! still agree. DATETIME values cross the wire as strings (see clock.zig).
//!
//! Multi-node safety needs no coordinator: claiming uses `FOR UPDATE SKIP
//! LOCKED` short transactions, cron firing uses a compare-and-swap on
//! `wing_schedules.next_run_at`, and rescue/prune are idempotent statements.

const std = @import("std");
const mantle = @import("mantle");
const clock = @import("clock.zig");
const model = @import("model.zig");
const Id = @import("wing_id").Id;

/// MySQL ER_DUP_ENTRY: unique-index collision, used for job dedupe.
const er_dup_entry = 1062;

const sql = struct {
    // Four insert variants instead of one with NULL-bound optionals, so each
    // prepared statement's parameter list stays fixed (one cache entry per
    // shape, no optional-typed params). An earlier mantle bug that corrupted
    // the allocator on NULL binds is no longer reproducible (regression test
    // in mantle's integration suite), so this is now purely a statement-cache
    // choice.
    const insert_delay =
        \\INSERT INTO wing_jobs (id, kind, queue, priority, args, max_attempts, scheduled_at)
        \\VALUES (?, ?, ?, ?, ?, ?, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? MICROSECOND))
    ;
    const insert_at =
        \\INSERT INTO wing_jobs (id, kind, queue, priority, args, max_attempts, scheduled_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;
    const insert_unique_delay =
        \\INSERT INTO wing_jobs (id, kind, queue, priority, args, max_attempts, unique_key, unique_keep, scheduled_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? MICROSECOND))
    ;
    const insert_unique_at =
        \\INSERT INTO wing_jobs (id, kind, queue, priority, args, max_attempts, unique_key, unique_keep, scheduled_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;
    // Lock-free probe so an idle producer poll costs one statement instead
    // of a full claim transaction; a false negative lasts one poll interval.
    const has_due =
        \\SELECT 1 AS one FROM wing_jobs
        \\WHERE state IN ('available','retryable') AND scheduled_at <= UTC_TIMESTAMP(3)
        \\LIMIT 1
    ;
    // Lock only due rows, skipping ones other workers hold; the lock lives
    // for two statements, never for the job's execution.
    const claim_select =
        \\SELECT id, kind, args, attempt, max_attempts FROM wing_jobs
        \\WHERE state IN ('available','retryable') AND scheduled_at <= UTC_TIMESTAMP(3)
        \\ORDER BY priority, scheduled_at, id
        \\LIMIT ?
        \\FOR UPDATE SKIP LOCKED
    ;
    // Every finalize predicate includes `state='running'`: an execution that
    // outlived `rescue_after` was rescued and possibly re-claimed, and its
    // stale finalize must not clobber the newer attempt's row.
    const complete =
        \\UPDATE wing_jobs SET state='completed', finalized_at=UTC_TIMESTAMP(3),
        \\  unique_key=IF(unique_keep, unique_key, NULL)
        \\WHERE id=? AND state='running'
    ;
    const snooze =
        \\UPDATE wing_jobs SET state='available',
        \\  scheduled_at=DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? MICROSECOND),
        \\  attempt=attempt-1
        \\WHERE id=? AND state='running'
    ;
    const retry =
        \\UPDATE wing_jobs SET state='retryable',
        \\  scheduled_at=DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND),
        \\  errors=JSON_ARRAY_APPEND(COALESCE(errors, JSON_ARRAY()), '$',
        \\    JSON_OBJECT('attempt', ?, 'at', CAST(UTC_TIMESTAMP(3) AS CHAR), 'error', ?))
        \\WHERE id=? AND state='running'
    ;
    const dead =
        \\UPDATE wing_jobs SET state=?, finalized_at=UTC_TIMESTAMP(3),
        \\  unique_key=IF(unique_keep, unique_key, NULL),
        \\  errors=JSON_ARRAY_APPEND(COALESCE(errors, JSON_ARRAY()), '$',
        \\    JSON_OBJECT('attempt', ?, 'at', CAST(UTC_TIMESTAMP(3) AS CHAR), 'error', ?))
        \\WHERE id=? AND state='running'
    ;
    // Write the job back untouched except for state, e.g. on graceful
    // shutdown: the interruption consumed an attempt, the row is immediately
    // claimable again.
    const release_back =
        \\UPDATE wing_jobs SET state='available' WHERE id=? AND state='running'
    ;
    const rescue =
        \\UPDATE wing_jobs SET
        \\  state = IF(attempt >= max_attempts, 'discarded', 'retryable'),
        \\  finalized_at = IF(attempt >= max_attempts, UTC_TIMESTAMP(3), finalized_at),
        \\  unique_key = IF(attempt >= max_attempts AND NOT unique_keep, NULL, unique_key),
        \\  errors = JSON_ARRAY_APPEND(COALESCE(errors, JSON_ARRAY()), '$',
        \\    JSON_OBJECT('attempt', attempt, 'at', CAST(UTC_TIMESTAMP(3) AS CHAR), 'error', 'rescued: stuck running'))
        \\WHERE state='running' AND attempted_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? SECOND)
    ;
    const cancel_pending =
        \\UPDATE wing_jobs SET state='cancelled', finalized_at=UTC_TIMESTAMP(3),
        \\  unique_key=IF(unique_keep, unique_key, NULL)
        \\WHERE id=? AND state IN ('available','retryable')
    ;
    const ensure_schedule =
        \\INSERT IGNORE INTO wing_schedules (schedule_id, schedule_key, next_run_at) VALUES (?, ?, ?)
    ;
    // Old `next_run_at` as CAS predicate: exactly one node wins each firing.
    // Two variants (see the insert note): re-arming without firing must not
    // touch `last_run_at`.
    const cas_fire =
        \\UPDATE wing_schedules SET next_run_at=?, last_run_at=?, updated_at=UTC_TIMESTAMP(3)
        \\WHERE schedule_key=? AND next_run_at=?
    ;
    const cas_advance =
        \\UPDATE wing_schedules SET next_run_at=?, updated_at=UTC_TIMESTAMP(3)
        \\WHERE schedule_key=? AND next_run_at=?
    ;
    const utc_now = "SELECT CAST(UTC_TIMESTAMP(3) AS CHAR) AS now";
    const count_states = "SELECT state, COUNT(*) AS n FROM wing_jobs GROUP BY state";
    // Age of the queue head: the O(1) queue-health number.
    const oldest_available =
        \\SELECT TIMESTAMPDIFF(SECOND, MIN(scheduled_at), UTC_TIMESTAMP(3)) AS age_s
        \\FROM wing_jobs WHERE state='available' AND scheduled_at <= UTC_TIMESTAMP(3)
    ;
    const list_schedules =
        \\SELECT schedule_key, CAST(next_run_at AS CHAR) AS next_run_at,
        \\       CAST(last_run_at AS CHAR) AS last_run_at
        \\FROM wing_schedules ORDER BY schedule_key
    ;
};

/// Row to insert. `at` (a `clock.formatDateTime` string) wins over `delay_us`.
pub const NewJob = struct {
    kind: []const u8,
    queue: []const u8 = "default",
    priority: i8 = 0,
    args: []const u8,
    max_attempts: u16 = 20,
    unique_key: ?[]const u8 = null,
    unique_keep: bool = false,
    at: ?[]const u8 = null,
    delay_us: i64 = 0,
};

pub const DueSchedule = struct {
    key: []const u8,
    next_run_at: []const u8,
};

pub const ScheduleRow = struct {
    key: []const u8,
    next_run_at: []const u8,
    last_run_at: ?[]const u8,
};

pub const Stats = struct {
    counts: std.enums.EnumArray(model.State, u64),
    oldest_available_s: ?i64,
};

pub const FireResult = enum { fired, lost_race, skipped_overlap };

pub const Repository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) Repository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Insert on an explicit connection — the transactional-enqueue seam.
    /// The id is minted here (UUIDv7); returns it, or `error.DuplicateJob`
    /// on a unique collision.
    pub fn insertOn(gpa: std.mem.Allocator, conn: *mantle.Connection, job: NewJob) !Id {
        const new_id = Id.new();
        const keep: u8 = @intFromBool(job.unique_keep);
        const result = if (job.unique_key) |key|
            (if (job.at) |at|
                conn.exec(gpa, sql.insert_unique_at, .{ new_id, job.kind, job.queue, job.priority, job.args, job.max_attempts, key, keep, at })
            else
                conn.exec(gpa, sql.insert_unique_delay, .{ new_id, job.kind, job.queue, job.priority, job.args, job.max_attempts, key, keep, job.delay_us }))
        else if (job.at) |at|
            conn.exec(gpa, sql.insert_at, .{ new_id, job.kind, job.queue, job.priority, job.args, job.max_attempts, at })
        else
            conn.exec(gpa, sql.insert_delay, .{ new_id, job.kind, job.queue, job.priority, job.args, job.max_attempts, job.delay_us });

        _ = result catch |err| {
            if (err == error.ServerError) {
                if (conn.lastError()) |se| {
                    if (se.code == er_dup_entry) return error.DuplicateJob;
                }
            }
            return err;
        };
        return new_id;
    }

    pub fn insert(self: *Repository, job: NewJob) !Id {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        return insertOn(self.gpa, db.conn, job);
    }

    /// Claim up to `limit` due jobs: lock candidate rows, mark them running,
    /// commit. READ COMMITTED sidesteps REPEATABLE READ gap-lock pileups on
    /// the hot index. Returned jobs own their strings; free via
    /// `ClaimedJob.deinit` + `gpa.free(slice)`.
    ///
    /// `attempted_by` must be a plain identifier (it is embedded literally in
    /// the follow-up UPDATE, keeping the prepared-statement cache free of
    /// per-batch-size variants).
    pub fn claim(self: *Repository, limit: u64, attempted_by: []const u8) ![]model.ClaimedJob {
        const ClaimRow = struct {
            id: Id,
            kind: []const u8,
            args: []const u8,
            attempt: u16,
            max_attempts: u16,
        };

        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        {
            const Probe = struct { one: u8 };
            var probe = try db.conn.queryAll(Probe, self.gpa, sql.has_due);
            defer probe.deinit();
            if (probe.rows.len == 0) return &.{};
        }

        var tx = try db.conn.beginWith(self.gpa, .{ .isolation = .read_committed });
        defer tx.deinit(self.gpa);

        var table = try tx.conn.queryAllParams(ClaimRow, self.gpa, sql.claim_select, .{limit});
        defer table.deinit();

        if (table.rows.len == 0) {
            try tx.commit(self.gpa);
            return &.{};
        }

        var update: std.Io.Writer.Allocating = .init(self.gpa);
        defer update.deinit();
        try update.writer.print(
            "UPDATE wing_jobs SET state='running', attempt=attempt+1, " ++
                "attempted_at=UTC_TIMESTAMP(3), attempted_by='{s}' WHERE id IN (",
            .{attempted_by},
        );
        for (table.rows, 0..) |row, i| {
            // Safe to splice into statement text: the value round-tripped
            // through Id during the scan, so only hex and hyphens can appear
            // — no quoting hazard.
            try update.writer.print("{s}'{s}'", .{ if (i == 0) "" else ",", &row.id.toText() });
        }
        try update.writer.writeByte(')');
        try tx.conn.execSimple(self.gpa, update.written());
        try tx.commit(self.gpa);

        const out = try self.gpa.alloc(model.ClaimedJob, table.rows.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*j| j.deinit(self.gpa);
            self.gpa.free(out);
        }
        for (table.rows) |row| {
            out[filled] = .{
                .id = row.id,
                .kind = try self.gpa.dupe(u8, row.kind),
                .args = try self.gpa.dupe(u8, row.args),
                .attempt = row.attempt + 1,
                .max_attempts = row.max_attempts,
            };
            filled += 1;
        }
        return out;
    }

    pub fn complete(self: *Repository, id: Id) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.complete, .{id});
    }

    pub fn snooze(self: *Repository, id: Id, delay_us: i64) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.snooze, .{ delay_us, id });
    }

    pub fn retry(self: *Repository, id: Id, attempt: u16, backoff_s: u64, msg: []const u8) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.retry, .{ backoff_s, attempt, msg, id });
    }

    /// Terminal failure: `cancelled` or `discarded`.
    pub fn markDead(self: *Repository, id: Id, state: model.State, attempt: u16, msg: []const u8) !void {
        std.debug.assert(state == .cancelled or state == .discarded);
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.dead, .{ @tagName(state), attempt, msg, id });
    }

    /// Graceful-shutdown write-back: running -> available, attempt kept.
    pub fn releaseBack(self: *Repository, id: Id) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.release_back, .{id});
    }

    /// Revive (or dead-letter) jobs stuck `running` longer than
    /// `rescue_after_s`. Kinds in `discard_kinds` (rescue = .discard) go
    /// straight to `discarded` for manual review instead of re-running.
    /// Idempotent; safe to run on every node.
    pub fn rescue(
        self: *Repository,
        rescue_after_s: u32,
        comptime discard_kinds: []const []const u8,
    ) !u64 {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        var total: u64 = 0;
        if (comptime discard_kinds.len > 0) {
            const discard_sql = comptime
                \\UPDATE wing_jobs SET state='discarded', finalized_at=UTC_TIMESTAMP(3),
                \\  unique_key=IF(unique_keep, unique_key, NULL),
                \\  errors=JSON_ARRAY_APPEND(COALESCE(errors, JSON_ARRAY()), '$',
                \\    JSON_OBJECT('attempt', attempt, 'at', CAST(UTC_TIMESTAMP(3) AS CHAR), 'error', 'rescued: kind is non-retryable, needs manual review'))
                \\WHERE state='running' AND attempted_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? SECOND)
                \\  AND kind IN (
            ++ kindListSql(discard_kinds) ++ ")";
            const ok = try db.conn.exec(self.gpa, discard_sql, .{rescue_after_s});
            total += ok.affected_rows;
        }
        // The general sweep must exclude the discard kinds, or a row crossing
        // the stale threshold between the two statements gets auto-retried
        // despite its no-double-run declaration.
        const general_sql = comptime if (discard_kinds.len > 0)
            sql.rescue ++ " AND kind NOT IN (" ++ kindListSql(discard_kinds) ++ ")"
        else
            sql.rescue;
        const ok = try db.conn.exec(self.gpa, general_sql, .{rescue_after_s});
        return total + ok.affected_rows;
    }

    /// Delete one batch of terminal rows past retention; returns rows removed
    /// (loop until 0). `state_in` is a comptime `'a','b'` list.
    pub fn pruneBatch(
        self: *Repository,
        comptime state_in: []const u8,
        retention_s: u32,
        limit: u32,
    ) !u64 {
        const stmt = "DELETE FROM wing_jobs WHERE state IN (" ++ state_in ++
            ") AND finalized_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? SECOND) LIMIT ?";
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        const ok = try db.conn.exec(self.gpa, stmt, .{ retention_s, limit });
        return ok.affected_rows;
    }

    /// Cancel a job that has not started; running jobs cannot be signaled (v1).
    pub fn cancelPending(self: *Repository, id: Id) !bool {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        const ok = try db.conn.exec(self.gpa, sql.cancel_pending, .{id});
        return ok.affected_rows > 0;
    }

    // ---- scheduler ----

    pub fn utcNowMs(self: *Repository) !i64 {
        const Row = struct { now: []const u8 };
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        var table = try db.conn.queryAll(Row, self.gpa, sql.utc_now);
        defer table.deinit();
        if (table.rows.len != 1) return error.UnexpectedResult;
        return clock.parseDateTime(table.rows[0].now) catch error.UnexpectedResult;
    }

    /// First-boot registration of a schedule row; no-op when it exists. Mints
    /// a UUIDv7 `schedule_id` (surrogate PK, unused elsewhere) so the table
    /// follows the same app-generated-id convention as every other entity.
    pub fn ensureSchedule(self: *Repository, key: []const u8, next_at: []const u8) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        const new_id = Id.new();
        _ = try db.conn.exec(self.gpa, sql.ensure_schedule, .{ new_id, key, next_at });
    }

    /// Schedule rows whose keys this binary no longer declares (leftovers of
    /// a rollback or rename). Reported, never auto-deleted: drift stays
    /// visible. Keys are duped into `arena`.
    pub fn straySchedules(
        self: *Repository,
        arena: std.mem.Allocator,
        comptime keys_sql: []const u8,
    ) ![][]const u8 {
        const stmt = "SELECT schedule_key FROM wing_schedules WHERE schedule_key NOT IN (" ++ keys_sql ++ ")";
        const Row = struct { schedule_key: []const u8 };
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        var table = try db.conn.queryAll(Row, self.gpa, stmt);
        defer table.deinit();
        const out = try arena.alloc([]const u8, table.rows.len);
        for (table.rows, out) |row, *dst| dst.* = try arena.dupe(u8, row.schedule_key);
        return out;
    }

    /// Due rows among this process's declared keys (`keys_sql` is a comptime
    /// `'a','b'` list). Strings are duped into `arena`.
    pub fn dueSchedules(
        self: *Repository,
        arena: std.mem.Allocator,
        comptime keys_sql: []const u8,
    ) ![]DueSchedule {
        const stmt = "SELECT schedule_key, CAST(next_run_at AS CHAR) AS next_run_at " ++
            "FROM wing_schedules WHERE schedule_key IN (" ++ keys_sql ++
            ") AND next_run_at <= UTC_TIMESTAMP(3)";
        const Row = struct { schedule_key: []const u8, next_run_at: []const u8 };
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        var table = try db.conn.queryAll(Row, self.gpa, stmt);
        defer table.deinit();
        const out = try arena.alloc(DueSchedule, table.rows.len);
        for (table.rows, out) |row, *dst| {
            dst.* = .{
                .key = try arena.dupe(u8, row.schedule_key),
                .next_run_at = try arena.dupe(u8, row.next_run_at),
            };
        }
        return out;
    }

    /// One atomic firing: insert the job and CAS `next_run_at` forward in the
    /// same transaction. Losing the CAS means another node fired (the insert
    /// rolls back with it); a duplicate insert means the previous run is
    /// still pending (no-overlap guard) — the schedule then advances without
    /// recording a firing (`last_run_at` untouched).
    pub fn fireSchedule(
        self: *Repository,
        key: []const u8,
        observed_next: []const u8,
        new_next: []const u8,
        fired_at: ?[]const u8,
        job: ?NewJob,
    ) !FireResult {
        std.debug.assert((job == null) == (fired_at == null));
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var tx = try db.conn.beginWith(self.gpa, .{ .isolation = .read_committed });
        defer tx.deinit(self.gpa);

        var duplicate = false;
        if (job) |j| {
            _ = insertOn(self.gpa, tx.conn, j) catch |err| switch (err) {
                error.DuplicateJob => duplicate = true,
                else => return err,
            };
        }
        const fired = job != null and !duplicate;
        const ok = if (fired)
            try tx.conn.exec(self.gpa, sql.cas_fire, .{ new_next, fired_at.?, key, observed_next })
        else
            try tx.conn.exec(self.gpa, sql.cas_advance, .{ new_next, key, observed_next });
        if (ok.affected_rows == 0) {
            try tx.rollback(self.gpa);
            return .lost_race;
        }
        try tx.commit(self.gpa);
        return if (duplicate) .skipped_overlap else .fired;
    }

    // ---- observability ----

    pub fn queueStats(self: *Repository) !Stats {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var stats: Stats = .{ .counts = .initFill(0), .oldest_available_s = null };
        {
            const Row = struct { state: []const u8, n: u64 };
            var table = try db.conn.queryAll(Row, self.gpa, sql.count_states);
            defer table.deinit();
            for (table.rows) |row| {
                if (model.stateFromSql(row.state)) |s| stats.counts.set(s, row.n);
            }
        }
        {
            const Row = struct { age_s: ?i64 };
            var table = try db.conn.queryAll(Row, self.gpa, sql.oldest_available);
            defer table.deinit();
            if (table.rows.len == 1) stats.oldest_available_s = table.rows[0].age_s;
        }
        return stats;
    }

    /// All schedule rows (arena-owned strings), for the stats endpoint.
    pub fn scheduleStats(self: *Repository, arena: std.mem.Allocator) ![]ScheduleRow {
        const Row = struct { schedule_key: []const u8, next_run_at: []const u8, last_run_at: ?[]const u8 };
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        var table = try db.conn.queryAll(Row, self.gpa, sql.list_schedules);
        defer table.deinit();
        const out = try arena.alloc(ScheduleRow, table.rows.len);
        for (table.rows, out) |row, *dst| {
            dst.* = .{
                .key = try arena.dupe(u8, row.schedule_key),
                .next_run_at = try arena.dupe(u8, row.next_run_at),
                .last_run_at = if (row.last_run_at) |l| try arena.dupe(u8, l) else null,
            };
        }
        return out;
    }
};

/// Comptime `'a','b','c'` list for embedding code-defined names in SQL.
/// Rejects quoting hazards at build time (names come from code, not users).
pub fn kindListSql(comptime names: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (names, 0..) |name, i| {
            for (name) |ch| {
                if (ch == '\'' or ch == '\\')
                    @compileError("name is embedded in SQL and must not contain quotes: " ++ name);
            }
            out = out ++ (if (i == 0) "'" else ",'") ++ name ++ "'";
        }
        return out;
    }
}
