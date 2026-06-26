//! Request-scope middleware: assigns a process-unique request id, exposes it
//! on `ctx.request_id` and the `x-request-id` response header, and binds it as
//! task-local state so EVERY std.log line emitted while this request runs (app,
//! wing, mantle SQL) carries the request id.
//!
//! Must sit at the FRONT of the chain, before `wing.middleware.logger`: the
//! logger emits its access line after `next` returns, so the binding has to
//! still be live at that point — i.e. this middleware must be the outer one.

const std = @import("std");
const scope = @import("../trace/scope.zig");

pub const request_scope = struct {
    var counter: std.atomic.Value(u64) = .init(1);

    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        const id = counter.fetchAdd(1, .monotonic);
        const buf = try std.fmt.allocPrint(ctx.arena, "{x:0>16}", .{id});
        ctx.request_id = buf;
        try ctx.addHeader("x-request-id", buf);

        // Node lives on this frame, which outlives the wrapped `next` call.
        var node: scope.Node = .unset;
        scope.bind(&node, .{ .request_id = buf });
        defer scope.unbind(&node); // clears on success AND error paths
        return next.call(ctx);
    }
};
