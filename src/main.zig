const std = @import("std");
const server = @import("server.zig");

/// Root log function: every std.log line gets timestamp + trace id + level + scope + msg.
pub const std_options: std.Options = .{
    .logFn = @import("wing_trace").logFn,
};

pub fn main(init: std.process.Init) !void {
    try server.run(init);
}
