//! Route table for the `users` feature.
//!
//! Each feature owns a sub-router built against relative paths; the top-level
//! router (routes.zig) nests it under a prefix. This keeps feature wiring local
//! and lets the app scale by adding feature route files, not by growing one
//! giant table.

const std = @import("std");
const wing = @import("wing");

const AppState = @import("../state.zig").AppState;
const user_controller = @import("../controllers/user_controller.zig");

/// Build the users sub-router. Paths are relative; they become
/// `/api/v1/users...` once nested by the caller.
pub fn build(gpa: std.mem.Allocator) !wing.Router(AppState) {
    var r = wing.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/", user_controller.index);
    try r.post("/", user_controller.create);
    try r.get("/:id", user_controller.show);

    return r;
}
