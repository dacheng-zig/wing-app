//! GET /openapi.json — the OpenAPI 3.1 document (assembled once at startup).
//!
//! Streams the spec stored in `ApiDocs` (projected from AppState by type). No
//! generation here — that is the `openapi` package's job. Hidden from the spec
//! itself (see docs_routes.zig).

const state = @import("../../state.zig");
const Ctx = state.Ctx;
const ApiDocs = state.ApiDocs;

pub fn handle(ctx: *Ctx, docs: *ApiDocs) anyerror!void {
    try ctx.respond(docs.spec, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}
