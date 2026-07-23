//! Server bootstrap and graceful shutdown.
//!
//! Owns the runtime lifecycle: load config, start the zio runtime, build the
//! router and state, wire the talon HTTP server, and watch SIGINT for a clean
//! drain.

const std = @import("std");
const zio = @import("zio");
const talon = @import("talon");

const fd_limit = @import("fd_limit.zig");
const Config = @import("config/config.zig").Config;
const AppState = @import("state.zig").AppState;
const App = @import("app.zig").App;
const routes = @import("routes/routes.zig");
const job_registry = @import("jobs/registry.zig");

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;

    const config = Config.load(init.environ_map);

    // Single-executor runtime: ALL coroutines run on one OS thread under zio's
    // cooperative scheduling. With a co-located DB the work is socket-syscall
    // bound, so extra executors only add cross-core contention.
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();

    const built = try routes.build(gpa);
    var router = built.router;
    defer router.deinit();
    // The OpenAPI spec lives for the whole app; freed on shutdown. Stored into
    // AppState below so the `/openapi.json` handler can serve it.
    defer gpa.free(built.openapi_spec);

    // `std.Io` for auth's CSPRNG, wall-clock, and argon2 entropy. These are
    // synchronous syscalls / CPU work (no scheduler yield), so the std threaded
    // instance is safe to call from within zio coroutines and avoids importing
    // zio's internal io adapter. (Heavy argon2 hashing still runs on the calling
    // executor; offloading via zio.spawnBlocking is a future optimization.)
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.init(gpa, io, config);
    defer state.deinit();
    state.api_docs.spec = built.openapi_spec;

    // Connect lazily but create the schema now so the first request finds the
    // table. Runs inside the runtime; a DB failure here aborts startup.
    try state.migrate();

    // Background job runner: shares the DB pool and the zio scheduler with
    // HTTP. Declared before `group` so its deinit runs after `group.cancel()`
    // has stopped the coroutines, and before `state.deinit()` drops the pool.
    var job_runner: ?job_registry.JobRunner = if (config.jobs.enabled)
        try job_registry.JobRunner.init(gpa, state.database.pool, config.jobs, config.db.pool_size)
    else
        null;
    defer if (job_runner) |*r| r.deinit();

    var app = App.init(&router, &state);

    const addr = try zio.net.IpAddress.parseIp4(config.host, config.port);
    var listener = try talon.TcpListener.listen(addr, .{});

    // Reserve fds for the listener, stdio, log files, each pooled DB
    // connection, and the short-lived KILL-QUERY sidecar a timeout may open per
    // pooled connection (hence `* 2`), then admit up to the remaining budget.
    const fd_reserve: u32 = 64 + @as(u32, @intCast(config.db.pool_size)) * 2;
    var server = try talon.http.Server(App).init(gpa, &app, .{
        .limits = .{ .max_connections = fd_limit.resolveMaxConnections(fd_reserve) },
    });
    defer server.deinit();

    // Setup signal watcher for Ctrl+C
    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(signalWatcher, .{&server});
    if (job_runner) |*r| try group.spawn(job_registry.JobRunner.run, .{r});

    std.log.info("listening on http://{f} (Ctrl+C to stop)", .{addr});
    try server.serve(&listener);
}

/// Watch for SIGINT and trigger a graceful server drain.
fn signalWatcher(server: *talon.http.Server(App)) !void {
    var sig = try zio.Signal.init(.interrupt);
    defer sig.deinit();
    try sig.wait();
    std.log.info("SIGINT received, darining...", .{});
    server.shutdown();
}
