//! Authentication business logic: credential verification.
//!
//! Sits between the controller (HTTP) and storage: it looks up the stored hash
//! and verifies the password, returning the authenticated user id. Session
//! creation and cookie writing are the controller's job (they touch HTTP), so
//! this service stays callable from a CLI or a job.
//!
//! IO/allocator: argon2 verification needs a `std.Io` (salt-free here, but the
//! API requires it) and a `gpa` for its transient memory-hard buffer — both are
//! held explicitly rather than reaching through the repository.

const std = @import("std");
const UserRepository = @import("../../user/repositories/user_repository.zig").UserRepository;
const password = @import("../support/password.zig");

pub const AuthService = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    users: UserRepository,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, users: UserRepository) AuthService {
        return .{ .io = io, .gpa = gpa, .users = users };
    }

    /// Verify a username/password pair, returning the user id on success.
    ///
    /// Failure is always `error.Unauthorized` whether the user is missing or
    /// the password is wrong — the response must not let an attacker enumerate
    /// usernames (mapped to 401 by wing). `arena` owns the looked-up hash.
    pub fn login(self: *AuthService, arena: std.mem.Allocator, username: []const u8, plain: []const u8) !u64 {
        const cred = (try self.users.findByUsername(arena, username)) orelse
            return error.Unauthorized;
        if (!password.verify(self.io, self.gpa, cred.password_hash, plain))
            return error.Unauthorized;
        return cred.id;
    }
};
