//! Entity ids: UUIDv7, generated app-side, stored as CHAR(36).
//!
//! Every table's primary key is a time-ordered UUIDv7 instead of an
//! AUTO_INCREMENT bigint: ids are generated here (no insert round-trip to
//! learn the key), stay insert-ordered for the clustered index, and don't
//! leak row counts. The 36-char lowercase hyphenated form is used everywhere
//! text appears — the CHAR(36) column, the HTTP boundary, and logs — so a
//! value copied from an API response matches the database literally.
//!
//! `Id` wraps `uuid.Uuid` (same 16-byte layout) to carry the codec
//! conventions of every boundary it crosses: mantle (`toMantleText` /
//! `fromMantleText` — repositories bind an `Id` parameter and scan `id: Id`
//! row fields directly), std.json (`jsonStringify`/`jsonParse` — response
//! and job-args structs hold `Id` fields that travel as the text form), and
//! the OpenAPI reflector (`openapi_type`/`openapi_format`). Call sites never
//! convert; the text form appears exactly where the wire needs it.
//!
//! Generation: a monotonic `V7Generator` guarantees uniqueness via its
//! counter; the PRNG only makes the low bits unpredictable across restarts.
//! Single-executor runtime, so neither needs locking. This is the one
//! process-wide id sequence — wing-trace's request-id middleware mints from
//! it too (`Id.new().toBase32()`).

const std = @import("std");
const uuid = @import("uuid");

pub const Id = extern struct {
    uuid: uuid.Uuid,

    /// All-zero sentinel — "no id" in tests and fakes.
    pub const nil: Id = .{ .uuid = .nil };

    /// Mint a new time-ordered id from the process-wide generator (the
    /// file-level `gen`/`prng` globals below — one monotonic sequence per
    /// process). Wall clock via the always-available io the std default
    /// logger uses (synchronous syscall, no scheduler yield).
    pub fn new() Id {
        const now = std.Io.Clock.now(.real, std.Options.debug_io);
        if (!seeded) {
            prng = .init(@truncate(@as(u96, @bitCast(now.toNanoseconds()))));
            seeded = true;
        }
        // Clamp a pre-1970 clock to 0 instead of tripping the @intCast safety
        // check — same policy as the request-id generator.
        const ms: u48 = @intCast(@max(now.toMilliseconds(), 0));
        return .{ .uuid = gen.next(prng.random(), ms) };
    }

    /// Deterministic ids for tests, without minting real v7 values.
    pub fn fromInt(n: u128) Id {
        return .{ .uuid = .fromInt(n) };
    }

    /// Canonical 36-char text form, by value — the boundary form (JSON
    /// responses, URLs, logs). Callers `arena.dupe` when the text must
    /// outlive their frame.
    pub fn toText(self: Id) [36]u8 {
        return uuid.toHexLower(self.uuid);
    }

    /// Parse the canonical text form (path params, job args).
    pub fn parse(text: []const u8) uuid.ParseError!Id {
        return .{ .uuid = try uuid.parse(text) };
    }

    /// Compact 26-char Crockford Base32 form. Same alphabet and width as the
    /// request-id middleware's trace ids (wing-trace), so an id rendered this
    /// way correlates with request logs — use it wherever an id serves as a
    /// trace_id. The canonical 36-char `toText` form remains the DB/JSON/HTTP
    /// boundary form.
    pub fn toBase32(self: Id) [26]u8 {
        return uuid.base32.toBase32(self.uuid);
    }

    /// Parse the compact Base32 form back into an id (`toBase32`'s inverse).
    pub fn fromBase32(text: []const u8) uuid.base32.DecodeError!Id {
        return .{ .uuid = try uuid.base32.fromBase32(text) };
    }

    /// mantle encode convention: an `Id` prepared-statement parameter binds
    /// as its canonical text (the CHAR(36) column value).
    pub fn toMantleText(self: Id, buf: []u8) []const u8 {
        buf[0..36].* = uuid.toHexLower(self.uuid);
        return buf[0..36];
    }

    /// mantle decode convention: an `id: Id` row field scans from a CHAR(36)
    /// column. Length-checked before parsing: any other width means the
    /// query projected the wrong column.
    pub fn fromMantleText(text: []const u8) !Id {
        if (text.len != 36) return error.InvalidId;
        return parse(text) catch error.InvalidId;
    }

    /// std.json convention: an `Id` field serializes as its canonical text.
    pub fn jsonStringify(self: Id, jw: anytype) !void {
        const text = uuid.toHexLower(self.uuid);
        try jw.write(@as([]const u8, &text));
    }

    /// std.json convention: an `Id` field parses from the canonical text
    /// (job args round-trip through this).
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Id {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer switch (token) {
            .allocated_string, .allocated_number => |s| allocator.free(s),
            else => {},
        };
        const text = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return parse(text) catch error.UnexpectedToken;
    }

    /// wing scalar convention: a Path/Query/Cookies field of type `Id`
    /// parses from the canonical text (malformed → the binder's 400).
    pub fn fromScalar(raw: []const u8) !Id {
        return parse(raw);
    }

    /// OpenAPI wire shape (see lib/wing-openapi/schema.zig): custom `jsonStringify`
    /// means field reflection would document a shape that never appears on
    /// the wire, so the schema is declared alongside it.
    pub const openapi_type = "string";
    pub const openapi_format = "uuid";
};

/// Process-wide generator state behind `Id.new` — kept at file scope so the
/// "this is one shared monotonic sequence per process" fact stays visible.
/// Single-executor runtime: no locking (same convention as wing-trace's
/// request-id generator).
var gen: uuid.V7Generator(.{}) = .empty;
var prng: std.Random.DefaultPrng = .init(0);
var seeded = false;

const testing = std.testing;

test "new: v7, monotonic within the process" {
    const a = Id.new();
    const b = Id.new();
    try testing.expectEqual(@as(u4, 7), a.uuid.version());
    try testing.expect(std.mem.order(u8, &a.uuid.bytes, &b.uuid.bytes) == .lt);
}

test "base32 round-trips" {
    const id = Id.new();
    const text = id.toBase32();
    try testing.expectEqual(@as(usize, 26), text.len);
    try testing.expectEqual(id, try Id.fromBase32(&text));
    try testing.expectError(error.InvalidLength, Id.fromBase32("tooshort"));
}

test "text/column round-trips" {
    const id = Id.new();
    const text = id.toText();
    try testing.expectEqual(id, try Id.parse(&text));
    try testing.expectEqual(id, try Id.fromMantleText(&text));
    try testing.expectError(error.InvalidId, Id.fromMantleText("short"));
    try testing.expectError(error.InvalidId, Id.fromMantleText("zz9f2845-d481-75f2-8ed5-e1ddfad13c17"));
}

test "json round-trips as the canonical text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Payload = struct { user_id: Id };
    const id = Id.new();

    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.write(Payload{ .user_id = id });

    var expected: [50]u8 = undefined;
    const expected_json = try std.fmt.bufPrint(&expected, "{{\"user_id\":\"{s}\"}}", .{&id.toText()});
    try testing.expectEqualStrings(expected_json, out.written());

    const back = try std.json.parseFromSliceLeaky(Payload, arena, out.written(), .{});
    try testing.expectEqual(id, back.user_id);

    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSliceLeaky(Payload, arena, "{\"user_id\":\"nope\"}", .{}),
    );
}
