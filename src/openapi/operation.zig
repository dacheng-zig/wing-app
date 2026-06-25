//! handler signature → OpenAPI operation object.
//!
//! The two comptime classifiers:
//!   - `paramRole`: type-identity match against wing's public extractor
//!     constructors. `wing.Path(T)` evaluated twice is the *same* type
//!     (Zig memoizes generic instantiation), so `P == wing.Path(T)`
//!     unambiguously means "path params" without touching wing internals.
//!     A param whose type declares `pub const auth_requirement` (a plain comptime
//!     literal, read structurally — see `paramRole`/`authOptional`) is an
//!     auth extractor: it contributes the operation's `security` requirement,
//!     bound to the app's `auth_scheme` (from `BuildCtx`). The extractor states
//!     only *that* it needs auth (and whether it's optional) — never *which*
//!     scheme — so switching cookie→bearer is a one-place config change. Zero
//!     coupling: neither the openapi nor the auth package imports the other.
//!   - `responseOf`: maps the (error-unwrapped) return type to a status +
//!     optional body, aligned with wing's hardcoded responders
//!     (Json→200, Created→201, Redirect→302).
//!
//! `makeBuild` captures the handler type in a thunk so the runtime `RouteDoc`
//! list can render the operation later without the type (it is erased once the
//! route is registered).

const std = @import("std");
const wing = @import("wing");
const schema = @import("schema.zig");
const meta = @import("meta.zig");

const Value = schema.Value;
const ObjectMap = schema.ObjectMap;
const Array = schema.Array;

const Role = union(enum) {
    /// Dependency-injection parameter (`*State`/`*Service`) — not API surface.
    skip,
    path: type,
    query: type,
    body: type,
    /// Auth extractor: its type declares `auth_requirement`. The marker is read off
    /// the param type directly in `operationValue`, so no payload here.
    security,
};

fn paramRole(comptime P: type) Role {
    // Pointers are State/sub-state projections (`*Config`, `*UserService`).
    if (@typeInfo(P) == .pointer) return .skip;
    // Auth extractors opt in via this decl (checked before the `value`-field
    // test below, since auth extractors have no `value`).
    if (@typeInfo(P) == .@"struct" and @hasDecl(P, "auth_requirement")) return .security;
    // Other extractors with no `value` field (e.g. bare DI structs) are skipped.
    if (@typeInfo(P) != .@"struct" or !@hasField(P, "value")) return .skip;
    const T = @FieldType(P, "value");
    if (P == wing.Path(T)) return .{ .path = T };
    if (P == wing.Query(T)) return .{ .query = T };
    if (P == wing.Json(T)) return .{ .body = T };
    return .skip;
}

const Response = struct { status: u16, body: ?type };

fn responseOf(comptime Ret: type) Response {
    const P = if (@typeInfo(Ret) == .error_union) @typeInfo(Ret).error_union.payload else Ret;
    if (P == void or P == []const u8 or P == []u8) return .{ .status = 200, .body = null };
    if (P == wing.Redirect) return .{ .status = 302, .body = null };
    if (@typeInfo(P) == .@"struct" and @hasField(P, "value")) {
        const T = @FieldType(P, "value");
        if (P == wing.Json(T)) return .{ .status = 200, .body = T };
        if (P == wing.Created(T)) return .{ .status = 201, .body = T };
    }
    return .{ .status = 200, .body = null };
}

/// Builds a `BuildFn` that renders handler `H`'s operation. The closure is a
/// plain function pointer (no captures), so it is safe to store at runtime.
pub fn makeBuild(comptime H: type) meta.BuildFn {
    return struct {
        fn build(ctx: *meta.BuildCtx) anyerror!Value {
            return operationValue(H, ctx);
        }
    }.build;
}

