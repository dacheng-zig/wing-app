//! Shared database resource: the app-wide MySQL connection pool.
//!
//! One pool is created at startup and shared by every repository. Repositories
//! borrow it to lease connections — they neither own nor initialize it, so the
//! pool lifecycle lives in exactly one place. The pool is heap-pinned (mantle
//! requires it not move after init), so passing `Database` by value only copies
//! the pointer.

const std = @import("std");
const mantle = @import("mantle");
const Db = @import("../config/config.zig").Db;
const sql = @import("sql.zig");

pub const Database = struct {
    gpa: std.mem.Allocator,
    pool: *mantle.TcpPool,

    pub fn init(gpa: std.mem.Allocator, cfg: Db) !Database {
        const pool = try gpa.create(mantle.TcpPool);
        errdefer gpa.destroy(pool);

        const target: mantle.TcpDriver.Target = .{
            .host = cfg.host,
            .port = cfg.port,
            .options = .{
                .username = cfg.username,
                .password = cfg.password,
                .database = cfg.database,
                .character_set = cfg.character_set,
            },
        };
        pool.* = mantle.TcpPool.init(gpa, mantle.TcpDriver.init(target), .{
            .max_connections = cfg.pool_size,
        });
        return .{ .gpa = gpa, .pool = pool };
    }

    pub fn deinit(self: *Database) void {
        self.pool.deinit();
        self.gpa.destroy(self.pool);
    }

    /// Apply all schema migrations in order. Run once at startup, inside the
    /// zio runtime. Connections dial lazily, so this is the first real I/O.
    pub fn migrate(self: *Database) !void {
        var db = try mantle.PooledConnection.acquire(self.pool);
        defer db.release();
        for (sql.migrations) |stmt| {
            try db.conn.execSimple(self.gpa, stmt);
        }
    }
};
