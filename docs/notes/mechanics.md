# ESR 运行 Mechanics — 怎么 implement 一个功能

**Date:** 2026-05-03 (rev 9)
**Audience:** 同 `concepts.md`
**Status:** prescriptive 设计文档；**不**描述当前实现，**不**讨论迁移路径

---

## 这份文档是什么

`concepts.md` 给元模型词汇（5 个概念）。`session.md` 列出 ESR 应有的 Sessions + Entity / Resource declarations。

这份 doc 给**运行机制**——读完知道**新功能落点**：
- 读 ESR 代码时，知道每个模块的角色和它跟其他模块的关系
- 实现新功能时，知道写在哪、连接哪些已有的东西

类比：理解 actor model 的人知道"创建 actor / 处理消息 / 发送消息"三件事就够；理解 agent harness 的人知道"hook → tool → response → hook" loop 就够。这份 doc 给 ESR 的同等级 essence。

---

## 一、ESR 跑起来的样子（4 件事）

### 1. Scope 是 runtime 的有界容器

每个 Scope 是一个 named scope，通过 reference / membership 引用一组 Entity 和 Resource 作为 members。Scope 之间可以 nest（一个 Scope 是另一个 Scope 的 member）。

每个 Scope 由某个 Session（declarative kind+wiring 描述）实例化。Session 描述了"这种 Scope 长什么样、默认有哪些 members、哪些订阅关系"。

### 2. 每个 Entity 是一个 OTP actor

Entity 在运行时表现为一个 OTP GenServer。**理解 actor 三件事就够**：

- **`init(args)`** — actor 启动时怎么准备；返回初始 state
- **`handle_call / handle_cast / handle_info`** — 收到消息时怎么响应；call 是同步请求-应答，cast 是异步通知，info 是非 GenServer 来源的消息（Process.send / pubsub broadcast）
- **`terminate(reason, state)`** — actor 退出时怎么清理（unregister / release resource / 通知邻居）

每个 Entity 实现的 callback 取决于它实现哪些 Interface（trait）。

### 3. 通信通过 Resource，主要是 Channel

Entity 之间互相协调通过 **Channel Resource**，对应 Phoenix.PubSub 的 topic + Phoenix.Channel framework。3 个原语：

- **`subscribe(channel)`** — Entity 加入 Channel 的接收者列表
- **`publish(channel, msg)`** — Entity 把 msg 广播给 Channel 上所有 subscriber
- **`unsubscribe(channel)`** — Entity 离开

也可以 send / call / cast 做 point-to-point（actor pid 直传），但**优先用 Channel 解耦**——这样 sender 不需要知道 receiver 是谁、有几个。

其他 Resource type：
- **Dir** — 共享的 fs namespace，多 reader 自由
- **Capability** — 权限 token，由 CapabilityRegistry 持有 grant 关系；调用前检查

### 4. Topology 是 Session 内部声明的连接关系

每个 Session 的 Topology facet 声明：

- 它实例化的 Scope 默认有哪些 members
- 哪些 member 订阅哪些 Channel
- 哪些 Adapter 收到外部 event 后 publish 到哪个 Channel

**Topology 是 Session 的 wiring 部分**，跟 Context 一起在 Session declaration（code）里表达。具体在 `concepts.md §六` 里的 Session 定义中。

加新功能不用改 Elixir 连接逻辑——改 Session 的 Topology 声明 → startup time 重新 instantiate Scope。

---

## 二、加新功能的落点表

任何 ESR 新功能都落在下面 5 个 metamodel-level bucket 之一（或几个的组合）：

| 落点 | 怎么改 |
|---|---|
| **新 Scope kind** | 写新 Session declaration（含 Context + Topology） |
| **新 Entity type** | 写 Entity declaration；可 compose 现有 Entity（`use Handler` 等） |
| **新 Resource type** | 写 Resource declaration |
| **新 Interface** | 加 Interface declaration（在 `session.md §七`） |
| **修 wiring** | 修现有 Session 的 Topology facet（加 member、加订阅边） |

具体 feature 落到这 5 个 bucket 的**组合**——见 §三 例子。

---

## 三、常见 feature → bucket 组合（FAQ）

### Q：怎么加一个新的 AI agent 类型？

落 **Entity type** + 可能 **修 wiring**：

