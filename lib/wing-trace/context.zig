//! Task-local binding of the active trace context.
//!
//! The `request_id` middleware (or a job runner) binds the current unit
//! of work's context here; `logFn` reads it for every std.log line. Backed by
//! zio's `TaskLocal`, so the binding follows the task across yields and
//! executor migration, and is naturally isolated per concurrent task. Bindings
//! are per-task and do NOT propagate to spawned child tasks; bind again inside
//! the child if its log lines should carry the same trace id.
//!
//! Lives apart from `trace.zig` so that module stays std-only (and thus unit
//! testable without a zio runtime); the TaskLocal mechanism is exercised by
//! zio's own tests.

const zio = @import("zio");
const trace = @import("trace.zig");

pub const Context = trace.Context;

var active: zio.TaskLocal(Context) = .{};

/// Caller-owned storage for one binding. Declare `.unset`, keep it alive and
/// unmoved until `unbind`; callers park it on a stack frame that outlives the
/// bound work (the middleware's frame outlives the wrapped `next` call).
pub const Binding = @TypeOf(active).Node;

/// Bind `context` to the current task. Must be called inside a zio task.
pub fn bind(binding: *Binding, context: Context) void {
    active.set(binding, context);
}

/// Release the binding established by `bind`, returning `binding` to `.unset`.
/// Safe on both the success and error unwinding paths.
pub fn unbind(binding: *Binding) void {
    active.clear(binding);
}

/// The trace context bound to the current task, or null when called outside
/// any bound work (or outside any task, e.g. startup logging).
pub fn current() ?Context {
    return active.get();
}
