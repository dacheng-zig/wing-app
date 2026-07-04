//! Data-access layer for user roles — mantle (MySQL) implementation.
//!
//! Read-only in v1: it answers "what roles does this user hold?" for the auth
//! extractors. Role assignment has no endpoint yet (out of scope), so there is
//! deliberately no write path here. Ownership follows user_repository.zig: scan
//! into `gpa`-backed scratch, freed at once, and duplicate every role string
//! the caller keeps into the request `arena`.

const std = @import("std");
const mantle = @import("mantle");
const Id = @import("wing_id").Id;

const sql = struct {
    const roles_of = "SELECT role FROM roles WHERE user_id = ?";
};

/// Row shape for the roles query.
const RoleRow = struct {
    role: []const u8,
};

pub const RoleRepository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) RoleRepository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Snapshot a user's roles into `arena` (duplicated strings), so the slice
    /// stays valid for the whole request. Returns an empty slice for a user
    /// with no roles.
    pub fn rolesOf(self: *RoleRepository, arena: std.mem.Allocator, user_id: Id) ![]const []const u8 {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(RoleRow, self.gpa, sql.roles_of, .{user_id});
        defer table.deinit();

        const out = try arena.alloc([]const u8, table.rows.len);
        for (table.rows, out) |row, *dst| {
            dst.* = try arena.dupe(u8, row.role);
        }
        return out;
    }
};
