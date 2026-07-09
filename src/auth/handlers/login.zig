//! POST /api/v1/auth/login — verify credentials, open a session, set the cookie.
//!
//! Public route. Bad credentials surface as 401 from the service
//! (indistinguishable from "no such user", to prevent enumeration).

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const credential_ttl = @import("../support/auth.zig").credential_ttl;
const Id = @import("wing_id").Id;

pub const Request = struct {
    username: []const u8,
    password: []const u8,
};

/// `Id` serializes as canonical UUID text (see lib/wing-id).
pub const Response = struct {
    user_id: Id,
};

pub fn handle(ctx: *Ctx, body: wing.extract.Json(Request)) anyerror!wing.respond.Json(Response) {
    const uid = try ctx.state.auth.login(ctx.arena, body.value.username, body.value.password);
    const secret = try ctx.state.credentials.issue(ctx.arena, uid, credential_ttl);
    try ctx.setCookie(sessionCookie(secret));
    return .{ .value = .{ .user_id = uid } };
}

/// A hardened session cookie. `ctx.setCookie` validates it on serialize, so a
/// malformed value errors instead of emitting a broken header. `Secure` restricts
/// it to HTTPS; over plain http (local dev) the browser will not send it back —
/// test via TLS or by setting the header manually.
fn sessionCookie(secret: []const u8) wing.Cookie {
    return .{
        .name = "session_id",
        .value = secret,
        .http_only = true,
        .secure = true,
        .same_site = .strict,
        .path = "/",
        .max_age = @intCast(credential_ttl),
    };
}
