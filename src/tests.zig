//! Unit-test aggregator.
//!
//! Pulls in the modules whose `test` blocks should run under `zig build test`.
//! These are the dependency-free auth units — pure logic and extractors driven
//! by hand-rolled fakes — so they compile and run without the HTTP stack or a
//! live database. DB-backed paths (repositories, real session/login flow) need
//! a MySQL instance and are covered by manual/integration checks instead.
//!
//! Whole-app typechecking is covered by `zig build` (it compiles the executable,
//! including the mantle-backed layers); this target adds runtime verification of
//! the security-critical auth logic.

test {
    // Entity ids (lib/wing-id) and the jobs pure layer (lib/wing-jobs) live in
    // their own modules and get their own test compiles in build.zig — test
    // collection stops at module boundaries.

    _ = @import("auth/models/principal.zig");
    _ = @import("auth/support/password.zig");
    _ = @import("auth/support/authorizer.zig");
    // Credential store: hashing/expiry logic exercised against a fake repo
    // (generic over the repository, so no MySQL needed here).
    _ = @import("auth/services/credential.zig");
    // Locators (axis A): cookie/bearer/query/header extraction, fake-request driven.
    _ = @import("auth/support/locate.zig");
    // Scheme/Composite + extractors: OR ordering, short-circuit, role gate.
    _ = @import("auth/support/scheme.zig");
    // App auth assembly: the single declaration of the default channel chain.
    _ = @import("auth/support/auth.zig");

    // openapi package tests live in lib/wing-openapi and get their own test compile
    // in build.zig (test collection stops at module boundaries).

    // catchAll maintenance middleware: bypass matching + 503 short-circuit,
    // driven by a fake ctx/next (no HTTP stack).
    _ = @import("middleware/maintenance.zig");

    // fd-limit admission policy: pure arithmetic (floor/ceiling/reserve).
    _ = @import("fd_limit.zig");
}
