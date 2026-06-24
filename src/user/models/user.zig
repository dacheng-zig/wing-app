//! Domain model + DTOs for the `users` feature.
//!
//! The model layer holds plain data: domain entities and the request/response
//! shapes that cross the HTTP boundary. It depends on nothing else in the app,
//! so every other layer may import it freely.

/// Domain entity. `name` is owned by the request arena (see
/// user_repository.zig) and stays valid for the duration of the response.
pub const User = struct {
    id: u64,
    name: []const u8,
};

/// Request body for `POST /api/v1/users`. Bound from JSON by `wing.Json`.
/// Registration carries credentials: the password is hashed by the service
/// before storage (the schema requires `username`/`password_hash`).
pub const CreateUserReq = struct {
    name: []const u8,
    username: []const u8,
    password: []const u8,
};
