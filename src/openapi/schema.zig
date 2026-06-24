//! Zig type → JSON Schema (OpenAPI 3.1 / JSON Schema 2020-12).
//!
//! Comptime reflection over a type produces a `std.json.Value` schema node.
//! Named structs are registered once in the shared `components` map and
//! referenced by `$ref` (dedup by fully-qualified `@typeName`); everything
//! else is inlined. The field-traversal here is the same `inline for` shape
//! the validator uses, so the two can share infrastructure later.

const std = @import("std");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

const ref_prefix = "#/components/schemas/";

/// Schema node for `T`. Named structs return a `$ref` and are registered in
/// `components`; scalars/optionals/arrays/enums are inlined.
pub fn schemaValue(comptime T: type, gpa: std.mem.Allocator, components: *ObjectMap) anyerror!Value {
    return switch (@typeInfo(T)) {
        .bool => try scalar(gpa, "boolean"),
        .int => |i| try integerNode(gpa, i.bits),
        .float => try scalar(gpa, "number"),
        .optional => |o| try nullable(try schemaValue(o.child, gpa, components), gpa),
        .@"enum" => |e| try enumNode(gpa, e),
        .array => |a| try arrayNode(a.child, gpa, components),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                try scalar(gpa, "string") // []const u8 / []u8 → string
            else
                try arrayNode(p.child, gpa, components),
            else => @compileError("openapi: unsupported pointer type " ++ @typeName(T) ++
                " — only slices ([]T, []const u8) are supported"),
        },
        .@"struct" => blk: {
            try defineStruct(T, gpa, components);
            break :blk try refNode(T, gpa);
        },
        else => @compileError("openapi: unsupported type " ++ @typeName(T)),
    };
}

/// Registers `T`'s full object schema in `components` (idempotent by
/// `@typeName`), recursing into named-struct fields. A null placeholder is
/// inserted first so self-referential types terminate.
pub fn defineStruct(comptime T: type, gpa: std.mem.Allocator, components: *ObjectMap) anyerror!void {
    const name = @typeName(T);
    if (components.contains(name)) return;
    try components.put(gpa, name, .null); // recursion guard; overwritten below

    var props: ObjectMap = .empty;
    var required: Array = .init(gpa);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        try props.put(gpa, f.name, try schemaValue(f.type, gpa, components));
        if (isRequired(f)) try required.append(.{ .string = f.name });
    }

    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "object" });
    try obj.put(gpa, "properties", .{ .object = props });
    if (required.items.len > 0) try obj.put(gpa, "required", .{ .array = required });
    try components.put(gpa, name, .{ .object = obj });
}

/// A struct field is required unless it is optional or has a default value —
/// the same rule wing's Query parser applies (extract.zig parseQuery).
pub fn isRequired(comptime f: std.builtin.Type.StructField) bool {
    return @typeInfo(f.type) != .optional and f.defaultValue() == null;
}

fn scalar(gpa: std.mem.Allocator, comptime type_name: []const u8) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = type_name });
    return .{ .object = obj };
}

fn integerNode(gpa: std.mem.Allocator, bits: u16) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "integer" });
    try obj.put(gpa, "format", .{ .string = if (bits <= 32) "int32" else "int64" });
    return .{ .object = obj };
}

fn enumNode(gpa: std.mem.Allocator, comptime e: std.builtin.Type.Enum) !Value {
    var values: Array = .init(gpa);
    inline for (e.fields) |field| try values.append(.{ .string = field.name });
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "string" });
    try obj.put(gpa, "enum", .{ .array = values });
    return .{ .object = obj };
}

fn arrayNode(comptime Child: type, gpa: std.mem.Allocator, components: *ObjectMap) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "type", .{ .string = "array" });
    try obj.put(gpa, "items", try schemaValue(Child, gpa, components));
    return .{ .object = obj };
}

fn refNode(comptime T: type, gpa: std.mem.Allocator) !Value {
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "$ref", .{ .string = ref_prefix ++ @typeName(T) });
    return .{ .object = obj };
}

/// OpenAPI 3.1 nullability. Scalars with a string `type` collapse to the
/// `["x","null"]` union; anything else (e.g. a `$ref`) uses `anyOf`.
fn nullable(inner: Value, gpa: std.mem.Allocator) !Value {
    if (inner == .object) {
        if (inner.object.get("type")) |t| {
            if (t == .string) {
                var node = inner;
                var types: Array = .init(gpa);
                try types.append(.{ .string = t.string });
                try types.append(.{ .string = "null" });
                try node.object.put(gpa, "type", .{ .array = types });
                return node;
            }
        }
    }
    var any_of: Array = .init(gpa);
    try any_of.append(inner);
    try any_of.append(try scalar(gpa, "null"));
    var obj: ObjectMap = .empty;
    try obj.put(gpa, "anyOf", .{ .array = any_of });
    return .{ .object = obj };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn render(value: Value, gpa: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.write(value);
    return out.written();
}

test "schema: scalars, optionals, slices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var components: ObjectMap = .empty;

    try testing.expectEqualStrings(
        \\{"type":"integer","format":"int64"}
    , try render(try schemaValue(u64, a, &components), a));
    try testing.expectEqualStrings(
        \\{"type":"integer","format":"int32"}
    , try render(try schemaValue(u16, a, &components), a));
    try testing.expectEqualStrings(
        \\{"type":"string"}
    , try render(try schemaValue([]const u8, a, &components), a));
    try testing.expectEqualStrings(
        \\{"type":"boolean"}
    , try render(try schemaValue(bool, a, &components), a));
    // Optional scalar → 3.1 type-array union.
    try testing.expectEqualStrings(
        \\{"type":["string","null"]}
    , try render(try schemaValue(?[]const u8, a, &components), a));
    // Slice of strings → array of string.
    try testing.expectEqualStrings(
        \\{"type":"array","items":{"type":"string"}}
    , try render(try schemaValue([]const []const u8, a, &components), a));
}

test "schema: named struct registers a component and refs it" {
    const User = struct { id: u64, name: []const u8, nickname: ?[]const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var components: ObjectMap = .empty;

    const node = try schemaValue(User, a, &components);
    // Reference, not inline.
    try testing.expect(node.object.contains("$ref"));
    try testing.expectEqual(@as(usize, 1), components.count());

    const def = components.get(@typeName(User)).?;
    // id + name required, nickname optional.
    const req = def.object.get("required").?.array;
    try testing.expectEqual(@as(usize, 2), req.items.len);
    try testing.expect(def.object.get("properties").?.object.contains("nickname"));
}
