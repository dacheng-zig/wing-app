//! The single source of truth for this app's authentication policy.
//!
//! Everything about *which* channels authenticate and *in what order* is
//! declared here, once. Handlers keep writing `auth: Auth` (DX unchanged), but
//! the channel set behind it is now configurable, and the OpenAPI
//! `securitySchemes`/`security` derive from these same declarations — runtime
//! and docs cannot drift (see the design §6).
//!
//! Two schemes share the one `"credentials"` resolver because browser sessions
//! and API tokens are the same hashed-secret records (see credential.zig); they
//! differ only in their Locator (cookie vs bearer) and their issuing endpoint.

const scheme = @import("scheme.zig");
const locate = @import("locate.zig");

// cookie(session) and bearer(api token) both resolve through `AppState.credentials`.
const cookie_scheme = scheme.Token(locate.Cookie("session_id"), "credentials", .{
    .name = "cookieSession",
    .kind = "apiKey",
    .in = "cookie",
    .parameter_name = "session_id",
    .description = "Session cookie issued by POST /api/v1/auth/login.",
});
const bearer_scheme = scheme.Token(locate.Bearer, "credentials", .{
    .name = "bearerToken",
    .kind = "http",
    .scheme = "bearer",
    .description = "API access token issued by POST /api/v1/auth/token.",
});

/// The default chain: cookie(session) first, then bearer(api token). Adding,
/// removing, or reordering channels is a one-line change here.
pub const Default = scheme.Composite(.{ cookie_scheme, bearer_scheme });

/// App-wide extractors. Handlers declare these; switching mechanism never
/// touches a handler signature.
pub const Auth = scheme.Authenticated(Default);
pub const OptionalAuth = scheme.Optional(Default);
pub fn RequireRole(comptime r: []const u8) type {
    return scheme.Require(Default, scheme.Role(r));
}

// Per-route single-channel overrides. Endpoints that own exactly one credential
// type use these, and OpenAPI then lists only that scheme (zero extra config).
pub const CookieOnly = scheme.Authenticated(scheme.Composite(.{cookie_scheme}));
pub const BearerOnly = scheme.Authenticated(scheme.Composite(.{bearer_scheme}));

/// Credential lifetime (7 days) — shared by cookie sessions and API tokens, so
/// it lives with the auth policy rather than in any one handler. The session
/// cookie's Max-Age mirrors it; revocation is immediate regardless, so this is
/// an upper bound.
pub const credential_ttl: u64 = 7 * 24 * 60 * 60;

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "Default chain documents cookie then bearer (order preserved)" {
    try testing.expectEqual(@as(usize, 2), Auth.security_schemes.len);
    try testing.expectEqualStrings("cookieSession", Auth.security_schemes[0].name);
    try testing.expectEqualStrings("bearerToken", Auth.security_schemes[1].name);
    // Same chain drives OptionalAuth and RequireRole.
    try testing.expectEqual(@as(usize, 2), OptionalAuth.security_schemes.len);
    try testing.expectEqual(@as(usize, 2), RequireRole("admin").security_schemes.len);
}

test "per-route overrides list only their own scheme" {
    try testing.expectEqual(@as(usize, 1), CookieOnly.security_schemes.len);
    try testing.expectEqualStrings("cookieSession", CookieOnly.security_schemes[0].name);
    try testing.expectEqual(@as(usize, 1), BearerOnly.security_schemes.len);
    try testing.expectEqualStrings("bearerToken", BearerOnly.security_schemes[0].name);
}

test "extractors declare their auth requirement for OpenAPI" {
    try testing.expect(!Auth.auth_requirement.optional);
    try testing.expect(OptionalAuth.auth_requirement.optional);
    try testing.expect(!RequireRole("admin").auth_requirement.optional);
}
