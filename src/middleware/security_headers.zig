//! Custom middleware example: baseline security response headers.
//!
//! A wing middleware is any struct with `pub fn run(ctx, next)`. Optional
//! `pub const provides`/`requires` declarations let the framework enforce
//! ordering at comptime. This one has no ordering needs — it just queues
//! headers via `ctx.addHeader`, which `ctx.respond` merges into every reply.
//!
//! Use this file as the template for your own middleware (auth, rate limiting,
//! request shaping, ...). Register it in the chain in app.zig.

pub const security_headers = struct {
    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        try ctx.addHeader("x-content-type-options", "nosniff");
        try ctx.addHeader("x-frame-options", "DENY");
        return next.call(ctx);
    }
};
