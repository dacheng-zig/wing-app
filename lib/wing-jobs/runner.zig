//! Execution engine: producer + N workers + rescuer + scheduler coroutines.
//!
//! Everything runs as cooperative coroutines on the app's single-executor zio
//! runtime, so job handlers share the scheduler thread with HTTP — CPU-heavy
//! work inside `run` must go through `zio.spawnBlocking`/`blockInPlace`.
//!
//! Delivery is at-least-once. A worker that dies between executing and
//! finalizing leaves the row `running`; the rescuer revives it after
//! `rescue_after`. Finalize itself runs inside a cancellation shield so a
//! graceful shutdown can't sever the commit mid-protocol.

const std = @import("std");
const zio = @import("zio");
const mantle = @import("mantle");

const jobs = @import("root.zig");
const model = @import("model.zig");
const repository = @import("repository.zig");
const scheduler = @import("scheduler.zig");
const wing_trace = @import("wing_trace");
const id_mod = @import("wing_id");

const log = std.log.scoped(.jobs);

/// Same-process enqueues wake the producer instantly; enqueues from other
/// nodes are covered by the poll interval.
var wakeup: zio.Notify = .{};

pub fn notifyEnqueued() void {
    wakeup.signal();
}

/// Jitter source for retry backoff. Single-executor runtime: no locking
/// (same convention as the request-id generator).
var prng: std.Random.DefaultPrng = .init(0);
var prng_seeded = false;

fn jitterRandom() std.Random {
    if (!prng_seeded) {
        var seed: [8]u8 = undefined;
        zio.random(&seed);
        prng = .init(std.mem.readInt(u64, &seed, .little));
        prng_seeded = true;
    }
    return prng.random();
}

