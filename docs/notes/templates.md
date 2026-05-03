# ESR Templates — 目标态设计

**Date:** 2026-05-03 (rev 6, was views.md)
**Audience:** 同 `concepts.md`
**Status:** prescriptive 设计文档；**不**描述当前实现，**不**讨论迁移路径

---

## 这份文档是什么

`concepts.md` 定义了元模型（4 runtime primitive: Session/Entity/Resource/Interface + 1 declarative: Template）。这份 doc 在元模型之上**枚举 ESR 应有的 Templates**——即 ESR 在目标态下需要存在哪些 Template，每个 Template 产出什么 primitive (Session / Entity / Resource)，包含什么 default 内容、实现哪些 Interface。

读它的目标：

- 设计新功能时，确认它属于哪个 Template，或者是否需要新增 Template
- 写 spec 时，引用本文档中 Template 名字
- 重构时，把代码模块对应到本文档登记的 Template

本文档**不**讨论：今天的代码长什么样、谁要改名、如何从现状迁移——这些是后续重构计划的内容。

---

## 一、Template 一览表

按产出 primitive 分类（不是 metamodel-level subtype）：

### Session-producing Templates

| Template | 产出 | 实例数 |
|---|---|---|
| **DaemonTemplate** | Daemon Session（root scope） | 1（每个 esrd 1 份） |
| **AdminTemplate** | Admin Session（操作员 scope） | 1（daemon 内嵌 1 份） |
| **GroupChatTemplate** | Group-Chat Session（多成员群聊） | N（每个群 1 份） |

### Entity-producing Templates

| Template | 产出 | 实例数 |
|---|---|---|
| **UserTemplate** | User Entity（人类） | N（每个人 1 份） |
| **AgentTemplate** | Agent Entity（AI） | N（每个 AI 实例 1 份） |
| **AdapterTemplate** | Adapter Entity（外部接入） | N（每个外部 instance 1 份） |
| **HandlerTemplate** | Handler Entity（纯函数事件处理） | N（每种 event 处理逻辑 1 份） |
| **DispatcherTemplate** | Dispatcher Entity（admin queue 调度器） | 1（admin scope 内 1 份） |
| **SlashCommandHandlerTemplate** | SlashCommandHandler Entity | 1 |

### Resource-producing Templates

| Template | 产出 | 实例数 |
|---|---|---|
| **ChannelTemplate** | Channel Resource（消息流） | N |
| **DirTemplate** | Dir Resource（fs namespace） | N |
| **CapabilityTemplate** | Capability Resource（perm token） | N |
| **AdminQueueTemplate** | Admin-Queue Resource（fs-based job queue） | 1（admin scope 内 1 份） |
| **SlashRouteRegistryTemplate** | Slash-Route-Registry Resource | 1 |
| **CapabilityRegistryTemplate** | Capability-Registry Resource | 1 |

---

## 二、Session-producing Templates

### DaemonTemplate

**产出**：1 个 Daemon Session（top-level scope）

**职责**：ESR 进程级 root scope。所有其他 Session / Entity / Resource 都是它的 member 或 nested Session。

**默认成员**：

- 1 Admin Session（嵌套）
- N Group-Chat Sessions（动态创建）
- N User Entity（注册的所有人类）
- N Agent Entity declarations
- N Adapter Entity（连接外部世界的所有 instance）
- M Capability Resource（daemon-tier 权限）

**实现的 Interface**：

- `BootInterface` — 启动 / 关闭 / 健康检查
- `RegistryInterface` — Entity / Resource 注册表
- `RoutingInterface` — 把 inbound 路由到正确的 Session

---

### AdminTemplate

**产出**：1 个 Admin Session

**职责**：管理员 / 操作员动作的 scope。daemon-level 操作（创建 Session、grant capability、注册 Adapter 等）在这里执行。

**默认成员**：

- 1 Dispatcher Entity（DispatcherTemplate 产出，处理 admin queue）
- 1 SlashCommandHandler Entity（SlashCommandHandlerTemplate 产出）
- 1 Admin-Queue Resource（AdminQueueTemplate 产出）
- 1 SlashRouteRegistry Resource（SlashRouteRegistryTemplate 产出）
- 1 CapabilityRegistry Resource（CapabilityRegistryTemplate 产出）

