# wing-app OpenAPI 包：开发者指南

> 受众：维护 / 扩展 `lib/wing-openapi/` 的工程师。
> 范围：当前**已落地**的架构、技术实现与缺口。以代码为准——本文所有断言已用 `zig build test` / `zig build openapi` 验证。
> 配套：`openapi-user-guide.md`（集成使用）。

---

## 1. 一句话定位

从 handler 签名（`@typeInfo` comptime 反射）**自动生成 OpenAPI 3.1**，零 wing 核心改动、请求期零开销、单一真相源。落地路线 = utoipa 式 **code-first 编译期派生**。

实测产物（`zig build openapi`）：7 个 path、5 个 component schema、合法 `3.1.0` 文档。

---

## 2. 架构总览

### 2.1 数据流

```
注册点 (comptime)                启动期 (一次)              请求期 (每次)
─────────────────                ─────────────            ───────────────
openapi.Router.get(path,h,meta)
  ├─ inner.add(...)  ──────────► 真实路由树 (wing)
  └─ record():                                              GET /openapi.json
       RouteDoc{method,path,                                  └─ respond(state.api_docs.spec)
                meta, build_op} ─► assemble.json():           GET /docs
       build_op = 绑定 @TypeOf(h)     遍历 docs                  └─ respond(@embedFile scalar.html)
                 的 thunk              每条 build_op() 渲染 op
                                       schema 去重进 components
                                       序列化 → spec []const u8
                                       存入 AppState.api_docs
```

核心洞察：**一次 `r.get(...)` 同时驱动"真实路由注册"和"文档记账"**，无并行手写表，结构上消灭漂移（`router.zig:84-91`）。

### 2.2 模块分层

| 文件 | 职责 | 依赖 |
|---|---|---|
| `lib/wing-openapi/root.zig` | barrel：导出 `Router`/`Meta`/`ApiInfo`/`RouteDoc`/`SecurityScheme`/`ApiDocs`/`docsRoutes` | — |
| `lib/wing-openapi/router.zig` | `Router(State)`：包装 `wing.Router`，镜像方法 + 记账 + nest/merge 折叠 + `intoRouter` | `wing.Router` |
| `lib/wing-openapi/operation.zig` | comptime：handler 签名 → operation 对象（`paramRole`/`responseOf` 分类） | `wing` 公开 extractor 类型 |
| `lib/wing-openapi/schema.zig` | comptime：Zig type → JSON Schema 2020-12 节点 + `$ref` 去重 | std |
| `lib/wing-openapi/assemble.zig` | 启动期：`[]RouteDoc` → 完整 3.1 文档（路径模板化、operationId、info） | `operation` 产物 + std.json |
| `lib/wing-openapi/meta.zig` | `Meta`/`ApiInfo`/`Contact`/`License`/`RouteDoc`/`BuildFn` 数据结构 | std |
| `lib/wing-openapi/serve.zig` | serve 层：`ApiDocs` + `docsRoutes(State)`（`/openapi.json` + `/docs` + `/docs/scalar.js` 三端点，`@embedFile` `assets/scalar.html` 与锁定版本的 `assets/scalar-api-reference.js.gz`，`/docs/scalar.js` 响应带 `Content-Encoding: gzip`） | wing |
| `src/openapi_gen.zig` | 离线导出工具（`zig build openapi`） | routes |

依赖方向单向：`schema`/`operation`/`meta` → `router` → `assemble`；serve 层只消费产物。OpenAPI 知识全部内聚，**不碰 `wing/src/*`**。

---

## 3. 三个技术支柱

### 3.1 类型 identity 分类（为何无需改 wing）

wing 的 `extract.Path(T)`/`extract.Query(T)`/`extract.Json(T)` 结构相同（都 `value: T`），duck typing 无法区分。但 **Zig 对泛型实例化做记忆化**——`wing.extract.Path(u64)` 求值两次得同一类型。于是用 identity 校验直接判定（`operation.zig:44-57`）：

```zig
fn paramRole(comptime P: type) Role {
    if (@typeInfo(P) == .pointer) return .skip;              // *State / *Service：DI 注入
    if (@typeInfo(P) != .@"struct" or !@hasField(P, "value")) return .skip; // auth 等
    const T = @FieldType(P, "value");
    if (P == wing.extract.Path(T)) return .{ .path = T };    // identity 命中
    if (P == wing.extract.Query(T)) return .{ .query = T };
    if (P == wing.extract.Json(T)) return .{ .body = T };
    return .skip;
}
```

返回类型同理（`responseOf`，`operation.zig:47-57`），对齐 wing 硬编码响应器：`Json→200`、`Created→201`、`Redirect→302`、`void`/`[]const u8`→200。

