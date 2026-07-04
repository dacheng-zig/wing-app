//! Top-level route composition.
//!
//! Assembles the application router from feature sub-routers (nested under
//! prefixes) and flat ops routes (merged at the root), then sets the fallback.
//! This is the one place that maps URL space to features.

const std = @import("std");
const wing = @import("wing");
const openapi = @import("wing_openapi");

const AppState = @import("../state.zig").AppState;
const Ctx = @import("../state.zig").Ctx;
const home = @import("../handlers/home.zig");
const health = @import("../handlers/health.zig");
const jobs_stats = @import("../handlers/jobs_stats.zig");
const user_routes = @import("../user/routes/user_routes.zig");
const auth_routes = @import("../auth/routes/auth_routes.zig");

fn notFound(ctx: *Ctx) anyerror!void {
    try ctx.respond("not found\n", .{ .status = .not_found });
}

/// The built router plus the OpenAPI document generated from it.
/// `openapi_spec` is owned by `gpa` (the server frees it); the server also
/// stores it into `AppState.api_docs` so the `/openapi.json` handler can serve
/// it.
pub const Built = struct {
    router: wing.Router(AppState),
    openapi_spec: []const u8,
};

/// Build the full application router and assemble its OpenAPI spec. Caller owns
/// both: `deinit` the router and `free` the spec.
pub fn build(gpa: std.mem.Allocator) !Built {
    // Feature sub-routers (nested under prefixes; move semantics). Unlike
    // wing.Router, the wrapper keeps heap (docs list + path arena) after a
    // move, so each must be deinitialized — hence `defer`, not `errdefer`.
    var users = try user_routes.build(gpa);
    defer users.deinit();

    var auth = try auth_routes.build(gpa);
    defer auth.deinit();

    // Flat ops routes (merged at the root).
    var ops = openapi.Router(AppState).init(gpa);
    defer ops.deinit();
    try ops.get("/health", health.handle, .{ .summary = "Health check", .tags = &.{"ops"} });
    try ops.get("/internal/jobs/stats", jobs_stats.handle, .{ .summary = "Job queue stats", .tags = &.{"ops"} });

    // Docs feature: spec endpoint + Scalar page (hidden; root-level → merged).
    var docs = try openapi.docsRoutes(AppState, gpa);
    defer docs.deinit();

    var root = openapi.Router(AppState).init(gpa);
    // The real router is moved out via `intoRouter` before return; `deinit`
    // then frees only the wrapper's bookkeeping (docs list, path arena, and
    // the empty inner left behind by the move).
    defer root.deinit();
    try root.get("/", home.handle, .{ .summary = "Home page", .tags = &.{"ops"} });
    try root.nest("/api/v1/users", &users);
    try root.nest("/api/v1/auth", &auth);
    try root.merge(&ops);
    // Merged before assembly so the hidden-route exclusion path is exercised.
    try root.merge(&docs);

    const openapi_spec = try root.openApiJson(gpa, .{
        .title = "Wing App API",
        .version = "0.0.0",
        .summary = "Layered HTTP API on the wing framework (Zig 0.16).",
        .description =
        \\Demonstrates a layered wing application: typed extractors, AppState
        \\projection, multi-scheme auth (cookie/bearer over one hashed-secret
        \\credential store) + role authorization, and MySQL via mantle.
        ,
        .contact = .{
            .name = "Dacheng Gao",
            .url = "https://github.com/dacheng-zig/wing-app",
        },
        // Auth schemes are no longer declared app-wide: each auth extractor
        // carries the scheme(s) it accepts (see auth/support/auth.zig), so the
        // generated securitySchemes/security stay in lockstep with the runtime
        // composite. Changing channels is a one-place edit there.
        // No license chosen yet — add `.license = .{ .name = "MIT", .identifier
        // = "MIT" }` (and a LICENSE file) once decided.
    });
    errdefer gpa.free(openapi_spec);

    root.fallback(notFound);
    return .{ .router = root.intoRouter(), .openapi_spec = openapi_spec };
}
