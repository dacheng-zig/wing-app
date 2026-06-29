//! Scheme + Composite: bind the two auth axes and compose them in order.
//!
//! A Scheme is the unified primitive — any comptime type with
//! `pub fn authenticate(ctx) !?u64`:
//!   - `null`  ⟹ no identity from this scheme (credential absent, OR present
//!               but invalid — forged/expired).
//!   - `u64`   ⟹ a resolved uid.
//!   - `error` ⟹ a real IO error (resolver DB failure, ...) — never swallowed.
//!
//! `Token(Locator, resolver_field, doc)` binds axis A (a Locator, see locate.zig)
//! to axis B (a resolver field on `AppState`, see credential.zig). `Composite`
//! tries schemes in declaration order (OR semantics: missing/invalid → next,
//! first hit → stop), matching Yii2 `CompositeAuth` and ASP.NET multi-scheme.
//!
//! Each scheme also carries `pub const security_schemes: []const SecurityScheme`
//! — the OpenAPI documentation for itself — so the runtime composite and the
//! generated `securitySchemes`/`security` derive from the same declaration and
//! cannot drift (see the design §6).
//!
//! The extractors (`Authenticated`/`Optional`/`Require`) wrap a composite into a
//! compile-time-safe wing extractor and resolve roles once, after authentication
//! and independent of which scheme matched (the role-resolution invariant from
//! the original extractor.zig is preserved).

const std = @import("std");
const Principal = @import("../models/principal.zig").Principal;
const SecurityScheme = @import("../../openapi/meta.zig").SecurityScheme;

/// Token-class scheme = a Locator × a resolver field. `doc` is this scheme's
/// OpenAPI `SecurityScheme`, declared beside the runtime binding so the two stay
/// in lockstep.
pub fn Token(
    comptime Locator: type,
    comptime resolver_field: []const u8,
    comptime doc: SecurityScheme,
) type {
    return struct {
        pub const security_schemes: []const SecurityScheme = &.{doc};

        pub fn authenticate(ctx: anytype) !?u64 {
            const token = Locator.locate(ctx) orelse return null; // absent → next scheme
            const resolver = &@field(ctx.state, resolver_field);
            return resolver.resolve(token); // !?u64: unknown/expired → null, IO → propagate
        }
    };
}

/// Try each scheme in declaration order: missing/invalid → next, first hit →
/// stop, all empty → null. An empty set is a compile error (it would otherwise
/// authenticate nothing and silently 401 every request).
pub fn Composite(comptime schemes: anytype) type {
    if (schemes.len == 0) @compileError("Composite needs at least one scheme");
    return struct {
        pub const security_schemes: []const SecurityScheme = concatDocs(schemes);

        pub fn authenticate(ctx: anytype) !?u64 {
            inline for (schemes) |S| {
                if (try S.authenticate(ctx)) |uid| return uid; // hit → stop; IO already propagated by try
            }
            return null;
        }
    };
}

/// Concatenate every scheme's `security_schemes` into one comptime list (for the
/// OpenAPI OR array). Duplicates, if any, are deduped later by name at registration.
fn concatDocs(comptime schemes: anytype) []const SecurityScheme {
    comptime {
        var out: []const SecurityScheme = &.{};
        for (schemes) |S| out = out ++ S.security_schemes;
        return out;
    }
}

/// Required authentication. A handler taking `Authenticated(C)` is, by its
/// signature, an authenticated route (compile-time guaranteed). Roles are
/// resolved once here, after the composite picks a uid — scheme-independent.
pub fn Authenticated(comptime C: type) type {
    return struct {
        principal: Principal,

        pub const auth_requirement = .{ .optional = false };
        pub const security_schemes = C.security_schemes; // travel to OpenAPI

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const uid = (try C.authenticate(ctx)) orelse return error.Unauthorized;
            const roles = try ctx.state.roles.rolesOf(ctx.arena, uid);
            return .{ .principal = .{ .id = uid, .roles = roles } };
        }
    };
}

/// Allows anonymous: only "no identity" degrades to `null`; a real IO error
/// still propagates (it is not anonymity). present-but-invalid resolves to `null`
/// inside the composite and so falls through to anonymous, by OR semantics.
pub fn Optional(comptime C: type) type {
    return struct {
        principal: ?Principal,

        pub const auth_requirement = .{ .optional = true };
        pub const security_schemes = C.security_schemes;

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const uid = (try C.authenticate(ctx)) orelse return .{ .principal = null };
            const roles = try ctx.state.roles.rolesOf(ctx.arena, uid);
            return .{ .principal = .{ .id = uid, .roles = roles } };
        }
    };
}

