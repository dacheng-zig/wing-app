//! OpenAPI route metadata + the runtime doc record.
//!
//! `Meta` is the per-route prose the user opts into at the call site (summary,
//! tags, ...); schema is always derived from the handler signature, so `.{}`
//! still yields a fully-typed operation. `RouteDoc` is the runtime record kept
//! in `openapi.Router.docs`: it pairs the runtime routing facts (method, path)
//! with a comptime-bound `buildOp` thunk that renders the operation's
//! parameters/requestBody/responses at assemble time (the handler type is
//! erased from the runtime list, so the thunk carries it).

const std = @import("std");
const wing = @import("wing");

/// Per-operation prose. All fields optional: schema is derived regardless.
pub const Meta = struct {
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    /// Override the default method+path-derived operationId.
    operation_id: []const u8 = "",
    /// Registered for real routing but excluded from the generated spec
    /// (e.g. the `/openapi.json` and `/docs` endpoints themselves).
    hidden: bool = false,
};

/// API author / support contact (OpenAPI `info.contact`). Emitted only when at
/// least one field is set. `url` is the project homepage / "website".
pub const Contact = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    email: []const u8 = "",
};

/// API license (OpenAPI `info.license`). Emitted only when `name` is set.
/// `identifier` (SPDX expression, 3.1) and `url` are mutually exclusive —
/// `identifier` wins when both are given.
pub const License = struct {
    name: []const u8 = "",
    identifier: []const u8 = "",
    url: []const u8 = "",
};

/// An OpenAPI security scheme (`components.securitySchemes` entry). The app
/// declares its one authentication mechanism here (the single source of truth
/// for *how* this deployment authenticates); auth extractors only declare *that*
/// they require auth (see `auth_requirement`), staying scheme-agnostic. Switching
/// cookie→bearer is therefore a one-literal change here, not per-extractor.
/// `kind` maps to the OpenAPI `type` field (avoids the `type` keyword).
pub const SecurityScheme = struct {
    /// `components.securitySchemes` key, e.g. "cookieSession".
    name: []const u8,
    /// OpenAPI `type`: "apiKey" | "http" | "oauth2" | "openIdConnect".
    kind: []const u8,
    /// apiKey location: "cookie" | "header" | "query".
    in: []const u8 = "",
    /// apiKey cookie/header/query parameter name, e.g. "session_id".
    parameter_name: []const u8 = "",
    /// http scheme: "bearer" | "basic" | ...
    scheme: []const u8 = "",
    description: []const u8 = "",
};

/// Top-level document identity (OpenAPI `info` object). Only `title` and
/// `version` are required; the rest are opt-in and omitted when empty.
pub const ApiInfo = struct {
    title: []const u8,
    version: []const u8,
    /// Short one-liner (3.1). Distinct from the CommonMark `description`.
    summary: []const u8 = "",
    description: []const u8 = "",
    terms_of_service: []const u8 = "",
    contact: Contact = .{},
    license: License = .{},
    /// The app's authentication scheme. Required iff any handler uses an auth
    /// extractor (those declare `auth_requirement`); operations needing auth bind to
    /// it at assemble time. Leaving it null while an auth op exists is a config
    /// error (assemble fails with `error.MissingAuthScheme`).
    auth_scheme: ?SecurityScheme = null,
};

/// Per-build collaborators threaded into each operation's `BuildFn`:
/// `components`/`security_schemes` collect deduped `$ref`/scheme registrations;
/// `auth_scheme` is the app scheme an auth-requiring operation binds to.
pub const BuildCtx = struct {
    gpa: std.mem.Allocator,
    components: *std.json.ObjectMap,
    security_schemes: *std.json.ObjectMap,
    auth_scheme: ?SecurityScheme,
};

/// Renders one operation object (`parameters`/`requestBody`/`responses`/
/// `security`) into JSON, registering referenced schemas/security schemes into
/// the `BuildCtx` maps (deduped across operations). Bound to the handler type at
/// registration; the ctx allocator owns the returned value tree.
pub const BuildFn = *const fn (*BuildCtx) anyerror!std.json.Value;

/// One documented route. `path` is valid for the owning router's lifetime
/// (either a static call-site literal or an arena-owned nested join).
pub const RouteDoc = struct {
    method: wing.talon.http.Method,
    path: []const u8,
    meta: Meta,
    build_op: BuildFn,
};
