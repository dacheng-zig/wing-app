# wing-jobs：后台任务与定时调度——设计与实现

> 本文是 `lib/wing-jobs/` 模块的权威说明：它是什么、怎么用、内部如何工作、为什么这么设计。
> 代码基线：`lib/wing-jobs/`（约 2000 行）+ 迁移 `004_create_wing_jobs.sql` / `005_create_wing_schedules.sql` + 应用侧组装 `src/jobs/registry.zig`。
> 设计前对 Sidekiq、Oban、River、Solid Queue、BullMQ、Quartz、Hangfire 等 21 个主流任务系统做过横向调研，文中的关键决策均取自这些系统被生产验证过的共识做法。

---

## 1. 这是什么

wing-jobs 给 wing-app 提供两件事：

1. **后台任务**：HTTP 请求里不想同步做的事（发邮件、清理数据、生成报表），写成一个任务丢进队列，由后台协程执行。支持延迟执行、失败重试、超次数后进入"死信"留待人工处理、单任务超时。
2. **定时任务**：用 cron 表达式（或固定间隔）声明周期性工作，比如"每小时清理过期凭证"。多实例部署时同一时刻只会触发一次；宕机重启后对错过的触发有明确的补跑规则。

它**只用 MySQL**，不需要 Redis 或任何新组件。任务就是 `wing_jobs` 表里的一行，用 SQL 就能查、能审计。这是刻意选择：对一个已经有 MySQL 的单体应用，数据库队列的运维成本最低，而且换来一个独有优势——**任务可以和业务写入放进同一个数据库事务**：业务回滚，任务一起消失，不存在"用户没建成但欢迎邮件发出去了"这种事。

**投递语义是 at-least-once（至少一次）**：正常情况下每个任务执行一次，但进程崩溃等极端场景下可能重复执行。系统不假装能做到"恰好一次"（调研过的 21 个主流系统没有一个真正做到），代价由任务代码承担：**handler 必须写成幂等的**——重复执行一次结果不变。

## 2. 快速上手

### 定义一个任务

一个任务 = 一个 struct：`kind` 是它落库的名字，字段是载荷（自动 JSON 序列化），`run` 是执行逻辑。

```zig
pub const SendWelcomeEmail = struct {
    pub const kind = "send_welcome_email";
    pub const queue = "mailer";                        // 可选，默认 "default"（目前仅作标签）
    pub const max_attempts: u16 = 5;                   // 可选，默认 20
    pub const timeout: zio.Duration = .fromMinutes(2); // 可选，默认不限时

    user_id: Id,          // 载荷字段，JSON 序列化；改字段要保持向后兼容
    name: []const u8,

    pub fn run(self: @This(), ctx: *jobs.Context) !jobs.Outcome {
        // ctx.arena 是本次执行专用内存；ctx.pool 是共享连接池
        // CPU 密集段必须 zio.blockInPlace / spawnBlocking，别占住调度线程
        return .ok;
    }
};
```

`run` 的返回值就是任务的去向：

| 返回 | 含义 | 落库状态 |
|---|---|---|
| `.ok` | 成功 | `completed` |
| `.{ .snooze = d }` | 主动让路，d 之后重排（**不消耗重试次数**） | `available` |
| `.{ .cancel = "原因" }` | 主动取消，不再重试 | `cancelled` |
| `.{ .discard = "原因" }` | 主动放弃，进死信 | `discarded` |
| 返回 error | 失败，按退避公式重试；次数耗尽进死信 | `retryable` / `discarded` |

### 注册

所有任务类型集中列在 `src/jobs/registry.zig`，这个集合在**编译期**闭合并校验——`kind` 重复、缺 `run`、cron 表达式写错，都是编译错误而不是线上事故：

```zig
pub const JobRegistry = jobs.Registry(&.{
    SendWelcomeEmail,
    CleanupExpiredCredentials,
});
```

### 入队

```zig
// 独立入队（内部走连接池的短事务）：
_ = try JobRegistry.insert(gpa, pool, SendWelcomeEmail{ .user_id = id, .name = n }, .{});

// 业务事务内入队（推荐，原子性免费获得）：
_ = try JobRegistry.insertTx(gpa, tx, SendWelcomeEmail{ ... }, .{});
// 提交后调 jobs.notifyEnqueued() 可立即唤醒执行；不调也行，最多等一个轮询间隔（默认 1s）

// 选项：延迟执行、绝对时间、优先级（数小者先跑）、唯一性（见 §8）
.{ .delay = .fromMinutes(10), .priority = 1, .unique = .{ ... } }
```