**这是整个方案的基石**，因此有专门的 comptime 断言守护（`operation.zig:161` `"identity: wing extractor constructors are memoized"`）。wing 若重构破坏 identity，测试变红而非线上静默坏文档。

### 3.2 thunk 捕获类型（跨越 comptime/runtime 边界）

运行时 `RouteDoc` 列表里 handler 类型已被擦除。解法：注册点把 `@TypeOf(h)` 绑进一个**无捕获的函数指针** `build_op`（`operation.zig:61-67` `makeBuild`），启动期 `assemble` 回调它渲染 operation。`BuildFn` 签名见 `meta.zig:59`。

### 3.3 nest/merge 前缀折叠（包装层优势）

前缀在 `nest("/api/v1/users", &users)` 处显式已知，文档路径直接字符串拼接，**无需遍历 radix 树重建嵌套路径**（`router.zig:95-106`）。`joinPath` 镜像 wing 的 `/` → 前缀本身的语义（`router.zig:134-137`）。move 语义也镜像：源 `docs` 清空。

---

## 4. 类型映射表（schema.zig 实测）

| Zig 类型 | JSON Schema 3.1 | 代码 |
|---|---|---|
| `bool` | `{"type":"boolean"}` | `schema.zig:21` |
| `u8..u64` / `i*` | `{"type":"integer","format":"int32"\|"int64"}`（按位宽，≤32 为 int32） | `:77` |
| `f32`/`f64` | `{"type":"number"}` | `:23` |
| `[]const u8` / `[]u8` | `{"type":"string"}` | `:28` |
| `?T` | 标量塌缩为 `{"type":["x","null"]}`；`$ref` 等用 `anyOf+null` | `:108` |
| `enum{...}` | `{"type":"string","enum":[...]}`（字段名） | `:84` |
| `[]T` / `[N]T` | `{"type":"array","items":<T>}` | `:93` |
| 具名 `struct` | 注册到 `components.schemas/<@typeName>`，引用处 `$ref` | `:35,46` |

**required 规则**：非 optional 且无默认值即 required（`schema.zig:67` `isRequired`），与 wing Query 解析器一致。
**去重**：具名 struct 按全限定 `@typeName` 去重，递归前先插 `.null` 占位以终止自引用类型（`schema.zig:49`）。
**不支持类型**：`@compileError` 前移到编译期，错误带 `@typeName`（`schema.zig:39`）。

---

## 5. 关键设计决策

- **请求期零开销**：spec 在 `routes.build()` 启动期组装一次，存入 `AppState.api_docs.spec`（`state.zig:28`、`server.zig:55`）；handler 只 `respond` 静态字节。
- **spec 生命周期**：bytes 由 server 的 `gpa` 拥有，应用期存活，shutdown 释放（`server.zig:45`）。`ApiDocs` 包装 `[]const u8` 而非裸字符串，保证 AppState 按类型投影不与未来字符串字段冲突（`state.zig:25-30`）。
- **hidden 路由**：`/openapi.json` 与 `/docs` 自身 `hidden = true`，真实注册但从 spec 排除（`docs_routes.zig`、`assemble.zig:34`）。
- **路径模板化**：wing 的 `:id`/`*rest` → OpenAPI `{id}`（`assemble.zig:92` `toTemplate`），声明的 path 参数才能对上 `{name}` 占位。
- **operationId**：Zig 拿不到 handler 声明名，默认由 `method+path` 派生（`get_api_v1_users_id`，`assemble.zig:111`），`Meta.operation_id` 可覆盖。
- **离线导出**：`routes.build` 只注册 + 组装 JSON，从不连 DB / 跑 handler，故 `zig build openapi` 可无服务器、无数据库导出真实 spec（`openapi_gen.zig`），适合 CI 校验/diff。

---

## 6. 缺口与限制（按优先级）

> 标注 `[设计 defer]` = 设计阶段即明确的延后项（YAGNI，出现需求再加）；`[实测]` = 运行 spec 暴露的具体表现。

### ✅ 已闭合 — 安全方案反射（原 P1 #1）

`[已实现，方案 D2]` spec 现发射 `components.securitySchemes`，鉴权端点带 per-operation `security`。实测：`/api/v1/auth/me`、`/api/v1/auth/logout`（handler 声明 `Auth`）→ `security: [{cookieSession: []}]`；公开端点无 `security`。解决 `todo.md:8`。

