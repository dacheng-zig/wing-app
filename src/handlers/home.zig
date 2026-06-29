//! GET / — home page; demonstrates the view layer.
//!
//! Returns `void` and drives the response manually via `ctx.respond` so it can
//! set `content-type: text/html`. `*Config` is projected from AppState by type.

const Ctx = @import("../state.zig").Ctx;
const Config = @import("../config/config.zig").Config;
const views = @import("../views/home.zig");

pub fn handle(ctx: *Ctx, cfg: *Config) anyerror!void {
    const html = try views.render(ctx.arena, cfg.greeting);
    try ctx.respond(html, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}