注意：`insert`/`insertTx` 的 `gpa` 必须是长寿命分配器（应用级 allocator），**不能用请求 arena**——mantle 会把预编译语句缓存在池化连接上，寿命超出本次调用。

### 定时任务

定时任务就是"到点自动入队的普通任务"，要求所有字段都有默认值（调度器插入 `.{}`）。声明也在 `src/jobs/registry.zig`：

```zig
pub const schedules = [_]jobs.Schedule{
    .{ .key = "cleanup_expired_credentials",
       .spec = .{ .cron = "@hourly" },
       .job = CleanupExpiredCredentials },
};
```

`spec` 支持五段 cron（`分 时 日 月 周`，UTC）、`@hourly/@daily/@weekly/@monthly/@yearly` 别名，以及固定间隔 `.{ .every = .fromMinutes(5) }`。表达式在编译期解析，写错编译不过。

## 3. 总体架构

整个模块以几个协程的形式内嵌在 wing-app 进程里，与 HTTP 服务共享同一个 zio 单执行器运行时，随 `server.zig` 的 `zio.Group` 一起启停：

```
 HTTP handler ──insert/insertTx──▶ MySQL: wing_jobs 表 ◀──到点 INSERT── Scheduler 协程
      │                              ▲       │                              │ (tick 15s,
      └──同进程 Notify 立即唤醒──┐   │       │ 批量认领                      │  CAS 防重)
                                 ▼   │       ▼                              ▼
                            Producer 协程 ──Channel──▶ Worker 协程 ×4   wing_schedules 表
                                     │                     │
                                     │                finalize（屏蔽取消，保证提交完整）
                                     │
                            Rescuer 协程：定期扫描卡死的 running 行，复活或判死
                            Pruner：内部定时任务（每天 04:00 UTC），删过期终态行
```

三个结构性决策贯穿全局：

- **调度归调度，执行归执行**。Scheduler 只做一件事——在正确时刻 INSERT 一个普通任务；之后它与手工入队的任务走完全相同的认领/重试/死信路径。维护工作（Pruner）自己也是一个普通定时任务，吃自己的狗粮。
- **多实例安全全靠数据库裁决，没有任何协调组件**。认领靠 `FOR UPDATE SKIP LOCKED`（锁到行就归你，锁不到跳过）；cron 触发靠 CAS（更新时带上旧值做条件，只有一个节点改得动）+ 唯一索引双保险；rescue/prune 是幂等语句，多节点重复执行无害。不用 leader 选举，也**绝不用 MySQL 的 `GET_LOCK`**——会话级锁绑定物理连接，被连接池回收就静默丢锁。
- **数据库时钟是唯一时钟**。所有时间比较和存储时间戳都用 `UTC_TIMESTAMP(3)` 在服务端算，节点之间时钟偏移不影响判定。DATETIME 值以字符串过线（`clock.zig` 负责与 epoch 毫秒互转），避免会话时区搞出隐式转换。

## 4. 数据模型

两张表，全部时间列存 UTC。

**`wing_jobs`**（每个任务一行）：

| 列 | 说明 |
|---|---|
| `id` CHAR(36) | 应用生成的 UUIDv7（与全库主键约定一致） |
| `kind` / `queue` / `priority` | 任务类型名 / 队列标签 / 优先级（小者先） |
| `state` ENUM | 六态：`available / running / retryable / completed / cancelled / discarded` |
| `args` JSON | 载荷 |
| `attempt` / `max_attempts` | 已尝试次数 / 上限 |
| `errors` JSON | 失败历史数组，每次失败追加 `{attempt, at, error}`，审计免费 |
| `unique_key` VARBINARY(32) + `unique_keep` | 去重指纹与"完成后是否继续占用"标记（见 §8） |
| `scheduled_at` | 最早可执行时刻；**延迟任务 = 未来的 scheduled_at**，不设单独状态 |
| `attempted_at` / `attempted_by` | 本次认领时刻 / 认领节点（启动时生成的随机 id `node-<16位hex>`，崩溃归因用） |
| `finalized_at` | 进入终态时刻，清理依据 |

三个复合索引各管一条路径：`(state, queue, priority, scheduled_at, id)` 管认领，`(state, attempted_at)` 管救援扫描，`(state, finalized_at)` 管清理；`unique_key` 上有唯一索引。

**`wing_schedules`**（每个定时声明一行，只存最小运行状态）：`schedule_key`（代码里声明的 key）、`next_run_at`（预计算的下次触发）、`last_run_at`。cron 表达式本身**不落库**——定义在代码里，部署即真相；表里只有"下次几点跑"这个必须持久化的状态。启动时代码声明自动补齐缺行；表里有、代码里已删的 key 只告警不删，让漂移可见。

