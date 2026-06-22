//! Data-access layer for users — mantle (MySQL) implementation.
//!
//! The repository is the seam between business logic and storage. It persists
//! users in MySQL via a connection pool it **borrows** from the shared
//! `Database` (see db/database.zig); it does not own or initialize the pool.
//! SQL text comes from the central registry (db/sql.zig), not inline literals.
//!
//! Concurrency: each call leases its own connection from the pool, so there is
//! no shared mutable state to synchronize here — the pool caps physical
//! connections and hands a distinct one to every in-flight request.
//!
//! Ownership: query scratch (result arenas) is allocated from the long-lived
//! `gpa` and freed immediately via `Table.deinit`. Every `name` handed back to
//! the caller is duplicated into the request `arena`, so it stays valid for the
//! response and is reclaimed when the request ends.

const std = @import("std");
const mantle = @import("mantle");
const User = @import("../models/user.zig").User;
const sql = @import("../db/sql.zig");

/// Row shape for SELECTs. Field order/names map to the projected columns;
/// mantle scans binary rows into this struct.
const UserRow = struct {
    id: u64,
    name: []const u8,
};

pub const UserRepository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    /// Borrow the shared pool. The pool is owned by `Database`; the repository
    /// only holds a pointer to lease connections.
    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) UserRepository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Insert a new user. The returned `name` is duplicated into `arena`.
    pub fn create(self: *UserRepository, arena: std.mem.Allocator, name: []const u8) !User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        const ok = try db.conn.exec(self.gpa, sql.users.insert, .{name});
        return .{ .id = ok.last_insert_id, .name = try arena.dupe(u8, name) };
    }

    /// Look up one user by id; `null` when no row matches. The returned `name`
    /// is duplicated into `arena`.
    pub fn findById(self: *UserRepository, arena: std.mem.Allocator, id: u64) !?User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(
            UserRow,
            self.gpa,
            sql.users.select_by_id,
            .{id},
        );
        defer table.deinit();

        if (table.rows.len == 0) return null;
        const row = table.rows[0];
        return .{ .id = row.id, .name = try arena.dupe(u8, row.name) };
    }

    /// Snapshot all users into `arena` (ids and duplicated names), so the slice
    /// stays valid for the whole response.
    pub fn list(self: *UserRepository, arena: std.mem.Allocator) ![]User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAll(UserRow, self.gpa, sql.users.select_all);
        defer table.deinit();

        const out = try arena.alloc(User, table.rows.len);
        for (table.rows, out) |row, *dst| {
            dst.* = .{ .id = row.id, .name = try arena.dupe(u8, row.name) };
        }
        return out;
    }
};
