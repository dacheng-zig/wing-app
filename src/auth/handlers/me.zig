//! GET /api/v1/auth/me — the authenticated user's profile.
//!
//! `Auth` (the default cookie-or-bearer chain) is the compile-time proof this
//! route requires auth. The handler stays thin: project AppState, shape the
//! response.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const Auth = @import("../support/auth.zig").Auth;
const Id = @import("wing_id").Id;

/// Shape returned by `GET /me`. `Id` serializes as canonical UUID text
/// (see lib/wing-id).
pub const Response = struct {
    id: Id,
    name: []const u8,
    roles: []const []const u8,
};

pub fn handle(ctx: *Ctx, auth: Auth) anyerror!wing.respond.Json(Response) {
    const user = try ctx.state.users.get(ctx.arena, auth.principal.id);
    return .{ .value = .{
        .id = user.id,
        .name = user.name,
        .roles = auth.principal.roles,
    } };
}