实现要点（**intent 标记 + 配置层绑定 scheme**）：
- auth extractor 只声明**机制无关**的 intent 标记 `pub const auth_requirement = .{ .optional = ... }`（`auth/support/extractor.zig`）——**不提任何 scheme**。
- scheme 在**唯一**一处定义：`ApiInfo.auth_scheme`（`routes.zig` 的 `openApiJson` 调用）。换 cookie→bearer = 改这一处字面量，extractor 不动。
- `operation.zig paramRole` 的 `.security` 分支检测 `@hasDecl(P, "auth_requirement")`；`collectSecurity` 把 op 绑定到 `BuildCtx.auth_scheme`、发 `security`、按需登记 scheme（与 `components.schemas` 同去重模式）。
- 配置缺失保护：有 auth op 但 `auth_scheme == null` → `error.MissingAuthScheme`，`zig build openapi`/测试**直接失败**（不会静默把鉴权端点当公开）。
- `OptionalAuth` → `security: [{}, {cookieSession: []}]`（空对象允许匿名）。
- **解耦保持**：openapi 不 import auth、auth 不 import openapi（标记是结构化读取的纯字面量）；且 extractor 与"是 cookie 还是 bearer"完全解耦。
- **角色仍 defer**：`RequireRole("admin")` 只反射 authn（apiKey scheme 无 scope）；角色 → spec 是 P2（扩展 marker 从 policy 反射，见 §6 P2）。

### P1 — 影响文档可用性

1. **仅单一成功响应** `[设计 defer]` `[实测]`：每个 operation 只有一个 200/201/302（`operation.zig`），无错误响应（400/401/404/422）、无 RFC 9457 `problem+json`。依赖 validator 落地后统一补错误模型。

### P2 — 影响文档质量

2. **component 名是全限定 `@typeName`** `[实测]`：UI 里显示为 `user.models.user.User`、`auth.controllers.auth_controller.LoginReq` 等冗长名（`schema.zig:47/102`）。无机制自定义 schema 标题。可考虑取 `@typeName` 末段或加 `Meta`-级别命名覆盖。

3. **字段无约束/描述/示例** `[实测]`：不输出 `minLength`/`maximum`/`pattern`/`format`(email 等)/`description`/`example`。schema 只表达类型形状。与 validator 集成后可从校验规则派生约束。

4. **仅 path/query/body 参数**：不提取 header / cookie 参数（`paramRole` 只认三种 extractor）。

### P3 — 范围 / 工程

5. **不支持 oneOf/多态响应、webhooks、callbacks** `[设计 defer]`。
6. **Scalar 已本地化，但字体仍走 CDN**：`scalar.html` 引用 `/docs/scalar.js`（`@embedFile` 的 `assets/scalar-api-reference.js.gz`，锁定 `@scalar/api-reference@1.62.4`，gzip -9 预压缩、响应带 `Content-Encoding: gzip`），`/docs` 页面本身无需联网即可加载 UI。但 bundle 内嵌的 `@font-face` 规则仍指向 `fonts.scalar.com`（Inter 字重），渲染时按需请求；若离线/内网环境无法访问该域名，浏览器会回退到系统字体，页面仍可用。彻底离线需另行 vendor 字体文件并重写 `src`，未做 `[设计 defer]`。
7. **手动镜像样板**：`get/post/put/delete/patch/add/nest/merge/fallback` 需逐个转发（`router.zig:49-112`）；新增 wing 路由方法需同步。集中一处、每个仅几行，可维护。
8. **enum 仅 string 化**：int-backed enum 也输出为 string enum（字段名），不区分。

---

## 7. 测试与验证

- 单测随包内联（`zig build test`，实测通过）：identity 记忆化断言、`paramRole`/`responseOf` 分类、`operationValue` 端到端、schema 标量/optional/具名 struct、assemble 分组/去重/hidden 排除/info 发射。
- 端到端验证：`zig build openapi` 导出 spec，喂 OpenAPI 3.1 校验器 / `jq`；浏览器开 `/docs` 核对。
- **扩展类型时**：先在 `schema.zig` 加映射 + 单测（样例 DTO 比对 JSON 字符串，见 `schema.zig:140` 起），再在 `operation.zig` 接入。

---

## 8. 扩展示例：新增一种响应状态码

以补 `204 No Content` 为例，定位改动点：
1. `operation.zig:47 responseOf` — 新增返回类型 → `{status:204, body:null}` 的分支（需 wing 有对应响应器或包装类型）。
2. `operation.zig:139 statusKey` / `:148 statusText` — 加 `204 => "204"` / `"No Content"`。
3. 加单测断言 `responseOf` 映射，再 `zig build test`。

新增标量类型、字段约束等改动点同理集中在 `schema.zig`，符合"单一真相源 + 改动局部化"。
