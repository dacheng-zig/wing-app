//! Central SQL registry.
//!
//! Every SQL statement the app issues lives here, so SQL is managed in one
//! place instead of being scattered as string literals across repositories.
//! Schema migrations and per-feature queries are grouped as named constants;
//! repositories reference these constants rather than inlining SQL, and the
//! shared `Database` applies the migrations at startup.

/// Schema migrations, applied in order at startup by `Database.migrate`.
/// Each statement must be idempotent (`IF NOT EXISTS`) so re-running is safe.
/// The target database itself must already exist (the app manages tables, not
/// the database).
pub const migrations = [_][]const u8{
    \\CREATE TABLE IF NOT EXISTS users (
    \\  id   BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
    \\  name VARCHAR(255) NOT NULL
    \\) ENGINE=InnoDB
    ,
};

/// Queries for the `users` feature.
pub const users = struct {
    pub const insert = "INSERT INTO users (name) VALUES (?)";
    pub const select_by_id = "SELECT id, name FROM users WHERE id = ?";
    pub const select_all = "SELECT id, name FROM users ORDER BY id";
};