1. 写 Entity declaration（如 `MyAgent`）：`@behaviour MemberInterface` + `@behaviour AgentInterface`
2. 在 `session.md` 的 Entity declarations 段登记
3. 如果需要它默认在某个 Scope 里，修对应 Session 的 Topology 加成员（修 wiring）

### Q：怎么接入一个新的外部 platform（消息平台）？

落 **Entity type** + **修 wiring**：

1. 写 Adapter Entity declaration：`@behaviour BoundaryInterface`
2. 它持有的 ExternalConnection Resource 实现 `BoundaryConnectionInterface`
3. 修 DaemonSession.Topology：声明 adapter 收到 inbound 后 publish 到哪个 Channel（修 wiring）

### Q：怎么加一个新的 admin slash command？

落 **Entity type** + **修 wiring**：

1. 写一个 Handler-composing Entity（`use Handler` + `@behaviour SlashParseInterface`），实现 slash text → (kind, args) 解析
2. 修 AdminSession.Topology：声明这个新 Entity 默认是 admin Scope 的 member，订阅 SlashRouteRegistry（修 wiring）

注意：**没有"slash-route 加一行配置"这个独立 bucket**——slash-route 配置就是 AdminSession.Topology 中"哪些 Entity 处理哪些 kind"的 wiring，修配置等于"修 wiring"落点。

### Q：怎么让现有 Scope 发送一种新事件？

落 **新 Interface**：

1. 加新 Interface declaration（如 `MentionInterface`）
2. 给已有 Entity 加 `@behaviour MentionInterface` + 实现 callback
3. 完成

不需要改 Scope 自己的代码——Scope 是 dumb container，行为在 members 上。

### Q：怎么加一个新的 Scope 类别（如 voice-chat scope）？

落 **新 Scope kind**：

1. 写新 Session declaration（如 `VoiceChatSession`）
2. Context: 声明实现的 Interface（如 VoiceLifecycleInterface）
3. Topology: 默认 members + 订阅关系（如 1 个 voice-channel + 默认成员 = 实现 VoiceMemberInterface 的 Entity）

如果 voice-chat 需要新的 Resource type（如 AudioStream），那是额外的 **新 Resource type** 落点。

### Q：怎么调试一个 inbound message 没到位？

trace 顺序：

1. **Adapter** 是不是收到了？看 Adapter Entity 的 log
2. **publish 到 Channel** 了吗？看 Channel 的 publish log
3. **subscriber 收到了吗？** 看 subscriber Entity 的 `handle_info` log
4. **subscription 注册了吗？** 看 Session Topology 声明 + 运行时 registry

每一步都对应明确的代码模块，不需要"猜 pipeline"。

---

## 四、Trace 一个完整 message：从外部 inbound 到外部 outbound

```
[User 发消息到 Group-Chat]
  ↓
1. Adapter Entity（实现 BoundaryInterface）从外部协议收到 envelope
  ↓
2. Adapter 翻译成 ESR envelope → publish 到 routing-channel
  ↓
3. routing-channel 的 subscriber（Daemon Scope 里的 routing entity）lookup target Scope
  ↓
4. 路由 entity 把 envelope publish 到 target Scope 的 group-channel
  ↓
5. group-channel subscribers（多 user + 多 agent + 共享 Resource）各自 handle_info
  ↓
6. 某 agent Entity 的 handle_info 触发它实现的 MemberInterface.handle_mention
  ↓
7. agent 内部用它的 sub-graph 处理（zoom in：agent 是 Scope，里面有 sub-Entities + sub-Resources）
  ↓
8. agent 通过 group-channel publish reply
  ↓
9. group-channel fan_out 给 subscribers
  ↓
10. Adapter Entity（同 1，但 outbound 路径）收到 → 翻译成外部协议 → 发送
```

整个 flow **没有 pipeline orchestrator**——每一步都是一个 actor 收到一个 message 然后 publish 给下一步。actor 之间通过 Channel 解耦。"顺序"emerges from Topology subscription 关系，不是 explicit ordering。

---

## 五、相关文档

- `docs/notes/concepts.md` — metamodel 定义（必先读）
- `docs/notes/session.md` — Session catalog + Entity / Resource declarations
- `docs/notes/actor-role-vocabulary.md` — role trait 5 类（在新模型下，role trait 是 Session 中 Context 部分选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — 后续重构任务跟踪
