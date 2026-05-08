# ESR 概念词汇 — Tetrad Metamodel

**Date:** 2026-05-08 (Realm/Session swap, rev 10; P1-1 brainstorm baseline rev 9 from 2026-05-03)
**Audience:** 任何在 ESR 仓库读代码、写 spec、讨论架构的人——人类或 AI
**Status:** prescriptive；本文档定义元模型，不讨论现状偏差

---

## rev 10 改动摘要

把"Session = class、Scope = instance"对调成"**Realm = class、Session = instance**"。理由：操作员说 `/session:new` 直觉是"创建实例"——是 instance 语感；把 Session 安排到 instance 槽位、引入新词 Realm 占据 class 槽位（"Realm of admin operations" 读作 kind/category 自然），让 code 词汇和 operator 词汇都对齐到 instance。"Scope" 在 runtime 角色被 Session 取代；"Realm" 是新词，替代以前 Session 在 declarative 角色的位置。

实施：本 PR 只改本文档；后续的 cleanup PR 才搬代码（`Esr.Scope.* → Esr.Session.*` 等）。spec `2026-05-08-resource-typed-grammar.md` rev-3 §0 有完整背景。

---

## 这份文档为什么存在

这份 doc 给一套**最小、自相似的元模型 (metamodel)**，是 ESR 所有概念的源头规则。

用法：

- 写新模块时，先确认要表达的概念在 metamodel 里是什么 primitive、由哪个 Realm 产出
- review PR 时，对 noun 的理解不同就回到本文档对齐
- 写 spec 时，**只**用 metamodel 词汇 + `session.md` 里登记的具体 Realm 名字

**本文档不出现实现专有名词**（具体 agent 类型、外部平台名、私有缩写等都不出现）。具体实例化登记在伴随文档 `session.md`（文件名是 rev 9 时代的遗留；按 rev 10 该叫 `realm.md`，但本 PR 不动文件名，留作后续 doc 整理）。实现层面的偏差由重构计划单独处理。

---

## 一、TL;DR

ESR 的所有运行时活动用一句话描述：

> **Session 通过 membership 引用 Entities 和 Resources；Interface 是 Entity / Resource 实现的契约；Realm 是 Session 的 declarative 描述（kind + 默认 wiring）。**

**4 runtime primitive**：

- **Session** — 有界场域；用 membership 引用 Entity 和 Resource。runtime 的 instance
- **Entity** — 行动者 / 主语；有 identity，使用 Resource 发起动作
- **Resource** — 资源 / 宾语；被 Entity 使用，有限可数
- **Interface** — 契约 / trait；被 Entity 和 Resource 实现

**1 declarative primitive**：

- **Realm** — 一个 Session 的 kind + default wiring 描述。可分解为两个 facet：
  - **Context** — kind 部分（"什么 kind 的 Session，实现哪些 Interface"）
  - **Topology** — wiring 部分（"默认有哪些 members，订阅哪些 Channel"）

`use SomeRealm` 之后，得到一个具体的 Session 实例。

**完美对称**：3 个 noun primitive（Session / Entity / Resource）都是单一 primitive，没有 metamodel-level subtype；变化都通过实现哪些 Interface 来表达。

四个 runtime primitive 是**自相似的**：每一个 Entity 实例，zoom in 之后自身又是一个 Session（持有它内部的子图）。

---

## 二、Session — 有界场域

**定义**：一个有界场域。runtime 的 instance。通过 **reference / membership** 引用一组 Entity 和 Resource，构成这个场域内部的活动空间。

Session 之间通过 **reference** 关联——一个 Session 的 membership 列表可以包含其他 Session（嵌套），也可以共享同一个 Entity 或 Resource。

**例子**：

- 一个**群聊 Session**：references `user-alice`, `user-bob`, `agent-α`, `agent-β`, `channel-shared`, `dir-repo`
- 一个**daemon-level Session**：references `admin Session`, 多个 active group-chat Sessions, daemon-tier capabilities
- 一个**admin Session**：references admin-flavor entities, admin queue resource

每个 Session 都是某个 Realm 的实例化（类比 OOP：**Session 是 instance，Realm 是 class**）。