fn operationValue(comptime H: type, ctx: *meta.BuildCtx) anyerror!Value {
    const fn_info = @typeInfo(H).@"fn";
    const gpa = ctx.gpa;
    const components = ctx.components;

    var op: ObjectMap = .empty;
    var params: Array = .init(gpa);
    var request_body: ?Value = null;
    // Auth extractors all bind to the single app `auth_scheme`, so we only need
    // to know *whether* the op requires auth and whether any marker is optional
    // (OptionalAuth admits anonymous access via a leading empty `{}`).
    var needs_auth = false;
    var auth_optional = false;

    inline for (fn_info.params[1..]) |p| {
        const P = p.type.?;
        switch (comptime paramRole(P)) {
            .skip => {},
            .path => |T| try appendParams(&params, gpa, components, T, "path"),
            .query => |T| try appendParams(&params, gpa, components, T, "query"),
            .body => |T| request_body = try jsonBody(T, gpa, components),
            .security => {
                needs_auth = true;
                auth_optional = auth_optional or comptime authOptional(P);
            },
        }
    }

    if (params.items.len > 0) try op.put(gpa, "parameters", .{ .array = params });
    if (request_body) |rb| try op.put(gpa, "requestBody", rb);
    if (needs_auth) {
        const scheme = ctx.auth_scheme orelse return error.MissingAuthScheme;
        try registerScheme(ctx.security_schemes, gpa, scheme);
        try op.put(gpa, "security", try securityArray(gpa, scheme.name, auth_optional));
    }

    const resp = comptime responseOf(fn_info.return_type.?);
    try op.put(gpa, "responses", try responsesValue(resp, gpa, components));
    return .{ .object = op };
}

/// Whether auth extractor `P`'s `auth_requirement` marker admits anonymous access.
fn authOptional(comptime P: type) bool {
    const marker = P.auth_requirement;
    return @hasField(@TypeOf(marker), "optional") and marker.optional;
}

/// Registers one security scheme into `security_schemes` (idempotent by `name`).
/// `kind` maps to the OpenAPI `type`; the rest are emitted when non-empty.
fn registerScheme(security_schemes: *ObjectMap, gpa: std.mem.Allocator, scheme: meta.SecurityScheme) !void {
    if (security_schemes.contains(scheme.name)) return;
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = scheme.kind });
    if (scheme.in.len > 0) try obj.put(gpa, "in", .{ .string = scheme.in });
    if (scheme.parameter_name.len > 0) try obj.put(gpa, "name", .{ .string = scheme.parameter_name });
    if (scheme.scheme.len > 0) try obj.put(gpa, "scheme", .{ .string = scheme.scheme });
    if (scheme.description.len > 0) try obj.put(gpa, "description", .{ .string = scheme.description });
    try security_schemes.put(gpa, scheme.name, .{ .object = obj });
}

/// Builds the operation `security` array binding `scheme_name` (apiKey/http
/// carry no scopes → empty array). Required → `[{name:[]}]`; optional →
/// `[{}, {name:[]}]`, where the leading `{}` marks "no auth also allowed".
fn securityArray(gpa: std.mem.Allocator, scheme_name: []const u8, optional: bool) !Value {
    var requirement: ObjectMap = .empty;
    try requirement.put(gpa, scheme_name, .{ .array = Array.init(gpa) });
    var arr: Array = .init(gpa);
    if (optional) try arr.append(.{ .object = .empty });
    try arr.append(.{ .object = requirement });
    return .{ .array = arr };
}

fn appendParams(
    params: *Array,
    gpa: std.mem.Allocator,
    components: *ObjectMap,
    comptime T: type,
    comptime in: []const u8,
) !void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        var param: ObjectMap = .empty;
        try param.put(gpa, "name", .{ .string = f.name });
        try param.put(gpa, "in", .{ .string = in });
        // Path params are always required (wing errors on a missing capture);
        // query required-ness follows the optional/default rule.
        const required = comptime std.mem.eql(u8, in, "path") or schema.isRequired(f);
        try param.put(gpa, "required", .{ .bool = required });
        try param.put(gpa, "schema", try schema.schemaValue(f.type, gpa, components));
        try params.append(.{ .object = param });
    }
}

