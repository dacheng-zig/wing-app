//! Route table for the `docs` feature: the spec endpoint and the Scalar page.
//!
//! Both routes are `hidden` — real routes, but excluded from the generated
//! spec (they document the generator, not the API). Merged at the root by the
//! top-level router before assembly, so the exclusion path is exercised.

const std = @import("std");
const openapi = @import("../../openapi/root.zig");

const AppState = @import("../../state.zig").AppState;
const openapi_json = @import("../handlers/openapi_json.zig");
const scalar_page = @import("../handlers/scalar_page.zig");

/// Build the docs sub-router. Paths are absolute (root-level), so the caller
/// `merge`s rather than `nest`s.
pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/openapi.json", openapi_json.handle, .{ .hidden = true });
    try r.get("/docs", scalar_page.handle, .{ .hidden = true });

    return r;
}
