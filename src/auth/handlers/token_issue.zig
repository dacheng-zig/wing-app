//! POST /api/v1/auth/token/issue — verify credentials, issue an API token,
//! return it in the body (no cookie).
//!
//! Same request shape as `/login` (re-declared so each handler owns its
//! contract), anti-enumeration 401, and `credential_ttl` expiry; revoke early
//! via `/token/revoke`. The plaintext secret is returned only here, never
//! stored server-side.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const credential_ttl = @import("../support/auth.zig").credential_ttl;

pub const Request = struct {
    username: []const u8,
    password: []const u8,
};

pub const Response = struct {
    token: []const u8,
};

pub fn handle(ctx: *Ctx, body: wing.Json(Request)) anyerror!wing.Json(Response) {
    const uid = try ctx.state.auth.login(ctx.arena, body.value.username, body.value.password);
    const secret = try ctx.state.credentials.issue(ctx.arena, uid, credential_ttl);
    return .{ .value = .{ .token = secret } };
}