pub fn Runner(comptime Registry: type, comptime user_schedules: []const jobs.Schedule) type {
    // Maintenance rides the same pipeline: prune daily at a quiet hour.
    const all_schedules = user_schedules ++ [_]jobs.Schedule{.{
        .key = "wing.jobs.prune",
        .spec = .{ .cron = "0 4 * * *" },
        .job = @import("internal/prune.zig").Prune,
    }};
    const Scheduler = scheduler.Scheduler(Registry, all_schedules);

    return struct {
        const Self = @This();

        /// A finished execution's state transition, decided outside the
        /// cancellation shield and committed inside it.
        const Action = union(enum) {
            complete,
            snooze_us: i64,
            fail: []const u8, // retry, or discard once attempts are exhausted
            dead: struct { state: model.State, msg: []const u8 },
            release, // shutdown: hand the job back untouched
        };

        gpa: std.mem.Allocator,
        repo: repository.Repository,
        config: jobs.Config,
        channel: zio.Channel(model.ClaimedJob),
        channel_buf: []model.ClaimedJob,
        /// Worker slots not currently executing; producer claims that many.
        free_slots: std.atomic.Value(u32),
        /// Node identity for `attempted_by` crash attribution (hex, safe to
        /// embed in SQL).
        node_id: [21]u8,

        pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool, config: jobs.Config, pool_size: usize) !Self {
            // Each executing worker leases one pooled connection; leave real
            // headroom for HTTP handlers. Scaling workers means scaling the
            // pool first.
            if (config.workers >= pool_size) {
                log.err(
                    "JOBS_WORKERS ({d}) must be < DB_POOL_SIZE ({d}); raise the pool first",
                    .{ config.workers, pool_size },
                );
                return error.TooManyWorkers;
            }
            const buf = try gpa.alloc(model.ClaimedJob, config.workers);
            errdefer gpa.free(buf);

            return .{
                .gpa = gpa,
                .repo = repository.Repository.init(gpa, pool),
                .config = config,
                .channel = zio.Channel(model.ClaimedJob).init(buf),
                .channel_buf = buf,
                .free_slots = .init(config.workers),
                .node_id = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            // Drain jobs still parked in the channel (claimed but never run);
            // their rows stay `running` and the rescuer revives them.
            while (self.channel.tryReceive()) |job| {
                job.deinit(self.gpa);
            } else |_| {}
            self.gpa.free(self.channel_buf);
        }

        /// Entry point for `group.spawn`. Spawns the pipeline and blocks
        /// until the surrounding group is cancelled.
        pub fn run(self: *Self) !void {
            // Crash attribution for `attempted_by`; random beats host:pid
            // (needs a coroutine context, hence here and not in init).
            var raw: [8]u8 = undefined;
            zio.random(&raw);
            _ = std.fmt.bufPrint(&self.node_id, "node-{x:0>16}", .{std.mem.readInt(u64, &raw, .little)}) catch unreachable;

            var group: zio.Group = .init;
            defer group.cancel();

            try group.spawn(producer, .{self});
            for (0..self.config.workers) |_| try group.spawn(worker, .{self});
            try group.spawn(rescuer, .{self});
            try group.spawn(scheduleLoop, .{self});
            log.info("job runner up: {d} workers, node {s}", .{ self.config.workers, &self.node_id });

            try group.wait();
        }

        /// Centralized claiming: one coroutine batches `SKIP LOCKED` claims
        /// for however many workers are idle, so N workers never issue N
        /// competing claim transactions.
        fn producer(self: *Self) !void {
            const interval = zio.Duration.fromSeconds(self.config.poll_interval_s);
            // Polls tick on absolute deadlines, not interval-after-work, so
            // probe latency doesn't accumulate as phase drift.
            var next_poll = zio.now().addDuration(interval);
            while (true) {
                const free = self.free_slots.load(.monotonic);
                var saturated = false;
                if (free > 0) {
                    const batch = self.repo.claim(free, &self.node_id) catch |err| switch (err) {
                        error.Canceled => return err,
                        else => blk: {
                            log.warn("claim failed: {s}", .{@errorName(err)});
                            break :blk &[_]model.ClaimedJob{};
                        },
                    };
                    defer if (batch.len > 0) self.gpa.free(batch);
                    for (batch) |job| {
                        _ = self.free_slots.fetchSub(1, .monotonic);
                        // Capacity == worker count >= claimed batch: never blocks.
                        self.channel.send(job) catch |err| {
                            job.deinit(self.gpa);
                            return err;
                        };
                    }
                    saturated = batch.len == free;
                }
                if (saturated) continue; // backlog remains: claim again immediately
                wakeup.timedWait(.{ .deadline = next_poll }) catch |err| switch (err) {
                    error.Timeout => {
                        next_poll = next_poll.addDuration(interval);
                        // An overrun tick realigns forward instead of replaying.
                        if (next_poll.toNanoseconds() <= zio.now().toNanoseconds())
                            next_poll = zio.now().addDuration(interval);
                    },
                    // An enqueue wakeup claims right away; the tick deadline
                    // stands, so the poll phase never shifts.
                    error.Canceled => return err,
                };
            }
        }

        fn worker(self: *Self) !void {
            while (true) {
                const job = try self.channel.receive();
                defer wakeup.signal(); // slot freed (runs after fetchAdd below)
                defer _ = self.free_slots.fetchAdd(1, .monotonic);
                defer job.deinit(self.gpa);
                try self.runOne(&job);
            }
        }

        /// One execution: bind the trace context, arm the per-kind timeout,
        /// dispatch, then commit the state transition under a shield.
        fn runOne(self: *Self, job: *const model.ClaimedJob) !void {
            var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_inst.deinit();

            // Every log line inside the job carries the job's id as trace_id,
            // same channel request logs use.
            const job_id_text = id_mod.toText(job.id);
            var binding: wing_trace.Binding = .unset;
            wing_trace.bind(&binding, .{ .trace_id = &job_id_text });
            defer wing_trace.unbind(&binding);

            var ctx: jobs.Context = .{
                .gpa = self.gpa,
                .arena = arena_inst.allocator(),
                .pool = self.repo.pool,
                .config = self.config,
                .job = .{
                    .id = job.id,
                    .kind = job.kind,
                    .attempt = job.attempt,
                    .max_attempts = job.max_attempts,
                },
            };

            var timeout: zio.AutoCancel = .init;
            defer timeout.clear();
            if (Registry.timeoutFor(job.kind)) |t| timeout.set(.fromNanoseconds(@intCast(t.toNanoseconds())));

            const action: Action = blk: {
                const outcome = Registry.dispatch(job.kind, job.args, &ctx) catch |err| switch (err) {
                    error.Canceled => {
                        if (timeout.check(error.Canceled))
                            break :blk .{ .fail = "timeout" };
                        break :blk .release; // runner shutdown
                    },
                    error.UnknownJobKind => {
                        log.warn("job {s}: unknown kind \"{s}\" (rolled-back deploy?), discarding", .{ &job_id_text, job.kind });
                        break :blk .{ .dead = .{ .state = .discarded, .msg = "unknown job kind" } };
                    },
                    else => break :blk .{ .fail = @errorName(err) },
                };
                break :blk switch (outcome) {
                    .ok => .complete,
                    .snooze => |d| .{ .snooze_us = @intCast(d.toMicroseconds()) },
                    .cancel => |msg| .{ .dead = .{ .state = .cancelled, .msg = msg } },
                    .discard => |msg| .{ .dead = .{ .state = .discarded, .msg = msg } },
                };
            };

            // Stop the timer before entering the shield, then consume any
            // auto-cancel that fired after `run`'s last suspension point —
            // left pending, it would throw at the next `receive()` and
            // silently kill this worker.
            timeout.clear();
            if (timeout.triggered) _ = timeout.check(error.Canceled);

            // The commit must survive shutdown cancellation: a severed
            // finalize would report a finished job as crashed. Shielded, the
            // in-flight UPDATE completes before cancellation resumes.
            zio.beginShield();
            defer zio.endShield();
            self.finalize(job, action) catch |err| {
                // Row stays `running`; the rescuer will pick it up.
                log.err("job {s} finalize failed: {s}", .{ &job_id_text, @errorName(err) });
                if (err == error.Canceled) return err;
            };
            if (action == .release) return error.Canceled;
        }

        fn finalize(self: *Self, job: *const model.ClaimedJob, action: Action) !void {
            const id_text = id_mod.toText(job.id);
            switch (action) {
                .complete => {
                    try self.repo.complete(job.id);
                    log.debug("job {s} kind={s} attempt={d} -> completed", .{ &id_text, job.kind, job.attempt });
                },
                .snooze_us => |us| {
                    try self.repo.snooze(job.id, us);
                    log.debug("job {s} kind={s} snoozed {d}us", .{ &id_text, job.kind, us });
                },
                .fail => |msg| {
                    const reason = truncate(msg);
                    if (job.attempt >= job.max_attempts) {
                        try self.repo.markDead(job.id, .discarded, job.attempt, reason);
                        log.warn("job {s} kind={s} attempt={d}/{d} exhausted -> discarded: {s}", .{
                            &id_text, job.kind, job.attempt, job.max_attempts, reason,
                        });
                    } else {
                        const delay_s = model.backoffSeconds(job.attempt, jitterRandom());
                        try self.repo.retry(job.id, job.attempt, delay_s, reason);
                        log.info("job {s} kind={s} attempt={d}/{d} failed, retry in {d}s: {s}", .{
                            &id_text, job.kind, job.attempt, job.max_attempts, delay_s, reason,
                        });
                    }
                },
                .dead => |d| {
                    try self.repo.markDead(job.id, d.state, job.attempt, truncate(d.msg));
                    log.info("job {s} kind={s} -> {s}: {s}", .{ &id_text, job.kind, @tagName(d.state), truncate(d.msg) });
                },
                .release => {
                    try self.repo.releaseBack(job.id);
                    log.info("job {s} kind={s} released back (shutdown)", .{ &id_text, job.kind });
                },
            }
        }

        /// Revive crashed executions. Idempotent SQL, so every node runs it;
        /// no leader needed.
        fn rescuer(self: *Self) !void {
            while (true) {
                try zio.sleep(.fromSeconds(self.config.rescue_interval_s));
                const n = self.repo.rescue(self.config.rescue_after_s, Registry.rescue_discard_kinds) catch |err| switch (err) {
                    error.Canceled => return err,
                    else => {
                        log.warn("rescue sweep failed: {s}", .{@errorName(err)});
                        continue;
                    },
                };
                if (n > 0) {
                    log.warn("rescued {d} stuck job(s)", .{n});
                    wakeup.signal();
                }
            }
        }

        fn scheduleLoop(self: *Self) !void {
            try Scheduler.run(&self.repo, self.gpa, self.config);
        }
    };
}

/// Keep stored error reasons bounded; full detail is in the logs.
fn truncate(msg: []const u8) []const u8 {
    return msg[0..@min(msg.len, 512)];
}
