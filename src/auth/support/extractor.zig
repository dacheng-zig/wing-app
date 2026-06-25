//! Authentication & identity-based authorization as wing extractors.
//!
//! wing binds any handler parameter whose type has `fromRequestParts(ctx) !Self`
//! at comptime (see wing/src/extract.zig). So we make authentication — and any
//! authorization that needs *only* the `Principal` (roles/claims) — extractors.
//! A handler that declares `Auth`/`RequireRole(...)`/`Require(...)` is therefore
//! guaranteed by the type system to run authn/authz before its body; declaring
//! the wrong shape is a compile error.
//!
//! `resolvePrincipal` is the single place sessions are decoded, so stacking
//! authorization on top of authentication never re-parses the session. Errors
//! ride wing's default mapping: `error.Unauthorized` → 401, `error.Forbidden`
//! → 403.
//!
//! Object-level authorization (does this user own *this* record?) is NOT here:
//! an extractor runs before the handler with only `ctx` in hand — no loaded
//! record — so it cannot judge ownership. That lives in the service layer.

const std = @import("std");
const Principal = @import("../models/principal.zig").Principal;
const Authorizer = @import("authorizer.zig").Authorizer;

// `auth_requirement` (on the extractors below) is introspection metadata: it
// declares *that* this extractor requires authentication (and whether it is
// optional) — a fact about the extractor itself, named after that fact, not
// after any consumer. It says nothing about *which* scheme (cookie/bearer/...):
// the concrete scheme is declared once in app config (`ApiInfo.auth_scheme` in
// routes.zig), so switching mechanism is a one-place change there and these
// extractors stay untouched. A plain comptime literal any metadata consumer can
// read structurally — currently the openapi package, which imports nothing from
// here (and we import nothing from it): zero coupling, no foreign concept here.

/// The sole authentication primitive: cookie → session → `Principal`.
/// Missing/invalid session is `error.Unauthorized`; a real IO error from the
/// session/role lookup propagates unchanged (must never be swallowed as
/// "anonymous"). `ctx.state` is the app state; `sessions`/`roles` are its
/// fields (wired in state.zig).
pub fn resolvePrincipal(ctx: anytype) !Principal {
    const cookie = ctx.req.header("cookie") orelse return error.Unauthorized;
    const session_id = parseSessionId(cookie) orelse return error.Unauthorized;
    const uid = (try ctx.state.sessions.resolve(session_id)) orelse return error.Unauthorized;
    const roles = try ctx.state.roles.rolesOf(ctx.arena, uid);
    return .{ .id = uid, .roles = roles };
}

/// Extract the `session_id` value from a `Cookie` header, or `null` if absent/empty.
/// Header form: `a=b; session_id=<hex>; c=d`. Returns the first `session_id=` match (RFC 6265
/// does not order duplicates; first-match is intentional). Exported because
/// logout re-reads it to revoke the current session (the `Principal` carries no
/// session ID).
pub fn parseSessionId(cookie: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, trimmed, "session_id=")) {
            const value = trimmed["session_id=".len..];
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

/// Scenario 1 — required authentication. A handler that takes `Auth` is, by its
/// signature, an authenticated route (compile-time guaranteed).
pub const Auth = struct {
    principal: Principal,

    /// Documents this route as requiring authentication (scheme from app config).
    pub const auth_requirement = .{ .optional = false };

    pub fn fromRequestParts(ctx: anytype) !Auth {
        return .{ .principal = try resolvePrincipal(ctx) };
    }
};

/// Allows anonymous: routes that behave differently for logged-in vs. guest
/// users. Only "not authenticated" degrades to `null`; a real IO error still
/// propagates (it is not anonymity).
pub const OptionalAuth = struct {
    principal: ?Principal,

    /// Documents auth as accepted but not required (anonymous OK).
    pub const auth_requirement = .{ .optional = true };

    pub fn fromRequestParts(ctx: anytype) !OptionalAuth {
        return .{ .principal = resolvePrincipal(ctx) catch |e| switch (e) {
            error.Unauthorized => null,
            else => return e,
        } };
    }
};

/// Scenario 2 — required authentication + required role. The authorization
/// layer is thin and reuses the single authentication pass. Missing role is
/// `error.Forbidden` → 403. Convenience alias for `Require(Role(role))`.
pub fn RequireRole(comptime role: []const u8) type {
    return Require(Role(role));
}

/// Scenario 3 — required authentication + a policy predicate over the
/// `Principal` (à la ASP.NET policy-based authz). Modeling the policy as a
/// *type* rather than a string makes a typo a compile error, not a runtime
/// surprise.
///
/// `Policy` is any type with `pub fn satisfiedBy(Principal, ctx) bool`.
pub fn Require(comptime Policy: type) type {
    return struct {
        principal: Principal,

        /// Same authn requirement as `Auth`; the role/policy gate is authz on
        /// top and (v1) is not yet expressed in the spec (see security design).
        pub const auth_requirement = .{ .optional = false };

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const a = try Auth.fromRequestParts(ctx); // authn once
            if (!Policy.satisfiedBy(a.principal, ctx)) // authz: evaluate policy
                return error.Forbidden;
            return .{ .principal = a.principal };
        }
    };
}

