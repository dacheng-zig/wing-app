# wing-app

A minimal, clone-and-go skeleton for building web services in [Zig](https://ziglang.org) on the
**wing** web framework. Fork it, rename it, and start writing your own routes, handlers, and state —
the build wiring, server bootstrap, and conventions are already in place.

> Stack: `zio` (coroutine runtime) → `talon` (HTTP engine) → `wing` (web framework, ≈ ASP.NET Core / axum).
> wing handles routing, middleware, `Context`, and extractors; all "framework magic" is resolved at
> comptime, so the steady-state request path does no reflection and no heap allocation.

## Requirements

- **Zig 0.16.0** (`minimum_zig_version` is pinned in `build.zig.zon`)
- Local checkouts of `wing` and `mantle` (the MySQL driver) as **sibling directories**
  (`../wing`, `../mantle`). This skeleton depends on them via local paths while they are
  pre-release; see [Dependencies](#dependencies) to switch to a pinned release later.
- A reachable **MySQL server** with the target database created. The app manages its own
  table but not the database itself:

  ```bash
  mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS wing_app;"
  ```

  Connection settings come from `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` /
  `DB_NAME` / `DB_POOL_SIZE` (defaults: `127.0.0.1:3306`, `root`/`root`, db `wing_app`,
  pool `8`). The `users` table is created automatically at startup.

## Quick start

```bash
git clone <this-repo> my-app && cd my-app
zig build run
# in another terminal:
curl http://127.0.0.1:8080/
# -> Hello, world!
```

`Ctrl+C` triggers a graceful drain (the server watches `SIGINT` and shuts down cleanly).

Other commands:

```bash
zig build                  # compile to zig-out/bin/wing_app
./zig-out/bin/wing_app     # run the compiled binary directly
```

## Project layout

A classical layered structure that scales from a weekend project to an enterprise service.
Each layer has one job and depends only on the layers below it:

```
.
├── build.zig              # build graph: pulls wing + its transitive talon/zio modules
├── build.zig.zon          # package manifest, dependency pins, Zig version floor
├── src/
│   ├── main.zig           # entry point — hands the allocator to the server
│   ├── server.zig         # bootstrap: runtime, listener, HTTP server, graceful drain
│   ├── app.zig            # middleware chain + error→status mapping
│   ├── state.zig          # AppState: wires config + database + repositories → services (no DI container)
│   ├── config/
│   │   └── config.zig     # configuration (defaults + env overrides)
│   ├── db/                # shared data infrastructure
│   │   ├── database.zig   # app-wide MySQL pool (owned here; repositories borrow it)
│   │   └── sql.zig        # central SQL registry: migrations + per-feature queries
│   ├── routes/
│   │   ├── routes.zig     # top-level URL→feature composition (nest/merge/fallback)
│   │   └── user_routes.zig# per-feature route table
│   ├── controllers/       # HTTP layer: bind request → call service → shape response
│   │   ├── home_controller.zig
│   │   ├── health_controller.zig
│   │   └── user_controller.zig
│   ├── services/          # business logic / rules (HTTP-agnostic)
│   │   └── user_service.zig
│   ├── repositories/      # data access — runs central SQL on the shared pool
│   │   └── user_repository.zig
│   ├── models/            # domain entities + request/response DTOs
│   │   └── user.zig
│   ├── middleware/        # custom middleware (example: security headers)
│   │   └── security_headers.zig
│   └── views/             # server-rendered output (HTML, …)
│       └── home.zig
└── docs/
    ├── architecture.md    # layer responsibilities, dependency rules, scaling guide
    └── todo.md            # roadmap notes
```

**Request flow:** `routes` → `controller` → `service` → `repository`, with `models` shared
across layers and `views` rendering output. The `users` feature is threaded through every layer
as a worked example. See `docs/architecture.md` for layer responsibilities and how to scale to
feature-module organization for large teams.

## Adding a feature

Follow the `users` example and add a slice per layer, bottom-up:

1. **Model** (`models/`) — define the entity and request/response DTOs.
2. **Repository** (`repositories/`) — data access; MySQL via mantle (lease a pooled connection, run parameterized SQL).
3. **Service** (`services/`) — business rules; HTTP-agnostic, returns domain types or errors.
4. **Controller** (`controllers/`) — bind request with `wing.Path`/`Query`/`Json`, call the
   service, return a typed response (`wing.Json(T)`, `wing.Created(T)`, …).
5. **Routes** (`routes/`) — add a `*_routes.zig` sub-router and `nest` it in `routes.zig`.
6. **State** (`state.zig`) — add the service as a top-level field so handlers can project it.

A controller stays thin — extract, delegate, respond:

```zig
pub fn show(
    ctx: *Ctx,
    svc: *UserService,                       // projected from AppState by type
    path: wing.Path(struct { id: u64 }),
) anyerror!wing.Json(User) {
    _ = ctx;
    return .{ .value = try svc.get(path.value.id) };
}
```

Map domain errors to status codes once, in `app.zig` (`error.NotFound` → 404 comes for free;
`error.InvalidName` → 400 is wired as an example). See the wing **user guide**
(`../wing/docs/user-guide.md`) for extractors, typed responses, state projection, custom
middleware, and error handling — and `docs/architecture.md` for the layering rationale.

## Dependencies

Declared in `build.zig.zon`:

```zig
.dependencies = .{
    .wing = .{ .path = "../wing" }, // local path during pre-release co-development
},
```

`build.zig` reaches through wing's dependency graph to also expose `talon` (the `TcpListener` /
`Server`) and `zio` (the `Runtime`) to the executable — the same pattern wing's own `build.zig` uses.
When wing/talon publish tagged releases, replace the `.path` with a `url` + `hash` pin.

## Make it yours

1. Rename the package: `.name` in `build.zig.zon` and `.name` in `build.zig` (`wing_app` → your app).
2. Regenerate the `.fingerprint` in `build.zig.zon` (`zig build` will prompt if it's stale).
3. Replace the `users` example feature with your own (or delete it) and update `state.zig`/`routes.zig`.
4. Adjust `config/config.zig`, the middleware chain in `app.zig`, and the home view to taste.

## Roadmap

See `docs/todo.md`. The `user_repository` is backed by MySQL through
[`mantle`](../mantle)'s connection pool; the repository boundary kept that change local —
service, controller, and routes were untouched in spirit.
