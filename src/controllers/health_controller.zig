//! Operational endpoints (liveness/readiness probes, etc.).
//!
//! Kept separate from feature controllers because these serve ops/monitoring,
//! not business use cases.

const Ctx = @import("../state.zig").Ctx;

/// GET /health
pub fn check(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "ok\n";
}
