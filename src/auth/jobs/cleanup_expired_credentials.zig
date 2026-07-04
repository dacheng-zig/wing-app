//! Scheduled job: hourly cleanup of expired credential rows.
//!
//! Scheduled jobs are plain jobs with all fields defaulted (the scheduler
//! inserts `.{}`); the schedule itself is declared in the app's job
//! registry. Delete logic lives in `CredentialRepository`, which owns the
//! `credentials` table.

const std = @import("std");
const jobs = @import("wing_jobs");
const CredentialRepository = @import("../repositories/credential_repository.zig").CredentialRepository;

const log = std.log.scoped(.auth);

pub const CleanupExpiredCredentials = struct {
    pub const kind = "cleanup_expired_credentials";
    pub const max_attempts: u16 = 3;

    batch: u32 = 1000,

    pub fn run(self: @This(), ctx: *jobs.Context) !jobs.Outcome {
        var repo = CredentialRepository.init(ctx.gpa, ctx.pool);
        const total = try repo.deleteExpired(self.batch);
        if (total > 0) log.info("removed {d} expired credential(s)", .{total});
        return .ok;
    }
};