fn jsonBody(comptime T: type, gpa: std.mem.Allocator, components: *ObjectMap) !Value {
    var body: ObjectMap = .empty;
    try body.put(gpa, "required", .{ .bool = true });
    try body.put(gpa, "content", try jsonContent(T, gpa, components));
    return .{ .object = body };
}

fn responsesValue(comptime resp: Response, gpa: std.mem.Allocator, components: *ObjectMap) !Value {
    var entry: ObjectMap = .empty;
    try entry.put(gpa, "description", .{ .string = statusText(resp.status) });
    if (resp.body) |T| try entry.put(gpa, "content", try jsonContent(T, gpa, components));

    var responses: ObjectMap = .empty;
    try responses.put(gpa, statusKey(resp.status), .{ .object = entry });
    return .{ .object = responses };
}

fn jsonContent(comptime T: type, gpa: std.mem.Allocator, components: *ObjectMap) !Value {
    var media: ObjectMap = .empty;
    try media.put(gpa, "schema", try schema.schemaValue(T, gpa, components));
    var content: ObjectMap = .empty;
    try content.put(gpa, "application/json", .{ .object = media });
    return .{ .object = content };
}

fn statusKey(comptime status: u16) []const u8 {
    return switch (status) {
        200 => "200",
        201 => "201",
        302 => "302",
        else => std.fmt.comptimePrint("{d}", .{status}),
    };
}

