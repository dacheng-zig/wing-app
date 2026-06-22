//! Top-level route composition.
//!
//! Assembles the application router from feature sub-routers (nested under
//! prefixes) and flat ops routes (merged at the root), then sets the fallback.
//! This is the one place that maps URL space to features.

const std = @import("std");
const wing = @import("wing");

const AppState = @import("../state.zig").AppState;
const Ctx = @import("../state.zig").Ctx;
const home_controller = @import("../controllers/home_controller.zig");
const health_controller = @import("../controllers/health_controller.zig");
const user_routes = @import("user_routes.zig");

fn notFound(ctx: *Ctx) anyerror!void {
    try ctx.respond("not found\n", .{ .status = .not_found });
}

/// Build the full application router. Caller owns it and must `deinit`.
pub fn build(gpa: std.mem.Allocator) !wing.Router(AppState) {
    // Feature sub-router (nested under a prefix; move semantics).
    var users = try user_routes.build(gpa);
    errdefer users.deinit();

    // Flat ops routes (merged at the root).
    var ops = wing.Router(AppState).init(gpa);
    errdefer ops.deinit();
    try ops.get("/health", health_controller.check);

    var root = wing.Router(AppState).init(gpa);
    errdefer root.deinit();
    try root.get("/", home_controller.index);
    try root.nest("/api/v1/users", &users);
    try root.merge(&ops);
    root.fallback(notFound);

    return root;
}
