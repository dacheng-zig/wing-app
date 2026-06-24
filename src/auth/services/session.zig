//! Server-side session store (revocable).
//!
//! Sessions live in the database, so they can be revoked instantly (delete the
//! row) and carry no client-trusted state — the smallest attack surface. The
//! session ID is an opaque, high-entropy token (128-bit CSPRNG, hex-encoded)
//! with no business meaning.
//!
//! IO: Zig 0.16 removed the global `std.crypto.random` and wall-clock helpers,
//! so this store holds a `std.Io` for the CSPRNG token and the real-time clock
//! that stamps/checks expiry. The clock must be wall-clock (`.real`) so expiry
//! survives process restarts — a monotonic clock would reset.

const std = @import("std");
const SessionRepository = @import("../repositories/session_repository.zig").SessionRepository;

/// Session lifetime. Seven days balances usability against exposure; revocation
/// is immediate regardless, so this is an upper bound, not a security floor.
const ttl_seconds: u64 = 7 * 24 * 60 * 60;

pub const SessionStore = struct {
    io: std.Io,
    repo: SessionRepository,

    pub fn init(io: std.Io, repo: SessionRepository) SessionStore {
        return .{ .io = io, .repo = repo };
    }

    /// Create a session for `user_id`: 128-bit CSPRNG token, hex-encoded,
    /// persisted with an absolute expiry. Returns the session ID duplicated
    /// into `arena` (for the Set-Cookie header).
    pub fn create(self: *SessionStore, arena: std.mem.Allocator, user_id: u64) ![]const u8 {
        var raw: [16]u8 = undefined;
        try self.io.randomSecure(&raw); // CSPRNG, always a syscall
        const session_id = std.fmt.bytesToHex(raw, .lower); // [32]u8 by value

        const expires_at = self.nowSeconds() + ttl_seconds;
        try self.repo.insert(&session_id, user_id, expires_at);
        return arena.dupe(u8, &session_id);
    }

    /// Resolve a session ID to its `user_id`, or `null` if unknown/expired.
    pub fn resolve(self: *SessionStore, session_id: []const u8) !?u64 {
        return self.repo.resolve(session_id, self.nowSeconds());
    }

    /// Revoke a session immediately (logout). Idempotent.
    pub fn revoke(self: *SessionStore, session_id: []const u8) !void {
        return self.repo.delete(session_id);
    }

    /// Current wall-clock time in seconds. `.real` so persisted expiries remain
    /// meaningful across restarts. The `< 0` guard only triggers if the system
    /// clock is set before 1970 (effectively impossible); were it to happen,
    /// freshly created sessions would simply use a near-epoch baseline.
    fn nowSeconds(self: *SessionStore) u64 {
        const secs = std.Io.Clock.now(.real, self.io).toSeconds();
        return if (secs < 0) 0 else @intCast(secs);
    }
};
