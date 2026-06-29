//! POST /api/v1/auth/token/revoke — revoke the presented bearer token.
//!
//! `BearerOnly`: this endpoint owns the bearer credential, so the revoked object
//! is unambiguous. Re-read the secret from `Authorization` and delete its row.

const Ctx = @import("../../state.zig").Ctx;
const locate = @import("../support/locate.zig");
const BearerOnly = @import("../support/auth.zig").BearerOnly;

pub fn handle(ctx: *Ctx, auth: BearerOnly) anyerror!void {
    _ = auth; // presence enforces "must be authenticated via bearer"
    if (locate.Bearer.locate(ctx)) |secret| try ctx.state.credentials.revoke(secret);
}
