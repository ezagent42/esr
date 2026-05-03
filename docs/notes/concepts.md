# ESR 概念词汇 — Tetrad Metamodel

**Date:** 2026-05-03 (P1-1 brainstorm, rev 7)
**Audience:** 任何在 ESR 仓库读代码、写 spec、讨论架构的人——人类或 AI
**Status:** prescriptive；本文档定义元模型，不讨论现状偏差

---

## 这份文档为什么存在

这份 doc 给一套**最小、自相似的元模型 (metamodel)**，是 ESR 所有概念的源头规则。

用法：

- 写新模块 / 新 yaml entry 时，先确认要表达的概念在 metamodel 里是什么 primitive、由哪个 Session 产出
- review PR 时，对 noun 的理解不同就回到本文档对齐
- 写 spec 时，**只**用 metamodel 词汇 + `session.md` 里登记的具体 Session 名字

**本文档不出现实现专有名词**（具体 agent 类型、外部平台名、私有缩写等都不出现）。具体实例化登记在伴随文档 `session.md`。实现层面的偏差由重构计划单独处理。

---

## 一、TL;DR

ESR 的所有运行时活动用一句话描述：

> **Scope 通过 membership 引用 Entities 和 Resources；Interface 是 Entity / Resource 实现的契约；Session 是 Scope 的 declarative 描述（kind + 默认 wiring）。**

**4 runtime primitive**：

- **Scope** — 有界场域；用 membership 引用 Entity 和 Resource。runtime 的 instance
- **Entity** — 行动者 / 主语；有 identity，使用 Resource 发起动作
- **Resource** — 资源 / 宾语；被 Entity 使用，有限可数
- **Interface** — 契约 / trait；被 Entity 和 Resource 实现

**1 declarative primitive**：

- **Session** — 一个 Scope 的 kind + default wiring 描述。可分解为两个 facet：
  - **Context** — kind 部分（"什么 kind 的 Scope，实现哪些 Interface"）
  - **Topology** — wiring 部分（"默认有哪些 members，订阅哪些 Channel"）

`use SomeSession` 之后，得到一个具体的 Scope 实例。

**完美对称**：3 个 noun primitive（Scope / Entity / Resource）都是单一 primitive，没有 metamodel-level subtype；变化都通过实现哪些 Interface 来表达。

四个 runtime primitive 是**自相似的**：每一个 Entity 实例，zoom in 之后自身又是一个 Scope（持有它内部的子图）。

---

## 二、Scope — 有界场域

**定义**：一个有界 scope。runtime 的 instance。通过 **reference / membership** 引用一组 Entity 和 Resource，构成这个 scope 内部的活动空间。

Scope 之间通过 **reference** 关联——一个 Scope 的 membership 列表可以包含其他 Scope（嵌套），也可以共享同一个 Entity 或 Resource。

**例子**：

- 一个**群聊 Scope**：references `user-alice`, `user-bob`, `agent-α`, `agent-β`, `channel-shared`, `dir-repo`
- 一个**daemon-level Scope**：references `admin Scope`, 多个 active group-chat Scopes, daemon-tier capabilities
- 一个**admin Scope**：references admin-flavor entities, admin queue resource

每个 Scope 都是某个 Session 的实例化（类比 OOP：Scope 是 instance，Session 是 class）。

---

## 三、Entity — 行动者

**定义**：有 identity 的 actor。实现一组 Interface，使用 Resource，发起动作。**独立存在**——同一个 Entity 可以被多个 Scope 引用。

**例子**：

- `user-alice`（人类）：注册一份在 daemon-level Entity registry，参与多个 group-chat Scope
- `agent-cc-7`（AI）：声明一份，作为 member 加入 Scope
- `dispatcher`：admin Scope 的成员，处理 admin queue 上的 operation

---

## 四、Resource — 资源

**定义**：被 Entity 使用的对象。有限、可计数、可被占有 / 转让 / 释放。

Resource 是单一 primitive，**没有 metamodel-level subtype**。不同 Resource 通过实现不同 Interface 表现差异——这跟 Scope / Entity 的处理方式完全对称。

