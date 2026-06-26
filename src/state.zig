//! Application state — the explicit dependency graph.
//!
//! wing has no DI container: you aggregate every shared dependency into one
//! `AppState` struct, and the framework hands handlers a `*AppState` (or, via
//! comptime type-matching, a `*` projection of any top-level field). This file
//! is where the layers are wired together: config + repositories → services.
//!
//! Each top-level field must have a distinct type so projection is
//! unambiguous. Handlers then declare
//! `*Config` or `*UserService` parameters and receive the matching field.

const std = @import("std");
const wing = @import("wing");

const Config = @import("config/config.zig").Config;
const Database = @import("db/database.zig").Database;
const UserService = @import("user/services/user_service.zig").UserService;
const UserRepository = @import("user/repositories/user_repository.zig").UserRepository;
const SessionStore = @import("auth/services/session.zig").SessionStore;
const SessionRepository = @import("auth/repositories/session_repository.zig").SessionRepository;
const RoleRepository = @import("auth/repositories/role_repository.zig").RoleRepository;
const Authorizer = @import("auth/support/authorizer.zig").Authorizer;
const AuthService = @import("auth/services/auth_service.zig").AuthService;

/// Wraps the assembled OpenAPI spec so it projects unambiguously by type
/// (a bare `[]const u8` field would collide with any future string field).
/// The bytes are owned by the server (app lifetime); filled after startup.
pub const ApiDocs = struct {
    spec: []const u8 = "",
};

pub const AppState = struct {
    config: Config,
    /// App-wide shared MySQL pool. Owned here; repositories borrow it.
    database: Database,
    users: UserService,
    /// Auth dependencies. Each has a distinct type so `*T` projection stays
    /// unambiguous; extractors/controllers reach them via `ctx.state.<field>`.
    sessions: SessionStore,
    roles: RoleRepository,
    authorizer: Authorizer,
    auth: AuthService,
    /// Assembled OpenAPI document, served by the `docs` feature. Populated by
    /// the server after `build()` generates it (default empty until then).
    api_docs: ApiDocs = .{},

    /// `io` supplies the CSPRNG, wall-clock, and argon2 entropy that Zig 0.16
    /// no longer exposes globally. It is threaded into the components that need
    /// it (password hashing, session tokens/expiry).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, config: Config) !AppState {
        const database = try Database.init(gpa, config.db);
        const pool = database.pool;
        return .{
            .config = config,
            .database = database,
            .users = UserService.init(io, gpa, UserRepository.init(gpa, pool)),
            .sessions = SessionStore.init(io, SessionRepository.init(gpa, pool)),
            .roles = RoleRepository.init(gpa, pool),
            .authorizer = .{},
            .auth = AuthService.init(io, gpa, UserRepository.init(gpa, pool)),
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
