//! catchAll maintenance middleware: short-circuits EVERY request to a uniform
//! 503 while the app is under maintenance, à la Yii2's `catchAll`.
//!
//! There is no runtime control surface: presence in the chain IS the switch.
//! To enter maintenance, add `maintenance(.{ ... })` to the chain in app.zig and
//! redeploy; remove it to exit. It sits before `route_match`, so it catches
//! matched and unmatched routes alike — a true catch-all.
//!
//! `bypass_paths` (default `/health`) lets liveness/readiness probes through, so
//! an orchestrator doesn't mark the node down and drain it mid-maintenance.
//! Transport peer IP is intentionally NOT a bypass axis: talon doesn't thread
//! the connection into the App layer, so wing middleware can't see it, and a
//! forwarded-header allowlist would be client-spoofable.

const std = @import("std");

/// Compile-time knobs for the maintenance responder. All comptime: the switch
/// is whether this middleware is in the chain, so its config is baked in too.
pub const Options = struct {
    /// `Retry-After` header value, in seconds — hints clients/proxies when to
    /// retry. 3600 = one hour.
    retry_after_seconds: u32 = 3600,
    /// Response body. Plain text; keep it short and human-readable.
    message: []const u8 = "under maintenance\n",
    /// Exact request paths (query stripped) that skip maintenance. Defaults to
    /// the health probe so orchestrators keep seeing the node as live.
    bypass_paths: []const []const u8 = &.{"/health"},
};

/// Build a maintenance middleware from `options`. Returns a struct with the
/// `run(ctx, next)` shape wing expects (same factory idiom as
/// `wing.middleware.recoverWith` / `static`).
pub fn maintenance(comptime options: Options) type {
    // Precompute the header value once, at comptime.
    const retry_after = std.fmt.comptimePrint("{d}", .{options.retry_after_seconds});
    return struct {
        pub fn run(ctx: anytype, next: anytype) anyerror!void {
            if (isBypassed(pathOf(ctx.req.target()))) return next.call(ctx);
            // Short-circuit: do NOT call `next`. 503 + Retry-After is the
            // HTTP-correct "temporarily down" reply; content-type is explicit
            // because talon sets none by default. Goes through `ctx.respond` so
            // accumulated headers (e.g. x-request-id) still merge in.
            return ctx.respond(options.message, .{
                .status = .service_unavailable,
                .extra_headers = &.{
                    .{ .name = "retry-after", .value = retry_after },
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
        }

        /// Exact-match (not prefix) against the configured bypass list. Exact
        /// keeps it predictable: "/healthz" does not slip through "/health".
        fn isBypassed(path: []const u8) bool {
            inline for (options.bypass_paths) |bypass| {
                if (std.mem.eql(u8, path, bypass)) return true;
            }
            return false;
        }
    };
}

/// Request target with the query string stripped: the routable path. Mirrors
/// wing's internal `pathOf` (not exported), kept tiny and local.
fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pathOf strips the query string" {
    try testing.expectEqualStrings("/health", pathOf("/health?probe=1"));
    try testing.expectEqualStrings("/health", pathOf("/health"));
    try testing.expectEqualStrings("/", pathOf("/?x=1"));
}

// Hand-rolled fakes: the middleware is generic over `ctx`/`next`, so a tiny
// recorder exercises both branches without the HTTP stack.
const Recorder = struct {
    next_called: bool = false,
    responded: bool = false,
    status: ?std.http.Status = null,
    body: []const u8 = "",
    retry_after: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

const FakeReq = struct {
    url: []const u8,
    pub fn target(self: FakeReq) []const u8 {
        return self.url;
    }
};

const FakeCtx = struct {
    req: FakeReq,
    rec: *Recorder,
    pub fn respond(self: FakeCtx, body: []const u8, opts: anytype) !void {
        self.rec.responded = true;
        self.rec.status = opts.status;
        self.rec.body = body;
        // `opts` is `anytype`, so `extra_headers` is still the comptime tuple
        // literal (the real typed `RespondOptions` is what coerces it to a
        // slice); iterate it with `inline for`.
        inline for (opts.extra_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) self.rec.retry_after = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) self.rec.content_type = h.value;
        }
    }
};

const FakeNext = struct {
    rec: *Recorder,
    pub fn call(self: FakeNext, ctx: anytype) !void {
        _ = ctx;
        self.rec.next_called = true;
    }
};

fn drive(comptime M: type, url: []const u8) !Recorder {
    var rec: Recorder = .{};
    const ctx: FakeCtx = .{ .req = .{ .url = url }, .rec = &rec };
    const next: FakeNext = .{ .rec = &rec };
    try M.run(ctx, next);
    return rec;
}

test "non-bypassed request short-circuits to 503 with Retry-After" {
    const M = maintenance(.{ .retry_after_seconds = 120, .message = "down\n" });
    const rec = try drive(M, "/api/v1/users");
    try testing.expect(!rec.next_called);
    try testing.expect(rec.responded);
    try testing.expectEqual(std.http.Status.service_unavailable, rec.status.?);
    try testing.expectEqualStrings("down\n", rec.body);
    try testing.expectEqualStrings("120", rec.retry_after.?);
    try testing.expectEqualStrings("text/plain; charset=utf-8", rec.content_type.?);
}

test "bypass path passes through to next (query stripped)" {
    const M = maintenance(.{}); // default bypass: /health
    const health = try drive(M, "/health");
    try testing.expect(health.next_called);
    try testing.expect(!health.responded);

    const health_q = try drive(M, "/health?probe=1");
    try testing.expect(health_q.next_called);
    try testing.expect(!health_q.responded);
}

test "bypass is exact match, not prefix" {
    const M = maintenance(.{});
    const rec = try drive(M, "/healthz");
    try testing.expect(!rec.next_called);
    try testing.expect(rec.responded);
}
