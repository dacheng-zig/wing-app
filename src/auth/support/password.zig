//! Password hashing — a thin wrapper over Zig's std argon2id.
//!
//! We store PHC strings (algorithm + params + salt + hash, self-describing) so
//! verification needs no out-of-band parameters and the cost can be raised
//! later without a schema change. argon2id is the OWASP-recommended default
//! (memory-hard, resistant to GPU brute force).
//!
//! Ownership/IO: argon2 needs a real allocator for its memory-hard scratch
//! (~19 MiB per call with `owasp_2id`), freed internally before returning — pass
//! `gpa`, not the request arena, so it does not accumulate. It also needs a
//! `std.Io` for the random salt; both `hash` and `verify` take one explicitly
//! (Zig 0.16 removed the global `std.crypto.random`).

const std = @import("std");

const argon2 = std.crypto.pwhash.argon2;

/// OWASP-recommended argon2id parameters (t=2, m=19 MiB, p=1). p=1 keeps the
/// derivation single-lane, so it runs as a plain synchronous CPU computation.
const params = argon2.Params.owasp_2id;

/// Upper bound for the PHC output string. The argon2id PHC encoding with a
/// 16-byte salt and 32-byte digest is well under 100 bytes; 128 is safe.
const phc_max = 128;

/// Hash `plain`, returning a PHC string duplicated into `arena`.
///
/// `gpa` backs argon2's transient memory-hard buffer; `io` supplies the random
/// salt. Distinct calls on the same password yield distinct hashes (per-call
/// salt).
pub fn hash(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    plain: []const u8,
) ![]const u8 {
    var buf: [phc_max]u8 = undefined;
    const phc = try argon2.strHash(
        plain,
        .{ .allocator = gpa, .params = params, .mode = .argon2id },
        &buf,
        io,
    );
    // `phc` points into the stack buffer; copy it out before it dies.
    return arena.dupe(u8, phc);
}

/// Verify `plain` against a stored PHC string in constant time. Returns `false`
/// for a mismatch or any malformed/unsupported stored hash — callers must not
/// distinguish those cases to the client (avoids user enumeration).
pub fn verify(io: std.Io, gpa: std.mem.Allocator, stored: []const u8, plain: []const u8) bool {
    argon2.strVerify(stored, plain, .{ .allocator = gpa }, io) catch return false;
    return true;
}

test "hash then verify: correct password accepts, wrong rejects" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const phc = try hash(std.testing.io, gpa, arena, "correct horse");
    try std.testing.expect(verify(std.testing.io, gpa, phc, "correct horse"));
    try std.testing.expect(!verify(std.testing.io, gpa, phc, "wrong horse"));
}

test "hash is salted: same password hashes differently" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try hash(std.testing.io, gpa, arena, "same");
    const b = try hash(std.testing.io, gpa, arena, "same");
    try std.testing.expect(!std.mem.eql(u8, a, b));
    // ...but both still verify.
    try std.testing.expect(verify(std.testing.io, gpa, a, "same"));
    try std.testing.expect(verify(std.testing.io, gpa, b, "same"));
}

test "verify rejects a malformed stored hash without erroring" {
    try std.testing.expect(!verify(std.testing.io, std.testing.allocator, "not-a-phc-string", "x"));
}
