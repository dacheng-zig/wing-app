//! Background jobs: MySQL-backed queue + cron scheduling.
//!
//! Public surface of the module. Define a job as a struct (`kind` + `run` +
//! JSON-serializable fields), collect job types in a `Registry`, enqueue with
//! `Registry.insert`/`insertTx`, and spawn a `Runner` next to the HTTP server
//! for execution. Delivery is at-least-once: handlers must be idempotent —
//! a crashed worker's job is re-run after `rescue_after`.
//!
//! ```zig
//! pub const SendWelcomeEmail = struct {
//!     pub const kind = "send_welcome_email";
//!     pub const max_attempts: u16 = 5;          // optional, default 20
//!     pub const queue = "mailer";               // optional row label (v1 claims all queues)
//!     pub const timeout: zio.Duration = .fromMinutes(2); // optional
//!
//!     user_id: jobs.Id, // serialized as canonical UUID text via Id's json hooks
//!
//!     pub fn run(self: @This(), ctx: *jobs.Context) !jobs.Outcome {
//!         // CPU-heavy work must leave the scheduler thread:
//!         // try zio.blockInPlace(render, .{...});
//!         _ = self; _ = ctx;
//!         return .ok;
//!     }
//! };
//! ```

const std = @import("std");
const zio = @import("zio");
const mantle = @import("mantle");

pub const cron = @import("cron.zig");
pub const clock = @import("clock.zig");
pub const model = @import("model.zig");
pub const Id = @import("wing_id").Id;
pub const Config = @import("config.zig").Config;
pub const Repository = @import("repository.zig").Repository;
pub const Registry = @import("registry.zig").Registry;
pub const Runner = @import("runner.zig").Runner;
/// Wake this process's producer. `Registry.insert` calls it automatically;
/// after an `insertTx` commit, call it yourself for instant pickup.
pub const notifyEnqueued = @import("runner.zig").notifyEnqueued;

/// What a `run` returns; encodes the state transition. Returning an error
/// instead means retry with backoff (or discard once attempts are exhausted).
pub const Outcome = union(enum) {
    /// -> completed
    ok,
    /// -> available again after the delay; does not consume an attempt.
    snooze: zio.Duration,
    /// -> cancelled (no retry); the reason lands in `errors`.
    cancel: []const u8,
    /// -> discarded (dead-letter, no retry); the reason lands in `errors`.
    discard: []const u8,
};

/// What the rescuer does with a crashed (`running`, stale) job of this kind.
/// Declare `pub const rescue: jobs.RescuePolicy = .discard;` on job types that
/// must never double-run; they then park in `discarded` for manual review.
pub const RescuePolicy = enum { retry, discard };

pub const UniqueOptions = struct {
    /// Fingerprint dimensions: kind+args (default) or kind only.
    by: enum { args, kind } = .args,
    /// Throttle window: when set, the epoch-aligned time bucket joins the
    /// fingerprint, so at most one job per period can exist.
    period: ?zio.Duration = null,
    /// Keep occupying the fingerprint after the job reaches a terminal state
    /// (until pruned). Default releases it, i.e. "unique while pending".
    keep_after_done: bool = false,
};

pub const InsertOptions = struct {
    /// Run no earlier than now + delay.
    delay: ?zio.Duration = null,
    /// Absolute UTC run time (epoch ms). Takes precedence over `delay`.
    scheduled_at_ms: ?i64 = null,
    /// Lower runs first; 0 is the highest priority.
    priority: i8 = 0,
    unique: ?UniqueOptions = null,
};

/// Handed to every `run`. `arena` lives for this execution only (args are
/// parsed into it); `pool` is the shared app pool for DB work.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pool: *mantle.TcpPool,
    config: Config,
    job: struct {
        id: Id,
        kind: []const u8,
        attempt: u16,
        max_attempts: u16,
    },
};

/// A periodic trigger: at each firing instant the scheduler inserts one
/// normal job of type `job`, which then flows through the exact same
/// claim/retry/dead-letter path as a hand-enqueued job. `job` must be listed
/// in the same `Registry` the `Runner` executes and needs all fields
/// defaulted (the scheduler inserts `job{}`).
pub const Schedule = struct {
    /// Stable identity of the `wing_schedules` row. `[A-Za-z0-9_.-]` only.
    key: []const u8,
    spec: Spec,
    job: type,
    catch_up: cron.CatchUp = .coalesce,
    /// Max age of a missed trigger that `.coalesce` will still fire.
    grace: zio.Duration = .fromMinutes(60),
    /// Skip a firing while the previous one is still pending/running
    /// (enforced via a kind-scoped unique fingerprint).
    no_overlap: bool = true,
};

pub const Spec = union(enum) {
    /// Five-field cron (`min hour dom mon dow`) or an `@daily`-style alias,
    /// parsed at comptime — a typo is a build error. UTC.
    cron: []const u8,
    /// Fixed interval, fired on epoch-aligned multiples.
    every: zio.Duration,

    pub fn compile(comptime self: Spec) cron.Compiled {
        return switch (self) {
            .cron => |src| .{ .cron = cron.compile(src) },
            .every => |d| .{ .every_ms = @intCast(d.toMilliseconds()) },
        };
    }
};

test {
    // The pure layer: UTC civil-time math, cron parse/nextAfter/misfire,
    // state machine + backoff + unique fingerprint. The DB-backed repository,
    // runner and scheduler need MySQL; the app's test aggregator gives them
    // compile coverage by instantiating its registry/runner generics.
    _ = clock;
    _ = cron;
    _ = model;
}
