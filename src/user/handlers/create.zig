//! POST /api/v1/users — register a user.
//!
//! Thin handler: owns its request body and unpacks it into primitives for the
//! HTTP-agnostic service (which hashes and validates). `error.InvalidCredentials`
//! maps to 400 in app.zig.

const std = @import("std");
const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const UserService = @import("../services/user_service.zig").UserService;
const User = @import("../models/user.zig").User;
const id_mod = @import("wing_id");

pub const Request = struct {
    name: []const u8,
    username: []const u8,
    password: []const u8,
};

pub fn handle(ctx: *Ctx, svc: *UserService, body: wing.Json(Request)) anyerror!wing.Created(User) {
    const user = try svc.register(ctx.arena, body.value.name, body.value.username, body.value.password);
    const id_text = id_mod.toText(user.id);
    return .{
        .value = user,
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{s}", .{&id_text}),
    };
}
