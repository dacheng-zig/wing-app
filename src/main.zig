//! Entry point.
//!
//! Intentionally thin: the executable's only job is to hand the allocator to
//! the server bootstrap. All wiring lives in the layered modules under `src/`
//! (config, state, app, routes, controllers, services, repositories, ...).

const std = @import("std");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    try server.run(init);
}
