//! POST /api/v1/auth/logout — revoke the current session and clear the cookie.
//!
//! `CookieOnly`: this endpoint owns the cookie credential, so the revoked object
//! is unambiguous. The `Principal` carries no secret, so we re-read it from the
//! cookie to revoke the exact row.

const wing = @import("wing");

const Ctx = @import("../../state.zig").Ctx;
const locate = @import("../support/locate.zig");
const CookieOnly = @import("../support/auth.zig").CookieOnly;

pub fn handle(ctx: *Ctx, auth: CookieOnly) anyerror!void {
    _ = auth; // presence enforces "must be authenticated via cookie"
    if (locate.Cookie("session_id").locate(ctx)) |secret| try ctx.state.credentials.revoke(secret);
    try ctx.setCookie(expiredCookie());
}

/// An immediately-expiring cookie to clear the session on logout. `Path=/` must
/// match the original so the UA actually removes it.
fn expiredCookie() wing.Cookie {
    var c = wing.Cookie.removal("session_id");
    c.path = "/";
    return c;
}
