//! GET /docs — Scalar API reference page.
//!
//! Serves a static HTML page that fetches `/openapi.json` and renders it. Hidden
//! from the spec itself (see docs_routes.zig).

const Ctx = @import("../../state.zig").Ctx;

const scalar_html = @embedFile("../assets/scalar.html");

pub fn handle(ctx: *Ctx) anyerror!void {
    try ctx.respond(scalar_html, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}
