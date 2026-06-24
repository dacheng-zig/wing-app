//! Route table for the `auth` feature.
//!
//! Relative paths, nested under `/api/v1/auth` by the top-level router. Login is
//! public; logout and me are protected by the `Auth` extractor on their
//! handlers (not by the route table) — see auth_controller.zig.

const std = @import("std");
const openapi = @import("../../openapi/root.zig");

const AppState = @import("../../state.zig").AppState;
const auth_controller = @import("../controllers/auth_controller.zig");

/// Build the auth sub-router. Paths become `/api/v1/auth...` once nested.
pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.post("/login", auth_controller.login, .{ .summary = "Log in", .tags = &.{"auth"} });
    try r.post("/logout", auth_controller.logout, .{ .summary = "Log out", .tags = &.{"auth"} });
    try r.get("/me", auth_controller.me, .{ .summary = "Current user", .tags = &.{"auth"} });

    return r;
}
