# ESR Views — 目标态设计

**Date:** 2026-05-03 (P1-2)
**Audience:** 同 `concepts.md`
**Status:** prescriptive 设计文档；**不**描述当前实现，**不**讨论迁移路径

---

## 这份文档是什么

`concepts.md` 定义了元模型（4 primitive + Template + View）。这份 doc 在元模型之上**枚举 ESR 应有的 View**——即 ESR 在目标态下需要存在哪些 Template / View，每个 View 内部包含什么 Entity / Resource / Interface 组合。

读它的目标：

- 设计新功能时，确认它属于哪个 View，或者是否需要新增 View
- 写 spec 时，引用本文档中 View 名字
- 重构时，把代码模块对应到本文档登记的 Template / View

本文档**不**讨论：今天的代码长什么样、谁要改名、如何从现状迁移——这些是后续重构计划的内容。

---

## 一、View 一览表

| View 名字 | 由谁产出 | 主要 primitive flavor | 实例数 |
|---|---|---|---|
| **Daemon Session** | DaemonTemplate | Session | 1（每个 esrd 实例 1 份）|
| **Admin Session** | AdminTemplate | Session | 1（daemon 内嵌 1 份） |
| **Group-Chat Session** | GroupChatTemplate | Session | N（每个群 1 份） |
| **User** | UserTemplate | Entity | N（每个人 1 份） |
| **Agent** | AgentTemplate | Entity | N（每个 AI 实例 1 份） |
| **Adapter** | AdapterTemplate | Entity (boundary) | N（每个外部接入 1 份） |
| **Handler** | HandlerTemplate | Entity (pipeline) | N（每种 event 处理逻辑 1 份） |
| **Channel** | ChannelTemplate | Resource | N（每个消息流 1 份） |
| **Dir** | DirTemplate | Resource | N（每个文件空间 1 份） |
| **Capability** | CapabilityTemplate | Resource | N（每条权限 1 份） |

**说明**：

- Daemon / Admin / Group-Chat 都是 Session（按 metamodel，`concepts.md §一`），命名是 informal 区分用途
- User / Agent / Adapter / Handler 都是 Entity；区分在于 implements 哪些 Interface
- Channel / Dir / Capability 都是 Resource；区分在于 implements 哪些 Interface

---

## 二、Daemon Session View

**Template**: DaemonTemplate（singleton）

**职责**：ESR 进程级 root scope。所有其他 View 都是它的 member 或 nested Session。

**成员（members）**：

- 1 Admin Session（嵌套）
- N Group-Chat Sessions（嵌套）
- N User Entity（注册的所有人类）
- N Agent Entity (declared)（声明的所有 AI 类型）
- N Adapter Entity（连接外部世界的所有 instance）
- M Capability Resource（daemon-tier 权限）

**Interface contracts implemented**：

- `BootInterface` — 启动 / 关闭 / 健康检查
- `RegistryInterface` — Entity / Resource 注册表（lookup by name / id）
- `RoutingInterface` — 把 inbound 路由到正确的 Session

---

## 三、Admin Session View

**Template**: AdminTemplate

**职责**：管理员 / 操作员动作的 scope。所有 daemon-level 操作（创建 Session、grant capability、注册 Adapter 等）在这里执行。

**成员**：

- 1 Dispatcher Entity（控制类，处理 admin queue 上的 operation）
- 1 SlashCommandHandler Entity（解析 user-facing slash command 到 operation）
- 1 Admin-Queue Resource（fs-based job queue，承载 pending operation）
- 1 SlashRouteRegistry Resource（slash → kind → command_module 的映射）
- 1 CapabilityRegistry Resource（cap 声明 + grant 表）

**Interface contracts**：

- `OperationInterface` — Dispatcher 实现：enqueue / execute / report
- `SlashParseInterface` — SlashCommandHandler 实现
- `JobQueueInterface` — Admin-Queue 实现
- `RegistryInterface` — SlashRouteRegistry / CapabilityRegistry 实现

---

## 四、Group-Chat Session View

**Template**: GroupChatTemplate

**职责**：ESR 最 canonical 的 Session 形态。是 metamodel `concepts.md §九` 描述的群聊 Session。

**成员**（典型组成）：

- N User Entity（人类参与者）
- M Agent Entity（AI 参与者）
- 1 或多个 Channel Resource（群级消息流，可能分子群）
- 0..N Dir Resource（共享代码空间 / 文档空间）
- M Capability Resource（session-level 权限子集）

