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
//! The id is a UUIDv7 from wing-id's process-wide generator (`Id.new`),
//! rendered as 26-char Crockford Base32 (`toBase32`): sortable by creation
//! order, unique within the process, and drawn from the same sequence as
//! entity ids. Generation and rendering live in wing-id — this middleware
//! only binds the result.
//!
//! Must sit at the FRONT of the chain, before the access logger: the logger
//! emits its access line after `next` returns, so the binding has to still be
//! live at that point — i.e. this middleware must be the outer one.

const std = @import("std");
const Id = @import("wing_id").Id;
const context = @import("context.zig");

pub const request_id = struct {
    pub fn run(ctx: anytype, next: anytype) anyerror!void {
        const text = Id.new().toBase32();
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
