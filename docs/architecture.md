# 项目分层架构

> 适用：wing-app 骨架｜Zig 0.16.0｜读者：基于本骨架开发 Web 服务的工程师

本文说明 wing-app 采用的经典分层目录结构、各层职责、依赖方向，以及如何从小型项目扩展到企业级规模。

## 1. 为什么这样分层

主流成熟 Web 框架（Spring MVC、ASP.NET Core、Rails、NestJS、Laravel）都收敛到同一套**分层架构（Layered Architecture）**：把"处理 HTTP"、"业务规则"、"数据访问"三件事拆开，让每一层只依赖下一层。好处是固定的：

- **关注点分离**：改 HTTP 协议细节不碰业务规则；换数据库不碰 controller。
- **可测试**：service 不依赖 HTTP，可脱离 Web 单测；repository 可替换为内存或其他存储实现。
- **可替换**：repository 是数据访问的接缝（seam），换存储后端只改这一层（当前为 MySQL/mantle）。
- **可定位**：新人凭目录名就知道代码该写在哪、该去哪找。

wing 的设计与此天然契合：handler 是带类型签名的普通函数，State 是显式聚合的依赖结构（无 DI 容器），路由可用 `nest`/`merge` 模块化组合。

## 2. 目录与职责

```
src/
├── main.zig          入口，仅把 allocator 交给 server（保持极薄）
├── server.zig        启动装配：runtime / listener / HTTP server / 优雅退出
├── app.zig           中间件链 + 错误→状态码映射
├── state.zig         AppState：把 config + database + repositories 装配进 services（依赖图）
├── config/           配置（默认值 + 环境变量覆盖）
├── db/               共享数据基础设施：database.zig（app 级连接池）+ sql.zig（集中 SQL）
├── routes/           URL→功能 的组合（顶层 routes.zig + 各功能 *_routes.zig）
├── controllers/      HTTP 层：绑定请求 → 调用 service → 组织响应
├── services/         业务逻辑层：规则与编排，不感知 HTTP
├── repositories/     数据访问层：在共享连接池上执行集中管理的 SQL
├── models/           领域实体 + 请求/响应 DTO
├── middleware/       自定义中间件（示例：安全响应头）
└── views/            服务端渲染输出（HTML 等）
```

| 层 | 职责 | 不该做 |
|----|------|--------|
| `models` | 纯数据：实体与 DTO | 任何逻辑、I/O |
| `repositories` | 增删改查、持久化 | 业务规则 |
| `services` | 业务规则、跨 repo 编排、事务 | 触碰 `*Ctx`、HTTP 类型 |
| `controllers` | 提取请求、调用 service、组织响应 | 业务规则、直接访问数据 |
| `routes` | 把 URL 映射到 controller | 处理逻辑 |
| `views` | 把数据渲染为展示格式 | 取数、业务判断 |
| `config` | 集中运行参数 | 散落在各处的魔法值 |
| `middleware` | 横切关注点（鉴权、日志、限流…） | 单个功能的业务逻辑 |

## 3. 依赖方向（单向，从上到下）

```
main → server → app → routes → controllers → services → repositories
                  ↓        ↓          ↓            ↓           ↓
                state    (views)   (models 被各层共享)      (models)
```

铁律：**依赖只能向下**。controller 可以调 service，service 不准反过来认识 controller；service 不准 `@import` 任何 HTTP 类型。`models` 是唯一允许被各层共享的"地基"。违反这条，分层就退化成了"按文件夹堆代码"。

## 4. 状态装配（无 DI 容器）

wing 不用 DI 容器，而是用一个显式的 `AppState` 聚合所有共享依赖；框架在编译期按**类型**把 `*某字段类型` 参数投影给 handler（见 wing 用户指南 §4.1）。

```zig
// state.zig：装配点
pub const AppState = struct {
    config: Config,        // handler 声明 *Config 即可拿到
    database: Database,     // app 级共享连接池的所有者，repository 借用
    users: UserService,    // handler 声明 *UserService 即可拿到
};
```

