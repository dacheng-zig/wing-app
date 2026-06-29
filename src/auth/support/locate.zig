//! Axis A — Locators: pull the raw credential out of a request.
//!
//! A Locator is any comptime type with `pub fn locate(ctx) ?[]const u8`. It
//! returns `null` when this channel carries no credential (absent/empty) and the
//! raw credential string otherwise. Locators do no IO and no identity
//! resolution — that is axis B (the resolver, see credential.zig). They are pure
//! slices except the query channel, which delegates decoding to `wing.Query`
//! (its percent/`+` decode lands in `ctx.arena`).
//!
//! Channel exposure differs (see the design §10): cookie (`HttpOnly`+`Secure`+
//! `SameSite`) is safest; bearer/header need TLS; query tokens leak into access
//! logs / browser history / Referer, so the query channel is opt-in per route
//! and never in the default chain.

const std = @import("std");
const wing = @import("wing");

/// Cookie channel: read the value of cookie `name` via `wing.CookieView` (first
/// match, auto-trimmed, zero-copy). An empty value counts as absent.
pub fn Cookie(comptime name: []const u8) type {
    return struct {
        pub fn locate(ctx: anytype) ?[]const u8 {
            const header = ctx.req.header("cookie") orelse return null;
            const v = wing.CookieView.init(header).get(name) orelse return null;
            return if (v.len == 0) null else v;
        }
    };
}

/// Bearer channel: `Authorization: Bearer <token>`. The scheme name is matched
/// case-insensitively (RFC 7235); a single space separates it from the token.
pub const Bearer = struct {
    pub fn locate(ctx: anytype) ?[]const u8 {
        return schemeToken(ctx.req.header("authorization"), "Bearer");
    }
};

/// Query channel: reuse `wing.Query` to parse the query string and read the
/// parameter named `name`. The single-field struct declares `?[]const u8`, so a
/// missing parameter parses to `null` rather than erroring; any parse failure
/// (e.g. OOM) degrades to "no credential" (`null`) — there is no real IO here,
/// only the request head and the arena.
pub fn Query(comptime name: []const u8) type {
    return struct {
        // A one-field struct `{ <name>: ?[]const u8 }`, built at comptime so the
        // query parameter name is configurable (and matches the OpenAPI scheme's
        // parameter_name). `@Struct` is the Zig 0.16 replacement for `@Type`.
        const Q = @Struct(.auto, null, &.{name}, &.{?[]const u8}, &.{.{}});
        pub fn locate(ctx: anytype) ?[]const u8 {
            const parsed = wing.Query(Q).fromRequestParts(ctx) catch return null;
            const v = @field(parsed.value, name) orelse return null;
            return if (v.len == 0) null else v;
        }
    };
}

/// Custom-header channel: the verbatim value of header `name` (e.g. X-Api-Key).
/// `ctx.req.header` is case-insensitive. An empty value counts as absent.
pub fn Header(comptime name: []const u8) type {
    return struct {
        pub fn locate(ctx: anytype) ?[]const u8 {
            const v = ctx.req.header(name) orelse return null;
            return if (v.len == 0) null else v;
        }
    };
}

/// Parse an `Authorization`-style header value of the form `<scheme> <token>`:
/// the scheme name matched case-insensitively, exactly one space, a non-empty
/// token. Returns `null` on any mismatch. Pure slicing, no allocation. wing has
/// no Authorization helper and the grammar is trivial, so this stays local.
fn schemeToken(header: ?[]const u8, comptime scheme: []const u8) ?[]const u8 {
    const h = header orelse return null;
    if (h.len < scheme.len + 1) return null;
    if (!std.ascii.eqlIgnoreCase(h[0..scheme.len], scheme)) return null;
    if (h[scheme.len] != ' ') return null;
    const token = h[scheme.len + 1 ..];
    return if (token.len == 0) null else token;
}

// --- tests -----------------------------------------------------------------
//
// Locators are generic over `ctx`, so a hand-rolled fake request exercises every
// channel without an HTTP stack. The query fake supplies a raw `target()`.

const testing = std.testing;

const FakeReq = struct {
    headers: []const [2][]const u8 = &.{},
    url: []const u8 = "/",
    // `pub` because wing's `Query` extractor reaches these across the module
    // boundary (`ctx.req.header`/`ctx.req.target`).
    pub fn header(self: FakeReq, name: []const u8) ?[]const u8 {
        for (self.headers) |kv| {
            if (std.ascii.eqlIgnoreCase(kv[0], name)) return kv[1];
        }
        return null;
    }
    pub fn target(self: FakeReq) []const u8 {
        return self.url;
    }
};

const FakeCtx = struct {
    req: FakeReq,
    arena: std.mem.Allocator,
};

fn ctxWith(req: FakeReq) FakeCtx {
    return .{ .req = req, .arena = testing.allocator };
}

test "Cookie: named value present, surrounded, absent, empty" {
    const C = Cookie("session_id");
    try testing.expectEqualStrings("abc", C.locate(ctxWith(.{ .headers = &.{.{ "cookie", "session_id=abc" }} })).?);
    try testing.expectEqualStrings("abc", C.locate(ctxWith(.{ .headers = &.{.{ "cookie", "foo=1; session_id=abc; bar=2" }} })).?);
    try testing.expect(C.locate(ctxWith(.{ .headers = &.{.{ "cookie", "foo=1" }} })) == null);
    try testing.expect(C.locate(ctxWith(.{ .headers = &.{.{ "cookie", "session_id=" }} })) == null);
    try testing.expect(C.locate(ctxWith(.{})) == null); // no cookie header
}

test "Bearer: case-insensitive scheme, missing prefix, no space, empty token" {
    try testing.expectEqualStrings("xyz", Bearer.locate(ctxWith(.{ .headers = &.{.{ "authorization", "Bearer xyz" }} })).?);
    try testing.expectEqualStrings("xyz", Bearer.locate(ctxWith(.{ .headers = &.{.{ "authorization", "bearer xyz" }} })).?);
    try testing.expect(Bearer.locate(ctxWith(.{ .headers = &.{.{ "authorization", "Basic xyz" }} })) == null);
    try testing.expect(Bearer.locate(ctxWith(.{ .headers = &.{.{ "authorization", "Bearerxyz" }} })) == null);
    try testing.expect(Bearer.locate(ctxWith(.{ .headers = &.{.{ "authorization", "Bearer " }} })) == null);
    try testing.expect(Bearer.locate(ctxWith(.{})) == null);
}

test "Query: named param present, absent, empty" {
    const Q = Query("access_token");
    try testing.expectEqualStrings("t0k", Q.locate(ctxWith(.{ .url = "/dl?access_token=t0k" })).?);
    try testing.expectEqualStrings("t0k", Q.locate(ctxWith(.{ .url = "/dl?x=1&access_token=t0k&y=2" })).?);
    try testing.expect(Q.locate(ctxWith(.{ .url = "/dl?x=1" })) == null);
    try testing.expect(Q.locate(ctxWith(.{ .url = "/dl?access_token=" })) == null);
    try testing.expect(Q.locate(ctxWith(.{ .url = "/dl" })) == null); // no query string
}

test "Header: custom header present, absent, empty" {
    const H = Header("x-api-key");
    try testing.expectEqualStrings("k1", H.locate(ctxWith(.{ .headers = &.{.{ "X-Api-Key", "k1" }} })).?); // case-insensitive
    try testing.expect(H.locate(ctxWith(.{ .headers = &.{.{ "x-api-key", "" }} })) == null);
    try testing.expect(H.locate(ctxWith(.{})) == null);
}
