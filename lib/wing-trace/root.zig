//! wing-trace: task-scoped trace ids + trace-aware logging for zio-based apps.
//!
//! Four layers, from pure to glue:
//!   - `trace.zig`   — std-only: `Context` value type, timestamp/level formatting
//!   - `context.zig` — zio TaskLocal binding (`bind`/`unbind`/`current`)
//!   - `log.zig`     — `logFn` for `std_options`, prefixes lines with the trace id
//!   - `middleware.zig` — HTTP glue: per-request UUIDv7 id, `x-request-id`
//!     header, context binding for the request's lifetime
//!
//! HTTP requests bind via the `request_id` middleware (a drop-in for
//! `wing.middleware.request_id`); background jobs bind directly with
//! `bind`/`unbind` around each execution. Deps: `zio` (context binding),
//! `wing_id` (middleware only — request ids come from `Id.new`).

const trace = @import("trace.zig");
const context = @import("context.zig");

pub const Context = trace.Context;

pub const Binding = context.Binding;
pub const bind = context.bind;
pub const unbind = context.unbind;
pub const current = context.current;

pub const logFn = @import("log.zig").logFn;
pub const request_id = @import("middleware.zig").request_id;

test {
    _ = trace;
    _ = @import("log.zig");
    _ = @import("middleware.zig");
    // context.zig has no test blocks of its own; take the non-generic binding
    // fns' addresses so an independent `zig build test` analyzes their bodies.
    _ = &bind;
    _ = &unbind;
    _ = &current;
}
