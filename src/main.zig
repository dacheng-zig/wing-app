const std = @import("std");
const server = @import("server.zig");

/// Root log function: every std.log line gets timestamp + trace id + level + scope + msg.
pub const std_options: std.Options = .{
    .log_level = std.log.default_level,
    .log_scope_levels = &.{
        .{ .scope = .auth, .level = .info },
        .{ .scope = .users, .level = .info },
        .{ .scope = .mailer, .level = .info },
        .{ .scope = .jobs, .level = .info },
        .{ .scope = .wing, .level = .info },
        .{ .scope = .talon, .level = .warn },
        .{ .scope = .mantle, .level = .warn },
        .{ .scope = .zio, .level = .warn },
    },
    .logFn = @import("wing_trace").logFn,
};

pub fn main(init: std.process.Init) !void {
    try server.run(init);
}