**常见命名约定**（informal，由 Interface 实现决定，不是 metamodel-level type）：

- **Channel** — 一个实现"双向消息流"Interface 的 Resource。lifecycle 通常 ephemeral
- **Dir** — 一个实现"文件系统命名空间"Interface 的 Resource。lifecycle 通常 persistent
- **Capability** — 一个实现"符号权限 + grant binding"Interface 的 Resource。两态：声明 + 授权

允许 hybrid：理论上一个 Resource 可以同时实现 Channel-Interface 和 Dir-Interface（消息流 backed by 持久化文件），metamodel 不阻止。

**例子**：

- `channel-shared-c1`：实现 Channel-Interface 的 Resource，群聊 Scope 的共享消息流
- `dir-/repo/main`：实现 Dir-Interface 的 Resource，被多个 Scope 同时 reference
- `capability "scope.create"`：实现 Capability-Interface 的 Resource，granted 给 user-alice

---

## 五、Interface — 契约（trait）

**定义**：被 Entity 或 Resource **实现**的契约，规定一组 callback 或 message shape。

**关键性质**：

- **Nominal**：通过 `@behaviour SomeTrait` 显式 declare（不靠 structural matching）
- **声明期存在**：在编译期 / 模块加载期解析；运行时 Interface 表现为附在 Entity / Resource 上的 trait 标签
- **派生投影**：查询"实现了 Interface X 的所有 actor"是 runtime registry filter，不需要顶层 noun 来命名

**例子**：

- `MemberInterface`：所有 Scope 成员实现，要求支持 mention / reply / leave 等
- `ChannelInterface`：实现 Channel 语义的 Resource 实现，要求支持 publish / subscribe / frame
- `OperationInterface`：admin Scope 里 dispatchable 单元实现，要求支持 enqueue / execute / report

---

## 六、Session — declarative kind + wiring

**定义**：一个 Scope 的 declarative 描述。包含两个 facet：

- **Context**：kind declaration（"这是什么 kind 的 Scope，必须实现哪些 Interface"）
- **Topology**：wiring declaration（"默认有哪些 members；哪些 Entity 订阅哪些 Channel；哪些 Resource 被自动 attached"）

`use SomeSession` 之后，runtime instantiate 出一个具体 Scope 实例。

Session **跟 4 个 runtime primitive 平行**——是 metamodel 的 declarative 维度。

**Session 可组合**：`use SessionA; use SessionB` 在同一个模块上叠加；composition 在 Context（trait 集合并集）和 Topology（wiring 集合并集）两层各自独立合并。前提：trait callback 不冲突，wiring edge 不矛盾。

**例子**（具体 Session 名字在 `session.md`）：

- `GroupChatSession` declares：a Scope of kind "group-chat" + 默认有一个 shared channel + 所有 member 自动订阅这个 channel
- `AdminSession` declares：a Scope of kind "admin" + 默认有 dispatcher entity + admin queue resource

---

## 七、Entity / Resource declarations（不需要 Session wrapper）

注意：**Entity 和 Resource 不需要 Session 包**——它们的 declaration 就是普通的 module declaration（带 `@behaviour` 实现 Interface）。

只有 **Scope** 这个 primitive 需要 Session（kind + wiring）描述，因为 Scope 本身就是包含 members 的复合结构，它的 default 状态需要描述。

Entity 的 declaration 例子：

```
defmodule UserEntity do
  @behaviour MemberInterface
  @behaviour IdentityInterface
  ...
end
```

Resource 同理。这些 declaration 在 `session.md` 里也登记，但不叫"Session"——叫 Entity type / Resource type。

---

## 八、自相似 / 递归（graph 形式）

任意 zoom level 上看到的都是同一种结构：

```
{ Scopes }       { Entities }       { Resources }
       ↑                   ↑                  ↑
       └────── reference / membership ────────┘

Interface 是 trait，被 E 和 R 实现（不出现在 graph node 里）
```

**关键不同于 OOP containment**：

- E 和 R **独立存在**于 daemon-level registry
- Scope 通过 **reference / membership** 引用 E 和 R
- 同一个 E 可以被多个 Scope reference（一个 user 同时在多个 group-chat）
- 同一个 R 可以被多个 Scope 共享（一个 dir 被多 Scope 共用）

