//! Data-access layer for users — mantle (MySQL) implementation.
//!
//! The repository is the seam between business logic and storage. It persists
//! users in MySQL via a connection pool it **borrows** from the shared
//! `Database` (see db/database.zig); it does not own or initialize the pool.
//! The SQL it issues lives in the `sql` block below, beside its only caller.
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
const Id = @import("wing_id").Id;

const sql = struct {
    const insert = "INSERT INTO users (user_id, name, username, password_hash) VALUES (?, ?, ?, ?)";
    const find_by_username = "SELECT user_id, password_hash FROM users WHERE username = ?";
    const update_password_hash = "UPDATE users SET password_hash = ? WHERE user_id = ?";
    const select_by_id = "SELECT user_id, name FROM users WHERE user_id = ?";
    const select_all = "SELECT user_id, name FROM users ORDER BY user_id";
};

/// MySQL ER_DUP_ENTRY — a UNIQUE constraint (here, `users.username`) was
/// violated. Translated to a domain error at this boundary so the MySQL-specific
/// code never leaks into the service layer.
const er_dup_entry = 1062;

/// Row shape for SELECTs. Field order/names map to the projected columns;
/// mantle scans binary rows into this struct (the CHAR(36) user_id decodes via
/// `Id.fromMantleText`).
const UserRow = struct {
    user_id: Id,
    name: []const u8,
};

/// Row shape for the credential lookup (login). Carries only what auth needs:
/// the id to bind a session to, and the stored hash to verify against.
const CredentialRow = struct {
    user_id: Id,
    password_hash: []const u8,
};

/// A user's stored credentials, returned by `findByUsername`. `password_hash`
/// is duplicated into the request `arena`.
pub const Credentials = struct {
    id: Id,
    password_hash: []const u8,
};

pub const UserRepository = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    /// Borrow the shared pool. The pool is owned by `Database`; the repository
    /// only holds a pointer to lease connections.
    pub fn init(gpa: std.mem.Allocator, pool: *mantle.TcpPool) UserRepository {
        return .{ .gpa = gpa, .pool = pool };
    }

    /// Insert a new user with credentials. `password_hash` is the already-hashed
    /// PHC string (this layer never sees plaintext). The returned `name` is
    /// duplicated into `arena`.
    pub fn create(
        self: *UserRepository,
        arena: std.mem.Allocator,
        name: []const u8,
        username: []const u8,
        password_hash: []const u8,
    ) !User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        const new_id = Id.new();
        _ = db.conn.exec(self.gpa, sql.insert, .{ new_id, name, username, password_hash }) catch |err| {
            // A duplicate username is a client error (409), not a server fault.
            if (err == error.ServerError) {
                if (db.conn.lastError()) |se| {
                    if (se.code == er_dup_entry) return error.UsernameTaken;
                }
            }
            return err;
        };
        return .{ .id = new_id, .name = try arena.dupe(u8, name) };
    }

    /// Look up a user's credentials by username for login; `null` when no row
    /// matches. The returned `password_hash` is duplicated into `arena`.
    pub fn findByUsername(self: *UserRepository, arena: std.mem.Allocator, username: []const u8) !?Credentials {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(
            CredentialRow,
            self.gpa,
            sql.find_by_username,
            .{username},
        );
        defer table.deinit();

        if (table.rows.len == 0) return null;
        const row = table.rows[0];
        return .{ .id = row.user_id, .password_hash = try arena.dupe(u8, row.password_hash) };
    }

    /// Replace a user's stored password hash. Used for rehash-on-login: when a
    /// successful verify finds the hash is on an older algorithm, the login path
    /// upgrades it to the current default. The new `password_hash` is an
    /// already-hashed PHC string (this layer never sees plaintext).
    pub fn updatePasswordHash(self: *UserRepository, id: Id, password_hash: []const u8) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        _ = try db.conn.exec(self.gpa, sql.update_password_hash, .{ password_hash, id });
    }

    /// Look up one user by id; `null` when no row matches. The returned `name`
    /// is duplicated into `arena`.
    pub fn findById(self: *UserRepository, arena: std.mem.Allocator, id: Id) !?User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAllParams(
            UserRow,
            self.gpa,
            sql.select_by_id,
            .{id},
        );
        defer table.deinit();

        if (table.rows.len == 0) return null;
        const row = table.rows[0];
        return .{ .id = row.user_id, .name = try arena.dupe(u8, row.name) };
    }

    /// Snapshot all users into `arena` (ids and duplicated names), so the slice
    /// stays valid for the whole response.
    pub fn list(self: *UserRepository, arena: std.mem.Allocator) ![]User {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();

        var table = try db.conn.queryAll(UserRow, self.gpa, sql.select_all);
        defer table.deinit();

        const out = try arena.alloc(User, table.rows.len);
        for (table.rows, out) |row, *dst| {
            dst.* = .{ .id = row.user_id, .name = try arena.dupe(u8, row.name) };
        }
        return out;
    }
};
