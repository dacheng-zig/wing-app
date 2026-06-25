//! Startup-time assembly: `[]RouteDoc` → a complete OpenAPI 3.1 document.
//!
//! Runs once at boot. Walks the doc list, renders each operation (which
//! registers any referenced schemas into a shared `components` map for dedup),
//! groups operations under their path item, then serializes the whole tree.
//! The returned bytes are owned by `gpa` (caller frees); everything else lives
//! in a scratch arena freed on return — request-time cost is zero.

const std = @import("std");
const wing = @import("wing");
const meta = @import("meta.zig");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

const openapi_version = "3.1.0";

/// Serializes `docs` into an OpenAPI 3.1 JSON document. Hidden routes are
/// skipped. Caller owns the returned slice.
pub fn json(
    gpa: std.mem.Allocator,
    info: meta.ApiInfo,
    docs: []const meta.RouteDoc,
) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var components: ObjectMap = .empty;
    var security_schemes: ObjectMap = .empty;
    var paths: ObjectMap = .empty;

    // Shared across operations: the two maps dedup schema/scheme registrations;
    // `auth_scheme` is the app scheme that auth-requiring operations bind to.
    var build_ctx = meta.BuildCtx{
        .gpa = a,
        .components = &components,
        .security_schemes = &security_schemes,
        .auth_scheme = info.auth_scheme,
    };

    for (docs) |doc| {
        if (doc.meta.hidden) continue;

        // wing path syntax (`:id`, `*rest`) → OpenAPI templating (`{id}`),
        // so declared path parameters match their `{name}` placeholder.
        const template = try toTemplate(a, doc.path);

        var op = try doc.build_op(&build_ctx);
        try applyMeta(&op.object, a, doc.meta, doc.method, template);

        const gop = try paths.getOrPut(a, template);
        if (!gop.found_existing) gop.value_ptr.* = .{ .object = .empty };
        try gop.value_ptr.object.put(a, try methodKey(a, doc.method), op);
    }

    var root: ObjectMap = .empty;
    try root.put(a, "openapi", .{ .string = openapi_version });
    try root.put(a, "info", try infoValue(info, a));
    // Relative default server; concrete deployment URLs are a config concern.
    var server: ObjectMap = .empty;
    try server.put(a, "url", .{ .string = "/" });
    var servers: Array = .init(a);
    try servers.append(.{ .object = server });
    try root.put(a, "servers", .{ .array = servers });
    try root.put(a, "paths", .{ .object = paths });
    if (components.count() > 0 or security_schemes.count() > 0) {
        var comp: ObjectMap = .empty;
        if (components.count() > 0) try comp.put(a, "schemas", .{ .object = components });
        if (security_schemes.count() > 0) try comp.put(a, "securitySchemes", .{ .object = security_schemes });
        try root.put(a, "components", .{ .object = comp });
    }

    var out: std.Io.Writer.Allocating = .init(a);
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try stringify.write(Value{ .object = root });
    return gpa.dupe(u8, out.written());
}

fn applyMeta(
    op: *ObjectMap,
    a: std.mem.Allocator,
    m: meta.Meta,
    method: wing.talon.http.Method,
    template: []const u8,
) !void {
    if (m.summary.len > 0) try op.put(a, "summary", .{ .string = m.summary });
    if (m.description.len > 0) try op.put(a, "description", .{ .string = m.description });
    // operationId defaults to a method+path slug; unique because method+path
    // uniquely identifies an operation. User override wins.
    const op_id = if (m.operation_id.len > 0) m.operation_id else try operationId(a, method, template);
    try op.put(a, "operationId", .{ .string = op_id });
    if (m.tags.len > 0) {
        var tags: Array = .init(a);
        for (m.tags) |t| try tags.append(.{ .string = t });
        try op.put(a, "tags", .{ .array = tags });
    }
}

/// Rewrites wing path segments to OpenAPI path templating:
/// `:name`/`*name` → `{name}`. Other segments pass through unchanged.
fn toTemplate(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, path, ":*") == null) return path;
    var out: std.Io.Writer.Allocating = .init(a);
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.writer.writeByte('/');
        first = false;
        if (seg.len > 0 and (seg[0] == ':' or seg[0] == '*')) {
            try out.writer.print("{{{s}}}", .{seg[1..]});
        } else {
            try out.writer.writeAll(seg);
        }
    }
    return out.written();
}

