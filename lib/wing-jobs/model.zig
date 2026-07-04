//! Job domain types and pure policy math (std-only, unit-testable
//! aside from the shared id primitive).

const std = @import("std");
const Id = @import("wing_id").Id;

/// Job lifecycle. Tag names match the DB `state` enum literally, so
/// `@tagName` is the SQL value and `stateFromSql` the inverse.
pub const State = enum {
    available,
    running,
    retryable,
    completed,
    cancelled,
    discarded,
};

pub fn stateFromSql(s: []const u8) ?State {
    return std.meta.stringToEnum(State, s);
}

/// A claimed job as handed to a worker. Owns its strings (duped out of the
/// claim result set); freed by the worker after finalize.
pub const ClaimedJob = struct {
    id: Id,
    kind: []const u8,
    args: []const u8,
    /// Attempt number of this execution (already incremented by the claim).
    attempt: u16,
    max_attempts: u16,

    pub fn deinit(self: *const ClaimedJob, gpa: std.mem.Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.args);
    }
};

/// Retry delay in seconds: `attempt^4 + 15` plus up to 10% jitter — the
/// cross-ecosystem default (1→16s, 5→~10m, 10→~2.8h; 20 attempts ≈ one week).
pub fn backoffSeconds(attempt: u16, random: std.Random) u64 {
    const a: u64 = @min(attempt, 25); // cap keeps the pow well inside u64
    const base = a * a * a * a + 15;
    return base + random.uintAtMost(u64, base / 10);
}

/// Uniqueness fingerprint stored in `jobs.unique_key` (VARBINARY(32)).
///
/// SHA-256 over kind, serialized args, and an optional throttle bucket, each
/// length-prefixed so concatenation can't collide. Args serialization is
/// std.json over the job struct (stable field order within a build), which is
/// canonical enough for self-produced payloads.
pub fn fingerprint(kind: []const u8, args_json: ?[]const u8, bucket: ?i64) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, kind.len, .little);
    h.update(&len_buf);
    h.update(kind);
    if (args_json) |args| {
        std.mem.writeInt(u64, &len_buf, args.len, .little);
        h.update(&len_buf);
        h.update(args);
    }
    if (bucket) |b| {
        std.mem.writeInt(i64, &len_buf, b, .little);
        h.update(&len_buf);
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

const testing = std.testing;

test "state sql round-trip" {
    inline for (@typeInfo(State).@"enum".fields) |f| {
        const s = stateFromSql(f.name).?;
        try testing.expectEqualStrings(f.name, @tagName(s));
    }
    try testing.expectEqual(@as(?State, null), stateFromSql("nope"));
}

test "backoff curve" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    // Base values without jitter bounds: attempt n in [base, base*1.1].
    const expect_base = [_]u64{ 16, 31, 96, 271, 640 };
    for (expect_base, 1..) |base, attempt| {
        const d = backoffSeconds(@intCast(attempt), r);
        try testing.expect(d >= base and d <= base + base / 10);
    }
    // Cap: absurd attempt values stay finite.
    _ = backoffSeconds(65535, r);
}

test "fingerprint dimensions" {
    const a = fingerprint("send_email", "{\"id\":1}", null);
    const b = fingerprint("send_email", "{\"id\":2}", null);
    const c = fingerprint("send_email", null, null);
    const d = fingerprint("send_email", "{\"id\":1}", 12345);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expect(!std.mem.eql(u8, &a, &c));
    try testing.expect(!std.mem.eql(u8, &a, &d));
    // Deterministic.
    try testing.expectEqualSlices(u8, &a, &fingerprint("send_email", "{\"id\":1}", null));
}
