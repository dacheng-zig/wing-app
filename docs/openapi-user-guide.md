# wing-app OpenAPI：集成与使用指南

> 受众：在 wing 应用里想自动生成接口文档的开发者（API 使用方，非 `openapi` 包维护者）。
> 一句话：把 `wing.Router` 换成 `openapi.Router`，每条路由末尾加一个文档参数，spec 与 Scalar 页面就自动有了——schema 全部从 handler 签名推导，零手写。
> 配套：架构与缺口见 `openapi-developer-guide.md`。

---

## 1. 你能得到什么

- `GET /openapi.json`：从代码自动生成的 **OpenAPI 3.1** 文档。
- `GET /docs`：Scalar 渲染的交互式接口文档页。
- `zig build openapi`：无需启动服务器/数据库，把 spec 打到 stdout（CI 校验、生成 client）。

所有 path/query 参数、请求体、响应体 schema **从 handler 签名推导**，是单一真相源——改了 handler，文档自动跟着变。

---

## 2. 五步集成

### 第 1 步：feature 路由用 `openapi.Router` 替换 `wing.Router`

每条注册方法多一个末参 `Meta`（文档元信息）。`schema` 始终从签名推导，所以 `.{}` 空 Meta 也会产出带完整参数/请求体/响应的文档。

```zig
// src/user/routes/user_routes.zig
const openapi = @import("../../openapi/root.zig");
const AppState = @import("../../state.zig").AppState;
const user_controller = @import("../controllers/user_controller.zig");

pub fn build(gpa: std.mem.Allocator) !openapi.Router(AppState) {
    var r = openapi.Router(AppState).init(gpa);
    errdefer r.deinit();

    try r.get("/",    user_controller.index,  .{ .summary = "List users", .tags = &.{"users"} });
    try r.post("/",   user_controller.create, .{ .summary = "Create user", .tags = &.{"users"} });
    try r.get("/:id", user_controller.show,   .{ .summary = "Get user by id", .tags = &.{"users"} });

    return r;
}
```

### 第 2 步：handler 用 wing 的类型化 extractor

文档质量完全取决于签名表达力。用 `wing.Path/Query/Json` 接收输入、用 `wing.Json/Created` 返回，文档才能推导出参数与 schema：

```zig
// src/user/controllers/user_controller.zig
pub fn index(ctx: *Ctx, svc: *UserService) anyerror!wing.Json([]User) { ... }   // → 200 + User[] schema

pub fn show(
    ctx: *Ctx,
    svc: *UserService,
    path: wing.Path(struct { id: u64 }),                                         // → path 参数 id
) anyerror!wing.Json(User) { ... }                                              // → 200 + User schema

pub fn create(
    ctx: *Ctx,
    svc: *UserService,
    body: wing.Json(CreateUserReq),                                             // → requestBody
) anyerror!wing.Created(User) { ... }                                          // → 201 + User schema
```

推导规则速查：

| 你写的 | 文档里变成 |
|---|---|
| `wing.Path(struct{ id: u64 })` | path 参数（必填） |
| `wing.Query(struct{ page: ?u32 })` | query 参数（optional/有默认 → 非必填） |
| `wing.Json(T)` 入参 | `application/json` 请求体 |
| `wing.Json(T)` 返回 | `200` + T 的 schema |
| `wing.Created(T)` 返回 | `201` + T 的 schema |
| `wing.Redirect` 返回 | `302` |
| `Auth` / `OptionalAuth` / `Require(...)` 参数 | **`security` 要求**（自动反射 + 登记 `securitySchemes`） |
| `*State` / `*Service` 参数 | **忽略**（不进文档） |

> DTO（如 `User`、`CreateUserReq`）会自动登记到 `components.schemas` 并以 `$ref` 引用、自动去重。

### 第 3 步：顶层组装 + 填 API 元信息

`nest`/`merge` 与 `wing.Router` 用法一致；前缀会自动折叠进文档路径。结尾 `openApiJson` 组装 spec、`intoRouter` 交出真实 router。

```zig
// src/routes/routes.zig（节选）
var users = try user_routes.build(gpa);
defer users.deinit();   // 注意：wrapper 即使被 move，仍持有 docs 列表，需 deinit

var root = openapi.Router(AppState).init(gpa);
defer root.deinit();
try root.get("/", home_controller.index, .{ .summary = "Home page", .tags = &.{"ops"} });
try root.nest("/api/v1/users", &users);   // 路径自动变 /api/v1/users...

const openapi_spec = try root.openApiJson(gpa, .{
    .title = "Wing App API",
    .version = "0.0.0",
    .summary = "Layered HTTP API on the wing framework (Zig 0.16).",
    .contact = .{ .name = "Dacheng Gao", .url = "https://github.com/dacheng-zig/wing-app" },
    // 鉴权方案：唯一一处声明"本 app 怎么认证"。用 Auth 等 extractor 的接口都绑定到它。
    // 换 bearer 只改这里：.{ .name = "bearerAuth", .kind = "http", .scheme = "bearer" }。
    // 若有 extractor 用了 auth 但这里没配 → assemble 报 error.MissingAuthScheme（不会静默漏标）。
    .auth_scheme = .{ .name = "cookieSession", .kind = "apiKey", .in = "cookie", .parameter_name = "session_id" },
    // .license = .{ .name = "MIT", .identifier = "MIT" },  // 可选
});
errdefer gpa.free(openapi_spec);

root.fallback(notFound);
return .{ .router = root.intoRouter(), .openapi_spec = openapi_spec };
```

