const std = @import("std");
const server = @import("server.zig");

/// Root log function: every std.log line gets timestamp + request id + level + scope + msg.
pub const std_options: std.Options = .{
    .logFn = @import("trace/log.zig").requestAwareLogFn,
};

pub fn main(init: std.process.Init) !void {
    try server.run(init);
}
