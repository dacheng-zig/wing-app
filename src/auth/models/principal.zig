//! Request-scoped identity.
//!
//! `Principal` is the immutable answer to "who is this request?" — produced by
//! authentication (see extractor.zig) and read-only thereafter. Authorization
//! never mutates it; it only asks questions like `hasRole`. The slices it holds
//! are owned by the request arena (`ctx.arena`) and are reclaimed when the
//! request ends, so a `Principal` must not outlive the request that built it.
//!
//! v1 carries `id` + resolved `roles`. Claims (issuer-signed assertions such as
//! scope/email_verified) are a documented v2 extension point: adding them is a
//! purely additive change to this struct, so omitting them now does not force a
//! rework later (YAGNI).

const std = @import("std");
const Id = @import("wing_id").Id;

pub const Principal = struct {
    id: Id,
    /// Resolved roles for coarse-grained authorization. Arena-owned.
    roles: []const []const u8 = &.{},

    /// Whether this identity holds `role`. Linear scan: role sets are tiny
    /// (a handful per user), so a map would only add overhead.
    pub fn hasRole(self: Principal, role: []const u8) bool {
        for (self.roles) |r| {
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }
};

test "hasRole: present, absent, and empty set" {
    const a = Principal{ .id = .fromInt(1), .roles = &.{ "admin", "editor" } };
    try std.testing.expect(a.hasRole("admin"));
    try std.testing.expect(a.hasRole("editor"));
    try std.testing.expect(!a.hasRole("viewer"));

    const anon = Principal{ .id = .nil };
    try std.testing.expect(!anon.hasRole("admin"));
}
