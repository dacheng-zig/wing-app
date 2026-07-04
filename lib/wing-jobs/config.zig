//! Runner knobs, owned by the jobs module (std-only so the app config can
//! embed it without pulling in the DB/runtime stack). Durations are plain
//! seconds; the runner converts. The app maps `JOBS_*` env vars onto this in
//! config/config.zig.

pub const Config = struct {
    enabled: bool = true,
    /// Worker coroutines. Each holds at most one pooled DB connection while
    /// executing, so this must stay below the DB pool size or workers starve
    /// HTTP handlers of connections. Enforced at runner startup.
    workers: u16 = 4,
    /// Producer polling fallback for enqueues from other nodes (same-process
    /// enqueues wake the producer instantly).
    poll_interval_s: u32 = 1,
    /// Scheduler tick; worst-case cron trigger delay.
    tick_interval_s: u32 = 15,
    /// A `running` job older than this is presumed crashed and rescued.
    /// Effectively the max job runtime — longer work must snooze or split.
    rescue_after_s: u32 = 15 * 60,
    rescue_interval_s: u32 = 60,
    retention_completed_s: u32 = 7 * 24 * 3600,
    retention_discarded_s: u32 = 30 * 24 * 3600,
};
