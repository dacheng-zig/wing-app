//! HTTP layer for the `docs` feature: serve the generated API documentation.
//!
//! `/openapi.json` streams the spec assembled at startup (stored in `ApiDocs`,
//! projected from AppState by type); `/docs` serves a static Scalar page that
//! fetches that spec. Both set their content-type explicitly via `ctx.respond`.
//! Thin controller: no generation here — that is the `openapi` package's job.

const state = @import("../../state.zig");
const Ctx = state.Ctx;
const ApiDocs = state.ApiDocs;

const scalar_html = @embedFile("../assets/scalar.html");

/// GET /openapi.json — the OpenAPI 3.1 document (assembled once at startup).
pub fn openapiJson(ctx: *Ctx, docs: *ApiDocs) anyerror!void {
    try ctx.respond(docs.spec, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// GET /docs — Scalar API reference page.
pub fn docsPage(ctx: *Ctx) anyerror!void {
    try ctx.respond(scalar_html, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}
