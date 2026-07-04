//! openapi: code-first OpenAPI 3.1 generation for wing apps.
//!
//! Opt-in: swap `wing.Router(State)` for `openapi.Router(State)` and pass a
//! `Meta` at each registration. Schema is derived from the handler signature
//! (single source of truth); the spec is assembled once at startup and served
//! statically. Zero wing core changes — this package depends only on wing's
//! public extractor types and Router.

const router = @import("router.zig");
const meta = @import("meta.zig");
const serve = @import("serve.zig");

pub const Router = router.Router;
pub const Meta = meta.Meta;
pub const ApiInfo = meta.ApiInfo;
pub const RouteDoc = meta.RouteDoc;
pub const SecurityScheme = meta.SecurityScheme;
pub const ApiDocs = serve.ApiDocs;
pub const docsRoutes = serve.docsRoutes;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("schema.zig");
    _ = @import("operation.zig");
    _ = @import("assemble.zig");
    _ = @import("router.zig");
    _ = @import("meta.zig");
    _ = @import("serve.zig");
}
