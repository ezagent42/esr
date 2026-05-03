# ESR 概念词汇 — Tetrad Metamodel

**Date:** 2026-05-03 (P1-1 brainstorm, rev 5)
**Audience:** 任何在 ESR 仓库读代码、写 spec、讨论架构的人——人类或 AI
**Status:** prescriptive；本文档定义元模型，不讨论现状偏差

---

## 这份文档为什么存在

这份 doc 给一套**最小、自相似的元模型 (metamodel)**，是 ESR 所有概念的源头规则。

用法：

- 写新模块 / 新 yaml entry 时，先确认要表达的概念在 metamodel 里是什么 primitive、属于哪个 Template、对外呈现什么 View
- review PR 时，对 noun 的理解不同就回到本文档对齐
- 写 spec 时，**只**用 metamodel 词汇 + `views.md` 里登记的 View 名字

**本文档不出现实现专有名词**（具体 agent 类型、外部平台名、私有缩写等都不出现）。具体实例化登记在伴随文档 `views.md`。实现层面的偏差由重构计划单独处理。

---

## 一、TL;DR

ESR 的所有运行时活动用一句话描述：

> **Session 通过 membership 引用 Entities 和 Resources；Interface 是 Entity / Resource 实现的契约。**

四个 primitive：

- **Session** — 场域 / 命名 scope；用 membership 引用 Entity 和 Resource
- **Entity** — 行动者 / 主语；有 identity，使用 Resource 发起动作
- **Resource** — 资源 / 宾语；被 Entity 使用，有限可数
- **Interface** — 契约 / trait；被 Entity 和 Resource 实现

外加两个 generative concept：

- **Template** — 独立的 code generator，批量产出一组打包好的 actor，并打上同一标签
- **View** — Template 整合输出，是外部唯一调用入口

**完美对称**：3 个 noun primitive（Session / Entity / Resource）都是单一 primitive，没有 metamodel-level subtype；变化都通过实现哪些 Interface 来表达。

四个 primitive 是**自相似的**：每一个 Entity 实例，zoom in 之后自身又是一个 Session（持有它内部的子图）。

---

## 二、Session — 场域

**定义**：一个有界 scope。通过 **reference / membership** 引用一组 Entity 和 Resource，构成这个 scope 内部的活动空间。

Session 之间通过 **reference** 关联——一个 Session 的 membership 列表可以包含其他 Session（嵌套），也可以共享同一个 Entity 或 Resource。

**例子**：

- 一个**群聊 Session**：references `user-alice`, `user-bob`, `agent-α`, `agent-β`, `channel-shared`, `dir-repo`
- 一个**daemon-level Session**：references `admin View`, 多个 active group-chat Session, daemon-tier capabilities
- 一个**admin Session**：references admin-flavor entities, admin queue resource

---

## 三、Entity — 行动者

**定义**：有 identity 的 actor。实现一组 Interface，使用 Resource，发起动作。**独立存在**——同一个 Entity 可以被多个 Session 引用。

**例子**：

- `user-alice`（人类）：注册一份在 daemon-level Entity registry，参与多个 group-chat Session
- `agent-cc-7`（AI）：声明一份，作为 member 加入 Session
- `dispatcher`（control-flavor）：admin Session 的成员，处理 admin queue 上的 operation

---

## 四、Resource — 资源

**定义**：被 Entity 使用的对象。有限、可计数、可被占有 / 转让 / 释放。

Resource 是单一 primitive，**没有 metamodel-level subtype**。不同 Resource 通过实现不同 Interface 表现差异——这跟 Session / Entity 的处理方式完全对称。

**常见命名约定**（informal，由 Interface 实现决定，不是 metamodel-level type）：

- **Channel** — 一个实现"双向消息流"Interface 的 Resource。lifecycle 通常 ephemeral
- **Dir** — 一个实现"文件系统命名空间"Interface 的 Resource。lifecycle 通常 persistent
- **Capability** — 一个实现"符号权限 + grant binding"Interface 的 Resource。两态：声明 + 授权

允许 hybrid：理论上一个 Resource 可以同时实现 Channel-Interface 和 Dir-Interface（消息流 backed by 持久化文件），metamodel 不阻止。具体哪些 Interface 组合在 ESR 里有意义，由 `views.md` 列出常见组合。

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
- **没有独立 View**：查询"实现了 Interface X 的所有 actor"是派生投影（runtime registry filter），不需要顶层 noun 来命名

**例子**：

- `MemberInterface`：所有 Session 成员实现，要求支持 mention / reply / leave 等
- `ChannelInterface`：实现 Channel 语义的 Resource 实现，要求支持 publish / subscribe / frame
- `OperationInterface`：admin Session 里 dispatchable 单元实现，要求支持 enqueue / execute / report

---

## 六、Template — 独立的 generator

**定义**：一个独立于 Session / Entity / Resource / Interface 的 code generator。当一个模块 `use SomeTemplate` 时，Template 批量产出一组打包好的 Entity 或 Resource 定义，并给它们打上 `from_template: <name>` 标签。

**Template 不归属于任何 primitive**——它平行于 4 个 primitive，是元模型的另一部分。

**例子**：

