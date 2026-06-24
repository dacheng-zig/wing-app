//! `openapi.Router(State)`: a thin wrapper around `wing.Router(State)`.
//!
//! Every registration mirrors wing's method, forwards to the inner router for
//! real routing, then records a `RouteDoc` for documentation — one call drives
//! both, so there is no parallel hand-written table to drift.
//! `nest`/`merge` mirror wing's move semantics and fold the prefix into the
//! recorded paths directly (the prefix is known at the call site, so no radix
//! tree walk is needed).
//!
//! `intoRouter` hands the real `wing.Router` to the server; the wrapper is then
//! deinitialized (its scratch arena holds only nested-path strings).

const std = @import("std");
const wing = @import("wing");

const meta = @import("meta.zig");
const operation = @import("operation.zig");
const assemble = @import("assemble.zig");

const Method = wing.talon.http.Method;

pub fn Router(comptime State: type) type {
    return struct {
        const Self = @This();

        inner: wing.Router(State),
        docs: std.ArrayList(meta.RouteDoc),
        /// Owns nested-path strings (joined in `nest`); freed in `deinit`.
        path_arena: std.heap.ArenaAllocator,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .inner = wing.Router(State).init(gpa),
                .docs = .empty,
                .path_arena = std.heap.ArenaAllocator.init(gpa),
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            self.docs.deinit(self.gpa);
            self.path_arena.deinit();
            self.inner.deinit();
        }

        // ── Registration (mirrors wing.Router) ──────────────────────────

        pub fn get(self: *Self, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.add(.GET, path, h, .{}, doc);
        }
        pub fn post(self: *Self, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.add(.POST, path, h, .{}, doc);
        }
        pub fn put(self: *Self, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.add(.PUT, path, h, .{}, doc);
        }
        pub fn delete(self: *Self, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.add(.DELETE, path, h, .{}, doc);
        }
        pub fn patch(self: *Self, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.add(.PATCH, path, h, .{}, doc);
        }

        /// Full form: routes through the inner router with wing route options
        /// (auth/cors/guard), then records the doc — the single point both the
        /// shortcuts above and direct callers funnel through.
        pub fn add(
            self: *Self,
            method: Method,
            path: []const u8,
            comptime h: anytype,
            options: wing.RouteOptions,
            doc: meta.Meta,
        ) !void {
            try self.inner.add(method, path, h, options);
            try self.record(method, path, h, doc);
        }

        pub fn fallback(self: *Self, comptime h: anytype) void {
            self.inner.fallback(h);
        }

        fn record(self: *Self, method: Method, path: []const u8, comptime h: anytype, doc: meta.Meta) !void {
            try self.docs.append(self.gpa, .{
                .method = method,
                .path = path,
                .meta = doc,
                .build_op = operation.makeBuild(@TypeOf(h)),
            });
        }

        // ── Composition (mirrors wing.Router move semantics) ────────────

        pub fn nest(self: *Self, prefix: []const u8, other: *Self) !void {
            try self.inner.nest(prefix, &other.inner);
            for (other.docs.items) |d| {
                try self.docs.append(self.gpa, .{
                    .method = d.method,
                    .path = try joinPath(self.path_arena.allocator(), prefix, d.path),
                    .meta = d.meta,
                    .build_op = d.build_op,
                });
            }
            other.docs.clearRetainingCapacity();
        }

        pub fn merge(self: *Self, other: *Self) !void {
            try self.inner.merge(&other.inner);
            try self.docs.appendSlice(self.gpa, other.docs.items);
            other.docs.clearRetainingCapacity();
        }

        // ── Output ──────────────────────────────────────────────────────

        /// Assembles the OpenAPI document from the recorded routes. Returned
        /// bytes are owned by `gpa` (caller frees).
        pub fn openApiJson(self: *Self, gpa: std.mem.Allocator, info: meta.ApiInfo) ![]const u8 {
            return assemble.json(gpa, info, self.docs.items);
        }

        /// Moves the real router out for the server; leaves an empty inner so
        /// the wrapper stays safe to `deinit`.
        pub fn intoRouter(self: *Self) wing.Router(State) {
            const router = self.inner;
            self.inner = wing.Router(State).init(self.gpa);
            return router;
        }
    };
}

/// Mirrors wing's nest: a sub-route "/" maps to the prefix itself, otherwise
/// the prefix is prepended.
fn joinPath(arena: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/")) return prefix;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, path });
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "router: nest folds the prefix into documented paths" {
    const State = struct { x: u32 };
    const Ctx = wing.Context(State);
    const Handlers = struct {
        fn index(ctx: *Ctx) anyerror!void {
            _ = ctx;
        }
        fn show(ctx: *Ctx, path: wing.Path(struct { id: u64 })) anyerror!void {
            _ = ctx;
            _ = path;
        }
    };

    var users = Router(State).init(testing.allocator);
    defer users.deinit();
    try users.get("/", Handlers.index, .{});
    try users.get("/:id", Handlers.show, .{});

    var root = Router(State).init(testing.allocator);
    defer root.deinit();
    try root.nest("/api/v1/users", &users);

    try testing.expectEqual(@as(usize, 2), root.docs.items.len);
    try testing.expectEqualStrings("/api/v1/users", root.docs.items[0].path);
    try testing.expectEqualStrings("/api/v1/users/:id", root.docs.items[1].path);
    // Move semantics: source emptied.
    try testing.expectEqual(@as(usize, 0), users.docs.items.len);
}
