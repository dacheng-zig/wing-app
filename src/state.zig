//! Application state — the explicit dependency graph.
//!
//! wing has no DI container: you aggregate every shared dependency into one
//! `AppState` struct, and the framework hands handlers a `*AppState` (or, via
//! comptime type-matching, a `*` projection of any top-level field). This file
//! is where the layers are wired together: config + repositories → services.
//!
//! Each top-level field must have a distinct type so projection is
//! unambiguous (see the wing user guide §4.1). Handlers then declare
//! `*Config` or `*UserService` parameters and receive the matching field.

const std = @import("std");
const wing = @import("wing");

const Config = @import("config/config.zig").Config;
const Database = @import("db/database.zig").Database;
const UserService = @import("services/user_service.zig").UserService;
const UserRepository = @import("repositories/user_repository.zig").UserRepository;

pub const AppState = struct {
    config: Config,
    /// App-wide shared MySQL pool. Owned here; repositories borrow it.
    database: Database,
    users: UserService,

    pub fn init(gpa: std.mem.Allocator, config: Config) !AppState {
        const database = try Database.init(gpa, config.db);
        return .{
            .config = config,
            .database = database,
            .users = UserService.init(UserRepository.init(gpa, database.pool)),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.database.deinit();
    }

    /// Run startup migrations (create tables). Must be called inside the zio
    /// runtime, after `init`, before serving.
    pub fn migrate(self: *AppState) !void {
        try self.database.migrate();
    }
};

/// Shared handler context alias, so layers don't re-spell `wing.Context(...)`.
pub const Ctx = wing.Context(AppState);
