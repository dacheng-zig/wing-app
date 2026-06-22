//! Server bootstrap and graceful shutdown.
//!
//! Owns the runtime lifecycle: load config, start the zio runtime, build the
//! router and state, wire the talon HTTP server, and watch SIGINT for a clean
//! drain. `main.zig` stays a one-liner that calls `run`.

const std = @import("std");
const zio = @import("zio");
const talon = @import("talon");

const Config = @import("config/config.zig").Config;
const AppState = @import("state.zig").AppState;
const App = @import("app.zig").App;
const routes = @import("routes/routes.zig");

/// Watch for SIGINT and trigger a graceful server drain.
fn signalWatcher(server: *talon.http.Server(App)) !void {
    var sig = try zio.Signal.init(.interrupt);
    defer sig.deinit();
    try sig.wait();
    std.log.info("SIGINT received, draining...", .{});
    server.shutdown();
}

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const config = Config.load(init.environ_map);

    // Multi-threaded runtime: spread connection coroutines and the DB client
    // across N executors (cores). Single-threaded (the zio default) pins all
    // work to one core and caps throughput well below the box's capacity.
    const rt = try zio.Runtime.init(gpa, .{
        .executors = if (config.worker_threads == 0)
            .auto
        else
            .exact(@max(1, @min(config.worker_threads, 64))),
    });
    defer rt.deinit();

    var router = try routes.build(gpa);
    defer router.deinit();

    var state = try AppState.init(gpa, config);
    defer state.deinit();

    // Connect lazily but create the schema now so the first request finds the
    // table. Runs inside the runtime; a DB failure here aborts startup.
    try state.migrate();

    var app = App.init(&router, &state);

    const addr = try zio.net.IpAddress.parseIp4(config.host, config.port);
    var listener = try talon.TcpListener.listen(addr, .{});

    var server = try talon.http.Server(App).init(gpa, &app, .{});
    defer server.deinit();

    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(signalWatcher, .{&server});

    std.log.info("wing-app listening on http://{f} (Ctrl+C to stop)", .{addr});
    try server.serve(&listener);
    std.log.info("bye", .{});
}
