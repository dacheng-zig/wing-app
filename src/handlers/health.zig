//! GET /health — liveness/readiness probe.
//!
//! Operational endpoint, kept separate from feature handlers because it serves
//! monitoring probes, not a business use case.

const Ctx = @import("../state.zig").Ctx;

pub fn handle(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "ok\n";
}