fn statusText(comptime status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        302 => "Found",
        else => "Response",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "identity: wing extractor constructors are memoized" {
    // The whole approach rests on this: the same instantiation is the same
    // type. If wing ever breaks this, these asserts turn red instead of the
    // generator silently emitting wrong docs.
    const Q = struct { page: u32 };
    try testing.expect(wing.Path(u64) == wing.Path(u64));
    try testing.expect(wing.Query(Q) == wing.Query(Q));
    try testing.expect(wing.Json(u8) == wing.Json(u8));
    // Distinct payloads are distinct types.
    try testing.expect(wing.Path(u64) != wing.Path(u32));
    // Path and Query are structurally identical but identity-distinct.
    try testing.expect(wing.Path(u64) != wing.Query(u64));
    // Identity holds because the SAME handler type flows from the registration
    // call into both wing's bind and our classifier — never two separately
    // written anonymous structs (which Zig would treat as distinct types).
}

test "paramRole classifies extractors, skips DI/auth params" {
    const State = struct { x: u32 };
    const AuthLike = struct { principal: u32 };
    try testing.expectEqual(Role.skip, paramRole(*State));
    try testing.expectEqual(Role.skip, paramRole(AuthLike));
    try testing.expect(paramRole(wing.Path(struct { id: u64 })) == .path);
    try testing.expect(paramRole(wing.Query(struct { q: []const u8 })) == .query);
    try testing.expect(paramRole(wing.Json(struct { n: u8 })) == .body);
}

test "responseOf maps return types to status + body" {
    try testing.expectEqual(@as(u16, 200), responseOf(anyerror!void).status);
    try testing.expectEqual(@as(u16, 200), responseOf(anyerror![]const u8).status);
    try testing.expectEqual(@as(u16, 201), responseOf(anyerror!wing.Created(u8)).status);
    try testing.expectEqual(@as(u16, 200), responseOf(anyerror!wing.Json(u8)).status);
    try testing.expectEqual(@as(u16, 302), responseOf(anyerror!wing.Redirect).status);
    try testing.expect(responseOf(anyerror!wing.Json(u8)).body != null);
    try testing.expect(responseOf(anyerror!void).body == null);
}

test "operationValue derives params, body, and response from a handler" {
    const Ctx = wing.Context(struct { x: u32 });
    const Dto = struct { name: []const u8 };
    const Handler = struct {
        fn h(ctx: *Ctx, body: wing.Json(Dto), path: wing.Path(struct { id: u64 })) anyerror!wing.Created(Dto) {
            _ = ctx;
            _ = body;
            _ = path;
            return undefined;
        }
    }.h;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var components: ObjectMap = .empty;
    var security_schemes: ObjectMap = .empty;
    var ctx = meta.BuildCtx{ .gpa = a, .components = &components, .security_schemes = &security_schemes, .auth_scheme = null };

    const op = try operationValue(@TypeOf(Handler), &ctx);
    // One path parameter.
    const params = op.object.get("parameters").?.array;
    try testing.expectEqual(@as(usize, 1), params.items.len);
    try testing.expectEqualStrings("id", params.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("path", params.items[0].object.get("in").?.string);
    // JSON request body present.
    try testing.expect(op.object.get("requestBody").?.object.contains("content"));
    // 201 response with a $ref body; Dto registered once.
    try testing.expect(op.object.get("responses").?.object.contains("201"));
    try testing.expectEqual(@as(usize, 1), components.count());
    // No security extractor → no `security` emitted.
    try testing.expect(!op.object.contains("security"));
}

test "operationValue binds a scheme-agnostic auth extractor to the app scheme" {
    const Ctx = wing.Context(struct { x: u32 });
    // Intent-only markers (shape mirrors auth's `Auth`/`OptionalAuth`): they
    // declare *that* auth is required, never *which* scheme — that comes from
    // the BuildCtx `auth_scheme` below.
    const Required = struct {
        principal: u32,
        pub const auth_requirement = .{ .optional = false };
    };
    const Optional = struct {
        principal: ?u32,
        pub const auth_requirement = .{ .optional = true };
    };
    const Handlers = struct {
        fn gated(ctx: *Ctx, a: Required) anyerror!void {
            _ = ctx;
            _ = a;
        }
        fn maybe(ctx: *Ctx, a: Optional) anyerror!void {
            _ = ctx;
            _ = a;
        }
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var components: ObjectMap = .empty;
    var security_schemes: ObjectMap = .empty;
    var ctx = meta.BuildCtx{
        .gpa = a,
        .components = &components,
        .security_schemes = &security_schemes,
        .auth_scheme = .{ .name = "cookieSession", .kind = "apiKey", .in = "cookie", .parameter_name = "session_id", .description = "Session cookie." },
    };

    // Required: `security: [{cookieSession: []}]`, scheme registered once.
    const gated = try operationValue(@TypeOf(Handlers.gated), &ctx);
    const sec = gated.object.get("security").?.array;
    try testing.expectEqual(@as(usize, 1), sec.items.len);
    const req = sec.items[0].object.get("cookieSession").?.array;
    try testing.expectEqual(@as(usize, 0), req.items.len); // empty scope list
    const scheme = security_schemes.get("cookieSession").?.object;
    try testing.expectEqualStrings("apiKey", scheme.get("type").?.string);
    try testing.expectEqualStrings("cookie", scheme.get("in").?.string);
    try testing.expectEqualStrings("session_id", scheme.get("name").?.string);

    // Optional: leading empty `{}` admits anonymous; scheme deduped (still 1).
    const maybe = try operationValue(@TypeOf(Handlers.maybe), &ctx);
    const sec2 = maybe.object.get("security").?.array;
    try testing.expectEqual(@as(usize, 2), sec2.items.len);
    try testing.expectEqual(@as(usize, 0), sec2.items[0].object.count()); // {}
    try testing.expect(sec2.items[1].object.contains("cookieSession"));
    try testing.expectEqual(@as(usize, 1), security_schemes.count());
}

test "operationValue errors when an auth op has no configured scheme" {
    const Ctx = wing.Context(struct { x: u32 });
    const Required = struct {
        principal: u32,
        pub const auth_requirement = .{ .optional = false };
    };
    const Handler = struct {
        fn gated(ctx: *Ctx, auth: Required) anyerror!void {
            _ = ctx;
            _ = auth;
        }
    }.gated;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var components: ObjectMap = .empty;
    var security_schemes: ObjectMap = .empty;
    var ctx = meta.BuildCtx{ .gpa = a, .components = &components, .security_schemes = &security_schemes, .auth_scheme = null };

    try testing.expectError(error.MissingAuthScheme, operationValue(@TypeOf(Handler), &ctx));
}