**实现的 Interface**：

- `OperationInterface` — Dispatcher 实现
- `SlashParseInterface` — SlashCommandHandler 实现

---

### GroupChatTemplate

**产出**：1 个 Group-Chat Session

**职责**：ESR 最 canonical 的 Session 形态——多成员 group chat。

**默认成员**（典型组成）：

- N User Entity（人类参与者，从 daemon registry reference 进来）
- M Agent Entity（AI 参与者）
- 1 或多个 Channel Resource（群级消息流）
- 0..N Dir Resource（共享代码空间 / 文档空间）
- M Capability Resource（session-level 权限子集）

**实现的 Interface**：

- `SessionLifecycleInterface` — start / pause / archive / resume
- 成员实现 `MemberInterface` / `ChannelInterface` 等

**Lifecycle**：

- 由 Admin 通过 `session.create` operation 创建
- 进入 active 状态后接受 inbound 消息 → 触发成员 callback
- 可被 Admin pause / archive / resume
- 解散时，shared Resource 引用计数减一；非共享的随 Session 一起销毁

---

## 三、Entity-producing Templates

### UserTemplate

**产出**：1 个 User Entity（人类参与者）

**职责**：可加入多 Session 的人类身份。

**默认成员（Entity 内部）**：

- 1 Identity record（username / email / phone / 外部平台 binding 列表）
- N Capability granted

**实现的 Interface**：

- `MemberInterface` — 加入 Session 时
- `IdentityInterface` — username 唯一性、外部平台 ID 解析

---

### AgentTemplate

**产出**：1 个 Agent Entity（AI 参与者）

**职责**：AI 参与者。Session 中跟 User 平等的成员。Agent 自身有内部 sub-Session 结构（agent 内部协作模块 + internal channel-bus）。

**外部成员（从 outer Session 视角）**：

- 1 Agent Entity 实例

**内部成员（agent zoom in 之后）**：

- 1 或多个 internal sub-modules（其他 Entity）
- 1 internal Channel Resource（agent 跟外部 AI service 通信的管道）
- 0..N internal Dir Resource
- 0..N internal Capability Resource

**实现的 Interface**：

- `MemberInterface` — 在 outer Session 中作为 member
- `AgentInterface` — 处理 mention / reply 的 AI-specific 接口（如 think / plan / act）

---

### AdapterTemplate

**产出**：1 个 Adapter Entity（外部接入桥）

**职责**：跟外部系统（消息平台、API、外部服务）的桥梁。把外部协议翻译成 ESR 内部 envelope。

**默认成员（Entity 持有的资源）**：

- 1 ExternalConnection Resource（实现 BoundaryConnectionInterface）
- 0..N Capability

**实现的 Interface**：

- `BoundaryInterface` — inbound 翻译、outbound 翻译
- `BoundaryConnectionInterface` — connect / reconnect / disconnect

---

### HandlerTemplate

**产出**：1 个 Handler Entity（纯函数事件处理器）

**职责**：处理特定 actor_type event 的纯函数。接收 event，返回 (new_state, [actions])。

**Purity 约束**：handler 只能 import `esr` SDK + 自己的 package；不持有跨 invocation 状态。

**实现的 Interface**：

- `EventHandlerInterface` — event → (state, [actions])
- `PurityInterface` — 编译期检查 import 限制

---

### DispatcherTemplate / SlashCommandHandlerTemplate

**职责**：admin scope 内部的 control-flavor Entity。

- **Dispatcher**: 从 Admin-Queue 拉 operation → 解析 → 调用对应 command 模块。实现 `OperationInterface`。
- **SlashCommandHandler**: 解析 user-facing slash 文本 → 输出 (kind, args)。实现 `SlashParseInterface`。

---

## 四、Resource-producing Templates

### ChannelTemplate

**产出**：1 个 Channel Resource

**职责**：两个或多个 Entity 之间的消息流。

**实现的 Interface**：

- `ChannelInterface` — publish / subscribe / unsubscribe / frame

**Lifecycle 选项**（由具体 Channel 实例决定）：

- **Ephemeral**：与某个 Session 同生死
- **Persistent**：跨 Session 长期存在
- **Shared**：被多个 Session reference

---

