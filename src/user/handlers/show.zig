//! GET /api/v1/users/:id — fetch one user by id.
//!
//! The path-parameter shape is a pure HTTP concern, so this handler owns it.
//! `Id` parses in the binder via its `fromScalar` convention: a malformed id
//! is 400 (`error.InvalidPathParam`), an unknown one 404 (`error.NotFound`
//! from the service) — both via wing's defaults.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const UserService = @import("../services/user_service.zig").UserService;
const User = @import("../models/user.zig").User;
const Id = @import("wing_id").Id;

pub const Params = struct { id: Id };

pub fn handle(ctx: *Ctx, svc: *UserService, path: wing.extract.Path(Params)) anyerror!wing.respond.Json(User) {
    return .{ .value = try svc.get(ctx.arena, path.value.id) };
}
