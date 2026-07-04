//! Application configuration.
//!
//! Centralizes runtime knobs (listen address, defaults) in one place. Values
//! come from compiled-in defaults, overridable by environment variables at
//! startup. Loaded once in `server.run` and stored on `AppState`.

const std = @import("std");

/// MySQL connection settings for the mantle-backed repositories.
///
/// Defaults target a local dev server. The `database` must already exist (the
/// app manages tables, not the database itself); every pooled connection
/// selects it at handshake time. Override any field via `DB_*` env vars.
pub const Db = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3306,
    username: []const u8 = "root",
    password: []const u8 = "root",
    database: []const u8 = "wing_app",
    /// utf8mb4_general_ci, matching mantle's default charset.
    character_set: u8 = 45,
    /// Hard upper bound on physical connections in the pool. Eight keeps the
    /// connections hot and matches MySQL's most efficient point-query
    /// concurrency on a single box; larger pools only add latency and contention
    /// here. Raise with `DB_POOL_SIZE` if the DB lives on its own host.
    pool_size: usize = 8,
};

/// Background job runner knobs. The struct (and its defaults — domain policy)
/// lives with the jobs module; this config only maps `JOBS_*` env vars onto
/// it. Std-only on both sides, so embedding pulls in no runtime deps.
pub const Jobs = @import("wing_jobs").Config;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    greeting: []const u8 = "Hello, world!",
    db: Db = .{},
    jobs: Jobs = .{},

    /// Build config from defaults, overriding from the environment.
    ///
    /// `env` is the process environment map handed to `main` via
    /// `std.process.Init` (the 0.16 std.Io-era way to read env vars). Reads
    /// `PORT` plus the `DB_*` database knobs. Env strings are owned by the map
    /// and outlive this call, so storing slices is safe.
    pub fn load(env: *const std.process.Environ.Map) Config {
        var cfg: Config = .{};
        if (env.get("PORT")) |raw| {
            if (std.fmt.parseInt(u16, raw, 10)) |p| {
                cfg.port = p;
            } else |_| {} // ignore malformed PORT, keep the default
        }
        if (env.get("DB_HOST")) |v| cfg.db.host = v;
        if (env.get("DB_PORT")) |v| {
            if (std.fmt.parseInt(u16, v, 10)) |p| cfg.db.port = p else |_| {}
        }
        if (env.get("DB_USER")) |v| cfg.db.username = v;
        if (env.get("DB_PASSWORD")) |v| cfg.db.password = v;
        if (env.get("DB_NAME")) |v| cfg.db.database = v;
        if (env.get("DB_POOL_SIZE")) |v| {
            if (std.fmt.parseInt(usize, v, 10)) |n| {
                if (n != 0) cfg.db.pool_size = n;
            } else |_| {}
        }
        if (env.get("JOBS_ENABLED")) |v| {
            cfg.jobs.enabled = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or
                std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "no"));
        }
        if (env.get("JOBS_WORKERS")) |v| {
            if (std.fmt.parseInt(u16, v, 10)) |n| {
                if (n != 0) cfg.jobs.workers = n;
            } else |_| {}
        }
        inline for (.{
            .{ "JOBS_POLL_INTERVAL", "poll_interval_s" },
            .{ "JOBS_TICK_INTERVAL", "tick_interval_s" },
            .{ "JOBS_RESCUE_AFTER", "rescue_after_s" },
            .{ "JOBS_RESCUE_INTERVAL", "rescue_interval_s" },
            .{ "JOBS_RETENTION_COMPLETED", "retention_completed_s" },
            .{ "JOBS_RETENTION_DISCARDED", "retention_discarded_s" },
        }) |knob| {
            if (env.get(knob[0])) |v| {
                if (std.fmt.parseInt(u32, v, 10)) |n| {
                    if (n != 0) @field(cfg.jobs, knob[1]) = n;
                } else |_| {}
            }
        }
        return cfg;
    }
};
