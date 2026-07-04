//! Comptime job registry: the closed set of job kinds this binary executes.
//!
//! Binding kind-string -> type at comptime buys three things a runtime
//! registry can't: duplicate/missing `kind`s are build errors, `dispatch`
//! deserializes straight into the right struct with zero reflection at
//! runtime, and `insert` only accepts registered types.

const std = @import("std");
const zio = @import("zio");
const mantle = @import("mantle");

const jobs = @import("root.zig");
const model = @import("model.zig");
const clock = @import("clock.zig");
const repository = @import("repository.zig");
const runner = @import("runner.zig");

/// Per-kind execution policy, read off the job type's optional decls.
pub const Meta = struct {
    /// Row label for observability/ad-hoc SQL; v1 claiming does not filter
    /// by queue (all workers drain all queues).
    queue: []const u8,
    max_attempts: u16,
    timeout: ?zio.Duration,
    rescue: jobs.RescuePolicy,
};

pub fn Registry(comptime user_types: []const type) type {
    // Internal maintenance jobs ride the same pipeline (dogfooding).
    const all_types = user_types ++ [_]type{@import("internal/prune.zig").Prune};

    comptime {
        for (all_types, 0..) |T, i| {
            if (!@hasDecl(T, "kind") or @TypeOf(@as([]const u8, T.kind)) != []const u8 or T.kind.len == 0)
                @compileError(@typeName(T) ++ ": a job type needs `pub const kind: []const u8` (non-empty)");
            if (!@hasDecl(T, "run"))
                @compileError(@typeName(T) ++ ": a job type needs `pub fn run(self, *jobs.Context) !jobs.Outcome`");
            for (all_types[i + 1 ..]) |U| {
                if (std.mem.eql(u8, T.kind, U.kind))
                    @compileError("duplicate job kind \"" ++ T.kind ++ "\": " ++ @typeName(T) ++ " and " ++ @typeName(U));
            }
        }
    }

    return struct {
        /// Kinds whose crashed executions must not auto-rerun.
        pub const rescue_discard_kinds: []const []const u8 = blk: {
            var kinds: []const []const u8 = &.{};
            for (all_types) |T| {
                if (metaOf(T).rescue == .discard) kinds = kinds ++ [_][]const u8{T.kind};
            }
            break :blk kinds;
        };

        pub fn contains(comptime T: type) bool {
            inline for (all_types) |U| {
                if (T == U) return true;
            }
            return false;
        }

        pub fn metaOf(comptime T: type) Meta {
            return .{
                .queue = if (@hasDecl(T, "queue")) T.queue else "default",
                .max_attempts = if (@hasDecl(T, "max_attempts")) T.max_attempts else 20,
                .timeout = if (@hasDecl(T, "timeout")) T.timeout else null,
                .rescue = if (@hasDecl(T, "rescue")) T.rescue else .retry,
            };
        }

        /// Execution timeout for a claimed kind, resolved from the row's
        /// kind string; null for unknown kinds and untimed jobs.
        pub fn timeoutFor(kind: []const u8) ?zio.Duration {
            inline for (all_types) |T| {
                if (std.mem.eql(u8, kind, T.kind)) return comptime metaOf(T).timeout;
            }
            return null;
        }

        /// Decode `args_json` into the matching job struct (arena-backed)
        /// and run it. Undecodable args are a permanent condition — discard,
        /// don't retry. Unknown kinds surface to the worker as an error.
        pub fn dispatch(kind: []const u8, args_json: []const u8, ctx: *jobs.Context) anyerror!jobs.Outcome {
            inline for (all_types) |T| {
                if (std.mem.eql(u8, kind, T.kind)) {
                    const args = std.json.parseFromSliceLeaky(T, ctx.arena, args_json, .{
                        .ignore_unknown_fields = true,
                    }) catch |err| {
                        return .{ .discard = std.fmt.allocPrint(
                            ctx.arena,
                            "args decode failed: {s}",
                            .{@errorName(err)},
                        ) catch "args decode failed" };
                    };
                    return T.run(args, ctx);
                }
            }
            return error.UnknownJobKind;
        }

        /// Enqueue on the shared pool (own short implicit transaction).
        /// Returns the job id; `error.DuplicateJob` when a unique fingerprint
        /// is already occupied. `gpa` must be long-lived (the app allocator,
        /// never a request arena): mantle caches the prepared statement on
        /// the pooled connection beyond this call.
        pub fn insert(gpa: std.mem.Allocator, pool: *mantle.TcpPool, job: anytype, opts: jobs.InsertOptions) !jobs.Id {
            var db = try mantle.PooledConnection.acquire(pool);
            defer db.release();
            const id = try insertOn(gpa, db.conn, job, opts);
            // Zero-latency pickup in this process; other nodes poll.
            runner.notifyEnqueued();
            return id;
        }

        /// Enqueue inside a caller-owned transaction: the job commits and
        /// rolls back atomically with the business writes around it. No
        /// producer wakeup here — the row is invisible until the caller
        /// commits; call `jobs.notifyEnqueued()` after the commit for instant
        /// pickup, or rely on the poll interval.
        pub fn insertTx(gpa: std.mem.Allocator, tx: *mantle.Transaction, job: anytype, opts: jobs.InsertOptions) !jobs.Id {
            return insertOn(gpa, tx.conn, job, opts);
        }

        fn insertOn(gpa: std.mem.Allocator, conn: *mantle.Connection, job: anytype, opts: jobs.InsertOptions) !jobs.Id {
            const T = @TypeOf(job);
            comptime {
                if (!contains(T)) @compileError(@typeName(T) ++ " is not in this job Registry");
            }
            const meta = comptime metaOf(T);

            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
            try stringify.write(job);
            const args_json = out.written();

            var key_buf: [32]u8 = undefined;
            var unique_key: ?[]const u8 = null;
            var unique_keep = false;
            if (opts.unique) |u| {
                const args_dim: ?[]const u8 = if (u.by == .args) args_json else null;
                const bucket: ?i64 = if (u.period) |p| bucketOf(p) else null;
                key_buf = model.fingerprint(T.kind, args_dim, bucket);
                unique_key = &key_buf;
                unique_keep = u.keep_after_done;
            }

            var at_buf: [clock.datetime_len]u8 = undefined;
            var at: ?[]const u8 = null;
            var delay_us: i64 = 0;
            if (opts.scheduled_at_ms) |ms| {
                at = clock.formatDateTime(&at_buf, ms);
            } else if (opts.delay) |d| {
                delay_us = @intCast(d.toMicroseconds());
            }

            return repository.Repository.insertOn(gpa, conn, .{
                .kind = T.kind,
                .queue = meta.queue,
                .priority = opts.priority,
                .args = args_json,
                .max_attempts = meta.max_attempts,
                .unique_key = unique_key,
                .unique_keep = unique_keep,
                .at = at,
                .delay_us = delay_us,
            });
        }
    };
}

/// Epoch-aligned throttle bucket. Uses this node's wall clock — bucket edges
/// may shift by clock skew, which throttling tolerates.
fn bucketOf(period: zio.Duration) i64 {
    const now_ms: i64 = @intCast(@divFloor(zio.Timestamp.now(.real).toNanoseconds(), 1_000_000));
    return @divFloor(now_ms, @as(i64, @intCast(period.toMilliseconds())));
}