---

## 三、Entity — 行动者

**定义**：有 identity 的 actor。实现一组 Interface，使用 Resource，发起动作。**独立存在**——同一个 Entity 可以被多个 Session 引用。

**例子**：

- `user-alice`（人类）：注册一份在 daemon-level Entity registry，参与多个 group-chat Session
- `agent-cc-7`（AI）：声明一份，作为 member 加入 Session
- `dispatcher`：admin Session 的成员，处理 admin queue 上的 operation

---

## 四、Resource — 资源

**定义**：被 Entity 使用的对象。有限、可计数、可被占有 / 转让 / 释放。

**常见命名约定**（informal，由实现哪些 Interface 决定）：

- **Channel** — 一个实现"双向消息流"Interface 的 Resource。lifecycle 通常 ephemeral
- **Dir** — 一个实现"文件系统命名空间"Interface 的 Resource。lifecycle 通常 persistent
- **Capability** — 一个实现"符号权限 + grant binding"Interface 的 Resource。两态：声明 + 授权

允许 hybrid：理论上一个 Resource 可以同时实现 Channel-Interface 和 Dir-Interface（消息流 backed by 持久化文件），metamodel 不阻止。

**例子**：

- `channel-shared-c1`：实现 Channel-Interface 的 Resource，群聊 Session 的共享消息流
- `dir-/repo/main`：实现 Dir-Interface 的 Resource，被多个 Session 同时 reference
- `capability "session.create"`：实现 Capability-Interface 的 Resource，granted 给 user-alice

---

## 五、Interface — 契约（trait）

**定义**：被 Entity 或 Resource **实现**的契约，规定一组 callback 或 message shape。

**关键性质**：

- **Nominal**：通过 `@behaviour SomeTrait` 显式 declare（不靠 structural matching）
- **声明期存在**：在编译期 / 模块加载期解析；运行时 Interface 表现为附在 Entity / Resource 上的 trait 标签
- **派生投影**：查询"实现了 Interface X 的所有 actor"是 runtime registry filter，不需要顶层 noun 来命名

**例子**：

- `MemberInterface`：所有 Session 成员实现，要求支持 mention / reply / leave 等
- `ChannelInterface`：实现 Channel 语义的 Resource 实现，要求支持 publish / subscribe / frame
- `OperationInterface`：admin Session 里 dispatchable 单元实现，要求支持 enqueue / execute / report

---

## 六、Realm — declarative kind + wiring

**定义**：一个 Session 的 declarative 描述。包含两个 facet：

- **Context**：kind declaration（"这是什么 kind 的 Session，必须实现哪些 Interface"）
- **Topology**：wiring declaration（"默认有哪些 members；哪些 Entity 订阅哪些 Channel；哪些 Resource 被自动 attached"）

`use SomeRealm` 之后，runtime instantiate 出一个具体 Session 实例。

Realm **跟 4 个 runtime primitive 平行**——是 metamodel 的 declarative 维度。

**Realm 可组合**：`use RealmA; use RealmB` 在同一个模块上叠加；composition 在 Context（trait 集合并集）和 Topology（wiring 集合并集）两层各自独立合并。前提：trait callback 不冲突，wiring edge 不矛盾。

**例子**（具体 Realm 名字在 `session.md`，文件名沿用 rev 9 命名）：

- `GroupChatRealm` declares：a Session of kind "group-chat" + 默认有一个 shared channel + 所有 member 自动订阅这个 channel
- `AdminRealm` declares：a Session of kind "admin" + 默认有 dispatcher entity + admin queue resource

---

## 七、Entity / Resource declarations（不需要 Realm wrapper）

注意：**Entity 和 Resource 不需要 Realm 包**——它们的 declaration 就是普通的 module declaration（带 `@behaviour` 实现 Interface）。

只有 **Session** 这个 primitive 需要 Realm（kind + wiring）描述，因为 Session 本身就是包含 members 的复合结构，它的 default 状态需要描述。

Entity 的 declaration 例子：

```
defmodule UserEntity do
  @behaviour MemberInterface
  @behaviour IdentityInterface
  ...
end
```