/// Lowercase-method + sanitized-path slug, e.g. GET `/api/v1/users/{id}` →
/// `get_api_v1_users_id`. Root path collapses to `get_root`.
fn operationId(a: std.mem.Allocator, method: wing.talon.http.Method, template: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll(try methodKey(a, method));
    var any_segment = false;
    var i: usize = 0;
    while (i < template.len) {
        if (!std.ascii.isAlphanumeric(template[i])) {
            i += 1;
            continue;
        }
        // One underscore-separated segment per maximal alphanumeric run.
        try out.writer.writeByte('_');
        any_segment = true;
        while (i < template.len and std.ascii.isAlphanumeric(template[i])) : (i += 1) {
            try out.writer.writeByte(std.ascii.toLower(template[i]));
        }
    }
    if (!any_segment) try out.writer.writeAll("_root");
    return out.written();
}

fn infoValue(info: meta.ApiInfo, a: std.mem.Allocator) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = info.title });
    if (info.summary.len > 0) try obj.put(a, "summary", .{ .string = info.summary });
    if (info.description.len > 0) try obj.put(a, "description", .{ .string = info.description });
    if (info.terms_of_service.len > 0) try obj.put(a, "termsOfService", .{ .string = info.terms_of_service });
    if (try contactValue(info.contact, a)) |c| try obj.put(a, "contact", c);
    if (try licenseValue(info.license, a)) |l| try obj.put(a, "license", l);
    try obj.put(a, "version", .{ .string = info.version });
    return .{ .object = obj };
}

fn contactValue(c: meta.Contact, a: std.mem.Allocator) !?Value {
    if (c.name.len == 0 and c.url.len == 0 and c.email.len == 0) return null;
    var obj: ObjectMap = .empty;
    if (c.name.len > 0) try obj.put(a, "name", .{ .string = c.name });
    if (c.url.len > 0) try obj.put(a, "url", .{ .string = c.url });
    if (c.email.len > 0) try obj.put(a, "email", .{ .string = c.email });
    return .{ .object = obj };
}

fn licenseValue(l: meta.License, a: std.mem.Allocator) !?Value {
    if (l.name.len == 0) return null; // `name` is required for a license object
    var obj: ObjectMap = .empty;
    try obj.put(a, "name", .{ .string = l.name });
    // identifier and url are mutually exclusive; SPDX identifier preferred.
    if (l.identifier.len > 0) {
        try obj.put(a, "identifier", .{ .string = l.identifier });
    } else if (l.url.len > 0) {
        try obj.put(a, "url", .{ .string = l.url });
    }
    return .{ .object = obj };
}

