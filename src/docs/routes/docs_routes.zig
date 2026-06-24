//! Route table for the `docs` feature: the spec endpoint and the Scalar page.
//!
//! Both routes are `hidden` — real routes, but excluded from the generated
//! spec (they document the generator, not the API). Merged at the root by the
//! top-level router before assembly, so the exclusion path is exercised.

const std = @import("std");
const openapi = @import("../../openapi/root.zig");

const AppState = @import("../../state.zig").AppState;
const docs_controller = @import("../controllers/docs_controller.zig");

/// Build the docs sub-router. Paths are absolute (root-level), so the caller
/// `merge`s rather than `nest`s.
pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/openapi.json", docs_controller.openapiJson, .{ .hidden = true });
    try r.get("/docs", docs_controller.docsPage, .{ .hidden = true });

    return r;
}
