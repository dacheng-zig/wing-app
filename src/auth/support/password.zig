//! Password hashing — a pluggable wrapper over Zig std's modern slow hashes.
//!
//! We store PHC strings (algorithm + params + salt + hash, self-describing) so
//! verification needs no out-of-band parameters and the cost can be raised
//! later without a schema change. The stored string's PHC/crypt prefix names the
//! algorithm, so `verify` dispatches on it and several algorithms coexist in one
//! `users.password_hash` column — which is what lets a table imported from a
//! bcrypt/scrypt system verify without forcing a password reset.
//!
//! New passwords use `default_algorithm` (argon2id, OWASP's first choice).
//! `verify` accepts argon2{id,i,d}, scrypt and bcrypt regardless of the default,
//! and `needsRehash` flags a stored hash whose algorithm differs from the
//! default so the login path can transparently upgrade it. PBKDF2 is
//! intentionally not offered (FIPS-only, no std PHC wrapper); see
//! docs/password-hashing-schemes-research.md.
//!
//! Ownership/IO: the memory-hard hashes need a real allocator for their scratch
//! (argon2id ~19 MiB, scrypt ~128 MiB per call, freed internally before
//! returning) — pass `gpa`, not the request arena, so it does not accumulate.
//! Hashing also needs a `std.Io` for the random salt; both `hash` and `verify`
//! take one explicitly (Zig 0.16 removed the global `std.crypto.random`).

const std = @import("std");

const pwhash = std.crypto.pwhash;
const argon2 = pwhash.argon2;
const scrypt = pwhash.scrypt;
const bcrypt = pwhash.bcrypt;

/// Slow-hash algorithms this project can store. Verification is supported for
/// all of them; `default_algorithm` selects which one fresh hashes use.
pub const Algorithm = enum { argon2id, scrypt, bcrypt };

/// Algorithm new passwords are hashed with. Flipping this only changes what
/// fresh and rehashed passwords use — existing rows of any algorithm keep
/// verifying (dispatch is by stored prefix). Compile-time so the leaf hashing
/// function called from a worker thread needs no extra parameter; promote to a
/// runtime config item only if per-deployment switching is ever required.
///
/// Keep this argon2id unless you have a specific reason (migration, FIPS, a
/// low-memory environment); see the research doc's recommendation matrix.
pub const default_algorithm: Algorithm = .argon2id;

/// OWASP-recommended parameters per algorithm.
/// - argon2id: t=2, m=19 MiB, p=1 — single-lane, plain synchronous CPU work.
/// - scrypt: ln=17 (N=2^17), r=8, p=1 — memory-hard but ~128 MiB/call, far
///   heavier than argon2id; lower `ln` if login concurrency makes memory the
///   bottleneck.
/// - bcrypt: rounds_log=10. `Params.owasp` also sets
///   `silently_truncate_password = false`, so passwords over bcrypt's 72-byte
///   limit are safely pre-hashed instead of silently truncated.
const argon2_params = argon2.Params.owasp_2id;
const scrypt_params = scrypt.Params.owasp;
const bcrypt_params = bcrypt.Params.owasp;

/// Upper bound for the PHC output string. The longest we emit is scrypt's PHC
/// encoding (≤101 bytes); argon2id ≈96 and bcrypt ≈80. 128 is safe, and the
/// `users.password_hash` column is `VARCHAR(255)`, so none of these truncate.
const phc_max = 128;

/// Hash `plain` with `default_algorithm`, returning a PHC string in `arena`.
///
/// `gpa` backs the transient memory-hard buffer; `io` supplies the random salt.
/// Distinct calls on the same password yield distinct hashes (per-call salt).
pub fn hash(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    plain: []const u8,
) ![]const u8 {
    return hashWith(io, gpa, arena, default_algorithm, plain);
}

/// Hash `plain` with an explicit `algorithm`. `hash` is the common entry; this
/// exists so the login path can rehash into the current default and so tests
/// can exercise each algorithm directly.
pub fn hashWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    algorithm: Algorithm,
    plain: []const u8,
) ![]const u8 {
    var buf: [phc_max]u8 = undefined;
    const phc = switch (algorithm) {
        .argon2id => try argon2.strHash(
            plain,
            .{ .allocator = gpa, .params = argon2_params, .mode = .argon2id },
            &buf,
            io,
        ),
        .scrypt => try scrypt.strHash(
            plain,
            .{ .allocator = gpa, .params = scrypt_params, .encoding = .phc },
            &buf,
            io,
        ),
        .bcrypt => try bcrypt.strHash(
            plain,
            .{ .params = bcrypt_params, .encoding = .phc },
            &buf,
            io,
        ),
    };
    // `phc` points into the stack buffer; copy it out before it dies.
    return arena.dupe(u8, phc);
}

