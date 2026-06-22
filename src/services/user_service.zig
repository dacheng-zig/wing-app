//! Business-logic layer for users.
//!
//! Services own the rules and orchestration. They sit between controllers
//! (HTTP) and repositories (storage): controllers translate requests, services
//! enforce invariants, repositories persist. Keep HTTP types out of here — a
//! service should be callable from a CLI or a job, not just a web handler.

const std = @import("std");
const UserRepository = @import("../repositories/user_repository.zig").UserRepository;
const User = @import("../models/user.zig").User;

pub const UserService = struct {
    repo: UserRepository,

    pub fn init(repo: UserRepository) UserService {
        return .{ .repo = repo };
    }

    /// Register a user after validating business rules. Returned data is owned
    /// by `arena`. `error.InvalidName` is mapped to 400 in app.zig.
    pub fn register(self: *UserService, arena: std.mem.Allocator, name: []const u8) !User {
        if (name.len == 0) return error.InvalidName;
        return self.repo.create(arena, name);
    }

    /// Fetch one user; `error.NotFound` is mapped to 404 by wing's defaults.
    /// Returned data is owned by `arena`.
    pub fn get(self: *UserService, arena: std.mem.Allocator, id: u64) !User {
        return (try self.repo.findById(arena, id)) orelse error.NotFound;
    }

    pub fn list(self: *UserService, arena: std.mem.Allocator) ![]User {
        return self.repo.list(arena);
    }
};
