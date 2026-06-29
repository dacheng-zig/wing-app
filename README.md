# wing-app

A clone-and-go starter for building HTTP services in [Zig](https://ziglang.org) on the **wing**
web framework. Fork it, rename it, and start writing features — the build wiring, server
bootstrap, auth, OpenAPI generation, and request tracing are already in place.

> **Stack:** `zio` (coroutine runtime) → `talon` (HTTP engine) → `wing` (web framework, ≈ ASP.NET
> Core / axum), with `mantle` as the pure-Zig MySQL driver. Routing, extractors, `Context`, and
> middleware are resolved at **comptime**, so the steady-state request path does no reflection and
> no heap allocation.

## Why you might like it

- **Handlers are just typed functions.** Declare what you need as parameters — `wing.Path(T)`,
  `wing.Json(T)`, `*UserService`, `auth: Auth` — and wing wires it at comptime. No annotations, no
  DI container; shared state is one explicit `AppState` struct projected to handlers by type.
- **Feature modules, not a controller pile.** Each feature is a vertical slice
  (`handlers/ routes/ services/ repositories/ models/`) with **one file per endpoint**. The app
  grows by adding feature folders, not by growing one giant table or controller.
- **Auth that can't drift from its docs.** Cookie sessions and bearer API tokens resolve through a
  single argon2 hashed-secret credential store, with role-based authorization. The accepted
  channels live in *one* file (`auth/support/auth.zig`); both the runtime checks and the OpenAPI
  `securitySchemes` derive from it.
- **OpenAPI 3.1, generated from your code.** The spec is assembled at comptime from the router and
  handler signatures — served live at `/openapi.json`, rendered by a [Scalar](https://scalar.com)
  UI at `/docs`, and dumpable offline with `zig build openapi`.
- **Request tracing built in.** Every request gets a process-unique id on the `x-request-id`
  header, and *every* log line it produces — app, wing, and mantle SQL — carries that id.
- **Production-minded defaults.** Graceful `SIGINT` drain, fd-limit-aware connection admission,
  and a single-executor zio runtime tuned for syscall-bound work against a co-located database.

## Requirements

- **Zig 0.16.0** (`minimum_zig_version` is pinned in `build.zig.zon`).
- Local checkouts of **`wing`** and **`mantle`** as **sibling directories** (`../wing`, `../mantle`).
  This starter depends on them by path while they are pre-release; see [Dependencies](#dependencies)
  to switch to pinned releases later.
- A reachable **MySQL server** with the target database already created. The app manages its own
  tables, not the database:

  ```bash
  mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS wing_app;"
  ```

  Connection settings come from `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` /
  `DB_POOL_SIZE` (defaults: `127.0.0.1:3306`, `root`/`root`, db `wing_app`, pool `8`); the listen
  port is `PORT` (default `8080`). Tables are created from embedded SQL migrations at startup.

## Quick start

```bash
git clone <this-repo> my-app && cd my-app
zig build run
# in another terminal:
curl http://127.0.0.1:8080/            # -> HTML greeting
curl http://127.0.0.1:8080/health      # -> health check
open  http://127.0.0.1:8080/docs       # -> interactive API docs (Scalar)
```

`Ctrl+C` triggers a graceful drain (the server watches `SIGINT` and shuts down cleanly).

Other build steps:

```bash
zig build                  # compile to zig-out/bin/wing_app
zig build test             # run unit tests (auth + openapi)
zig build openapi          # print the assembled OpenAPI 3.1 spec to stdout
```

## What's wired up

The `users` and `auth` features are threaded through every layer as worked examples:

| Method & path                  | Purpose                                  |
| ------------------------------ | ---------------------------------------- |
| `GET  /`                       | HTML home page (view layer)              |
| `GET  /health`                 | Health check                             |
| `GET  /docs`, `/openapi.json`  | Scalar UI + generated OpenAPI spec       |
| `GET  /api/v1/users`           | List users                               |
| `POST /api/v1/users`           | Create user                              |
| `GET  /api/v1/users/:id`       | Get user by id                           |
| `POST /api/v1/auth/login`      | Log in (issues a session cookie)         |
| `POST /api/v1/auth/logout`     | Revoke the session                       |
| `POST /api/v1/auth/token/issue`  | Issue a bearer API token               |
| `POST /api/v1/auth/token/revoke` | Revoke an API token                    |
| `GET  /api/v1/auth/me`         | Current authenticated user (cookie/bearer) |

## Project layout

A feature-module structure: shared infrastructure at the root of `src/`, and one self-contained
folder per business feature. Each feature depends on the shared layers, not on its siblings.

```
.
├── build.zig              # build graph: wing + transitive talon/zio, plus mantle
├── build.zig.zon          # manifest: dependency pins, Zig version floor
└── src/
    ├── main.zig           # entry point — hands the allocator to the server
    ├── server.zig         # bootstrap: runtime, listener, HTTP server, graceful drain
    ├── app.zig            # middleware chain + error→status mapping
    ├── state.zig          # AppState: the explicit dependency graph (no DI container)
    ├── config/            # config: compiled defaults + env overrides
    ├── db/                # MySQL pool + embedded SQL migrations (migrations/*.sql)
    ├── trace/             # request-id scope threaded through every log line
    ├── middleware/        # request_scope (req id), security_headers
    ├── openapi/           # comptime OpenAPI 3.1 generator (wraps wing.Router)
    ├── routes/            # top-level URL→feature composition (nest / merge / fallback)
    ├── handlers/          # root ops endpoints (home, health)
    ├── views/             # server-rendered output (HTML)
    ├── user/              # feature module ──┐
    │   ├── handlers/      #  one file per endpoint (index / show / create)
    │   ├── routes/        #  feature sub-router (relative paths, nested by routes.zig)
    │   ├── services/      #  business rules, HTTP-agnostic
    │   ├── repositories/  #  data access on the shared pool
    │   └── models/        #  entities + request/response DTOs
    ├── auth/              # feature module: login, tokens, sessions, roles
    │   ├── handlers/      #  login / logout / me / token_issue / token_revoke
    │   ├── services/      #  auth + credential store (argon2 hashed secrets)
    │   ├── repositories/  #  credentials + roles
    │   ├── support/       #  auth policy (schemes/locators), authorizer, password
    │   └── models/        #  principal
    └── docs/              # feature module: serves /openapi.json + Scalar /docs
```

**Request flow within a feature:** `routes` → `handler` → `service` → `repository`, with `models`
shared and `views` rendering output. A handler stays thin — extract, delegate, respond:

```zig
// src/user/handlers/show.zig — GET /api/v1/users/:id
pub fn handle(ctx: *Ctx, svc: *UserService, path: wing.Path(struct { id: u64 })) anyerror!wing.Json(User) {
    const user = try svc.get(ctx.arena, path.value.id);
    return .{ .value = user };
}
```

`svc: *UserService` is projected from `AppState` by type; `wing.Path` parses the route param;
`error.NotFound` from the service maps to 404 for free. Map any custom domain errors to status
codes once, in `app.zig`.

## Adding a feature

Create a folder under `src/<feature>/` and fill the slice bottom-up:

1. **Model** (`models/`) — the entity and its request/response DTOs.
2. **Repository** (`repositories/`) — data access: lease a pooled connection, run parameterized SQL.
3. **Service** (`services/`) — business rules; HTTP-agnostic, returns domain types or errors.
4. **Handler** (`handlers/`) — one file per endpoint: extract with `wing.Path`/`Query`/`Json`,
   require auth by declaring `auth: Auth`, return a typed response (`wing.Json(T)`, `wing.Created(T)`, …).
5. **Routes** (`routes/`) — a sub-router mapping paths to handlers; `nest` it in `src/routes/routes.zig`.
6. **State** (`state.zig`) — add the service as a top-level field so handlers can project it.

To protect an endpoint, add `auth: Auth` (cookie-or-bearer) or `auth: RequireRole("admin")` to its
handler signature — that *is* the compile-time proof the route needs auth, and the OpenAPI security
block updates automatically. See `src/auth/support/auth.zig` for the policy and per-route overrides
(`CookieOnly` / `BearerOnly`).

For framework details (extractors, typed responses, state projection, custom middleware, error
handling), see wing's user guide at `../wing/docs/user-guide.md`. For the OpenAPI generator, see
`docs/openapi-user-guide.md`.

## Dependencies

Declared in `build.zig.zon` as local paths during pre-release co-development:

```zig
.dependencies = .{
    .wing   = .{ .path = "../wing" },   // web framework
    .mantle = .{ .path = "../mantle" }, // pure-Zig MySQL driver
},
```

`build.zig` reaches through wing's dependency graph to also expose `talon` (`TcpListener` /
`Server`) and `zio` (the `Runtime`) to the executable — and because mantle depends on the same
`../zio`, Zig dedupes to a single zio instance, so the server runtime and the DB pool share one
scheduler. When wing/talon/mantle publish tagged releases, replace each `.path` with a `url` + `hash`.

## Make it yours

1. Rename the package: `.name` in `build.zig.zon` and `.name` in `build.zig` (`wing_app` → your app).
2. Regenerate `.fingerprint` in `build.zig.zon` (`zig build` prompts if it's stale).
3. Replace or delete the `users`/`auth` example features and update `state.zig` + `routes/routes.zig`.
4. Adjust `config/config.zig`, the middleware chain in `app.zig`, and the home view to taste.

## Status & feedback

This is pre-release software co-developed with wing, talon, and mantle, so the API surface and
defaults may still shift. It already runs a real MySQL-backed service with auth and generated docs —
kicking the tires and reporting friction is genuinely useful. **Open an issue** with what you tried,
what you expected, and what happened; bug reports, rough edges, and "this was confusing" notes are
all welcome.
