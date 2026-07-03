//! Domain model for the `users` feature.
//!
//! The model layer holds plain data: domain entities shared across layers. It
//! depends only on the app-wide id primitive (db/id.zig), so every other
//! layer may import it freely. Handlers return this struct directly: `Id` is
//! JSON- and OpenAPI-native (see db/id.zig), so no response DTO is needed.

const Id = @import("../../db/id.zig").Id;

/// Domain entity. `name` is owned by the request arena (see
/// user_repository.zig) and stays valid for the duration of the response.
pub const User = struct {
    id: Id,
    name: []const u8,
};