> 内存须知：`openapi.Router` 比 `wing.Router` 多持有 docs 列表 + path arena，**被 `nest`/`merge` move 之后仍要 `deinit`**——所以子路由用 `defer`（非 `errdefer`）。spec bytes 归调用方所有，server 在 shutdown 释放。

### 第 4 步：把 spec 存进 AppState，注册两个端点

```zig
// 存 spec（src/server.zig）
state.api_docs.spec = built.openapi_spec;

// docs feature 的两个端点都标 hidden（自身不进文档）
// src/docs/routes/docs_routes.zig
try r.get("/openapi.json", docs_controller.openapiJson, .{ .hidden = true });
try r.get("/docs",         docs_controller.docsPage,    .{ .hidden = true });
```

controller 直接 serve 静态字节（`src/docs/controllers/docs_controller.zig`）：`/openapi.json` 回 `state.api_docs.spec`、`/docs` 回 `@embedFile` 的 `scalar.html`，各自设好 content-type。

### 第 5 步：验证

```bash
zig build test                       # 单测通过
zig build openapi > openapi.json     # 离线导出，喂校验器/jq
zig build run                        # 启动后浏览器开 http://<host>:<port>/docs
```

---

## 3. Meta 字段参考

每条路由末参 `openapi.Meta`，全部可选：

| 字段 | 作用 | 默认 |
|---|---|---|
| `summary` | 一行摘要 | `""` |
| `description` | CommonMark 详述 | `""` |
| `tags` | 分组标签 `&.{"users"}` | `&.{}` |
| `operation_id` | 覆盖默认的 `method+path` slug | 自动派生 |
| `hidden` | 真实注册但**不进** spec（用于 `/docs` 自身等） | `false` |

`ApiInfo`（顶层 `openApiJson` 的元信息）：`title`、`version` 必填；`summary`/`description`/`terms_of_service`/`contact{name,url,email}`/`license{name,identifier,url}` 可选，空则省略。`auth_scheme`（`SecurityScheme{name,kind,in,parameter_name,scheme,description}`）：用到鉴权 extractor 时必填，是"本 app 怎么认证"的唯一声明处。

---

## 4. 注意事项与当前限制

直接影响使用体验，集成前请知悉（完整缺口清单见 `openapi-developer-guide.md §6`）：

- **登录要求会自动体现**：handler 声明 `Auth`/`OptionalAuth`/`Require(...)` 的接口（如 `/api/v1/auth/me`）会自动带 `security`，Scalar 上显示锁图标——无需手写。但 **`RequireRole("admin")` 的具体角色暂不进 spec**（只体现"需登录"），角色要求请在 `description` 里说明（P2 再自动化）。
- **只有成功响应**：每个接口只展示 200/201/302，**不含**错误响应（401/404/422 等）。
- **schema 名较长**：components 用全限定类型名（如 `user.models.user.User`），UI 里偏冗长，暂不可自定义。
- **`/docs` 需联网**：Scalar 通过 CDN 加载，离线/内网环境页面渲染不出（`/openapi.json` 本身不受影响，仍可用其它工具打开）。
- **字段无额外约束**：不输出 `minLength`/`format:email`/`example` 等；schema 只表达类型形状。
- **请求体 DTO 字段会原样暴露**：如 `CreateUserReq` 的 `password` 字段会出现在文档里——这是请求体的正常表达，但请确认 DTO 不含不应公开的字段。

---

## 5. 常见问题

**Q：不写 `Meta` 会怎样？**
A：传 `.{}` 即可。仍会生成带完整参数/请求体/响应 schema 的文档，只是没有 summary/tags 等说明文字。

**Q：某个内部接口不想出现在文档里？**
A：`Meta` 设 `.{ .hidden = true }`，路由照常工作但不进 spec。

**Q：handler 多了个 `*Service` 参数，会被当成参数吗？**
A：不会。指针型（`*State`/`*Service`）自动忽略；`wing.Path/Query/Json` 进参数/请求体；`Auth` 等鉴权 extractor 进 `security`（自动）。

**Q：怎样在 CI 里校验 spec？**
A：`zig build openapi > openapi.json`，再用任意 OpenAPI 3.1 校验器或 schema diff 工具检查；无需起服务器或数据库。

**Q：path 里写了 `:id` 但文档显示 `{id}`？**
A：正常。wing 的 `:id`/`*rest` 会自动转成 OpenAPI 标准的 `{id}` 模板。
