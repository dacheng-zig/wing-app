//! RBAC authorizer — a replaceable policy seam.
//!
//! `can` is the single decision surface (à la Casbin's `enforce`), kept narrow
//! so the model behind it can evolve without touching callers. v1 treats a role
//! as a permission point: `can(roles, required)` is "does the user hold that
//! role". v2 can inject a role→permission table and answer `can(roles,
//! "post:update")` without changing this signature. Object-level checks
//! (owner/tenant) deliberately do NOT live here — they need the loaded record
//! and belong in the service layer — which keeps the permission space from
//! exploding.

const std = @import("std");

pub const Authorizer = struct {
    /// Whether `roles` satisfies `required`. v1: required names a role.
    ///
    /// This is the single coarse-grained authorization decision (the extractor
    /// `Role` policy routes through it). Object-level checks in the service
    /// layer still use `Principal.hasRole` directly; when v2 introduces a
    /// role→permission table here, those call sites must be migrated too, or the
    /// two authorization paths will diverge.
    pub fn can(self: *const Authorizer, roles: []const []const u8, required: []const u8) bool {
        _ = self;
        for (roles) |r| {
            if (std.mem.eql(u8, r, required)) return true;
        }
        return false;
    }
};

test "can: holds required role, lacks it, empty set" {
    const az = Authorizer{};
    try std.testing.expect(az.can(&.{ "admin", "editor" }, "admin"));
    try std.testing.expect(!az.can(&.{"editor"}, "admin"));
    try std.testing.expect(!az.can(&.{}, "admin"));
}
