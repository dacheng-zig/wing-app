//! Application wiring: the middleware chain and error mapping.
//!
//! `App` is the request pipeline. wing checks middleware ordering at comptime
//! (e.g. `cors` must follow `route_match`), so a mis-ordered chain fails to
//! build rather than misbehaving at runtime. The `execute` terminal is appended
//! by the framework automatically.

const wing = @import("wing");
const talon = @import("talon");

const AppState = @import("state.zig").AppState;
const security_headers = @import("middleware/security_headers.zig").security_headers;

/// Map application errors to HTTP status codes, falling back to wing's
/// defaults. `error.InvalidName` (raised by UserService) becomes 400.
fn errorStatus(err: anyerror) talon.http.Status {
    return switch (err) {
        error.InvalidName => .bad_request,
        else => wing.middleware.defaultErrorStatus(err),
    };
}

pub const App = wing.App(AppState, .{
    // wing.middleware.logger,
    wing.middleware.recoverWith(errorStatus),
    // wing.middleware.request_id,
    // security_headers,
    wing.middleware.route_match, // provides RouteMatched...
    // wing.middleware.cors, // ...required here (ordering checked at comptime)
});
