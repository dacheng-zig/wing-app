//! HTTP layer for the `auth` feature: login, logout, and the current user.
//!
//! Controllers stay thin: bind the request, call the service/store, shape the
//! response and cookie. `login` is public (it declares no auth extractor);
//! `logout` and `me` declare `Auth`, so the type system guarantees they only
//! run for an authenticated request.

const std = @import("std");
const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const extractor = @import("../support/extractor.zig");
const Auth = extractor.Auth;

/// Session cookie max-age, mirroring the store's TTL (7 days).
const cookie_max_age: u64 = 7 * 24 * 60 * 60;

pub const LoginReq = struct {
    username: []const u8,
    password: []const u8,
};

pub const LoginResp = struct {
    user_id: u64,
};

/// Shape returned by `GET /me`.
pub const Profile = struct {
    id: u64,
    name: []const u8,
    roles: []const []const u8,
};

/// POST /api/v1/auth/login — verify credentials, open a session, set the cookie.
/// Public route: takes no auth extractor. Bad credentials surface as 401 from
/// the service (indistinguishable from "no such user").
pub fn login(ctx: *Ctx, body: wing.Json(LoginReq)) anyerror!wing.Json(LoginResp) {
    const uid = try ctx.state.auth.login(ctx.arena, body.value.username, body.value.password);
    const session_id = try ctx.state.sessions.create(ctx.arena, uid);
    try ctx.addHeader("set-cookie", try sessionCookie(ctx.arena, session_id));
    return .{ .value = .{ .user_id = uid } };
}

/// POST /api/v1/auth/logout — revoke the current session and clear the cookie.
/// Requires authentication (`Auth`). The `Principal` carries no session ID, so
/// we re-read it from the cookie to revoke the exact session.
pub fn logout(ctx: *Ctx, auth: Auth) anyerror!void {
    _ = auth; // presence enforces "must be authenticated"; id is not needed here
    if (ctx.req.header("cookie")) |cookie| {
        if (extractor.parseSessionId(cookie)) |session_id| try ctx.state.sessions.revoke(session_id);
    }
    try ctx.addHeader("set-cookie", expiredCookie());
}

/// GET /api/v1/auth/me — the authenticated user's profile. `Auth` in the
/// signature is the compile-time proof this route requires authentication.
pub fn me(ctx: *Ctx, auth: Auth) anyerror!wing.Json(Profile) {
    const user = try ctx.state.users.get(ctx.arena, auth.principal.id);
    return .{ .value = .{
        .id = user.id,
        .name = user.name,
        .roles = auth.principal.roles,
    } };
}

/// Build a hardened session cookie. `Secure` restricts it to HTTPS; over plain
/// http (local dev) the browser will not send it back — test via TLS or by
/// setting the header manually.
fn sessionCookie(arena: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "session_id={s}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age={d}",
        .{ session_id, cookie_max_age },
    );
}

/// An immediately-expiring cookie, to clear the session on logout.
fn expiredCookie() []const u8 {
    return "session_id=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0";
}
