//! Business-logic layer for users.
//!
//! Services own the rules and orchestration. They sit between controllers
//! (HTTP) and repositories (storage): controllers translate requests, services
//! enforce invariants, repositories persist. Keep HTTP types out of here — a
//! service should be callable from a CLI or a job, not just a web handler.

const std = @import("std");
const zio = @import("zio");
const UserRepository = @import("../repositories/user_repository.zig").UserRepository;
const User = @import("../models/user.zig").User;
const CreateUserReq = @import("../models/user.zig").CreateUserReq;
const password = @import("../../auth/support/password.zig");

pub const UserService = struct {
    /// For hashing the password at registration (argon2 needs both).
    io: std.Io,
    gpa: std.mem.Allocator,
    repo: UserRepository,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, repo: UserRepository) UserService {
        return .{ .io = io, .gpa = gpa, .repo = repo };
    }

    /// Register a user after validating business rules, hashing the password
    /// before storage (plaintext never reaches the repository). Returned data
    /// is owned by `arena`. `error.InvalidCredentials` maps to 400 in app.zig.
    pub fn register(self: *UserService, arena: std.mem.Allocator, req: CreateUserReq) !User {
        if (req.name.len == 0 or req.username.len == 0 or req.password.len == 0)
            return error.InvalidCredentials;
        // argon2 hash is ~tens of ms of pure CPU; offload it to zio's thread
        // pool so the single HTTP executor isn't stalled. join() suspends this
        // coroutine, not the executor.
        var hash_task = try zio.spawnBlocking(password.hash, .{ self.io, self.gpa, arena, req.password });
        const hash = try hash_task.join();
        return self.repo.create(arena, req.name, req.username, hash);
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
