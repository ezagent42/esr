# ESR 概念词汇 — CERI Tetrad Metamodel

**Date:** 2026-05-03 (P1-1 brainstorm, rev 3 — CERI metamodel)
**Audience:** 任何在 ESR 仓库读代码、写 spec、讨论架构的人——人类或 AI
**Status:** prescriptive；今天的代码与本文档定义有偏差，由后续 PR 修齐

---

## 这份文档为什么存在

ESR 长出来的过程中，session、proxy、admin、channel 这些 noun 反复被混用，PR review 反复绕路，spec 写出来歧义。这份 doc 不是描述今天代码长什么样——它给一套**最小、自相似的元模型 (metamodel)**，把"什么东西归哪一类"的问题一次性闭合。

读它的目标：

- 写新模块 / 新 yaml entry 时，先确认你要表达的概念在这个 metamodel 下是哪种 primitive、属于哪个 Template、对外呈现什么 View
- review PR 时，如果两人对一个 noun 理解不同，回到这份 doc 对齐
- 写 spec 时，**只**用 metamodel 词汇 + 在本仓库 `views.md` 里登记的具体 View 名字

**本文档不出现实现专有名词**（`cc`, `cc_mcp`, `feishu`, `pty`, `FCP` 等都不出现）。具体实例化登记在伴随文档 `views.md` 里。

---

## 一、TL;DR

ESR 的所有运行时活动可以用一句话描述：

> **Context contains Entities and Resources; Interface defines admissible (Entity → Resource) interactions.**

四个 primitive：

- **Context**（场域 / scope）
- **Entity**（行动者 / 主语）
- **Resource**（资源 / 宾语）
- **Interface**（契约 / trait）—— 注意：Interface 不是独立的一等 actor，是被 Entity 和 Resource 所**实现**的契约

外加两个 generative concept：

- **Template** — generator，批量产出一组打包好的 C/E/R actor，并打上同一标签（Elixir `@behaviour` + macro）
- **View** — Template 整合输出，是外部唯一调用入口

CERI 是**自相似的**：每个 primitive 实例（一个 Context 实例 / 一个 Entity 实例 / ...）在它自己的层级里，又可以分解为一个完整的 (C, E, R, I) tetrad。

---

## 二、四个 primitive

### Context — 场域

- **是什么**：actor 所处的 scope / 环境。一个边界，里面可以容纳 Entity 和 Resource。Context 之间可以**嵌套**（一个 Context 内部可以有 sub-Context）。
- **不是什么**：不是 actor 本身（Context 是一个**范畴**，里面装着 actor）；不是物理 OS 资源（OS 资源在 Resource）。
- **典型 instance（抽象）**：daemon-tier 的全局 context、group-chat 的 session context、admin-scope context。
- **持久化形态**：通常表现为 ETS registry + supervisor tree + 配置 yaml 的组合。具体见 `views.md` 中各 View 的描述。
- **递归**：一个 session Context 内部，可以再分解出 (sub-Context, Entities-在内部, Resources-在内部, Interfaces-在内部) 的 4-tuple。

### Entity — 行动者

- **是什么**：能"做事"的 actor。有 identity，有 intent，会调用 Resource，对外提供 Interface。
- **不是什么**：不是 Resource（Entity 是主语；Resource 是宾语）；不是 Interface（Interface 是它**实现**的契约）。
- **典型 instance**：人类参与者（principal）、AI 参与者（agent）、内部 proxy（pipeline 节点 / boundary 翻译器 / control 代理）。
- **持久化形态**：以代码模块 + actor 实例形式存在。多数 Entity 由某个 Template 生成。
- **递归**：一个复杂 Entity（如某个 agent）可以分解为它自己的 sub-Context（agent 内部状态）+ sub-Entities（agent 内部协作模块）+ sub-Resources（agent 持有的内部资源）+ sub-Interfaces。

### Resource — 资源

- **是什么**：被 Entity 使用的对象。有限、可计数、可被占有 / 转让 / 释放。
- **不是什么**：不是 Entity（不主动）；不是 Interface（Resource 实现 Interface，但 Resource 本身是有形的）。
- **三类 sub-Template**（lifecycle 和 ownership 差异显著，不收敛成单一 Template）：
  - **Channel** — Entity 之间的双向消息流。生命周期通常绑定 Context（如 session 死则 channel 死）。
  - **Dir** — 文件系统位置 / 命名空间 / 持久化存储。生命周期跨 Context（多 Entity 共读、不易释放）。
  - **Capability** — 符号性 token / 权限句柄 / 操作能力 grant。生命周期是 declarative + binding-record 两态。
- **持久化形态**：取决于 sub-Template（Channel = BEAM PubSub topic + 双方 actor 注册；Dir = OS fs；Capability = ETS table + yaml）。
- **递归**：一个 Channel 也可以分解（它有自己的 internal scope、participating endpoints、底层 transport resources、frame Interface）。

### Interface — 契约（**trait，不是 noun**）

