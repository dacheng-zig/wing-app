//! handler signature → OpenAPI operation object.
//!
//! The two comptime classifiers:
//!   - `paramRole`: type-identity match against wing's public extractor
//!     constructors. `wing.Path(T)` evaluated twice is the *same* type
//!     (Zig memoizes generic instantiation), so `P == wing.Path(T)`
//!     unambiguously means "path params" without touching wing internals.
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
    /// Dependency-injection or auth parameter — not part of the API surface.
    skip,
    path: type,
    query: type,
    body: type,
};

fn paramRole(comptime P: type) Role {
    // Pointers are State/sub-state projections (`*Config`, `*UserService`).
    if (@typeInfo(P) == .pointer) return .skip;
    // Extractors with no `value` field (e.g. auth `Auth { principal }`).
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
        fn build(gpa: std.mem.Allocator, components: *ObjectMap) anyerror!Value {
            return operationValue(H, gpa, components);
        }
    }.build;
}

fn operationValue(comptime H: type, gpa: std.mem.Allocator, components: *ObjectMap) anyerror!Value {
    const fn_info = @typeInfo(H).@"fn";

    var op: ObjectMap = .empty;
    var params: Array = .init(gpa);
    var request_body: ?Value = null;

    inline for (fn_info.params[1..]) |p| {
        const P = p.type.?;
        switch (comptime paramRole(P)) {
            .skip => {},
            .path => |T| try appendParams(&params, gpa, components, T, "path"),
            .query => |T| try appendParams(&params, gpa, components, T, "query"),
            .body => |T| request_body = try jsonBody(T, gpa, components),
        }
    }

    if (params.items.len > 0) try op.put(gpa, "parameters", .{ .array = params });
    if (request_body) |rb| try op.put(gpa, "requestBody", rb);

    const resp = comptime responseOf(fn_info.return_type.?);
    try op.put(gpa, "responses", try responsesValue(resp, gpa, components));
    return .{ .object = op };
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

    const op = try operationValue(@TypeOf(Handler), a, &components);
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
}
