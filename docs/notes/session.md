# ESR Sessions — 目标态设计

**Date:** 2026-05-03 (rev 8, was templates.md → views.md → session.md)
**Audience:** 同 `concepts.md`
**Status:** prescriptive 设计文档；**不**描述当前实现，**不**讨论迁移路径

---

## 这份文档是什么

`concepts.md` 定义了元模型（4 runtime primitive: Scope/Entity/Resource/Interface + 1 declarative: Session）。

这份 doc 在元模型之上**枚举 ESR 应有的 Sessions** 以及 **Entity / Resource declarations** 清单——

- **Session** 是 declarative 的 kind+wiring 描述，每个 Session 实例化为一个 Scope。本 doc §二、§三、§四 列所有 Session 定义。
- **Entity / Resource declarations** 不需要 Session 包，本 doc §五、§六 单独列出。

读它的目标：

- 设计新功能时，确认它属于哪个 Session 或哪个 Entity / Resource type，或者是否需要新增
- 写 spec 时，引用本文档中的具体名字
- 重构时，把代码模块对应到本文档登记的 Session / Entity / Resource

本文档**不**讨论：今天的代码长什么样、谁要改名、如何从现状迁移——这些是后续重构计划的内容。

---

## 一、整体清单

### Sessions（实例化为 Scope）

| Session | 产出 Scope | 实例数 |
|---|---|---|
| **DaemonSession** | Daemon Scope（root） | 1（每个 esrd 1 份） |
| **AdminSession** | Admin Scope（操作员 scope） | 1（daemon 内嵌 1 份） |
| **GroupChatSession** | Group-Chat Scope（多成员群聊） | N（每个群 1 份） |

### Entity types（base）

| Entity type | 角色 |
|---|---|
| **User** | 人类参与者 |
| **Agent** | AI 参与者 |
| **Adapter** | 外部接入桥 |
| **Handler** | 纯函数事件处理器（其他特定 Handler 通过 `use Handler` + 加 Interface composition 得到） |

### Resource types（base）

| Resource type | 角色 |
|---|---|
| **Channel** | 双向消息流 |
| **Dir** | fs namespace |
| **Capability** | perm token |
| **JobQueue** | FIFO job queue（具体 instance 如 admin scope 的 AdminQueue） |
| **Registry** | key-value lookup（具体 instance 如 SlashRouteRegistry / CapabilityRegistry） |

---

## 二、DaemonSession

**实例化产出**：1 个 Daemon Scope（top-level scope）

**Context（kind 部分）**：

- 实现 `BootInterface` — 启动 / 关闭 / 健康检查
- 实现 `RegistryInterface` — Entity / Resource 全局注册表
- 实现 `RoutingInterface` — 把 inbound 路由到正确的 Scope

**Topology（wiring 部分；默认成员）**：

- 嵌套 1 个 Admin Scope（由 AdminSession 实例化）
- N 个 Group-Chat Scope（动态创建）
- N 个 User Entity（注册的所有人类）
- N 个 Agent Entity declarations
- N 个 Adapter Entity（连接外部世界的所有 instance）
- M 个 Capability Resource（daemon-tier 权限）

---

## 三、AdminSession

**实例化产出**：1 个 Admin Scope

**职责**：管理员 / 操作员动作的 scope。daemon-level 操作（创建 Scope、grant capability、注册 Adapter 等）在这里执行。

**Context（kind 部分）**：

- 实现 `OperationInterface` — Dispatcher 实现
- 实现 `SlashParseInterface` — SlashCommandHandler 实现

**Topology（wiring 部分；默认成员）**：

- 1 个 Dispatcher Entity
- 1 个 SlashCommandHandler Entity
- 1 个 AdminQueue Resource（JobQueue base 的 instance；fs-based）
- 1 个 SlashRouteRegistry Resource（Registry base 的 instance）
- 1 个 CapabilityRegistry Resource（Registry base 的 instance）
- 默认订阅关系：Dispatcher 订阅 AdminQueue，SlashCommandHandler 订阅一个 admin slash channel

---

## 四、GroupChatSession

**实例化产出**：1 个 Group-Chat Scope

**职责**：ESR 最 canonical 的 Scope 形态——多成员 group chat。

**Context（kind 部分）**：

- 实现 `SessionLifecycleInterface` — start / pause / archive / resume
- 成员实现 `MemberInterface` / `ChannelInterface` 等

**Topology（wiring 部分；默认成员）**：

- N User Entity（人类参与者，从 daemon Scope 的 registry reference 进来）
- M Agent Entity（AI 参与者）
- 1 个 Channel Resource（群级消息流）
- 0..N Dir Resource（共享代码空间 / 文档空间）
- M Capability Resource（session-level 权限子集）
- 默认订阅关系：所有 member 订阅 Channel；Channel 的 publish 触发所有 member 的 handle_info

**Lifecycle**：

- 由 Admin 通过 `scope.create` operation 创建（slash command 或 admin queue）
- 进入 active 状态后接受 inbound 消息 → 触发成员 callback
- 可被 Admin pause / archive / resume
- 解散时，shared Resource 引用计数减一；非共享的随 Scope 一起销毁

---

## 五、Entity declarations

**Entity 不需要 Session 包**——它们的 declaration 就是普通的模块声明（`@behaviour ...`）。

### User

**职责**：可加入多 Scope 的人类身份。

**实现的 Interface**：
- `MemberInterface` — 加入 Scope 时
- `IdentityInterface` — username 唯一性、外部平台 ID 解析

**state**：
- 1 Identity record（username / email / phone / 外部平台 binding 列表）
- N Capability granted

---

### Agent

**职责**：AI 参与者。Scope 中跟 User 平等的成员。Agent 自身有内部 sub-Scope 结构（agent 内部协作模块 + internal channel-bus）。

