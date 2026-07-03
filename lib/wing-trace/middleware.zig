//! Request-id middleware: assigns a per-request id, exposes it on
//! `ctx.request_id` and the `x-request-id` response header, and binds it as
//! the task-local trace context so EVERY std.log line emitted while this
//! request runs (app, framework, SQL driver) carries the request id.
//!
//! Drop-in replacement for `wing.middleware.request_id` (same name, same
//! `ctx.request_id`/`x-request-id` contract): upgrades the process-unique
//! counter id to a sortable UUIDv7 and adds the trace-context binding.
//!
//! The ctx is duck-typed (`anytype`): anything with `arena`, `request_id`,
//! and `addHeader` works — no dependency on the wing framework itself.
//!
//! The id is a UUIDv7 rendered as 26-char Crockford Base32: a 48-bit
//! millisecond timestamp followed by a monotonic counter, so ids sort by
//! creation order and stay unique within the process. A single-executor
//! runtime means this middleware never runs on two threads at once, so the
//! generator and its RNG need no locking.
//!
//! Must sit at the FRONT of the chain, before the access logger: the logger
//! emits its access line after `next` returns, so the binding has to still be
//! live at that point — i.e. this middleware must be the outer one.

const std = @import("std");
const uuid = @import("uuid");
const context = @import("context.zig");

pub const request_id = struct {
    var gen: uuid.V7Generator(.{}) = .empty;
    var prng: std.Random.DefaultPrng = .init(0);
    var seeded = false;

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        // Wall clock via the same always-available io std's default logger uses
        // (mirrors log.zig); these are synchronous syscalls, no scheduler
        // yield.
        const now = std.Io.Clock.now(.real, std.Options.debug_io);

        // Seed the RNG once from nanosecond entropy on first use. Uniqueness is
        // guaranteed by the monotonic counter regardless of the RNG; the seed
        // only keeps the random low bits unpredictable across restarts. No guard
        // needed on the single executor.
        if (!seeded) {
            prng = .init(@truncate(@as(u96, @bitCast(now.toNanoseconds()))));
            seeded = true;
        }

        // Clamp a pre-1970 clock to 0 instead of tripping the @intCast safety
        // check — same policy as trace.formatTimestamp.
        const ms: u48 = @intCast(@max(now.toMilliseconds(), 0));
        const text = uuid.base32.toBase32(gen.next(prng.random(), ms));
        // Copy off this frame: the header and binding outlive `next`, and the
        // response is written further up the stack after `run` returns.
        const buf = try ctx.arena.dupe(u8, &text);
        ctx.request_id = buf;
        try ctx.addHeader("x-request-id", buf);

        // The binding lives on this frame, which outlives the wrapped `next` call.
        var binding: context.Binding = .unset;
        context.bind(&binding, .{ .trace_id = buf });
        defer context.unbind(&binding); // clears on success AND error paths
        return next.call(ctx);
    }
};

test {
    // Compile coverage: `run` is generic over ctx/next, so it is only analyzed
    // when instantiated. A fake ctx/next pair typechecks the whole body (and
    // transitively the context binding) without needing an HTTP stack or a zio
    // runtime — analysis only, never executed.
    const Fake = struct {
        const Ctx = struct {
            arena: std.mem.Allocator,
            request_id: []const u8 = "",
            fn addHeader(self: *@This(), name: []const u8, value: []const u8) !void {
                _ = self;
                _ = name;
                _ = value;
            }
        };
        const Next = struct {
            fn call(self: @This(), ctx: *Ctx) anyerror!void {
                _ = self;
                _ = ctx;
            }
        };
        fn coverage(ctx: *Ctx, next: Next) anyerror!void {
            return request_id.run(ctx, next);
        }
    };
    _ = &Fake.coverage;
}
