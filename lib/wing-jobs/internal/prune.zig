//! Retention cleanup, shipped as a normal scheduled job so the maintenance
//! path exercises the queue's own machinery.

const std = @import("std");
const jobs = @import("../root.zig");

const log = std.log.scoped(.jobs);

pub const Prune = struct {
    pub const kind = "wing.jobs.prune";
    pub const max_attempts: u16 = 3;

    /// Rows deleted per DELETE statement; batches keep row locks short.
    batch: u32 = 5000,

    pub fn run(self: @This(), ctx: *jobs.Context) !jobs.Outcome {
        var repo = jobs.Repository.init(ctx.gpa, ctx.pool);
        const done = try drain(&repo, "'completed'", ctx.config.retention_completed_s, self.batch);
        const failed = try drain(&repo, "'cancelled','discarded'", ctx.config.retention_discarded_s, self.batch);
        if (done + failed > 0)
            log.info("pruned {d} completed + {d} cancelled/discarded jobs", .{ done, failed });
        return .ok;
    }

    fn drain(repo: *jobs.Repository, comptime state_in: []const u8, retention_s: u32, batch: u32) !u64 {
        var total: u64 = 0;
        while (true) {
            const n = try repo.pruneBatch(state_in, retention_s, batch);
            total += n;
            if (n < batch) return total;
        }
    }
};
