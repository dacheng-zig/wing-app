//! Serve layer: `/openapi.json` + `/docs` (Scalar page) as a hidden sub-router.
//!
//! Generic over the app's `State`: the app embeds an `ApiDocs` field (distinct
//! type, so wing's by-type projection stays unambiguous), fills `spec` after
//! assembly, and merges `docsRoutes(State, gpa)` at the root. All three routes
//! are `hidden` — real routes, but excluded from the generated spec (they
//! document the generator, not the API); merging them before assembly
//! exercises the exclusion path.
//!
//! The Scalar UI script is vendored (not CDN-loaded): `/docs` needs no network
//! access. Pinned to `@scalar/api-reference@1.62.4` (MIT), fetched from
//! `https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.62.4`. To update: bump
//! the version in that URL, download the new `.js`, run `gzip -9 -k -c
//! scalar-api-reference.js > scalar-api-reference.js.gz`, and replace the
//! committed `.gz` (the plain `.js` is not tracked — it's only a throwaway
//! intermediate for regenerating the `.gz`).
//!
//! The script is embedded pre-compressed (gzip -9, ~3.5 MiB -> ~1 MiB) and
//! served as-is with `Content-Encoding: gzip`; every browser requesting a
//! `<script src>` decompresses it transparently, so this costs nothing at
//! request time while shrinking both the embed and the shipped binary.

const std = @import("std");
const wing = @import("wing");
const router = @import("router.zig");

/// Wraps the assembled spec bytes so they project unambiguously by type
/// (a bare `[]const u8` field would collide with any future string field).
/// The bytes are owned by the app (app lifetime); filled after startup.
pub const ApiDocs = struct {
    spec: []const u8 = "",
};

const scalar_html = @embedFile("assets/scalar.html");
const scalar_js_gz = @embedFile("assets/scalar-api-reference.js.gz");

/// Build the docs sub-router. Paths are absolute (root-level), so the caller
/// `merge`s rather than `nest`s.
pub fn docsRoutes(comptime State: type, gpa: std.mem.Allocator) !router.Router(State) {
    const Ctx = wing.Context(State);
    const handlers = struct {
        fn openapiJson(ctx: *Ctx, docs: *ApiDocs) anyerror!void {
            try ctx.respond(docs.spec, .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        }

        fn scalarPage(ctx: *Ctx) anyerror!void {
            try ctx.respond(scalar_html, .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            });
        }

        fn scalarScript(ctx: *Ctx) anyerror!void {
            try ctx.respond(scalar_js_gz, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/javascript; charset=utf-8" },
                    .{ .name = "content-encoding", .value = "gzip" },
                },
            });
        }
    };

    var r = router.Router(State).init(gpa);
    errdefer r.deinit();

    try r.get("/openapi.json", handlers.openapiJson, .{ .hidden = true });
    try r.get("/docs", handlers.scalarPage, .{ .hidden = true });
    try r.get("/docs/scalar.js", handlers.scalarScript, .{ .hidden = true });

    return r;
}