**递归**：任意 Entity 实例 **zoom in** 之后，自身又是一个 Scope（有自己的内部 sub-graph）。例如一个 agent，从外层 Scope 视角看是一个 Entity 成员；从 agent 内部视角看，agent 自己是一个 Scope，里面有它的 internal sub-Entities + sub-Resources。

**例子**：

```
ESR 顶层 (一个 Scope，由 DaemonSession 实例化)
├── members: [admin Scope, group-chat-1 Scope, group-chat-2 Scope, ...]

group-chat-1 (一个 Entity from 顶层视角；自身是一个 Scope，由 GroupChatSession 实例化)
├── members: [user-alice, user-bob, agent-cc-α, channel-shared, dir-repo]

agent-cc-α (一个 Entity from group-chat 视角；自身是一个 Scope)
├── members: [agent's internal sub-modules, agent's internal channel-bus, ...]
```

每一层都是同一种 (Scope, Entity, Resource) parallel 图结构 + Interface trait declaration。

---

## 九、群聊 Scope 作为典型例子

群聊是 ESR 中**最 canonical 的 Scope 形态**：多个 human + 多个 agent + 共享 Resource。由 GroupChatSession 实例化。

```
group-chat-scope "team-room"  (instance of GroupChatSession)
├── Entities (members):
│   ├── user-alice           (人类)
│   ├── user-bob             (人类)
│   ├── agent-cc-α           (AI)
│   └── agent-codex-β        (AI，未来)
├── Resources (members):
│   ├── channel-shared       (实现 ChannelInterface)
│   ├── dir-/repo/main       (实现 DirInterface)
│   └── capability subset    (实现 CapabilityInterface)
└── Interface contracts implemented by members:
    ├── MemberInterface       (所有 Entity 成员实现)
    ├── ChannelInterface      (channel-shared 实现)
    └── ...
```

**动作示例**——`user-alice` 发一条消息 `@agent-cc-α 帮我看下 main.py`：

1. `user-alice`（Entity）通过 `MemberInterface.send_message` 把消息投到 `channel-shared`（Resource）
2. `channel-shared` 通过 `ChannelInterface.fan_out` 通知所有 subscribed 成员
3. `agent-cc-α`（Entity）通过 `MemberInterface.handle_mention` 收到针对它的 mention
4. `agent-cc-α` 用它的 internal sub-graph（zoom in 之后是一个 Scope）处理这条消息
5. agent 通过 `channel-shared` 发回 reply

整个过程不需要 Scope 知道 agent 内部怎么工作——agent 是一个 Entity，从外层 Scope 视角是黑盒；只要 agent 实现 MemberInterface 的契约，Scope 就能跟它平等对话。

这就是 metamodel 在运行时的具象化：**在 Scope 里，Entities 通过 Interface 用 Resources 互动**。

---

## 十、命名学约定

- **概念名 == 代码模块名**。`Esr.Scopes.GroupChat`, `Esr.Entities.User`, `Esr.Resources.Channel`, `Esr.Sessions.GroupChat` 等。
- **跨语言**：Python / Elixir 共享同一组 primitive 命名（`esr.Scopes`, `esr.Entities`, ...）
- **describing concrete actors**：用 4-tuple + Session 来描述。例如：
  > "Dispatcher 是一个 Entity，admin Scope 的 member（由 AdminSession 实例化），使用 admin queue Resource，实现 OperationInterface。"

如果一个 noun 不在本文档里，**它就不在 metamodel 里**。要新加一个，先 propose 它属于哪个 primitive / 由哪个 Session 实例化，doc 同步更新。

---

## 十一、相关文档

- `docs/notes/session.md` — ESR 中每个 Session 的 catalog；以及 Entity / Resource declarations 列表
- `docs/notes/mechanics.md` — ESR 运行 essence：actor model + topology 怎么落地（4 件事，加新功能的落点）
- `docs/notes/actor-role-vocabulary.md` — role trait 的详细定义（在本 metamodel 下，role trait 是 Session 中 Context 部分选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — P2/P3 任务列表
