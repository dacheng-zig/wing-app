//! Request-scope middleware: assigns a per-request id, exposes it on
//! `ctx.request_id` and the `x-request-id` response header, and binds it as
//! task-local state so EVERY std.log line emitted while this request runs (app,
//! wing, mantle SQL) carries the request id.
//!
//! The id is a UUIDv7 rendered as 26-char Crockford Base32: a 48-bit
//! millisecond timestamp followed by a monotonic counter, so ids sort by
//! creation order and stay unique within the process. The single-executor
//! runtime (see server.zig) means this middleware never runs on two threads at
//! once, so the generator and its RNG need no locking.
//!
//! Must sit at the FRONT of the chain, before `wing.middleware.logger`: the
//! logger emits its access line after `next` returns, so the binding has to
//! still be live at that point — i.e. this middleware must be the outer one.

const std = @import("std");
const uuid = @import("uuid");
const scope = @import("../trace/scope.zig");

pub const request_scope = struct {
    var gen: uuid.V7Generator(.{}) = .empty;
    var prng: std.Random.DefaultPrng = .init(0);
    var seeded = false;

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        // Wall clock via the same always-available io std's default logger uses
        // (mirrors trace/log.zig); these are synchronous syscalls, no scheduler
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

        const ms: u48 = @intCast(now.toMilliseconds());
        const text = uuid.base32.toBase32(gen.next(prng.random(), ms));
        // Copy off this frame: the header and binding outlive `next`, and the
        // response is written further up the stack after `run` returns.
        const buf = try ctx.arena.dupe(u8, &text);
        ctx.request_id = buf;
        try ctx.addHeader("x-request-id", buf);

        // Node lives on this frame, which outlives the wrapped `next` call.
        var node: scope.Node = .unset;
        scope.bind(&node, .{ .request_id = buf });
        defer scope.unbind(&node); // clears on success AND error paths
        return next.call(ctx);
    }
};