/// Lowercased method name for the path-item key (`GET` → `get`).
fn methodKey(a: std.mem.Allocator, method: wing.talon.http.Method) ![]const u8 {
    const name = @tagName(method);
    const lower = try a.alloc(u8, name.len);
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    return lower;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "assemble: groups operations under paths, dedups components, skips hidden" {
    const Ctx = wing.Context(struct { x: u32 });
    const User = struct { id: u64 };
    const Handlers = struct {
        fn list(ctx: *Ctx) anyerror!wing.Json([]User) {
            _ = ctx;
            return undefined;
        }
        fn show(ctx: *Ctx, path: wing.Path(struct { id: u64 })) anyerror!wing.Json(User) {
            _ = ctx;
            _ = path;
            return undefined;
        }
        fn secret(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    const operation = @import("operation.zig");
    const docs = [_]meta.RouteDoc{
        .{ .method = .GET, .path = "/users", .meta = .{ .summary = "List", .tags = &.{"users"} }, .build_op = operation.makeBuild(@TypeOf(Handlers.list)) },
        .{ .method = .GET, .path = "/users/:id", .meta = .{}, .build_op = operation.makeBuild(@TypeOf(Handlers.show)) },
        .{ .method = .GET, .path = "/secret", .meta = .{ .hidden = true }, .build_op = operation.makeBuild(@TypeOf(Handlers.secret)) },
    };

    const spec = try json(testing.allocator, .{ .title = "T", .version = "1" }, &docs);
    defer testing.allocator.free(spec);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, spec, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqualStrings("3.1.0", root.get("openapi").?.string);
    const paths = root.get("paths").?.object;
    try testing.expect(paths.contains("/users"));
    try testing.expect(paths.contains("/users/{id}")); // wing `:id` → OpenAPI template
    try testing.expect(!paths.contains("/users/:id"));
    try testing.expect(!paths.contains("/secret")); // hidden
    // Default operationId derived from method + path.
    try testing.expectEqualStrings("get_users_id", paths.get("/users/{id}").?.object.get("get").?.object.get("operationId").?.string);
    // User schema registered exactly once and shared via $ref.
    try testing.expectEqual(@as(usize, 1), root.get("components").?.object.get("schemas").?.object.count());
    try testing.expectEqualStrings("List", paths.get("/users").?.object.get("get").?.object.get("summary").?.string);
}

test "assemble: auth extractor binds app scheme → per-op security + securitySchemes" {
    const Ctx = wing.Context(struct { x: u32 });
    // Intent-only marker; the scheme comes from info.auth_scheme below.
    const Auth = struct {
        principal: u32,
        pub const auth_requirement = .{ .optional = false };
    };
    const Handlers = struct {
        fn me(ctx: *Ctx, a: Auth) anyerror!void {
            _ = ctx;
            _ = a;
        }
        fn public(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
    };

    const operation = @import("operation.zig");
    const docs = [_]meta.RouteDoc{
        .{ .method = .GET, .path = "/me", .meta = .{}, .build_op = operation.makeBuild(@TypeOf(Handlers.me)) },
        .{ .method = .GET, .path = "/", .meta = .{}, .build_op = operation.makeBuild(@TypeOf(Handlers.public)) },
    };

    const spec = try json(testing.allocator, .{
        .title = "T",
        .version = "1",
        .auth_scheme = .{ .name = "cookieSession", .kind = "apiKey", .in = "cookie", .parameter_name = "session_id" },
    }, &docs);
    defer testing.allocator.free(spec);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, spec, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Scheme defined once under components.securitySchemes.
    const schemes = root.get("components").?.object.get("securitySchemes").?.object;
    try testing.expectEqualStrings("apiKey", schemes.get("cookieSession").?.object.get("type").?.string);
    try testing.expectEqualStrings("session_id", schemes.get("cookieSession").?.object.get("name").?.string);
    // Gated op carries security; public op does not.
    try testing.expect(root.get("paths").?.object.get("/me").?.object.get("get").?.object.contains("security"));
    try testing.expect(!root.get("paths").?.object.get("/").?.object.get("get").?.object.contains("security"));
}

test "assemble: info contact/license/summary emitted; empty omitted" {
    const spec = try json(testing.allocator, .{
        .title = "T",
        .version = "1",
        .summary = "short",
        .description = "long",
        .contact = .{ .name = "Ada", .url = "https://example.test" },
        .license = .{ .name = "MIT", .identifier = "MIT", .url = "https://ignored" },
    }, &.{});
    defer testing.allocator.free(spec);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, spec, .{});
    defer parsed.deinit();
    const info = parsed.value.object.get("info").?.object;

    try testing.expectEqualStrings("short", info.get("summary").?.string);
    try testing.expectEqualStrings("Ada", info.get("contact").?.object.get("name").?.string);
    try testing.expectEqualStrings("https://example.test", info.get("contact").?.object.get("url").?.string);
    try testing.expect(!info.get("contact").?.object.contains("email")); // unset → omitted
    // identifier wins over url for license (mutually exclusive).
    try testing.expectEqualStrings("MIT", info.get("license").?.object.get("identifier").?.string);
    try testing.expect(!info.get("license").?.object.contains("url"));

    // No contact/license fields set → those objects are absent entirely.
    const bare = try json(testing.allocator, .{ .title = "T", .version = "1" }, &.{});
    defer testing.allocator.free(bare);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, bare, .{});
    defer parsed2.deinit();
    const info2 = parsed2.value.object.get("info").?.object;
    try testing.expect(!info2.contains("contact"));
    try testing.expect(!info2.contains("license"));
    try testing.expect(!info2.contains("summary"));
}