### 状态机

```
 insert ──▶ available ──认领──▶ running ──▶ completed
               ▲                   │
               ├── retryable ◀─────┤ 失败且次数未耗尽（退避后重试）
               ├── snooze 重排 ◀───┤ （不消耗次数）
               │                   ├──▶ cancelled（主动取消）
               └── rescuer 复活 ◀──┴──▶ discarded（次数耗尽 / 主动放弃 / 死信）
```

认领条件统一是"(`available` 或 `retryable`) 且 `scheduled_at` 已到期"，所以不需要任何后台搬运器把状态搬来搬去。

## 5. 认领与执行

**Producer（一个协程集中认领）**：看有几个空闲 worker，就一次性认领几个任务，避免 N 个 worker 各自发起竞争性认领。认领是一个短事务两条语句：`SELECT ... FOR UPDATE SKIP LOCKED` 锁住到期行，`UPDATE` 置成 `running` 并把 `attempt` 加一。锁只存在于这两条语句之间，与任务执行时长完全无关。几个实现细节：

- 事务前先跑一条**无锁探测**（`SELECT 1 ... LIMIT 1`）：队列空闲时每次轮询只花一条语句的成本，不开事务。
- 认领事务用 **READ COMMITTED** 隔离级别，避开 REPEATABLE READ 下间隙锁在热索引上的堆积（Solid Queue 的生产教训）。
- 唤醒是"通知 + 轮询兜底"：同进程入队即时唤醒（`zio.Notify`），其他节点入队最多等一个轮询间隔（默认 1s）。轮询按绝对时间对齐，不会因为干活耗时产生相位漂移；一批认领满载说明还有积压，立即再拉。
- SQL 形状刻意保持固定，善待预编译语句缓存：插入语句按"是否延迟 / 是否唯一"分四个固定变体；认领批次的 UPDATE 把 id 列表直接拼进语句文本（id 经过 UUID 类型往返，只含十六进制和连字符，无注入面），避免每种批次大小各占一条缓存。

**Worker（默认 4 个协程）**：从 channel 取任务，每个任务配一个专属 arena（执行完整体释放），把任务 id 绑进日志上下文（任务内所有日志自动带 `trace_id`，与请求日志同一条管线），然后分发执行：

- **分发**是编译期生成的 kind→类型匹配：JSON 反序列化直接进对应 struct，再调它的 `run`。载荷解析失败视为永久性问题，直接 discard（重试也不会好）；kind 不认识（多半是回滚部署后留下的新任务）也 discard 并告警。
- **超时**用 `zio.AutoCancel`：到时后任务内所有 IO 抛 `error.Canceled`，按"失败"处理走重试。这是协作式取消——纯计算段不会被打断，所以长计算必须主动让出或走 `spawnBlocking`。一个容易踩的坑已在实现中处理：定时器在 `run` 的最后一个挂起点之后才触发时，取消信号会悬在协程上，若不显式消费掉，会在 worker 下一次取任务时炸出来把 worker 无声杀掉。
- **收尾（finalize）在取消屏蔽区内执行**（`zio.beginShield`）：优雅停机的取消信号不能把"任务其实做完了"的那条 UPDATE 拦腰斩断，否则完成的任务会被误判为崩溃而重跑。
- 每条收尾 UPDATE 都带 `WHERE state='running'` 条件：一个执行超时被 rescuer 复活又被别的 worker 认领后，迟到的旧收尾不能覆盖新一轮执行的状态。

**重试退避**：`attempt⁴ + 15` 秒，再加最多 10% 随机抖动（防惊群）。第 1 次失败约 16 秒后重试，第 5 次约 10 分钟，第 10 次约 2.8 小时，默认 20 次全程约一周，之后进 `discarded`。这条公式是 Sidekiq / Oban / asynq / River 四个生态不约而同的共识。

**并发约束**：每个执行中的 worker 占一条池化连接，所以 `JOBS_WORKERS` 必须小于 `DB_POOL_SIZE`，启动时强制检查（默认 4 < 8）。想加 worker 先扩池。

## 6. 崩溃恢复（Rescuer)

worker 拿到任务后进程崩了（kill -9、断电），行会永远停在 `running`。Rescuer 每分钟扫一次：`running` 超过 `rescue_after`（默认 15 分钟）的行，次数没耗尽就置回 `retryable` 重跑，耗尽就判 `discarded`，并在 `errors` 里记一笔"rescued: stuck running"。