**Interface contracts**：

- `MemberInterface` — 所有 Entity 成员（user 和 agent）实现：mention / reply / leave / join
- `ChannelInterface` — 所有 Channel Resource 实现：publish / subscribe / frame
- `SessionLifecycleInterface` — Session 自身实现：start / pause / archive / resume

**Lifecycle**：

- 由 Admin 通过 `session.create` operation 创建
- 进入 active 状态后接受 inbound 消息 → 触发成员 callback
- 可被 Admin pause / archive；archived Session 保留状态但不接收新消息
- 解散时，shared Resource 引用计数减一；非共享的随 Session 一起销毁

---

## 五、User View

**Template**: UserTemplate

**职责**：人类参与者的实体身份。跨多个 Session 持久存在。

**成员**：

- 1 Identity record（username / email / phone / 外部平台 binding 列表）
- N Capability granted（这个 user 拥有的权限）

**Interface contracts**：

- `MemberInterface` — 当 User 成为 Session member 时
- `IdentityInterface` — username 唯一性、外部平台 ID 解析

**关系**：

- 一个 User Entity 实例独立存在于 daemon 注册表
- 同一个 User 可以同时是多个 Group-Chat Session 的 member
- 同一个 User 可以拥有多个外部平台 binding（Feishu / Slack / 等）

---

## 六、Agent View

**Template**: AgentTemplate

**职责**：AI 参与者。Session 中跟 User 平等的成员。

**Agent 是有内部 Session 结构的**——zoom in 之后自身是一个 Session，包含它的 internal sub-Entities + sub-Resources（参考 `concepts.md §八` 的递归说明）。

**外部成员**（从 outer Session 视角看）：

- 1 Agent Entity 实例

**内部成员**（agent zoom in 之后）：

- 1 或多个 internal proxy Entity（控制 agent 内部 pipeline）
- 1 internal Channel Resource（agent 跟它的"外部 AI service"通信的管道）
- 0..N internal Dir Resource（agent 内部 working state）
- 0..N internal Capability Resource

**Interface contracts**：

- `MemberInterface` — 在 outer Session 中作为 member
- `AgentInterface` — 处理 mention / reply 的 AI-specific 接口（如 think / plan / act）
- 内部 sub-graph 的 Interface 由 internal proxies 实现

**关系**：

- 一个 Agent Entity 通常 1:1 绑定 outer Session（实例化时为某个 Session 创建一份）
- 但 agent **type** 可以有多个实例，分散在多个 Session
- 未来可能允许一个 agent 实例 join 多个 Session（类似 user）——metamodel 不阻止

---

## 七、Adapter View

**Template**: AdapterTemplate

**职责**：跟外部系统（消息平台、API、外部服务）的桥梁。把外部协议翻译成 ESR 内部 envelope。

**成员**：

- 1 Adapter Entity（实现 boundary trait）
- 1 ExternalConnection Resource（实现 BoundaryConnectionInterface；如 WS / HTTP keep-alive）
- 0..N Capability（adapter 实例需要的权限）

**Interface contracts**：

- `BoundaryInterface` — adapter 实现：inbound 翻译、outbound 翻译
- `BoundaryConnectionInterface` — ExternalConnection 实现：connect / reconnect / disconnect

**关系**：

- 一个 adapter type（如 "Feishu adapter type"）可以有多个 instance（每个外部 app 一份）
- 多个 instance 共享同一份代码，但各自有独立 ExternalConnection 和独立 capability
- adapter instances 通常 daemon-tier 注册，跨 Group-Chat Session 共享

---

## 八、Handler View

**Template**: HandlerTemplate

**职责**：纯函数事件处理逻辑。接收某 actor_type 的 event，输出 (new_state, [actions])。

**成员**：

- 1 Handler Entity（实现 pipeline trait + purity 约束）
- 0 内部 Resource（handler 是无状态的，state 由 SDK 外部托管）

**Interface contracts**：

- `EventHandlerInterface` — 接收 event → 返回 (state, [actions])
- `PurityInterface` — 声明只 import `esr` SDK + 自己的 package（编译期检查）

**关系**：

