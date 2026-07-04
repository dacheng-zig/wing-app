//! Data-access layer for credentials — mantle (MySQL) implementation.
//!
//! One table backs both browser sessions and API tokens (see the multi-scheme
//! auth design §7). A credential is a single opaque secret; only its SHA-256
//! (`secret_hash`) is persisted and is the exact row key. Mirrors
//! user_repository.zig's ownership contract: query scratch is allocated from the
//! long-lived `gpa` and freed at once via `Table.deinit`; nothing is handed back
//! by reference, so there is no arena duplication. The pool is borrowed from the
//! shared `Database`, not owned.

const std = @import("std");
const mantle = @import("mantle");
const Id = @import("wing_id").Id;

const sql = struct {
    const insert = "INSERT INTO credentials (credential_id, secret_hash, user_id, issue_at, expire_at) VALUES (?, ?, ?, ?, ?)";
    // NULL expire_at means "never expires" (long-lived token); a non-null
    // expiry is checked against the caller's clock.
    const resolve = "SELECT user_id FROM credentials WHERE secret_hash = ? AND (expire_at IS NULL OR expire_at > ?)";
    const delete_by_hash = "DELETE FROM credentials WHERE secret_hash = ?";
    // `expire_at` is epoch seconds; UNIX_TIMESTAMP() compares in the same unit
    // regardless of session time zone.
    const delete_expired = "DELETE FROM credentials WHERE expire_at IS NOT NULL AND expire_at < UNIX_TIMESTAMP() LIMIT ?";
};

/// Row shape for the credential resolve query (the CHAR(36) user_id
/// decodes via `Id.fromMantleText`).
const CredentialRow = struct {
    user_id: Id,
};

pub const CredentialRepository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) CredentialRepository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Persist a new credential row. `expire_at` null = never expires; it binds
    /// to SQL NULL via the driver. The slices are copied into the wire buffer, so
    /// the caller's memory need not outlive the call.
    pub fn insert(
        self: *CredentialRepository,
        secret_hash: []const u8,
        user_id: Id,
        issue_at: u64,
        expire_at: ?u64,
    ) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.insert, .{ Id.new(), secret_hash, user_id, issue_at, expire_at });
    }

    /// Resolve a non-expired credential to its `user_id`; `null` if absent or
    /// expired. `now` is wall-clock seconds (the caller's clock, so this stays
    /// IO-free of the system clock).
    pub fn resolve(self: *CredentialRepository, secret_hash: []const u8, now: u64) !?Id {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(
            CredentialRow,
            self.gpa,
            sql.resolve,
            .{ secret_hash, now },
        );
        defer table.deinit();

        if (table.rows.len == 0) return null;
        return table.rows[0].user_id;
    }

    /// Delete the credential with this hash (logout / revoke). Idempotent:
    /// deleting an absent row is a no-op.
    pub fn deleteByHash(self: *CredentialRepository, secret_hash: []const u8) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        _ = try db.conn.exec(self.gpa, sql.delete_by_hash, .{secret_hash});
    }

    /// Delete all rows past their `expire_at`, `limit` rows per statement
    /// (batched to keep row locks short). Returns the total rows removed.
    pub fn deleteExpired(self: *CredentialRepository, limit: u32) !u64 {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var total: u64 = 0;
        while (true) {
            const ok = try db.conn.exec(self.gpa, sql.delete_expired, .{limit});
            total += ok.affected_rows;
            if (ok.affected_rows < limit) break;
        }
        return total;
    }
};
