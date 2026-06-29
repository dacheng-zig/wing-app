//! Route table for the `auth` feature.
//!
//! Relative paths, nested under `/api/v1/auth` by the top-level router.
//! login/token-issue are public; logout/token-revoke/me are protected by the
//! auth extractor on their handlers (not by the route table) — each handler
//! owns one credential channel (CookieOnly / BearerOnly / default) and its own
//! request/response shape. One file per endpoint under `../handlers`.

const std = @import("std");
const openapi = @import("../../openapi/root.zig");

const AppState = @import("../../state.zig").AppState;
const me = @import("../handlers/me.zig");
const login = @import("../handlers/login.zig");
const logout = @import("../handlers/logout.zig");
const token_issue = @import("../handlers/token_issue.zig");
const token_revoke = @import("../handlers/token_revoke.zig");

/// Build the auth sub-router. Paths become `/api/v1/auth...` once nested.
pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/me", me.handle, .{ .summary = "Current user", .tags = &.{"auth"} });
    try r.post("/token/issue", token_issue.handle, .{ .summary = "Issue an API token", .tags = &.{"auth"} });
    try r.post("/token/revoke", token_revoke.handle, .{ .summary = "Revoke an API token", .tags = &.{"auth"} });
    try r.post("/login", login.handle, .{ .summary = "Log in (cookie session)", .tags = &.{"auth"} });
    try r.post("/logout", logout.handle, .{ .summary = "Log out (revoke session)", .tags = &.{"auth"} });

    return r;
}