/// Required authentication + a policy predicate over the `Principal`. The
/// authorization layer is thin and reuses the single authentication pass; a
/// failed policy is `error.Forbidden` → 403. `Policy` is any type with
/// `pub fn satisfiedBy(Principal, ctx) bool`.
pub fn Require(comptime C: type, comptime Policy: type) type {
    return struct {
        principal: Principal,

        pub const auth_requirement = .{ .optional = false };
        pub const security_schemes = C.security_schemes;

        pub fn fromRequestParts(ctx: anytype) !@This() {
            const a = try Authenticated(C).fromRequestParts(ctx); // authn once
            if (!Policy.satisfiedBy(a.principal, ctx)) return error.Forbidden; // authz
            return .{ .principal = a.principal };
        }
    };
}

/// The role policy, defined once. Delegates to the app's `Authorizer` (the
/// replaceable authorization model) so swapping RBAC for a role→permission table
/// later is a one-file change there, not a rewrite of every gated route.
pub fn Role(comptime r: []const u8) type {
    return struct {
        pub fn satisfiedBy(p: Principal, ctx: anytype) bool {
            return ctx.state.authorizer.can(p.roles, r);
        }
    };
}

// --- tests -----------------------------------------------------------------
//
// Schemes/composites/extractors are generic over `ctx`, so hand-rolled fakes
// drive them without HTTP/DB. Locators come from locate.zig; the resolver is a
// fake `credentials` field on a fake state.

const testing = std.testing;
const locate = @import("locate.zig");
const Authorizer = @import("authorizer.zig").Authorizer;

const FakeReq = struct {
    headers: []const [2][]const u8 = &.{},
    pub fn header(self: FakeReq, name: []const u8) ?[]const u8 {
        for (self.headers) |kv| if (std.ascii.eqlIgnoreCase(kv[0], name)) return kv[1];
        return null;
    }
};

