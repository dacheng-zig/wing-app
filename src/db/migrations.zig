//! Schema migrations.
//!
//! Each migration is a single, idempotent (`IF NOT EXISTS`) DDL statement kept
//! as a real `.sql` file under `migrations/` and embedded at compile time, so
//! schema lives as SQL (editor tooling, external migration tools) rather than
//! Zig string literals. The list order is the apply order — `Database.migrate`
//! runs each via `execSimple` at startup. The target database must already
//! exist (the app manages tables, not the database).
//!
//! These statements provision a fresh schema; they do not migrate an older
//! `users` table that predates the auth columns. A pre-existing dev database
//! must be dropped/recreated (the app is still pre-release).
//!
//! Migrations stay centralized here rather than per-module because they are a
//! single ordered set applied by one startup runner, spanning the users, roles,
//! and sessions tables together.

pub const migrations = [_][]const u8{
    @embedFile("migrations/001_create_users.sql"),
    @embedFile("migrations/002_create_roles.sql"),
    @embedFile("migrations/003_create_sessions.sql"),
};