/// Verify `plain` against a stored PHC/crypt string in constant time, with the
/// algorithm chosen by the stored prefix. Returns `false` for a mismatch or any
/// malformed/unsupported stored hash — callers must not distinguish those cases
/// to the client (avoids user enumeration).
pub fn verify(io: std.Io, gpa: std.mem.Allocator, stored: []const u8, plain: []const u8) bool {
    switch (algorithmOf(stored) orelse return false) {
        // argon2.strVerify re-derives the exact mode (id/i/d) from the string.
        .argon2id => argon2.strVerify(stored, plain, .{ .allocator = gpa }, io) catch return false,
        .scrypt => scrypt.strVerify(stored, plain, .{ .allocator = gpa }) catch return false,
        // Must match the hash-side truncation behaviour (`owasp` → false).
        .bcrypt => bcrypt.strVerify(stored, plain, .{ .silently_truncate_password = false }) catch return false,
    }
    return true;
}

/// Whether `stored` should be re-hashed with `default_algorithm`. True when its
/// algorithm differs from the default (e.g. a bcrypt hash migrated in while the
/// default is argon2id). Call after a successful `verify`, while the plaintext
/// is in hand, to transparently upgrade the row.
///
/// Returns `false` for an unrecognised string (nothing safe to do) and for a
/// hash already on the default algorithm. It detects an *algorithm* change only,
/// not a parameter (cost) bump within the same algorithm — raising e.g. argon2
/// `m`/`t` later would need a param-aware check, deferred until there is a
/// concrete cost increase to migrate to.
pub fn needsRehash(stored: []const u8) bool {
    const algo = algorithmOf(stored) orelse return false;
    return algo != default_algorithm;
}

/// Identify the algorithm of a stored hash from its PHC or crypt prefix, or
/// `null` if unrecognised. Accepts both this project's PHC output (`$argon2id$`,
/// `$scrypt$`, `$bcrypt$`) and the crypt-format strings other ecosystems emit
/// (`$7$` scrypt, `$2a$`/`$2b$`/`$2y$` bcrypt), so migrated tables verify.
fn algorithmOf(stored: []const u8) ?Algorithm {
    const has = std.mem.startsWith;
    if (has(u8, stored, "$argon2")) return .argon2id; // argon2id / argon2i / argon2d
    if (has(u8, stored, "$scrypt$") or has(u8, stored, "$7$")) return .scrypt;
    if (has(u8, stored, "$bcrypt$") or has(u8, stored, "$2")) return .bcrypt;
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "hash (default argon2id) then verify: correct accepts, wrong rejects" {
    const gpa = testing.allocator;
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const phc = try hash(testing.io, gpa, arena, "correct horse");
    try testing.expect(std.mem.startsWith(u8, phc, "$argon2id$")); // default algorithm
    try testing.expect(verify(testing.io, gpa, phc, "correct horse"));
    try testing.expect(!verify(testing.io, gpa, phc, "wrong horse"));
}

test "hash is salted: same password hashes differently but both verify" {
    const gpa = testing.allocator;
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try hash(testing.io, gpa, arena, "same");
    const b = try hash(testing.io, gpa, arena, "same");
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(verify(testing.io, gpa, a, "same"));
    try testing.expect(verify(testing.io, gpa, b, "same"));
}

test "verify dispatches across algorithms (round-trip for each)" {
    const gpa = testing.allocator;
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{ Algorithm.argon2id, .scrypt, .bcrypt }) |algo| {
        const phc = try hashWith(testing.io, gpa, arena, algo, "shared secret");
        try testing.expect(verify(testing.io, gpa, phc, "shared secret"));
        try testing.expect(!verify(testing.io, gpa, phc, "other secret"));
    }
}

test "verify accepts foreign crypt-format strings (migration: bcrypt $2b$, scrypt $7$)" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;

    // Simulate a hash produced by another ecosystem in crypt encoding.
    const bcrypt_crypt = try bcrypt.strHash(
        "migrated",
        .{ .params = bcrypt_params, .encoding = .crypt },
        &buf,
        testing.io,
    );
    try testing.expect(std.mem.startsWith(u8, bcrypt_crypt, "$2"));
    try testing.expect(verify(testing.io, gpa, bcrypt_crypt, "migrated"));
    try testing.expect(!verify(testing.io, gpa, bcrypt_crypt, "wrong"));
}

test "needsRehash: default algorithm no, foreign algorithm yes, garbage no" {
    const gpa = testing.allocator;
    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argon = try hashWith(testing.io, gpa, arena, .argon2id, "pw");
    const scr = try hashWith(testing.io, gpa, arena, .scrypt, "pw");
    const bcr = try hashWith(testing.io, gpa, arena, .bcrypt, "pw");

    // default_algorithm is argon2id: only the matching one is up-to-date.
    try testing.expectEqual(default_algorithm == .argon2id, !needsRehash(argon));
    try testing.expect(needsRehash(scr));
    try testing.expect(needsRehash(bcr));
    // Unrecognised → false (nothing safe to rehash from).
    try testing.expect(!needsRehash("not-a-phc-string"));
}

test "verify rejects a malformed stored hash without erroring" {
    try testing.expect(!verify(testing.io, testing.allocator, "not-a-phc-string", "x"));
    try testing.expect(!verify(testing.io, testing.allocator, "", "x"));
}
