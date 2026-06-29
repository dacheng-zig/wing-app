//! GET /api/v1/users/:id — fetch one user by id.
//!
//! The path-parameter shape is a pure HTTP concern, so this handler owns it.
//! `error.NotFound` from the service maps to 404 via wing's defaults.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const UserService = @import("../services/user_service.zig").UserService;
const User = @import("../models/user.zig").User;

pub const Params = struct { id: u64 };

pub fn handle(ctx: *Ctx, svc: *UserService, path: wing.Path(Params)) anyerror!wing.Json(User) {
    const user = try svc.get(ctx.arena, path.value.id);
    return .{ .value = user };
}