### DirTemplate

**产出**：1 个 Dir Resource

**职责**：命名的文件系统空间。

**实现的 Interface**：

- `DirInterface` — read / write / list / mkdir / rmdir

**关系**：可被多 Session 共享（如同一 git repo 被多个 Session 引用）；多 reader 自由；写冲突由外部协调（如 git worktree）。

---

### CapabilityTemplate

**产出**：1 个 Capability Resource

**职责**：符号性权限 token + 授权关系。

**实现的 Interface**：

- `CapabilityDeclarationInterface` — name / description / required-for
- `GrantInterface` — grant / revoke / check

**两态**：

- **Declarative**：cap 在代码 / yaml 里声明
- **Granted**：grant 关系存于 Grant Registry（admin Session 的 CapabilityRegistry Resource 持有）

---

### AdminQueueTemplate / SlashRouteRegistryTemplate / CapabilityRegistryTemplate

admin scope 内部的 Resource：

- **Admin-Queue**: fs-based job queue。`{id, kind, submitted_by, args, [result]}` schema。实现 `JobQueueInterface`。
- **Slash-Route-Registry**: kind → command_module 映射的运行时 registry。实现 `RegistryInterface`。
- **Capability-Registry**: cap 声明 + grant 关系的运行时 registry。实现 `RegistryInterface` + `GrantInterface`。

---

## 五、Common Interfaces 总表

为方便查询，列出本文档中提到的所有 Interface（不重复定义，仅汇总）：

### Session-flavor

- `SessionLifecycleInterface` — start / pause / archive / resume
- `MemberInterface` — mention / reply / leave / join

### Resource-flavor

- `ChannelInterface` — publish / subscribe / frame
- `DirInterface` — read / write / list
- `CapabilityDeclarationInterface` / `GrantInterface`
- `JobQueueInterface` — admin queue 等

### Entity-flavor

- `IdentityInterface` — username / external-id mapping
- `AgentInterface` — think / plan / act（AI-specific）
- `BoundaryInterface` — inbound / outbound 翻译
- `BoundaryConnectionInterface` — connect / reconnect
- `EventHandlerInterface` / `PurityInterface`

### Cross-cutting

- `OperationInterface` — enqueue / execute / report
- `RegistryInterface` — lookup / register / unregister
- `RoutingInterface` — route inbound to Session
- `BootInterface` — daemon 启停
- `SlashParseInterface` — slash command 解析

---

## 六、Cross-Template 关系示意

```
DaemonTemplate → 1 Daemon Session
  ├── 嵌套 1 Admin Session（AdminTemplate 产出）
  │     ├── Dispatcher（DispatcherTemplate）
  │     ├── SlashCommandHandler（SlashCommandHandlerTemplate）
  │     ├── Admin-Queue（AdminQueueTemplate）
  │     ├── SlashRouteRegistry（SlashRouteRegistryTemplate）
  │     └── CapabilityRegistry（CapabilityRegistryTemplate）
  │
  ├── N Adapter Entities（AdapterTemplate） — 跨 Group-Chat Session 共享
  ├── N User Entities（UserTemplate） — 跨 Group-Chat Session 共享
  ├── N Capability Resources（CapabilityTemplate） — 跨 Session 共享
  │
  └── N Group-Chat Sessions（GroupChatTemplate）
        ├── reference: User Entities (from daemon registry)
        ├── Agent Entities（AgentTemplate） — typically per-session
        │     └── (zoom in: agent's internal Session sub-graph)
        ├── Channel Resource（ChannelTemplate） — group-shared
        ├── reference: Dir Resource (from daemon registry)
        └── reference: Capability Resource subset
```

每个 Template 产出的 primitive 通过 **reference** 互相关联——不是 containment。同一个 User Entity 可以同时是 daemon 的 member 和多个 Group-Chat Session 的 member；同一个 Dir 可以被多 Session 共享。

---

## 七、相关文档

- `docs/notes/concepts.md` — metamodel 定义（必先读）
- `docs/notes/mechanics.md` — ESR 运行 essence：actor model + topology declaration 怎么落地
- `docs/notes/actor-role-vocabulary.md` — role trait 的详细定义（在新模型下，role trait 是 Template 选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — 后续重构任务跟踪
