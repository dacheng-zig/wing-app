//! Credential store (revocable, hash-at-rest) — the auth resolver.
//!
//! One store backs both browser sessions and API tokens: a credential is a
//! single opaque secret (256-bit CSPRNG, hex-encoded). Only its SHA-256
//! (`secret_hash`) is persisted; the plaintext secret is returned once at issue
//! and never stored, so a read-only DB leak yields no usable credential. To
//! authenticate, a presented secret is hashed and matched against the unique
//! `secret_hash` index — holding the secret is the proof of its preimage.
//!
//! Two axes stay orthogonal (see the multi-scheme auth design §2): this is the
//! *resolver* (secret → uid). The *locator* (where the secret comes from:
//! cookie / bearer / query / header) lives in locate.zig. v1 has one resolver
//! because sessions and tokens are the same hashed-secret shape; the resolver
//! axis stays open for heterogeneous credentials (e.g. JWT) later.
//!
//! IO: Zig 0.16 removed the global CSPRNG and wall-clock helpers, so the store
//! holds a `std.Io` for the secret bytes and the real-time clock that stamps and
//! checks expiry. The clock must be wall-clock (`.real`) so expiry survives
//! process restarts.
//!
//! Generic over the repository so the hashing/expiry logic is unit-testable
//! against a fake repo with no MySQL (state.zig wires the mantle-backed one).
//! Any `Repo` with `insert`/`resolve`/`deleteByHash` satisfies it.

const std = @import("std");
const Id = @import("../../db/id.zig").Id;

/// Secret entropy: 256-bit, matching the exposure surface of a long-lived API
/// token. Hex-encoded to a 64-char opaque token at issue.
const secret_bytes = 32;

/// SHA-256 of a presented secret, lower-hex. This is both the credential
/// identity and the exact row key (`WHERE secret_hash = ?`). 256-bit secrets
/// make the unique-index match effectively collision-free; security rests on the
/// secret's high entropy (preimage resistance), not on constant-time comparison,
/// so the database's ordinary index lookup is safe here.
pub fn secretHash(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn CredentialStore(comptime Repo: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        repo: Repo,

        pub fn init(io: std.Io, repo: Repo) Self {
            return .{ .io = io, .repo = repo };
        }

        /// Issue a credential for `user_id`: a 256-bit CSPRNG secret (hex),
        /// persisted as SHA-256(secret) plus `issue_at` and an optional expiry.
        /// `ttl` null = never expires (long-lived API token); otherwise the
        /// absolute expiry is `now + ttl`. Callers pass a trusted lifetime (a
        /// session constant, or null for a token), so no untrusted value reaches
        /// the arithmetic. Returns the plaintext secret duplicated into `arena` —
        /// the only time it exists outside the holder.
        pub fn issue(self: *Self, arena: std.mem.Allocator, user_id: Id, ttl: ?u64) ![]const u8 {
            var raw: [secret_bytes]u8 = undefined;
            try self.io.randomSecure(&raw); // CSPRNG, always a syscall
            const secret = std.fmt.bytesToHex(raw, .lower); // [64]u8 by value
            const hash = secretHash(&secret);
            const now = self.nowSeconds();
            const expire_at: ?u64 = if (ttl) |t| now + t else null;
            try self.repo.insert(&hash, user_id, now, expire_at);
            return arena.dupe(u8, &secret);
        }

        /// Resolve a presented secret to its `user_id`, or `null` if
        /// unknown/expired. Satisfies the resolver contract: `null` = unknown,
        /// `error` = real IO (never swallowed).
        pub fn resolve(self: *Self, token: []const u8) !?Id {
            const hash = secretHash(token);
            return self.repo.resolve(&hash, self.nowSeconds());
        }

        /// Revoke the credential for a presented secret (logout / token revoke).
        /// Idempotent.
        pub fn revoke(self: *Self, token: []const u8) !void {
            const hash = secretHash(token);
            return self.repo.deleteByHash(&hash);
        }

        /// Current wall-clock time in seconds. `.real` so persisted expiries
        /// remain meaningful across restarts. The `< 0` guard only triggers if
        /// the system clock predates 1970 (effectively impossible).
        fn nowSeconds(self: *Self) u64 {
            const secs = std.Io.Clock.now(.real, self.io).toSeconds();
            return if (secs < 0) 0 else @intCast(secs);
        }
    };
}

