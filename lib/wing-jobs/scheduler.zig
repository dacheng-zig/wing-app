//! Cron scheduler: turns declared `Schedule`s into inserted jobs.
//!
//! Every node runs the same tick loop against the shared `wing_schedules`
//! table; the CAS on `next_run_at` (plus a unique job fingerprint as second
//! line) guarantees each firing inserts exactly one job, with no leader and
//! no session locks. Scheduling and execution stay separate: a firing is
//! just an INSERT, after which the job is indistinguishable from a
//! hand-enqueued one.

const std = @import("std");
const zio = @import("zio");

const jobs = @import("root.zig");
const cron = @import("cron.zig");
const clock = @import("clock.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const runner = @import("runner.zig");

const log = std.log.scoped(.jobs);

pub fn Scheduler(comptime Registry: type, comptime schedules: []const jobs.Schedule) type {
    comptime {
        for (schedules, 0..) |s, i| {
            if (s.key.len == 0 or s.key.len > 128)
                @compileError("schedule key must be 1..128 chars: \"" ++ s.key ++ "\"");
            for (s.key) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-')
                    @compileError("schedule key allows [A-Za-z0-9_.-] only: \"" ++ s.key ++ "\"");
            }
            for (schedules[i + 1 ..]) |t| {
                if (std.mem.eql(u8, s.key, t.key))
                    @compileError("duplicate schedule key \"" ++ s.key ++ "\"");
                // no_overlap fingerprints are keyed by job kind, so two such
                // schedules sharing a job type would suppress each other.
                if (s.job == t.job and s.no_overlap and t.no_overlap)
                    @compileError("schedules \"" ++ s.key ++ "\" and \"" ++ t.key ++ "\" both run " ++
                        @typeName(s.job) ++ " with no_overlap; use distinct job types or disable no_overlap");
            }
            if (!Registry.contains(s.job))
                @compileError("schedule \"" ++ s.key ++ "\" references " ++ @typeName(s.job) ++ ", which is not in the Registry");
            for (@typeInfo(s.job).@"struct".fields) |f| {
                if (f.default_value_ptr == null)
                    @compileError("scheduled job " ++ @typeName(s.job) ++ " needs defaults on all fields (the scheduler inserts `.{}`)");
            }
            if (s.spec == .every and s.spec.every.toMilliseconds() < 1000)
                @compileError("schedule \"" ++ s.key ++ "\": `every` must be >= 1s");
        }
    }

    const compiled: [schedules.len]cron.Compiled = comptime blk: {
        var specs: [schedules.len]cron.Compiled = undefined;
        for (schedules, 0..) |s, i| specs[i] = s.spec.compile();
        break :blk specs;
    };

    const keys: []const []const u8 = comptime blk: {
        var out: []const []const u8 = &.{};
        for (schedules) |s| out = out ++ [_][]const u8{s.key};
        break :blk out;
    };
    const keys_sql = repository.kindListSql(keys);

    return struct {
        pub fn run(repo: *repository.Repository, gpa: std.mem.Allocator, config: jobs.Config) !void {
            try register(repo, gpa);
            while (true) {
                tick(repo, gpa) catch |err| switch (err) {
                    error.Canceled => return err,
                    else => log.warn("scheduler tick failed: {s}", .{@errorName(err)}),
                };
                try zio.sleep(.fromSeconds(config.tick_interval_s));
            }
        }

        /// Create missing `wing_schedules` rows. Keys present in the table but
        /// no longer declared in code are left alone and flagged, so drift
        /// after a rollback/rename stays visible.
        fn register(repo: *repository.Repository, gpa: std.mem.Allocator) !void {
            const now_ms = try repo.utcNowMs();
            inline for (schedules, 0..) |s, i| {
                if (compiled[i].nextAfter(now_ms)) |next_ms| {
                    var buf: [clock.datetime_len]u8 = undefined;
                    try repo.ensureSchedule(s.key, clock.formatDateTime(&buf, next_ms));
                } else {
                    log.warn("schedule \"{s}\" can never fire (unsatisfiable spec)", .{s.key});
                }
            }
            var arena_inst = std.heap.ArenaAllocator.init(gpa);
            defer arena_inst.deinit();
            for (try repo.straySchedules(arena_inst.allocator(), keys_sql)) |key| {
                log.warn("schedule row \"{s}\" exists in wing_schedules but is not declared in this build (rollback/rename?)", .{key});
            }
        }

        fn tick(repo: *repository.Repository, gpa: std.mem.Allocator) !void {
            var arena_inst = std.heap.ArenaAllocator.init(gpa);
            defer arena_inst.deinit();
            const arena = arena_inst.allocator();

            const due = try repo.dueSchedules(arena, keys_sql);
            if (due.len == 0) return;
            const now_ms = try repo.utcNowMs();

            for (due) |row| {
                inline for (schedules, 0..) |s, i| {
                    if (std.mem.eql(u8, row.key, s.key))
                        fire(repo, arena, s, compiled[i], row, now_ms) catch |err| switch (err) {
                            error.Canceled => return error.Canceled,
                            else => log.warn("schedule \"{s}\" firing failed: {s}", .{ s.key, @errorName(err) }),
                        };
                }
            }
        }

        fn fire(
            repo: *repository.Repository,
            arena: std.mem.Allocator,
            comptime s: jobs.Schedule,
            spec: cron.Compiled,
            row: repository.DueSchedule,
            now_ms: i64,
        ) !void {
            const observed_ms = clock.parseDateTime(row.next_run_at) catch {
                log.err("schedule \"{s}\": unparsable next_run_at \"{s}\"", .{ s.key, row.next_run_at });
                return;
            };
            const grace_ms: i64 = @intCast(s.grace.toMilliseconds());
            const res = cron.resolve(spec, observed_ms, now_ms, s.catch_up, grace_ms) catch {
                log.err("schedule \"{s}\": spec can never fire, leaving row untouched", .{s.key});
                return;
            };

            var next_buf: [clock.datetime_len]u8 = undefined;
            const next_str = clock.formatDateTime(&next_buf, res.next_ms);

            const fire_ms = res.fire_ms orelse {
                // Missed beyond grace (or catch_up = .skip): only re-arm.
                const r = try repo.fireSchedule(s.key, row.next_run_at, next_str, null, null);
                if (r == .fired) log.info("schedule \"{s}\": skipped missed run(s), next {s}", .{ s.key, next_str });
                return;
            };
            var fire_buf: [clock.datetime_len]u8 = undefined;
            const fire_str = clock.formatDateTime(&fire_buf, fire_ms);

            const meta = comptime Registry.metaOf(s.job);
            const args_json = try serializeDefault(s.job, arena);
            // Second line of defense behind the CAS: no-overlap keys the
            // fingerprint by kind (also blocks piling onto a still-pending
            // run); otherwise the firing instant makes it collide only with
            // the same trigger fired twice.
            const unique_key = if (s.no_overlap)
                model.fingerprint(s.job.kind, null, null)
            else
                model.fingerprint(s.key, null, fire_ms);

            const result = try repo.fireSchedule(s.key, row.next_run_at, next_str, fire_str, .{
                .kind = s.job.kind,
                .queue = meta.queue,
                .args = args_json,
                .max_attempts = meta.max_attempts,
                .unique_key = &unique_key,
                .at = fire_str,
            });
            switch (result) {
                .fired => {
                    log.info("schedule \"{s}\" fired at {s}, next {s}", .{ s.key, fire_str, next_str });
                    runner.notifyEnqueued();
                },
                .lost_race => {}, // another node fired this instant
                .skipped_overlap => log.info("schedule \"{s}\": previous run still pending, skipped", .{s.key}),
            }
        }

        fn serializeDefault(comptime T: type, arena: std.mem.Allocator) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(arena);
            var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
            try stringify.write(T{});
            return out.written();
        }
    };
}