/// The role policy, defined once. Delegates the decision to the app's
/// `Authorizer` (the replaceable authorization model, see authorizer.zig) so
/// that swapping RBAC for a role→permission table later is a one-file change
/// here, not a rewrite of every gated route. v1 `Principal` carries id+roles;
/// claim-based policies slot in unchanged once claims land.
pub fn Role(comptime r: []const u8) type {
    return struct {
        pub fn satisfiedBy(p: Principal, ctx: anytype) bool {
            return ctx.state.authorizer.can(p.roles, r);
        }
    };
}

// --- tests -----------------------------------------------------------------
//
// The extractors are generic over `ctx` (anytype), so they can be exercised
// against hand-rolled fakes — no HTTP stack and no database required. This
// covers the security-critical paths: missing/invalid session → 401, role
// gate → 403, anonymous fallthrough, and that IO errors are not masked.

const testing = std.testing;

const FakeReq = struct {
    cookie: ?[]const u8,
    fn header(self: FakeReq, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "cookie")) self.cookie else null;
    }
};

const FakeSessions = struct {
    known_session_id: []const u8 = "valid",
    uid: u64 = 42,
    io_error: bool = false,
    fn resolve(self: *FakeSessions, session_id: []const u8) !?u64 {
        if (self.io_error) return error.ConnectionLost;
        return if (std.mem.eql(u8, session_id, self.known_session_id)) self.uid else null;
    }
};

const FakeRoles = struct {
    roles: []const []const u8 = &.{},
    fn rolesOf(self: *FakeRoles, arena: std.mem.Allocator, uid: u64) ![]const []const u8 {
        _ = arena;
        _ = uid;
        return self.roles;
    }
};

const FakeState = struct {
    sessions: FakeSessions = .{},
    roles: FakeRoles = .{},
    authorizer: Authorizer = .{},
};

const FakeCtx = struct {
    req: FakeReq,
    arena: std.mem.Allocator,
    state: *FakeState,
};

fn fakeCtx(state: *FakeState, cookie: ?[]const u8) FakeCtx {
    return .{ .req = .{ .cookie = cookie }, .arena = testing.allocator, .state = state };
}

test "parseSessionId: present, surrounded, absent, empty" {
    try testing.expectEqualStrings("abc", parseSessionId("session_id=abc").?);
    try testing.expectEqualStrings("abc", parseSessionId("foo=1; session_id=abc; bar=2").?);
    try testing.expect(parseSessionId("foo=1; bar=2") == null);
    try testing.expect(parseSessionId("session_id=") == null);
}

test "Auth: no cookie -> Unauthorized" {
    var state = FakeState{};
    try testing.expectError(error.Unauthorized, Auth.fromRequestParts(fakeCtx(&state, null)));
}

test "Auth: cookie without session_id -> Unauthorized" {
    var state = FakeState{};
    try testing.expectError(error.Unauthorized, Auth.fromRequestParts(fakeCtx(&state, "other=1")));
}

test "Auth: unknown session_id -> Unauthorized" {
    var state = FakeState{};
    try testing.expectError(error.Unauthorized, Auth.fromRequestParts(fakeCtx(&state, "session_id=forged")));
}

test "Auth: valid session_id -> principal carries the right id and roles" {
    var state = FakeState{ .roles = .{ .roles = &.{"editor"} } };
    const a = try Auth.fromRequestParts(fakeCtx(&state, "session_id=valid"));
    try testing.expectEqual(@as(u64, 42), a.principal.id);
    try testing.expect(a.principal.hasRole("editor"));
}

test "Auth: a real IO error is not masked as Unauthorized" {
    var state = FakeState{ .sessions = .{ .io_error = true } };
    try testing.expectError(error.ConnectionLost, Auth.fromRequestParts(fakeCtx(&state, "session_id=valid")));
}

test "OptionalAuth: no session -> null, valid -> present, IO error -> propagates" {
    var anon = FakeState{};
    try testing.expect((try OptionalAuth.fromRequestParts(fakeCtx(&anon, null))).principal == null);

    var ok = FakeState{};
    const some = try OptionalAuth.fromRequestParts(fakeCtx(&ok, "session_id=valid"));
    try testing.expectEqual(@as(u64, 42), some.principal.?.id);

    var broken = FakeState{ .sessions = .{ .io_error = true } };
    try testing.expectError(error.ConnectionLost, OptionalAuth.fromRequestParts(fakeCtx(&broken, "session_id=valid")));
}

test "RequireRole: admin passes, non-admin Forbidden, anonymous Unauthorized" {
    var admin = FakeState{ .roles = .{ .roles = &.{ "admin", "editor" } } };
    const ok = try RequireRole("admin").fromRequestParts(fakeCtx(&admin, "session_id=valid"));
    try testing.expectEqual(@as(u64, 42), ok.principal.id);

    var plain = FakeState{ .roles = .{ .roles = &.{"editor"} } };
    try testing.expectError(error.Forbidden, RequireRole("admin").fromRequestParts(fakeCtx(&plain, "session_id=valid")));

    var anon = FakeState{};
    try testing.expectError(error.Unauthorized, RequireRole("admin").fromRequestParts(fakeCtx(&anon, null)));
}