Resource 同理。这些 declaration 在 `session.md` 里也登记，但不叫"Realm"——叫 Entity type / Resource type。

---

## 八、自相似 / 递归（graph 形式）

任意 zoom level 上看到的都是同一种结构：

```
{ Sessions }     { Entities }       { Resources }
       ↑                   ↑                  ↑
       └────── reference / membership ────────┘

Interface 是 trait，被 E 和 R 实现（不出现在 graph node 里）
```

**关键不同于 OOP containment**：

- E 和 R **独立存在**于 daemon-level registry
- Session 通过 **reference / membership** 引用 E 和 R
- 同一个 E 可以被多个 Session reference（一个 user 同时在多个 group-chat）
- 同一个 R 可以被多个 Session 共享（一个 dir 被多 Session 共用）

**递归**：任意 Entity 实例 **zoom in** 之后，自身又是一个 Session（有自己的内部 sub-graph）。例如一个 agent，从外层 Session 视角看是一个 Entity 成员；从 agent 内部视角看，agent 自己是一个 Session，里面有它的 internal sub-Entities + sub-Resources。

**例子**：

```
ESR 顶层 (一个 Session，由 DaemonRealm 实例化)
├── members: [admin Session, group-chat-1 Session, group-chat-2 Session, ...]

group-chat-1 (一个 Entity from 顶层视角；自身是一个 Session，由 GroupChatRealm 实例化)
├── members: [user-alice, user-bob, agent-cc-α, channel-shared, dir-repo]

agent-cc-α (一个 Entity from group-chat 视角；自身是一个 Session)
├── members: [agent's internal sub-modules, agent's internal channel-bus, ...]
```

每一层都是同一种 (Session, Entity, Resource) parallel 图结构 + Interface trait declaration。

---

## 九、群聊 Session 作为典型例子

群聊是 ESR 中**最 canonical 的 Session 形态**：多个 human + 多个 agent + 共享 Resource。由 GroupChatRealm 实例化。

```
group-chat-session "team-room"  (instance of GroupChatRealm)
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
4. `agent-cc-α` 用它的 internal sub-graph（zoom in 之后是一个 Session）处理这条消息
5. agent 通过 `channel-shared` 发回 reply

整个过程不需要 Session 知道 agent 内部怎么工作——agent 是一个 Entity，从外层 Session 视角是黑盒；只要 agent 实现 MemberInterface 的契约，Session 就能跟它平等对话。

这就是 metamodel 在运行时的具象化：**在 Session 里，Entities 通过 Interface 用 Resources 互动**。

---

## 十、命名学约定

- **概念名 == 代码模块名**。`Esr.Sessions.GroupChat`, `Esr.Entities.User`, `Esr.Resources.Channel`, `Esr.Realms.GroupChat` 等。
- **跨语言**：Python / Elixir 共享同一组 primitive 命名（`esr.Sessions`, `esr.Entities`, ...）
- **describing concrete actors**：用 4-tuple + Realm 来描述。例如：
  > "Dispatcher 是一个 Entity，admin Session 的 member（由 AdminRealm 实例化），使用 admin queue Resource，实现 OperationInterface。"

如果一个 noun 不在本文档里，**它就不在 metamodel 里**。要新加一个，先 propose 它属于哪个 primitive / 由哪个 Realm 实例化，doc 同步更新。

---

## 十一、相关文档

- `docs/notes/session.md` — ESR 中每个 Realm 的 catalog；以及 Entity / Resource declarations 列表（文件名沿用 rev 9 命名；按 rev 10 应作 `realm.md`，文件级 rename 留作后续整理）
- `docs/notes/mechanics.md` — ESR 运行 essence：actor model + topology 怎么落地（4 件事，加新功能的落点）
- `docs/notes/actor-role-vocabulary.md` — role trait 的详细定义（在本 metamodel 下，role trait 是 Realm 中 Context 部分选择的 Interface subset 命名约定）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/superpowers/specs/2026-05-08-resource-typed-grammar.md` — rev 10 swap 的代码-侧 cleanup spec（`Esr.Scope.* → Esr.Session.*` 等）
- `docs/futures/todo.md` — P2/P3 任务列表
