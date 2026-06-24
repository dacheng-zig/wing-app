//! Route table for the `users` feature.
//!
//! Each feature owns a sub-router built against relative paths; the top-level
//! router (routes.zig) nests it under a prefix. This keeps feature wiring local
//! and lets the app scale by adding feature route files, not by growing one
//! giant table.

const std = @import("std");
const openapi = @import("../../openapi/root.zig");

const AppState = @import("../../state.zig").AppState;
const user_controller = @import("../controllers/user_controller.zig");

/// Build the users sub-router. Paths are relative; they become
/// `/api/v1/users...` once nested by the caller. The trailing `Meta` documents
/// each route; schema is derived from the handler signature regardless.
pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/", user_controller.index, .{ .summary = "List users", .tags = &.{"users"} });
    try r.post("/", user_controller.create, .{ .summary = "Create user", .tags = &.{"users"} });
    try r.get("/:id", user_controller.show, .{ .summary = "Get user by id", .tags = &.{"users"} });

    return r;
}