- 这是纯幂等 UPDATE，**每个节点都跑，无需协调**。实现极简的代价是恢复时效以分钟计——对"崩溃是罕见事件"的场景是划算的取舍。
- `rescue_after` 实际上就是**任务运行时长上限**：超过它还没跑完的任务会被误判为崩溃并重复执行。长任务必须拆分或用 snooze 分段续命。
- 自动重跑意味着非幂等任务在崩溃场景可能双跑。绝不允许双跑的任务声明 `pub const rescue: jobs.RescuePolicy = .discard;`——rescuer 对这类 kind 不重跑，直接进 `discarded` 等人工裁决。实现上先处理 discard 类 kind 再做通用扫描，且通用扫描显式排除这些 kind，避免两条语句之间跨过时限的行被错误自动重试。
- 优雅停机没来得及写回的任务也走这条路复活——干净停机与崩溃共用同一条恢复路径。

## 7. 定时调度（Scheduler）

每个节点跑同样的 tick 循环（默认 15 秒一次，也是 cron 触发的最坏延迟）：

1. 查出本进程声明的、`next_run_at` 已到期的 schedule 行。
2. 对每一行，按 misfire 规则（见下）决定"这次要不要真的触发、触发时刻算哪个"，并算出新的 `next_run_at`。
3. 在**一个事务里**：INSERT 任务 + 用旧 `next_run_at` 做条件 CAS 更新。CAS 改到行 = 本节点赢得本次触发，提交；改不到 = 别的节点已经触发过了，回滚（任务 INSERT 一起消失），静默跳过。

防重是**双保险**：CAS 是主力（同一触发只有一个节点改得动那一行）；任务本身还带确定性 `unique_key` 指纹兜底。触发即入队原子成立——不存在"推进了 next_run_at 但任务没插进去"的窗口。

**错过触发（misfire）怎么办**：进程停机跨过触发点后，`next_run_at` 停在过去。重启后第一个 tick 按 per-schedule 策略处理：

- `catch_up = .coalesce`（默认）：错过 N 次只补跑**最近的一次**，且仅当它距现在不超过 `grace`（默认 60 分钟）；太久远就干脆跳过。这避免了重启后的补跑风暴和"补跑三天前的报表"这类僵尸执行。
- `catch_up = .skip`：全部跳过，直接对准未来最近的触发点。

**防自我踩踏**：`no_overlap = true`（默认）时，触发任务的去重指纹按 kind 计算——上一次触发还没跑完（还占着指纹），本次 INSERT 撞唯一索引即跳过并记日志。慢任务不会追尾自己。关闭 `no_overlap` 时指纹改为"schedule key + 触发时刻"，只防同一次触发被插两遍。同一个 job 类型不允许被两个 `no_overlap` 的 schedule 引用（编译期报错，否则会互相压制）。

cron 求值细节：全部 UTC、分钟粒度；日与周字段同时限定时按 vixie-cron 传统取"或"；固定间隔按 epoch 对齐取整，所以各节点无需协调也算出相同的触发时刻；永不可能命中的表达式（如 2 月 30 日）在启动时告警。misfire 解析对固定间隔有 O(1) 快速路径，长时间停机不会在共享执行器上空转补算。

## 8. 唯一任务（去重）

入队时带 `unique` 选项，可防止重复任务堆积：

```zig
.{ .unique = .{
    .by = .args,              // 指纹维度：kind+载荷（默认）或仅 kind
    .period = null,           // 设了就是节流：每个时间窗口最多一个
    .keep_after_done = false, // 完成后是否继续占用指纹（默认释放）
} }
```

指纹是 SHA-256（kind、载荷、可选时间桶各自带长度前缀拼接），32 字节存 `unique_key`，靠唯一索引硬约束——无锁、无竞态、与事务性入队天然兼容。撞车时 `insert` 返回 `error.DuplicateJob`，调用方自行决定是忽略还是提示。

- 默认语义是"**进行中去重**"：任务进入终态时指纹释放，同样的任务可以再来。
- `keep_after_done = true` 则占用到行被清理为止，即"完成后仍去重"，窗口约等于保留期。这个选择在插入时落库为行内的 `unique_keep` 标记，收尾 SQL 据此决定是否清空指纹——收尾方不需要知道入队时的选项。
- `period` 把对齐的时间桶编进指纹，桶自然过期，无需清理——即"每 5 分钟最多入队一个"式节流。

## 9. 停机与取消

- **优雅停机**：SIGINT → HTTP 排空 → `group.cancel()`。producer/scheduler/rescuer 在挂起点收到取消直接退出；执行中的 worker 在任务的下一个挂起点收到 `error.Canceled`，把任务**原样放回** `available`（本次中断算掉一次尝试，轻微保守），收尾本身在屏蔽区内不会被打断。没来得及放回的（进程被硬杀）由 rescuer 兜底。
- **远程取消**：`Repository.cancelPending(id)` 只能取消还没开始跑的任务。取消运行中的任务需要跨进程信号通道，MySQL 没有，留待需要时再加。

