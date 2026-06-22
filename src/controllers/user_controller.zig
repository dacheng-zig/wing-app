//! HTTP layer for the `users` feature.
//!
//! Controllers are thin: bind request data with wing extractors, call the
//! service, shape the response. No business rules and no storage here — those
//! belong to the service and repository. `*UserService` is projected from
//! AppState by type (see state.zig).

const std = @import("std");
const wing = @import("wing");

const Ctx = @import("../state.zig").Ctx;
const UserService = @import("../services/user_service.zig").UserService;
const models = @import("../models/user.zig");
const User = models.User;
const CreateUserReq = models.CreateUserReq;

/// GET /api/v1/users
pub fn index(ctx: *Ctx, svc: *UserService) anyerror!wing.Json([]User) {
    const users = try svc.list(ctx.arena);
    return .{ .value = users };
}

/// GET /api/v1/users/:id
pub fn show(
    ctx: *Ctx,
    svc: *UserService,
    path: wing.Path(struct { id: u64 }),
) anyerror!wing.Json(User) {
    const user = try svc.get(ctx.arena, path.value.id);
    return .{ .value = user };
}

/// POST /api/v1/users
pub fn create(
    ctx: *Ctx,
    svc: *UserService,
    body: wing.Json(CreateUserReq),
) anyerror!wing.Created(User) {
    const user = try svc.register(ctx.arena, body.value.name);
    return .{
        .value = user,
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{d}", .{user.id}),
    };
}
