//! Process file-descriptor budget: detect the fd limit, raise the soft limit to
//! the usable capacity, and derive the HTTP admission cap from it.
//!
//! Why this exists: talon admits up to 65536 connections by default — far above
//! the per-process fd soft limit (macOS GUI launches default to 256). DB
//! handlers block on the small mantle connection pool, so under load accepted
//! sockets pile up toward the admission cap; once concurrent fds reach
//! RLIMIT_NOFILE, `accept()` fails with EMFILE (`ProcessFdQuotaExceeded`) and
//! talon treats it as a fatal listener error, crashing the server. Capping
//! admission below the fd capacity keeps the server bounded; raising the soft
//! limit reclaims the headroom the hard limit already grants.
//!
//! The pure policy (`raiseTarget` / `maxConnections`) is split from the OS I/O
//! (`resolveMaxConnections`) so the interesting arithmetic — floor, ceiling
//! clamp, reserve, the warn threshold — is unit-tested without touching real
//! rlimits or the kernel.

const std = @import("std");
const builtin = @import("builtin");

/// talon's uncapped admission ceiling — the target when fds are plentiful.
pub const talon_default_max_connections: u32 = 65536;

/// Floor admission when the fd limit is too small to reserve headroom against.
/// Keeps the server alive and bounded rather than refusing to serve.
pub const min_max_connections: u32 = 16;

/// Below this admission cap we warn: the process fd limit is throttling HTTP
/// concurrency and the operator should raise `ulimit -n`. Dev boxes (macOS
/// default 256 fds → ~176 admission) trip this; it is advisory, not fatal.
pub const recommended_min_connections: u32 = 1024;

/// The soft limit worth raising to: the usable capacity, bounded by the hard
/// limit (how high we may raise) and the kernel per-process ceiling (raising
/// past it is meaningless). Pure.
pub fn raiseTarget(hard: u64, ceiling: u64) u64 {
    return @min(hard, ceiling);
}

/// HTTP admission cap from the effective soft limit and kernel ceiling, leaving
/// `reserve` fds for the listener, stdio, the DB pool, KILL-QUERY sidecars, and
/// log files. Pure: no I/O, no globals — fully table-testable.
pub fn maxConnections(soft: u64, ceiling: u64, reserve: u32) u32 {
    const capacity = @min(soft, ceiling);
    // Past u32 means genuinely unbounded (no kernel ceiling and an unlimited
    // hard limit, e.g. off macOS); fall back to talon's default.
    const cap = std.math.cast(u32, capacity) orelse return talon_default_max_connections;
    if (cap <= reserve) return min_max_connections; // pathologically low; keep serving.
    return @min(talon_default_max_connections, cap - reserve);
}

/// The kernel's per-process fd ceiling, enforced independently of
/// `RLIMIT_NOFILE`. On macOS the rlimit can report "unlimited" while
/// `kern.maxfilesperproc` still caps a single process, so capping admission
/// against the rlimit alone would overshoot the real limit. Returns
/// `maxInt(u64)` (no extra cap) off macOS or if the sysctl read fails.
pub fn osPerProcessFdCeiling() u64 {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            var value: c_int = 0;
            var len: usize = @sizeOf(c_int);
            if (std.c.sysctlbyname("kern.maxfilesperproc", &value, &len, null, 0) != 0) return std.math.maxInt(u64);
            if (value <= 0) return std.math.maxInt(u64);
            return @intCast(value);
        },
        else => return std.math.maxInt(u64),
    }
}

