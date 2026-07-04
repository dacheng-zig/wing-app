//! Example job: fire-and-forget work handed off from a request handler.
//!
//! Shows the full job-type surface: `kind` (required), per-kind queue/retry/
//! timeout policy (optional), JSON-serialized payload fields, and an
//! `Outcome`-returning `run`. Enqueued by the user-registration handler.

const std = @import("std");
const zio = @import("zio");
const jobs = @import("wing_jobs");
const id_mod = @import("wing_id");

const log = std.log.scoped(.mailer);

pub const SendWelcomeEmail = struct {
    pub const kind = "send_welcome_email";
    pub const queue = "mailer";
    pub const max_attempts: u16 = 5;
    pub const timeout: zio.Duration = .fromMinutes(2);

    // Payload: JSON-encoded on insert, decoded into the per-job arena before
    // `run`. Keep fields backward-compatible — old rows may still be queued
    // when new code deploys.
    user_id: id_mod.Id, // travels as canonical UUID text via Id's json hooks
    name: []const u8,

    pub fn run(self: @This(), ctx: *jobs.Context) !jobs.Outcome {
        // At-least-once delivery: this must stay idempotent (a crash after
        // the SMTP send but before finalize means one re-run).
        //
        // A real implementation renders + talks SMTP here. DB access goes
        // through ctx.pool; scratch memory through ctx.arena. CPU-heavy
        // rendering must leave the shared scheduler thread:
        //   const html = try zio.blockInPlace(renderTemplate, .{self.name});
        log.info(
            "welcome email for user {s} ({s}) sent (attempt {d}/{d})",
            .{ &id_mod.toText(self.user_id), self.name, ctx.job.attempt, ctx.job.max_attempts },
        );
        // Other outcomes: `.{ .snooze = .fromMinutes(10) }` to re-queue
        // without burning an attempt, `.{ .discard = "user gone" }` to
        // dead-letter, or any error to retry with backoff.
        return .ok;
    }
};