- handler 实例是 invocation-临时的（跑完即结束）
- 一个 handler 处理一种 actor_type（一个 actor_type 对应一个 handler 模块）
- handler 不持有跨 invocation 状态，state 由 SDK 在外部 Resource（如 ETS 或文件）持久化

---

## 九、Channel View

**Template**: ChannelTemplate（或者直接 Resource，无 Template）

**职责**：两个或多个 Entity 之间的消息流。

**成员**：

- 1 Channel Resource
- N Subscription record（哪些 Entity 订阅了这个 channel）

**Interface contracts**：

- `ChannelInterface` — publish / subscribe / unsubscribe / frame

**Lifecycle 选项**（由具体 Channel 实例决定）：

- **Ephemeral**：与某个 Session 同生死
- **Persistent**：跨 Session 长期存在（A2 解耦 channel 实现这个）
- **Shared**：被多个 Session reference

---

## 十、Dir View

**Template**: DirTemplate（或者直接 Resource）

**职责**：命名的文件系统空间。

**成员**：

- 1 Dir Resource
- 关联 path（OS-level fs path）

**Interface contracts**：

- `DirInterface` — read / write / list / mkdir / rmdir

**关系**：

- 一个 Dir Resource 通常跨 Session 共享（如同一个 git repo 被多个 Session 同时引用）
- 没有 ownership 约束（多 reader 自由）；写冲突由外部协调（如 git 的 worktree）

---

## 十一、Capability View

**Template**: CapabilityTemplate

**职责**：符号性权限 token + 授权关系。

**成员**：

- 1 Capability declaration（cap 名字 + scope + 描述）
- N Grant record（哪些 User / Agent 持有这个 cap）

**Interface contracts**：

- `CapabilityDeclarationInterface` — cap 自身：name / description / required-for
- `GrantInterface` — 授权关系：grant / revoke / check

**两态**：

- **Declarative**：cap 在代码 / yaml 里声明（跟 SlashRoute 一起）
- **Granted**：grant 关系存于 Grant Registry（admin Session 的成员）

---

## 十二、Common Interfaces 总表

为方便查询，列出本文档中提到的所有 Interface（不重复定义，仅汇总）：

### Session-level

- `SessionLifecycleInterface` — start / pause / archive / resume
- `MemberInterface` — mention / reply / leave / join

### Resource-flavor

- `ChannelInterface` — publish / subscribe / frame
- `DirInterface` — read / write / list
- `CapabilityDeclarationInterface` / `GrantInterface`

### Entity-flavor

- `IdentityInterface` — username / external-id mapping
- `AgentInterface` — think / plan / act（AI-specific）
- `BoundaryInterface` — inbound / outbound 翻译
- `BoundaryConnectionInterface` — connect / reconnect
- `EventHandlerInterface` / `PurityInterface`

### Cross-cutting

- `OperationInterface` — enqueue / execute / report
- `JobQueueInterface` — admin queue 等
- `RegistryInterface` — lookup / register / unregister
- `RoutingInterface` — route inbound to Session
- `BootInterface` — daemon 启停

### Admin-flavor

- `SlashParseInterface` — slash command 解析

---

## 十三、Cross-View 关系示意

```
Daemon Session (1)
├── Admin Session (1)
│   ├── Dispatcher Entity
│   ├── SlashCommandHandler Entity
│   ├── Admin-Queue Resource
│   ├── SlashRouteRegistry Resource
│   └── CapabilityRegistry Resource
│
├── Adapter Entities (N) — 跨 Group-Chat Session 共享
│
├── User Entities (N) — 跨 Group-Chat Session 共享
│
├── Capability Resources (N) — 跨 Session 共享
│
└── Group-Chat Sessions (N)
    ├── User Entities (referenced from daemon registry)
    ├── Agent Entities (typically per-session instances)
    │   └── (zoom in: agent's internal Session sub-graph)
    ├── Channel Resource
    ├── Dir Resource (referenced from daemon registry)
    └── Capability Resource (referenced from daemon registry)
```

每个 View 通过 **reference** 互相关联——不是 containment。同一个 User Entity 可以同时是 daemon 的 member 和多个 Group-Chat Session 的 member；同一个 Dir 可以被多 Session 共享。

---

## 十四、相关文档

- `docs/notes/concepts.md` — metamodel 定义（必先读）
- `docs/notes/actor-role-vocabulary.md` — role trait 5 类（在新模型下，role trait 是 Template 选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — 后续重构任务跟踪
