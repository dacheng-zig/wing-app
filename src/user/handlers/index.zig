//! GET /api/v1/users — list all users.
//!
//! Thin handler: project `*UserService` from AppState by type, call the
//! service, shape the response. No business rules or storage here.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const UserService = @import("../services/user_service.zig").UserService;
const User = @import("../models/user.zig").User;

pub fn handle(ctx: *Ctx, svc: *UserService) anyerror!wing.Json([]User) {
    const users = try svc.list(ctx.arena);
    return .{ .value = users };
}
