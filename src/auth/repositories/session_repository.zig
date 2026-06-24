//! Data-access layer for server-side sessions — mantle (MySQL) implementation.
//!
//! Persists opaque session IDs and their expiry. Mirrors user_repository.zig's
//! ownership contract: query scratch is allocated from the long-lived `gpa` and
//! freed immediately via `Table.deinit`; nothing here is handed back by
//! reference, so there is no arena duplication to do. The pool is borrowed from
//! the shared `Database`, not owned.

const std = @import("std");
const mantle = @import("mantle");

const sql = struct {
    const session_insert = "INSERT INTO sessions (session_id, user_id, expires_at) VALUES (?, ?, ?)";
    const session_resolve = "SELECT user_id FROM sessions WHERE session_id = ? AND expires_at > ?";
    const session_delete = "DELETE FROM sessions WHERE session_id = ?";
};

/// Row shape for the session resolve query.
const SessionRow = struct {
    user_id: u64,
};

pub const SessionRepository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) SessionRepository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Persist a new session row. `session_id` is copied by the driver into the wire
    /// buffer, so the caller's slice need not outlive the call.
    pub fn insert(self: *SessionRepository, session_id: []const u8, user_id: u64, expires_at: u64) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.session_insert, .{ session_id, user_id, expires_at });
    }

    /// Resolve a non-expired session to its `user_id`; `null` if absent or
    /// expired. `now` is wall-clock seconds (the caller's clock, so this stays
    /// IO-free).
    pub fn resolve(self: *SessionRepository, session_id: []const u8, now: u64) !?u64 {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(
            SessionRow,
            self.gpa,
            sql.session_resolve,
            .{ session_id, now },
        );
        defer table.deinit();

        if (table.rows.len == 0) return null;
        return table.rows[0].user_id;
    }

    /// Delete a session (logout / revoke). Idempotent: deleting an absent row
    /// is a no-op.
    pub fn delete(self: *SessionRepository, session_id: []const u8) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.session_delete, .{session_id});
    }
};