## 10. 配置

配置结构体由 jobs 模块自带（纯 std，应用 config 直接内嵌），应用侧把 `JOBS_*` 环境变量映射上去：

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `JOBS_ENABLED` | true | 关掉则整个 runner 不启动 |
| `JOBS_WORKERS` | 4 | worker 协程数，必须 < `DB_POOL_SIZE` |
| `JOBS_POLL_INTERVAL` | 1s | producer 轮询兜底间隔 |
| `JOBS_TICK_INTERVAL` | 15s | 调度 tick，即 cron 最坏触发延迟 |
| `JOBS_RESCUE_AFTER` | 900s | running 超过此时长视为崩溃（= 任务运行时长上限） |
| `JOBS_RESCUE_INTERVAL` | 60s | 救援扫描间隔 |
| `JOBS_RETENTION_COMPLETED` | 7 天 | 成功任务行保留期 |
| `JOBS_RETENTION_DISCARDED` | 30 天 | 死信/取消行保留期 |

保留期由内部定时任务 Prune 执行（每天 04:00 UTC，每批 DELETE 5000 行循环到清空），对抗单表膨胀。

## 11. 可观测性

- **`GET /internal/jobs/stats`**：各状态计数、**队首等待秒数**（最老的可跑任务等了多久——一个数字看清队列健康度）、每个 schedule 的下次/上次触发时刻。
- **日志**：任务内所有日志自动带任务 id 作为 trace_id；认领、完成、重试、救援、cron 触发各有一条结构化日志。
- **审计**：`wing_jobs` 表本身就是事实源——`errors` 是完整失败历史，`attempted_by` 标明哪个节点跑的，mysql 客户端直接查。不需要 Web UI。

## 12. 写任务的契约（必读清单）

1. **幂等**：任务可能重复执行（崩溃恢复、rescue、超时重试），重复一次结果必须不变。做不到就声明 `rescue = .discard`。
2. **CPU 密集段离开调度线程**：整个进程是单执行器，HTTP 和所有任务共享一个 OS 线程。长计算必须 `zio.blockInPlace`/`spawnBlocking`，否则拖慢所有请求。
3. **控制运行时长**：超过 `rescue_after`（默认 15 分钟）的任务会被误判崩溃而双跑。长工作拆分成多个任务或用 snooze 分段。
4. **载荷向后兼容**：升级部署时表里可能还有旧代码序列化的任务行，字段只加不改不删（解析时未知字段被忽略）。
5. **不删除任务类型前先排空**：kind 从 Registry 移除后，表里遗留的该类任务会被 discard 并告警。
6. **入队用长寿命 allocator**：不要把请求 arena 传给 `insert`/`insertTx`。

## 13. 关键取舍一览

| 取舍 | 选了什么 | 代价 |
|---|---|---|
| MySQL vs Redis | MySQL 单表 | 吞吐上限低一个量级（数百任务/秒内没问题），换来零新组件 + 事务性入队 |
| 崩溃恢复 | rescuer 定时扫描 | 恢复时效 15 分钟级；换来无 leader、无心跳的极简实现 |
| cron 防重 | 单行 CAS + 唯一索引 | 无集中协调点；目前也没有需要协调点的职责 |
| 投递语义 | at-least-once | handler 承担幂等责任；`rescue = .discard` 做逃生口 |
| kind 集合 | 编译期封闭 | 不支持运行时动态注册任务类型；换来整套编译期校验 |
| 时区 | v1 全 UTC | 本地时区 cron 语义（含夏令时）后置 |

明确**不做**的：exactly-once、全局限流、任务编排（workflow/父子任务）、Web UI、Redis 后端、跨语言协议、leader 选举——都是调研确认可以后置或永不需要的。

## 14. 测试现状

- 纯函数层（cron 解析与 nextAfter、misfire 决策、UTC 历法换算、退避曲线、指纹、状态枚举）在模块内有完整单元测试，含月末/闰年/周日 7→0 归一化/`2 月 30 日永不触发`等边界。
- 需要 MySQL 的部分（repository/runner/scheduler）由应用测试聚合器实例化泛型获得编译覆盖；NULL 参数绑定的历史 bug 已在 mantle 集成测试中有回归守卫。
- 端到端行为（入队→执行→重试→死信、双进程 cron 不重复触发、kill -9 后 rescue 复活）目前依赖手工验证，尚无自动化集成测试——这是当前最大的测试缺口。
