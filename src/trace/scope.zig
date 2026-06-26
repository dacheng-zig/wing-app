//! Task-local binding of the active request scope.
//!
//! The `request_scope` middleware binds the current request's scope here at the
//! front of the chain; `requestAwareLogFn` reads it for every std.log line.
//! Backed by zio's `TaskLocal`, so the binding follows the task across yields
//! and executor migration, and is naturally isolated per concurrent request —
//! replacing the coroutine-pointer side table this used to need.
//!
//! Lives apart from `trace.zig` so that module stays std-only (and thus unit
//! testable without a zio runtime); the TaskLocal mechanism is exercised by
//! zio's own tests.

const zio = @import("zio");
const trace = @import("trace.zig");

pub const RequestScope = trace.RequestScope;

var active: zio.TaskLocal(RequestScope) = .{};

/// Caller-owned storage for one binding. Declare `.unset`, keep it alive and
/// unmoved until `unbind`; the middleware parks it on its stack frame, which
/// outlives the wrapped `next` call.
pub const Node = @TypeOf(active).Node;

/// Bind `scope` to the current task. Must be called inside a zio task — the
/// request handler always is.
pub fn bind(node: *Node, scope: RequestScope) void {
    active.set(node, scope);
}

/// Release the binding established by `bind`, returning `node` to `.unset`.
/// Safe on both the success and error unwinding paths.
pub fn unbind(node: *Node) void {
    active.clear(node);
}

/// The request scope bound to the current task, or null when called outside a
/// request (or outside any task, e.g. startup logging).
pub fn current() ?RequestScope {
    return active.get();
}
