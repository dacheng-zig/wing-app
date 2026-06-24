//! Dev tool: print the assembled OpenAPI 3.1 spec to stdout, then exit.
//!
//! `routes.build` only registers handlers and assembles JSON — it never opens a
//! database connection or runs a handler — so this dumps the real spec offline.
//! Useful for CI (validate/diff the spec without a running server) and for
//! piping into an OpenAPI validator or `jq`.
//!
//!   zig build openapi > openapi.json

const std = @import("std");
const routes = @import("routes/routes.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const built = try routes.build(gpa);
    var router = built.router;
    defer router.deinit();
    defer gpa.free(built.openapi_spec);

    try std.Io.File.stdout().writeStreamingAll(init.io, built.openapi_spec);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