- **是什么**：被 Entity 或 Resource 实现的契约 / behaviour / trait。规定一组 callback 或 message shape。
- **不是什么**：**不是一等 actor**（不能 "instantiate an Interface"）；不是独立 noun（不出现在 ESR 主语 / 宾语位置）；不直接持久化（Interface 是编译期 / 声明期存在）。
- **关键性质**：Interface 是 **nominal**（Elixir `@behaviour` 风格），通过 `use SomeTemplate` 显式 declare，不靠 structural matching 推断。
- **没有独立 View**：查询"实现了 Interface X 的所有 actor"是一个**派生投影**，不命名为顶层 noun。具体实现是对 registry 的 filter+aggregate 查询。
- **类比**：Rust trait / Go interface / Elixir Behaviour。

---

## 三、generative concepts

### Template — generator

- **是什么**：一个 macro / 配置模板，**批量生成**一组带相同标签的 C/E/R actor，并让它们各自实现 Interface 的相应子集。
- **Elixir 实现**：典型为一个 `defmacro __using__` + 一组 `defstruct` + 一组 `@behaviour`。actor 通过 `use MyTemplate` 拿到标签 + 默认实现。
- **数据层**：actor 上有 `from_template: <name>` 元数据，可在 registry 查询时过滤。
- **可组合性**：Template 之间通过 `use` chain 组合（`use AdminTemplate; use WorkspaceTemplate`），约束是不同 Template 的 callback / state field 不冲突。
- **关系**：1 Template → N actor（生成一组）；1 Template → 1 View（外部接口）。

### View — projection

- **是什么**：Template 整合输出。外部调用方对 Template 生成的 actor 集合的**唯一 handle**。
- **runtime-projected**：View 不是编译期产物——它是在 actor registry 上做 filter + aggregate 的**查询结果**，可以热重新计算。
- **不是什么**：不是单个 actor（View 通常 wrap 多个 actor）；不是 Interface（Interface 是 trait 声明；View 是 trait 实现的具体 instances）。
- **内部 named elements**：View 内部可以识别出"这个 actor 担任 Context 角色 / 那个担任 Entity 角色 / 这些是 Resource"，但**外部调用方不需要知道**。
- **关系**：1 Template → 1 View；1 View 包含 1 或多个 C/E/R element。

---

## 四、CERI 自相似 / 递归

每个 primitive 实例在它自己的 zoom level 上**自身就是一个完整 tetrad**：

```
顶层 ESR
├── Context（daemon scope）
│   ├── Entities：{Admin Template 生成的 entities，Session Template 生成的 entities，...}
│   ├── Resources：{daemon-tier resources}
│   └── Interfaces：{daemon trait set}
│
└── 任何 Session 实例（一个 Context）
    ├── 内部 Context（如 sub-rooms / 子会话）
    ├── Entities：{多个 user, 多个 agent, 多个 proxy}
    ├── Resources：{Channel, Dir, Capability shared by group}
    └── Interfaces：{group-chat trait, member trait, ...}

    └── 任何 Entity 实例（如一个 agent）
        ├── 内部 Context（agent 内部 state scope）
        ├── 内部 Entities（agent 内部协作模块）
        ├── 内部 Resources（agent 持有的资源）
        └── 内部 Interfaces（agent 内部 trait）
```

这个 fractal 结构解决了一个昨天困扰我们的问题：**一个 actor 既是它所在 Context 中的 Entity，又自己是一个完整的 (C, E, R, I) tetrad**——不是模型 leak，是元模型本来就 self-similar。

---

## 五、规范的 group-chat session 模型

session 在 ESR 中**就是 group chat**：一个 Context，里面有多个 human 参与者（principal）和多个 agent 参与者，他们通过 Interface 契约互相沟通。

session 不再是 1 user × 1 agent × 1 chat 的 1:1:1 模型。

具体的成员和资源构成（抽象层）：

| 角色 | primitive | 数量 | 备注 |
|---|---|---|---|
| session 自己 | Context | 1 | 是顶层 group-chat 容器 |
| 人类参与者 | Entity (principal) | N | 来自 User Template |
| AI 参与者 | Entity (agent) | M | 来自 Agent Template |
| group channel | Resource (Channel) | 1 或 N | 共享消息流 |
| 工作目录 | Resource (Dir) | 1 或 N | 共享文件空间 |
| 群级权限 | Resource (Capability subset) | — | session 级 cap binding |

session 的主要 Interface 契约：member-join / member-leave / message-broadcast / message-direct / mention / quote / 等等。

具体的 ESR 实例（admin / cc / feishu integration / etc）登记在 `views.md`，不在本文档。

---

## 六、命名学约定