约束：**每个顶层字段类型必须唯一**，否则投影无法消歧（Zig 反射拿不到参数名）。两个同类型依赖时，各包一层不同的 struct。

并发：所有请求共享同一个 `*AppState`。`user_repository` 不持有共享可变状态——每个请求向 mantle 连接池租用各自的连接，由连接池负责并发与连接上限。若你新增内存型共享状态，写入时需自行同步（如 `zio.Mutex`）。

## 5. 请求生命周期

```
HTTP 请求
  → 中间件链（logger → recover → request_id → security_headers → route_match → cors）
  → controller（wing.extract.Path/Query/Json 提取 → 调 service）
  → service（业务规则，如校验非空 → 调 repository）
  → repository（数据访问，返回 model）
  → controller 返回 typed response（wing.respond.Json / Created / …）
  → 框架 comptime 转换为 HTTP 响应
```

错误处理集中在 `app.zig`：handler/service `return error.X`，由 `recoverWith` 映射为状态码（`error.NotFound`→404 内置；`error.InvalidName`→400 为本骨架示例）。

## 6. 从小型到企业级的扩展路径

本骨架是**按技术分层（layer-first）**：`controllers/`、`services/`… 各放一类。对中小项目最直观，是教科书式的"经典结构"。

随着功能与团队增长，可平滑演进到**按功能分模块（feature-first / modular monolith）**——大型企业代码库（含 NestJS / 大型 Spring 工程）的常见终态：

```
src/modules/
├── users/
│   ├── user_controller.zig
│   ├── user_service.zig
│   ├── user_repository.zig
│   ├── user_model.zig
│   └── user_routes.zig
└── orders/
    └── ...
```

每个功能内部仍保持同样的分层与依赖方向，只是物理上聚合在一起，降低跨目录跳转成本，并让模块边界（和未来的服务拆分边界）显式化。`models/` 中的跨模块共享类型可上提为 `shared/` 或 `common/`。

何时切换：单功能的文件开始分散得难以一起修改、或团队按功能而非按层分工时，就是信号。两种组织都遵循同一套分层原则，迁移是移动文件 + 改 `@import` 路径，不改架构。

## 7. 数据层：mantle（MySQL）

数据访问通过 [`mantle`](../../mantle) 持久化到 MySQL，由两块共享基础设施 + 各功能 repository 组成：

- **`db/database.zig`**：app 级共享连接池的唯一所有者。`AppState` 在启动时创建一个 `Database`（堆固定的 `*mantle.TcpPool`），所有 repository 都**借用**它来租用连接，自己不创建、不挂载池。
- **`db/sql.zig`**：集中的 SQL 注册表。所有语句（schema migrations + 各功能查询）都以命名常量集中在这里，repository 引用常量而非内联字面量。
- **`repositories/user_repository.zig`**：`create`/`findById`/`list` 借用共享池租用连接、执行 `db/sql.zig` 里的参数化 SQL。语义与内存版一致，controller、routes 未动——这正是 repository 接缝的价值。

要点：

- **同一个 zio 实例**：wing/talon 与 mantle 都用 `../zio` path 依赖，Zig 去重为单一模块，`server.zig` 启动的 runtime 与连接池共享同一调度器。
- **连接配置**：`config/config.zig` 的 `Db`（`DB_*` 环境变量覆盖）。每条 pooled 连接握手即选库，因此目标 database 必须预先存在（app 只建表，不建库）。
- **所有权**：查询临时结果用长生命周期 `gpa` 分配并即时 `Table.deinit` 释放；返回给上层的 `name` 复制进请求 `arena`，随响应结束回收。
- **并发**：每个请求租用各自的连接，无共享可变状态，repository 不需要 `zio.Mutex`。
- **建表**：启动时 `AppState.migrate` 委托 `Database.migrate`，按序执行 `db/sql.zig` 中的 migrations（在 runtime 内）。