**实现的 Interface**：
- `MemberInterface` — 在 outer Scope 中作为 member
- `AgentInterface` — 处理 mention / reply 的 AI-specific 接口（如 think / plan / act）

**外部成员（从 outer Scope 视角）**：1 Agent Entity 实例

**内部成员（agent zoom in 之后是一个 Scope）**：

- 1 或多个 internal sub-modules（其他 Entity）
- 1 internal Channel Resource
- 0..N internal Dir Resource
- 0..N internal Capability Resource

---

### Adapter

**职责**：跟外部系统（消息平台、API、外部服务）的桥梁。把外部协议翻译成 ESR 内部 envelope。

**实现的 Interface**：
- `BoundaryInterface` — inbound 翻译、outbound 翻译

**默认占有的 Resource**：
- 1 ExternalConnection Resource（实现 BoundaryConnectionInterface）
- 0..N Capability

---

### Handler（base）

**职责**：处理特定 actor_type event 的纯函数。接收 event，返回 (new_state, [actions])。

**实现的 Interface**：
- `EventHandlerInterface` — event → (state, [actions])
- `PurityInterface` — 编译期检查 import 限制

**Purity 约束**：handler 只能 import `esr` SDK + 自己的 package；不持有跨 invocation 状态。

**Composition 例子**——通过 `use Handler` + 加 specific Interface 得到特定 Handler：

- **SlashCommandHandler**: `use Handler` + 加 `SlashParseInterface`。处理 user-facing slash 文本，输出 (kind, args)。
- **Dispatcher**: `use Handler` + 加 `OperationInterface`。从 JobQueue 拉 operation → 解析 → 调用对应 command 模块。

这些不是独立的 base Entity type——是 Handler 的 specific application。

---

## 六、Resource declarations

**Resource 不需要 Session 包**——它们的 declaration 也是普通模块声明。

### Channel

**职责**：两个或多个 Entity 之间的消息流。

**实现的 Interface**：
- `ChannelInterface` — publish / subscribe / unsubscribe / frame

**Lifecycle 选项**：
- **Ephemeral**：与某个 Scope 同生死
- **Persistent**：跨 Scope 长期存在
- **Shared**：被多个 Scope reference

---

### Dir

**职责**：命名的文件系统空间。

**实现的 Interface**：
- `DirInterface` — read / write / list / mkdir / rmdir

**关系**：可被多 Scope 共享；多 reader 自由；写冲突由外部协调（如 git worktree）。

---

### Capability

**职责**：符号性权限 token + 授权关系。

**实现的 Interface**：
- `CapabilityDeclarationInterface` — name / description / required-for
- `GrantInterface` — grant / revoke / check

**两态**：
- **Declarative**：cap 在代码 / yaml 里声明
- **Granted**：grant 关系存于 CapabilityRegistry（admin Scope 的成员）

---

### JobQueue（base）

**职责**：FIFO 异步 job 队列。投递 job → consumer 拉取处理。

**实现的 Interface**：
- `JobQueueInterface` — enqueue / dequeue / report

**Lifecycle 选项**：
- **Persistent**：fs-based 跨重启可见
- **Ephemeral**：进程内队列

**Instance 例子**：
- **AdminQueue**: 持久化的 admin scope JobQueue。schema `{id, kind, submitted_by, args, [result]}`，作为 AdminSession 的成员（具体实例配置在 AdminSession.Topology 里）。

---

### Registry（base）

**职责**：运行时 key-value lookup 表。

**实现的 Interface**：
- `RegistryInterface` — lookup / register / unregister

**Instance 例子**（admin scope 内的具体 Registry）：
- **SlashRouteRegistry**: kind → command_module 映射
- **CapabilityRegistry**: cap 声明 + grant 关系（在 RegistryInterface 之外另加 `GrantInterface`）

具体内容在 AdminSession.Topology 里声明。

---

## 七、Common Interfaces 总表

为方便查询，列出本文档中提到的所有 Interface（不重复定义，仅汇总）：

### Scope-flavor

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
- `RoutingInterface` — route inbound to Scope
- `BootInterface` — daemon 启停
- `SlashParseInterface` — slash command 解析

---

## 八、Cross-Session 关系示意

```
DaemonSession → 1 Daemon Scope
  ├── 嵌套 1 Admin Scope（AdminSession 实例化）
  │     ├── Dispatcher Entity
  │     ├── SlashCommandHandler Entity
  │     ├── AdminQueue Resource
  │     ├── SlashRouteRegistry Resource
  │     └── CapabilityRegistry Resource
  │
  ├── N Adapter Entities — 跨 Group-Chat Scope 共享
  ├── N User Entities — 跨 Group-Chat Scope 共享
  ├── N Capability Resources — 跨 Scope 共享
  │
  └── N Group-Chat Scopes（GroupChatSession 实例化）
        ├── reference: User Entities (from daemon registry)
        ├── Agent Entities — typically per-Scope
        │     └── (zoom in: agent's internal Scope sub-graph)
        ├── Channel Resource — group-shared
        ├── reference: Dir Resource (from daemon registry)
        └── reference: Capability Resource subset
```

每个 Session 实例化产出的 Scope 通过 **reference** 互相关联——不是 containment。同一个 User Entity 可以同时是 daemon Scope 的 member 和多个 Group-Chat Scope 的 member。

---

## 九、相关文档

- `docs/notes/concepts.md` — metamodel 定义（必先读）
- `docs/notes/mechanics.md` — ESR 运行 essence：actor model + topology declaration 怎么落地
- `docs/notes/actor-role-vocabulary.md` — role trait 5 类（在新模型下，role trait 是 Session 中 Context 部分选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — 后续重构任务跟踪
