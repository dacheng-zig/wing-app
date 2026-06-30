//! Synchronous request-aware logging.
//!
//! `requestAwareLogFn` (wired via `std_options` in main.zig) prefixes every
//! std.log line with an ISO-8601 timestamp, the current request's id (from the
//! task-local request scope), level and scope, then writes it straight to
//! stderr under the std stderr lock. Mirrors std's own lock/unlock dance.
//!
//! Writes are synchronous: stderr is expected to be a regular file (or a sink
//! that returns promptly), so a write never stalls the single executor. An async
//! drain was evaluated and dropped — it only pays off when stderr can block
//! (pipe/tty), which this deployment does not do; see docs/request-id-logging.

const std = @import("std");
const trace = @import("trace.zig");
const req_scope = @import("scope.zig");

// Placeholder when no request scope is bound. Same 26-char Base32 width as real
// ids (see request_scope.zig) so columns line up; real UUIDv7 ids always carry
// version/variant bits, so the all-zero value is unambiguous.
const no_request_id = "00000000000000000000000000";

pub fn requestAwareLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Wall-clock first (no stderr lock held). `debug_io` is the same io std's
    // own default logger uses, always available without extra wiring.
    const total_ms: i64 = std.Io.Clock.now(.real, std.Options.debug_io).toMilliseconds();
    var ts_buf: [32]u8 = undefined;
    const ts = trace.formatTimestamp(&ts_buf, total_ms);

    // Task-local lookup: follows the task across yields and executor migration,
    // and is null outside any request (e.g. startup logging) → all-zero id.
    const req: []const u8 = if (req_scope.current()) |s| s.request_id else no_request_id;

    var lock_buf: [256]u8 = undefined;
    const term = std.debug.lockStderr(&lock_buf).terminal();
    defer std.debug.unlockStderr();
    const w = term.writer;
    w.print("{s} {s} {s} [{t}] ", .{ ts, req, trace.levelText(level), scope }) catch return;
    w.print(format ++ "\n", args) catch return;
}