- **doc / spec 用语**：本文档列的 primitive (Context / Entity / Resource / Interface) + generative (Template / View) 是规范用法。讨论中如果某 noun 不在这里，先问"它是 primitive？Template？View？还是某 View 内部的 named element？"，归类后再讨论。
- **代码 namespace 不立即跟随**：今天 `Esr.Peers.*`、`Esr.Workspaces.*` 等命名空间保留。但**代码注释和 docstring 应当用本文档词汇**——例如说"this entity is generated by AdminTemplate"，不说"this peer is in admin tier"。
- **跨语言一致**：Python sdk 的 entity / context 概念跟 Elixir 共享同一组 primitive 命名。
- **describing concrete actors**：用 4-tuple 坐标 + Template/View 来描述具体 actor。例如：
  > "Dispatcher 是 AdminTemplate 生成的 Entity，在 admin Context 下，使用 admin queue Resource，实现 admin trait 的 dispatch 部分。所属 View: admin View."

---

## 七、对应的实现层关系（高层参考）

下表是 ESR 顶层 Templates 的清单。**每个 Template 的具体内部组成、yaml 配置、actor 实现细节登记在 `views.md`**，不在本文档。

| Template | 输出 View | 主要 primitive flavor |
|---|---|---|
| **AdminTemplate** | admin View | Context-为主（global daemon scope）+ control-flavor entities |
| **SessionTemplate** | session View（group-chat） | Context-为主 + 多 Entity 成员 |
| **UserTemplate** | user / principal View | Entity-为主 |
| **AgentTemplate** | agent View | Entity-为主 |
| **AdapterTemplate** | adapter View | Entity-为主 (boundary trait) |
| **HandlerTemplate** | handler View | Entity-为主 (pipeline trait) |
| **ChannelTemplate** | channel View | Resource-为主 |
| (atomic resources) | Dir, Capability | 直接 Resource，不需 Template |

---

## 八、相关文档

- `docs/notes/views.md`（待写，P1-2）— ESR 中每个 Template / View 的具体 instantiation：actor 列表、yaml schema、实现路径
- `docs/notes/actor-role-vocabulary.md` — 5 类 role trait（Boundary / State / Pipeline / Control / OTP）的详细定义；本文档下，role trait 是 Template 选择的 trait subset 的别名
- `docs/notes/esr-uri-grammar.md` — URI 语法
- `docs/futures/todo.md` — P2/P3 任务列表

---

## 九、已废弃 / 即将移除（来自 rev 1/2 的 carry-over）

下列 noun 在 rev 1/2 出现过，本元模型下不存在或已重新定义：

### peer

- **状态**：deprecated；本文档不使用。
- **原因**：peer 同时混用为"代码模块"（rev 2 的 B entity）和"OTP actor 实例"——在 CERI 模型下分别归属 Entity（前者）和 Resource（后者，actor process 是有限可数 BEAM 资源）。
- **行动项**：注释 / docstring 里 "peer" 改为 entity 或 actor；`Esr.Peers.*` namespace rename 是 A2 territory。

### thread（作为路由维度 / ESR noun）

- **状态**：deprecated；PR-21λ 已经把 SessionRegistry 路由键收窄为 `(chat_id, app_id)`。
- **原因**：thread 是外部平台（Feishu）概念，不应是 ESR 内部 primitive。今天 `thread_id` 仅在 envelope 里流转，给外部 reply API quoting 用。
- **行动项**：完成 cc_mcp / agent 内部 reply context 缓存后，从 envelope 字段彻底去掉 thread_id。

### principal-as-URI-id（`users/<ou_xxx>`）

- **状态**：过渡态。今天 URI 既可以是 `users/<username>` 也可以是 `users/<ou_xxx>`。
- **目标**：URI 只用 esr-username；principal_id 仅在 envelope 字段存在。
- **行动项**：见 todo.md "Design: pure esr-username caps (eliminate ou_* in capabilities.yaml)"。

### "admin entity" / "admin tier" 作为顶层 noun

- **状态**：deprecated。
- **新形态**：admin 是一个 **Template**（AdminTemplate），生成的 actor bundle 整合为 admin View。"admin queue"是 admin Template 内部的一个 Resource（不是顶层 noun）；Dispatcher / SlashHandler / FAA 是 admin Template 生成的 Entity（不是单独"admin entity"）。

### session 1:1:1 模型

- **状态**：deprecated；2026-05-03 user 决定重构为 group-chat 模型。
- **新形态**：session 是 Context，容纳 N user + M agent + 共享 Resource。chat-current routing 模型在 group-chat 模型下意义改变——具体迁移路径见 P2 的 `/session new` 重设计 spec。
- **行动项**：A1（`/session new` 重设计）spec 重启，按 group-chat 模型设计。

---

## 十、后续 P1-2

P1-1 给定义；P1-2 落实成具体仓库内容：

- 写 `views.md`，每个 Template / View 列出今天的实际 actor list + yaml + lifecycle 状态
- 在 `views.md` 里同时列今天的 conflation —— 每个 Template 哪里跟本 metamodel 不一致 + 修齐方向
- 不强制立即修齐代码；本 metamodel 是 north star，P2/P3 PR 在 touch 相关代码时按这个 metamodel 改齐