- `AdminTemplate`：产出 admin View 所需的 entities + resources（dispatcher entity, admin queue resource）
- `GroupChatTemplate`：产出群聊 Session 所需的 entities + resources（chat orchestrator, group channel）
- `AgentTemplate`：产出某种 AI 参与者所需的 entities + resources（agent's internal proxies, internal channels）

**可组合性**：`use TemplateA; use TemplateB` 在同一个模块上叠加，前提是 callback / state field 不冲突。

---

## 七、View — Template 的 runtime projection

**定义**：在 actor registry 上做 filter+aggregate 得到的 runtime 投影。Template 把 actors 打上标签，View 把同标签 actors 整合成一个**对外的统一 handle**。

**关键性质**：

- **runtime-projected**：随 actor registry 状态实时计算，可热重新整合
- **1 Template → 1 View**（典型；复合 Template 也产出 1 个复合 View）
- **包多个 actor 但外部不感知**：调用方拿 View handle 即可，不需要知道是在跟哪个 actor 通信

**例子**：

- `admin View`：runtime query "所有 from_template: admin 的 actor" 返回 dispatcher + admin queue 等的 integrated handle
- `group-chat-session1 View`：session1 内部所有成员 actor 的 integrated handle

---

## 八、自相似 / 递归（graph 形式）

任意 zoom level 上看到的都是同一种结构：

```
{ Sessions }       { Entities }       { Resources }
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
ESR 顶层 (一个 Session)
├── members: [admin View, group-chat-1 Session, group-chat-2 Session, ...]

group-chat-1 (一个 Entity from 顶层视角；自身是一个 Session)
├── members: [user-alice, user-bob, agent-cc-α, channel-shared, dir-repo]

agent-cc-α (一个 Entity from group-chat 视角；自身是一个 Session)
├── members: [agent's internal sub-modules, agent's internal channel-bus, ...]
```

每一层都是同一种 (Session, Entity, Resource) parallel 图结构 + Interface trait declaration。

---

## 九、群聊 Session 作为典型例子

群聊是 ESR 中**最 canonical 的 Session 形态**：多个 human + 多个 agent + 共享 Resource。

```
group-chat-session "team-room"
├── Entities (members):
│   ├── user-alice           (人类)
│   ├── user-bob             (人类)
│   ├── agent-cc-α           (AI)
│   └── agent-codex-β        (AI，未来)
├── Resources (members):
│   ├── channel-shared       (实现 ChannelInterface)
│   ├── dir-/repo/main       (实现 DirInterface)
│   └── capability subset    (实现 CapabilityInterface; session-level perms)
└── Interface contracts implemented by members:
    ├── MemberInterface       (所有 Entity 成员实现)
    ├── ChannelInterface      (channel-shared 实现)
    └── ...
```

通信通过 channel-shared 进行；mention / reply 等通过 MemberInterface 的 callback 表达；agent 和 user 在 Session 内部是平等的成员。

**动作示例**——`user-alice` 发一条消息 `@agent-cc-α 帮我看下 main.py`：

1. `user-alice`（Entity）通过 `MemberInterface.send_message` 把消息投到 `channel-shared`（Resource）
2. `channel-shared` 通过 `ChannelInterface.fan_out` 通知所有 subscribed 成员
3. `agent-cc-α`（Entity）通过 `MemberInterface.handle_mention` 收到针对它的 mention
4. `agent-cc-α` 用它的 internal sub-graph（zoom in 之后是一个 Session，里面有 sub-Entities + sub-Resources）处理这条消息，可能 read `dir-/repo/main`（共享 Resource），可能调用一个外部 AI service（这个调用通过 agent 内部的 boundary entity 发起）
5. agent 通过 `channel-shared` 发回 reply

整个过程不需要 Session 知道 agent 内部怎么工作——agent 是一个 Entity，从外层 Session 视角是黑盒；只要 agent 实现 MemberInterface 的契约，Session 就能跟它平等对话。

这就是 metamodel 在运行时的具象化：**在 Session 里，Entities 通过 Interface 用 Resources 互动**。

---

## 十、命名学约定

- **概念名 == 代码模块名**。`Esr.Sessions.GroupChat`, `Esr.Entities.User`, `Esr.Resources.Channel`, `Esr.Templates.Admin` 等。新写代码 / 重构时按这个对应。
- **跨语言**：Python / Elixir 共享同一组 primitive 命名（`esr.Sessions`, `esr.Entities`, ...）
- **describing concrete actors**：用 4-tuple + Template/View 来描述。例如：
  > "Dispatcher 是 AdminTemplate 生成的 Entity，admin Session 的 member，使用 admin queue Resource，实现 OperationInterface。所属 View: admin View."

如果一个 noun 不在本文档里，**它就不在 metamodel 里**。要新加一个，先 propose 它属于哪个 primitive / 哪个 Template，doc 同步更新。

---

## 十一、相关文档

- `docs/notes/views.md`（待写，P1-2）— ESR 中每个 Template / View 的具体 instantiation：actor 列表、yaml schema、实现路径
- `docs/notes/actor-role-vocabulary.md` — role trait 的详细定义（在本 metamodel 下，role trait 是 Template 选择的 Interface subset 的别名）
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — P2/P3 任务列表