/// Detect the fd limit, raise the soft limit to the usable capacity, and return
/// the HTTP admission cap — logging what it detected and chose. Call once at
/// startup before constructing the server.
pub fn resolveMaxConnections(reserve: u32) u32 {
    var lim = std.posix.getrlimit(.NOFILE) catch |err| {
        std.log.warn("fd limit: cannot read RLIMIT_NOFILE ({t}); admitting up to {d} connections", .{ err, talon_default_max_connections });
        return talon_default_max_connections;
    };

    const ceiling = osPerProcessFdCeiling();
    const target = raiseTarget(@as(u64, lim.max), ceiling);

    // Best-effort raise of the soft limit up to that capacity — never beyond, so
    // it lands on a concrete value instead of RLIM_INFINITY, and the raise target
    // matches the cap below. The inherited soft limit is often conservatively low
    // (macOS GUI launch defaults to 256) while the hard limit leaves room; claim
    // it so concurrency isn't throttled by the launch environment.
    if (@as(u64, lim.cur) < target) {
        const before = lim.cur;
        std.posix.setrlimit(.NOFILE, .{ .cur = @intCast(target), .max = lim.max }) catch {};
        lim = std.posix.getrlimit(.NOFILE) catch lim;
        if (lim.cur > before) {
            std.log.info("fd limit: raised soft limit {f} -> {f}", .{ FdCount{ .v = before }, FdCount{ .v = lim.cur } });
        }
    }

    const max_conn = maxConnections(@as(u64, lim.cur), ceiling, reserve);

    std.log.info("fd limit: soft={f}, per-process ceiling={f}, reserved={d} -> max_connections={d}", .{
        FdCount{ .v = lim.cur },
        FdCount{ .v = ceiling },
        reserve,
        max_conn,
    });
    if (max_conn < recommended_min_connections) {
        const recommended_fds = recommended_min_connections + reserve;
        std.log.warn(
            "fd limit: HTTP concurrency capped at {d} by fd capacity {f}; " ++
                "raise it (e.g. `ulimit -n {d}`) to admit {d}+ concurrent connections",
            .{ max_conn, FdCount{ .v = @min(@as(u64, lim.cur), ceiling) }, recommended_fds, recommended_min_connections },
        );
    }
    return max_conn;
}

/// Renders an fd-limit count, printing RLIM_INFINITY-scale values as "unlimited"
/// rather than a meaningless 19-digit sentinel. Real fd counts never approach
/// u32 range, so anything past it is treated as unbounded.
const FdCount = struct {
    v: u64,
    pub fn format(self: FdCount, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.v > std.math.maxInt(u32)) return w.writeAll("unlimited");
        try w.print("{d}", .{self.v});
    }
};

const unlimited = std.math.maxInt(u64);

test "raiseTarget: bounded by hard limit and kernel ceiling" {
    // macOS GUI: hard unlimited, kernel ceiling caps it.
    try std.testing.expectEqual(@as(u64, 61440), raiseTarget(unlimited, 61440));
    // Concrete hard below the ceiling wins.
    try std.testing.expectEqual(@as(u64, 10240), raiseTarget(10240, 61440));
    // No kernel ceiling (off macOS): hard limit wins.
    try std.testing.expectEqual(@as(u64, 1048576), raiseTarget(1048576, unlimited));
    // Both unbounded.
    try std.testing.expectEqual(unlimited, raiseTarget(unlimited, unlimited));
}

test "maxConnections: reserve subtracted, capped at talon default" {
    const reserve: u32 = 80;
    // macOS default soft=256 → throttled to 176.
    try std.testing.expectEqual(@as(u32, 176), maxConnections(256, 61440, reserve));
    // Inherited soft above the kernel ceiling clamps to the ceiling.
    try std.testing.expectEqual(@as(u32, 61360), maxConnections(65536, 61440, reserve));
    // JetBrains soft=10240 (ceiling well above) → 10160.
    try std.testing.expectEqual(@as(u32, 10160), maxConnections(10240, 61440, reserve));
}

test "maxConnections: talon default caps a huge but finite capacity" {
    const reserve: u32 = 80;
    // 200k usable fds, but we never admit more than the talon default.
    try std.testing.expectEqual(talon_default_max_connections, maxConnections(200_000, unlimited, reserve));
}

test "maxConnections: unbounded capacity falls back to talon default" {
    try std.testing.expectEqual(talon_default_max_connections, maxConnections(unlimited, unlimited, 80));
}

test "maxConnections: pathologically low fd limit hits the floor" {
    // soft below reserve → floor, never refuse to serve.
    try std.testing.expectEqual(min_max_connections, maxConnections(50, unlimited, 80));
    // Exactly at reserve also floors (no headroom left).
    try std.testing.expectEqual(min_max_connections, maxConnections(80, unlimited, 80));
}
