//! Synchronous trace-aware logging.
//!
//! `logFn` (wired via `std_options` in the app's root file) prefixes every
//! std.log line with an ISO-8601 timestamp, the current trace id (from the
//! task-local trace context), level and scope, then writes it straight to
//! stderr under the std stderr lock. Mirrors std's own lock/unlock dance.
//!
//! Writes are synchronous: stderr is expected to be a regular file (or a sink
//! that returns promptly), so a write never stalls the executor. An async
//! drain was evaluated and dropped — it only pays off when stderr can block;
//! callers routing stderr to a pipe/tty should reconsider that trade-off.

const std = @import("std");
const trace = @import("trace.zig");
const context = @import("context.zig");

// Placeholder when no trace context is bound. Same 26-char Base32 width as real
// ids (see middleware.zig) so columns line up; real UUIDv7 ids always carry
// version/variant bits, so the all-zero value is unambiguous.
const no_trace_id = "00000000000000000000000000";

pub fn logFn(
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
    // and is null outside any bound work (e.g. startup logging) → all-zero id.
    const id: []const u8 = if (context.current()) |c| c.trace_id else no_trace_id;

    var lock_buf: [256]u8 = undefined;
    const term = std.debug.lockStderr(&lock_buf).terminal();
    defer std.debug.unlockStderr();
    const w = term.writer;
    w.print("{s} {s} {s} [{t}] ", .{ ts, id, trace.levelText(level), scope }) catch return;
    w.print(format ++ "\n", args) catch return;
}

test {
    // Compile coverage: logFn is generic, so a plain container reference skips
    // its body; taking a concrete wrapper's address forces full analysis
    // without emitting any output.
    const coverage = struct {
        fn call() void {
            logFn(.info, .wing_trace, "{d}", .{1});
        }
    };
    _ = &coverage.call;
}
