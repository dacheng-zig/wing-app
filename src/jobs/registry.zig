//! App-level job assembly: THE closed set of job kinds and schedules this
//! binary runs. Adding a job = write the job struct, list it here; adding a
//! periodic task = also add a `Schedule` line. Everything is validated at
//! comptime (duplicate kinds, bad cron strings, schedules pointing outside
//! the registry are build errors).

const jobs = @import("wing_jobs");

pub const SendWelcomeEmail = @import("send_welcome_email.zig").SendWelcomeEmail;
pub const CleanupExpiredCredentials = @import("../auth/jobs/cleanup_expired_credentials.zig").CleanupExpiredCredentials;

pub const JobRegistry = jobs.Registry(&.{
    SendWelcomeEmail,
    CleanupExpiredCredentials,
});

pub const schedules = [_]jobs.Schedule{
    .{
        .key = "cleanup_expired_credentials",
        .spec = .{ .cron = "@hourly" },
        .job = CleanupExpiredCredentials,
        // Defaults also in effect: .catch_up = .coalesce (fire the newest
        // missed run after a restart, within .grace), .no_overlap = true
        // (skip a tick while the previous run is still pending).
    },
};

/// Instantiated in server.zig next to the HTTP server; internal maintenance
/// (job-row pruning) is appended automatically.
pub const JobRunner = jobs.Runner(JobRegistry, &schedules);
