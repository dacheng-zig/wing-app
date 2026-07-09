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
const Database = @import("../../db/database.zig").Database;
const job_registry = @import("../../jobs/registry.zig");

const log = std.log.scoped(.users);

pub const Request = struct {
    name: []const u8,
    username: []const u8,
    password: []const u8,
};

pub fn handle(ctx: *Ctx, svc: *UserService, db: *Database, body: wing.extract.Json(Request)) anyerror!wing.respond.Created(User) {
    const user = try svc.register(ctx.arena, body.value.name, body.value.username, body.value.password);
    const id_text = user.id.toText();

    // Hand the slow part (email) to the job queue; the response doesn't wait.
    // Fire-and-forget: a failed enqueue logs but doesn't undo a successful
    // registration. (When enqueue must be atomic with business writes, run
    // both in one transaction via `JobRegistry.insertTx`.)
    _ = job_registry.JobRegistry.insert(
        db.gpa, // long-lived: insert scratch feeds the connection's statement cache
        db.pool,
        job_registry.SendWelcomeEmail{ .user_id = user.id, .name = user.name },
        .{},
    ) catch |err| log.warn("welcome email enqueue failed for user {s}: {s}", .{ &id_text, @errorName(err) });

    return .{
        .value = user,
        .location = try std.fmt.allocPrint(ctx.arena, "/api/v1/users/{s}", .{&id_text}),
    };
}
