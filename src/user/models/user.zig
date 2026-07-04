//! Domain model for the `users` feature.
//!
//! The model layer holds plain data: domain entities shared across layers. It
//! depends only on the app-wide id primitive (lib/wing-id), so every other
//! layer may import it freely. Handlers return this struct directly: `Id` is
//! JSON- and OpenAPI-native (see lib/wing-id), so no response DTO is needed.

const Id = @import("wing_id").Id;

/// Domain entity. `name` is owned by the request arena (see
/// user_repository.zig) and stays valid for the duration of the response.
pub const User = struct {
    id: Id,
    name: []const u8,
};
