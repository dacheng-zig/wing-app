//! Domain model for the `users` feature.
//!
//! The model layer holds plain data: domain entities shared across layers. It
//! depends on nothing else in the app, so every other layer may import it
//! freely. HTTP request/response DTOs live with the handler that owns them (see
//! `../handlers`).

/// Domain entity. `name` is owned by the request arena (see
/// user_repository.zig) and stays valid for the duration of the response.
pub const User = struct {
    id: u64,
    name: []const u8,
};
