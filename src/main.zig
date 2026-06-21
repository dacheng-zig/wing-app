const std = @import("std");
const zio = @import("zio");
const talon = @import("talon");
const wing = @import("wing");

// No application state needed for a hello-world endpoint.
const State = struct {};
const Ctx = wing.Context(State);

// GET / -> "Hello, world!" (text/plain; returning a []const u8 is wing's
// plain-text response shortcut).
fn hello(ctx: *Ctx) anyerror![]const u8 {
    _ = ctx;
    return "Hello, world!\n";
}

const App = wing.App(State, .{
    wing.middleware.logger,
    wing.middleware.recover,
    // route_match: matches the request to an endpoint; without
    // it the terminal has nothing to run and every request 404s.
    wing.middleware.route_match,
});

fn signalWatcher(server: *talon.http.Server(App)) !void {
    var sig = try zio.Signal.init(.interrupt);
    defer sig.deinit();
    try sig.wait();
    std.log.info("SIGINT received, draining...", .{});
    server.shutdown();
}

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var router = wing.Router(State).init(init.gpa);
    defer router.deinit();
    try router.get("/", hello);

    var state: State = .{};
    var app = App.init(&router, &state);

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var listener = try talon.TcpListener.listen(addr, .{});

    var server = try talon.http.Server(App).init(init.gpa, &app, .{});
    defer server.deinit();

    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(signalWatcher, .{&server});

    std.log.info("wing listening on http://{f} (Ctrl+C to stop)", .{addr});
    try server.serve(&listener);
    std.log.info("bye", .{});
}