/// Fake resolver: knows one secret → uid; counts how many times it was consulted
/// (to assert short-circuit). `io_error` simulates a real DB failure.
const FakeResolver = struct {
    known: []const u8 = "good",
    uid: u64 = 1,
    io_error: bool = false,
    calls: usize = 0,
    fn resolve(self: *FakeResolver, token: []const u8) !?u64 {
        self.calls += 1;
        if (self.io_error) return error.ConnectionLost;
        return if (std.mem.eql(u8, token, self.known)) self.uid else null;
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
    credentials: FakeResolver = .{},
    roles: FakeRoles = .{},
    authorizer: Authorizer = .{},
};

const FakeCtx = struct {
    req: FakeReq,
    arena: std.mem.Allocator,
    state: *FakeState,
};

fn ctxWith(state: *FakeState, headers: []const [2][]const u8) FakeCtx {
    return .{ .req = .{ .headers = headers }, .arena = testing.allocator, .state = state };
}

const cookie_scheme = Token(locate.Cookie("session_id"), "credentials", .{ .name = "cookieSession", .kind = "apiKey", .in = "cookie", .parameter_name = "session_id" });
const bearer_scheme = Token(locate.Bearer, "credentials", .{ .name = "bearerToken", .kind = "http", .scheme = "bearer" });

test "Token: absent → null, invalid → null, hit → uid, IO → propagate" {
    var st = FakeState{ .credentials = .{ .known = "good", .uid = 7 } };
    try testing.expectEqual(@as(?u64, null), try cookie_scheme.authenticate(ctxWith(&st, &.{})));
    try testing.expectEqual(@as(?u64, null), try cookie_scheme.authenticate(ctxWith(&st, &.{.{ "cookie", "session_id=bad" }})));
    try testing.expectEqual(@as(?u64, 7), try cookie_scheme.authenticate(ctxWith(&st, &.{.{ "cookie", "session_id=good" }})));

    var broken = FakeState{ .credentials = .{ .io_error = true } };
    try testing.expectError(error.ConnectionLost, cookie_scheme.authenticate(ctxWith(&broken, &.{.{ "cookie", "session_id=good" }})));
}

test "Composite: order, fall-through on absent/invalid, short-circuit on hit" {
    const C = Composite(.{ cookie_scheme, bearer_scheme });

    // cookie absent → bearer consulted and hits.
    var st1 = FakeState{ .credentials = .{ .known = "good", .uid = 5 } };
    try testing.expectEqual(@as(?u64, 5), try C.authenticate(ctxWith(&st1, &.{.{ "authorization", "Bearer good" }})));

    // cookie present-but-invalid → falls through to a valid bearer.
    var st2 = FakeState{ .credentials = .{ .known = "good", .uid = 5 } };
    try testing.expectEqual(@as(?u64, 5), try C.authenticate(ctxWith(&st2, &.{ .{ "cookie", "session_id=bad" }, .{ "authorization", "Bearer good" } })));

    // both absent → null.
    var st3 = FakeState{};
    try testing.expectEqual(@as(?u64, null), try C.authenticate(ctxWith(&st3, &.{})));
}

test "Composite: a hit on the first scheme stops (resolver consulted once per request)" {
    // Both schemes share one resolver. Cookie hits first, so the resolver must be
    // consulted exactly once — a second call would mean bearer was tried too.
    var st = FakeState{ .credentials = .{ .known = "good", .uid = 9 } };
    const C = Composite(.{ cookie_scheme, bearer_scheme });
    const uid = try C.authenticate(ctxWith(&st, &.{ .{ "cookie", "session_id=good" }, .{ "authorization", "Bearer good" } }));
    try testing.expectEqual(@as(?u64, 9), uid);
    try testing.expectEqual(@as(usize, 1), st.credentials.calls); // short-circuited before bearer
}

test "Composite: any IO error propagates immediately" {
    var st = FakeState{ .credentials = .{ .io_error = true } };
    const C = Composite(.{ cookie_scheme, bearer_scheme });
    try testing.expectError(error.ConnectionLost, C.authenticate(ctxWith(&st, &.{.{ "cookie", "session_id=good" }})));
}

test "Composite: aggregated security_schemes lists both schemes" {
    const C = Composite(.{ cookie_scheme, bearer_scheme });
    try testing.expectEqual(@as(usize, 2), C.security_schemes.len);
    try testing.expectEqualStrings("cookieSession", C.security_schemes[0].name);
    try testing.expectEqualStrings("bearerToken", C.security_schemes[1].name);
}

test "Authenticated: no credential → 401, hit → principal with id+roles" {
    const C = Composite(.{ cookie_scheme, bearer_scheme });
    const Ext = Authenticated(C);

    var anon = FakeState{};
    try testing.expectError(error.Unauthorized, Ext.fromRequestParts(ctxWith(&anon, &.{})));

    var ok = FakeState{ .credentials = .{ .known = "good", .uid = 42 }, .roles = .{ .roles = &.{"editor"} } };
    const a = try Ext.fromRequestParts(ctxWith(&ok, &.{.{ "authorization", "Bearer good" }}));
    try testing.expectEqual(@as(u64, 42), a.principal.id);
    try testing.expect(a.principal.hasRole("editor"));
}

test "Optional: anonymous when absent, present when valid, IO propagates" {
    const Ext = Optional(Composite(.{cookie_scheme}));

    var anon = FakeState{};
    try testing.expect((try Ext.fromRequestParts(ctxWith(&anon, &.{}))).principal == null);

    var ok = FakeState{ .credentials = .{ .known = "good", .uid = 3 } };
    const some = try Ext.fromRequestParts(ctxWith(&ok, &.{.{ "cookie", "session_id=good" }}));
    try testing.expectEqual(@as(u64, 3), some.principal.?.id);

    var broken = FakeState{ .credentials = .{ .io_error = true } };
    try testing.expectError(error.ConnectionLost, Ext.fromRequestParts(ctxWith(&broken, &.{.{ "cookie", "session_id=good" }})));
}

test "Require(Role): admin passes, non-admin 403, anonymous 401" {
    const Ext = Require(Composite(.{cookie_scheme}), Role("admin"));

    var admin = FakeState{ .credentials = .{ .known = "good", .uid = 1 }, .roles = .{ .roles = &.{ "admin", "editor" } } };
    const ok = try Ext.fromRequestParts(ctxWith(&admin, &.{.{ "cookie", "session_id=good" }}));
    try testing.expectEqual(@as(u64, 1), ok.principal.id);

    var plain = FakeState{ .credentials = .{ .known = "good", .uid = 1 }, .roles = .{ .roles = &.{"editor"} } };
    try testing.expectError(error.Forbidden, Ext.fromRequestParts(ctxWith(&plain, &.{.{ "cookie", "session_id=good" }})));

    var anon = FakeState{};
    try testing.expectError(error.Unauthorized, Ext.fromRequestParts(ctxWith(&anon, &.{})));
}

test "CookieOnly vs BearerOnly: each accepts only its own channel" {
    const CookieOnly = Authenticated(Composite(.{cookie_scheme}));
    const BearerOnly = Authenticated(Composite(.{bearer_scheme}));

    var st = FakeState{ .credentials = .{ .known = "good", .uid = 8 } };
    // CookieOnly ignores a bearer credential.
    try testing.expectError(error.Unauthorized, CookieOnly.fromRequestParts(ctxWith(&st, &.{.{ "authorization", "Bearer good" }})));
    // BearerOnly ignores a cookie credential.
    try testing.expectError(error.Unauthorized, BearerOnly.fromRequestParts(ctxWith(&st, &.{.{ "cookie", "session_id=good" }})));
    // Each accepts its own.
    try testing.expectEqual(@as(u64, 8), (try CookieOnly.fromRequestParts(ctxWith(&st, &.{.{ "cookie", "session_id=good" }}))).principal.id);
    try testing.expectEqual(@as(u64, 8), (try BearerOnly.fromRequestParts(ctxWith(&st, &.{.{ "authorization", "Bearer good" }}))).principal.id);
}