// --- tests -----------------------------------------------------------------
//
// The store is generic over its repository, so issue/resolve/revoke run against
// a fake repo (no MySQL). This covers the security-critical invariants: the
// plaintext secret is never what gets stored (only its SHA-256), expiry is
// honoured, and revoke removes the row.

const testing = std.testing;

test "secretHash: deterministic, 64-char lower-hex, distinct per input" {
    const a = secretHash("token-a");
    const b = secretHash("token-b");
    try testing.expectEqual(@as(usize, 64), a.len);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    // Deterministic: same input → same hash (the index-match invariant).
    try testing.expectEqualStrings(&a, &secretHash("token-a"));
    // Lower-hex only.
    for (a) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

/// Minimal in-memory repository: stores one credential, mirroring the SQL
/// expiry predicate (`expire_at == null or expire_at > now`).
const FakeRepo = struct {
    hash: [64]u8 = undefined,
    user_id: Id = .nil,
    issue_at: u64 = 0,
    expire_at: ?u64 = null,
    present: bool = false,
    io_error: bool = false,

    fn insert(self: *FakeRepo, secret_hash: []const u8, user_id: Id, issue_at: u64, expire_at: ?u64) !void {
        @memcpy(&self.hash, secret_hash);
        self.user_id = user_id;
        self.issue_at = issue_at;
        self.expire_at = expire_at;
        self.present = true;
    }
    fn resolve(self: *FakeRepo, secret_hash: []const u8, now: u64) !?Id {
        if (self.io_error) return error.ConnectionLost;
        if (!self.present or !std.mem.eql(u8, &self.hash, secret_hash)) return null;
        if (self.expire_at) |exp| if (exp <= now) return null;
        return self.user_id;
    }
    fn deleteByHash(self: *FakeRepo, secret_hash: []const u8) !void {
        if (self.present and std.mem.eql(u8, &self.hash, secret_hash)) self.present = false;
    }
};

const TestStore = CredentialStore(FakeRepo);

test "issue stores the hash (not the plaintext) and stamps issue_at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = TestStore.init(testing.io, .{});
    const secret = try store.issue(arena, .fromInt(7), null);

    // The returned secret is the 64-char hex plaintext; the row holds its hash.
    try testing.expectEqual(@as(usize, 64), secret.len);
    try testing.expect(!std.mem.eql(u8, &store.repo.hash, secret)); // hash != plaintext
    try testing.expectEqualStrings(&secretHash(secret), &store.repo.hash);
    try testing.expect(store.repo.issue_at > 0);
    try testing.expect(store.repo.expire_at == null); // ttl null → never expires
}

test "resolve: issued secret → uid; unknown/expired → null; IO error propagates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = TestStore.init(testing.io, .{});
    const secret = try store.issue(arena, .fromInt(42), 3600);

    try testing.expectEqual(@as(?Id, Id.fromInt(42)), try store.resolve(secret));
    try testing.expectEqual(@as(?Id, null), try store.resolve("some-other-secret"));

    // Expired: force the stored expiry into the past.
    store.repo.expire_at = 1;
    try testing.expectEqual(@as(?Id, null), try store.resolve(secret));

    store.repo.expire_at = null; // back to never-expires
    store.repo.io_error = true;
    try testing.expectError(error.ConnectionLost, store.resolve(secret));
}

test "revoke removes the credential (idempotent)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = TestStore.init(testing.io, .{});
    const secret = try store.issue(arena, .fromInt(9), null);

    try store.revoke(secret);
    try testing.expectEqual(@as(?Id, null), try store.resolve(secret));
    try store.revoke(secret); // idempotent: revoking again is a no-op
}
