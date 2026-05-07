# Multi-Instance Routing Cleanup（多实例路由清理）

**日期：** 2026-05-07
**状态：** rev-1 DRAFT
**英文版：** `docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md`

---

## 锁定决策（Feishu 2026-05-07，Q5.1–Q5.7）

以下决策均于 2026-05-07 在 Feishu 锁定，原文引用。

**Q5.1 — ActorQuery 原语（决策：简单版，无谓词 DSL）**

```elixir
defmodule Esr.ActorQuery do
  @spec find_by_name(session_id :: String.t(), name :: String.t()) :: {:ok, pid} | :not_found
  @spec list_by_role(session_id :: String.t(), role :: atom()) :: [pid]
  @spec find_by_id(actor_id :: String.t()) :: {:ok, pid} | :not_found
end
```

无谓词 DSL，无 scope 枚举，无多属性查询语言。Cap-based discovery（Q5.5）明确不在本次 spec 范围内——留给后续 spec。

**Q5.2 — Esr.Entity.Registry 索引**

三个 ETS 索引（现有 actor_id 索引 + 两个新增）：
- `actor_id → pid`（现有）
- `(session_id, name) → pid`（新增——支持 find_by_name）
- `(session_id, role) → [pid]`（新增——支持 list_by_role；bag 风格；支持同一 session 内同 role 多实例）

Peer 在 `init/1` 时带 `%{actor_id, session_id, name, role}` 注册。在 terminate 或 monitor DOWN 时注销。

**Q5.3 sub-1 — Session 创建：空（无默认 agent）**

Session 创建仅 spawn 基础 pipeline（FCP + admin scope peers）。CC/PTY 等需要显式 `/session:add-agent`。无 `agent=cc` 默认值——完全为空。

**Q5.3 sub-2 — (CC, PTY) supervision 策略：`:one_for_all`**

PTY 是 IO 通道；孤存的 CC 没有语义价值。策略：`:one_for_all`。

**Q5.3 sub-3 — DynamicSupervisor 位置：per-session**

每个 session supervisor（`Esr.Scope.Supervisor`）托管一个 DynamicSupervisor，该 DynamicSupervisor 托管（CC, PTY）子树。`/session:end` 通过 OTP shutdown 自动清理，无需手动枚举。

**Q5.3 sub-4 — /session:add-agent 原子性：通过 GenServer 串行化**

InstanceRegistry GenServer 的 `add_instance(session_id, name, type)` 是一次原子调用：检查唯一性 → DynamicSupervisor.start_child → 注册 pid。与 Phase 5.2 metamodel-aligned 模式一致。

**Q5.4 — actor_id 与 name**

- `actor_id`：UUID v4，在 `/session:add-agent` 时生成，存在 InstanceRegistry 中（现有字段）
- `name`：可变的显示别名（面向运营者）；重命名不改变 actor_id
- 三个查询函数对应三种访问模式（见上）

**Q5.5 — Cap-based DSL：不在范围内**

后续 spec。本 spec 刻意将 ActorQuery 限定在（name、role、actor_id）查询。brainstorm 文档 §4.1 "统一原语"的表述被放弃：此次不统一"确定性 wire"与"动态发现"。

**Q5.6 — 迁移：5 阶段，无向后兼容**

每阶段硬切换。本 spec 落地后，无 `state.neighbors` 回退期，无 `_legacy.*` 双写。每阶段一个 PR，顺序依赖链（M-1 必须进 dev 才能开始 M-2；依此类推）。每个 PR 边界测试保持绿色。

| Phase | 标题 | 估算 LOC delta |
|---|---|---|
| M-1 | Esr.ActorQuery + Registry 索引（加法） | +250 |
| M-2 | 迁移调用方 + 删 state.neighbors + per-session DynSup + 原子 add-agent | 净 -200 |
| M-3 | 删 legacy diffusion（workspace.neighbors / topology symmetric_closure / reachable_set / describe_topology neighbor_workspaces） | -300 |
| M-4 | 删 _legacy.* compat shim + legacy %Workspace{} struct + 4 个调用方迁移 | -400 |
| M-5 | 测试 + e2e sweep + 新的 multi-CC 场景 | +200 / -100 |
| **合计** | | **约 -550 LOC** |

**Q5.7 — 时间窗：已无关**

session-first 模型迁移于 2026-05-07 落地（metamodel-aligned ESR spec）。brainstorm 文档中提到的前置依赖已满足。本 spec 可立即推进。

---

## 参考文档

- `docs/futures/multi-instance-routing-cleanup.md` — brainstorm 输入材料
- `docs/notes/concepts.md` — Tetrad 元模型词汇
- `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` — 同步落地的 session-first 迁移 spec

---

## §1 — 动机

PR-3 引入了 `state.neighbors :: Keyword<role_atom, pid>` 用于在 session 启动时连接各 peer。当时的 spec 是 1:1——每个 session 内每个 role 只有一个实例。这是设计意图决定的，不是审查失误。截至 2026-05-07，设计已演进：`Esr.Entity.Agent.InstanceRegistry` 和 `MentionParser` 支持每个 session 内有多个 agent 实例（multi-CC），`/session:add-agent` 也已将实例元数据写入 ETS。但 spawning 层没有跟上——`/session:add-agent` 只写了 ETS 记录，没有 spawn（CC, PTY）actor 子树。结果：`MentionParser` 能正确解析 `@<name>`，但 `find_by_name` 找不到对应 pid：命名 agent 在运行时不存在。与此同时，codebase 中还保留着 `workspace.neighbors:` / `Esr.Topology.symmetric_closure/0` / `reachable_set` / `describe_topology neighbor_workspaces` 这套 legacy diffusion 层——它最初设计用于引导 LLM 路由决策，但现在已沦为 LLM context shaper，与 capability grants 的职责重叠，且对路由决策没有实质影响。两个问题的根因相同：role 和 instance 从未被拆分为独立概念。本 spec 清理两者。

---

## §2 — 目标

1. 统一 peer 查询接口为 `Esr.ActorQuery`（3 个函数：`find_by_name/2`、`list_by_role/2`、`find_by_id/1`）。
2. 消除 `state.neighbors :: Keyword<role_atom, pid>` 所体现的 1:1 role-instance 假设。
3. 让 `/session:add-agent` 真正 spawn（CC, PTY）actor 子树，使命名 agent 从创建时即有运行时 pid。
4. 完整删除所有 legacy diffusion 机制（`workspace.neighbors`、`<reachable>`、`symmetric_closure`、`describe_topology neighbor_workspaces`）。
5. 净删除约 550 LOC。

---

## §3 — 不在范围内

- Cap-based discovery（Q5.5）：推迟到后续 spec。
- 用 broker 或消息队列替换 BEAM direct-send：PR-3 数据平面纪律不变。
- 跨 esrd 联邦：本 spec 只覆盖单 esrd 内 actor 查询。
- `cap_guard` 改造：授权层是独立的正交关注点。
- 向后兼容：没有回退期，硬切换。
- workspace 级元数据 API：M-4 删除 `workspace.role` / `workspace.metadata` 后，如有需要则单独设计。

---

## §4 — ActorQuery API

### 4.1 模块契约

```elixir
defmodule Esr.ActorQuery do
  @moduledoc """
  三函数 peer 查询。由 Esr.Entity.Registry 的三个 ETS 索引支撑。
  需要稳定引用的调用方应在查询成功后立即 monitor 返回的 pid。

  锁定决策 Q5.1（Feishu 2026-05-07）：无谓词 DSL，无 scope 枚举，
  无多属性查询语言。Cap-based discovery 不在范围内（Q5.5）。
  """

  @spec find_by_name(session_id :: String.t(), name :: String.t()) ::
          {:ok, pid()} | :not_found

  @spec list_by_role(session_id :: String.t(), role :: atom()) :: [pid()]

  @spec find_by_id(actor_id :: String.t()) :: {:ok, pid()} | :not_found
end
```

### 4.2 使用示例

**将 @mention 路由到命名 agent：**

```elixir
case Esr.ActorQuery.find_by_name(state.session_id, mention_name) do
  {:ok, target_pid} ->
    ref = Process.monitor(target_pid)
    send(target_pid, {:mention, envelope})
    {:noreply, Map.put(state, :active_monitor, ref)}

  :not_found ->
    reply_error(state, "agent '#{mention_name}' not found in session")
end
```

**向 session 内所有 CC peer 广播（fan-out）：**

```elixir
pids = Esr.ActorQuery.list_by_role(session_id, :cc_process)
Enum.each(pids, &send(&1, {:broadcast, event}))
```

### 4.3 边界情况

**名称唯一性：** name 在 session 内唯一。`InstanceRegistry.add_instance_and_spawn/1` 在 GenServer 层拒绝重名。`find_by_name/2` 永远不会返回多于一个结果。

**Pid 过时：** `(session_id, role)` ETS bag 在 monitor DOWN 时清理。调用方应在 send 前 monitor 返回的 pid。标准模式：query → monitor → send → handle DOWN。

**:not_found 意味着 agent 未 spawn：** M-2 后，InstanceRegistry 中有记录的 name 一定有对应的活跃 pid。

**重命名不改变 actor_id：** `find_by_name/2` 用新 name 找到同一 pid；`find_by_id/1` 用旧 actor_id 仍然有效。

### 4.4 ActorQuery 不做的事

- 无谓词过滤。
- 无 cap 检查（那是 `cap_guard` 的工作）。
- 无跨 esrd 查询。

---

## §5 — Esr.Entity.Registry 升级

### 5.1 现状

`Esr.Entity.Registry` 是 Elixir `Registry`（`:unique` 策略）的薄封装，只有一个索引：`actor_id → pid`。

### 5.2 新索引布局

**索引 1 — actor_id（现有，不变）：**
```
表：:esr_entity_registry（via Elixir Registry，:unique）
键：actor_id :: String.t()
值：pid
```

**索引 2 — (session_id, name)（新增）：**
```
表：:esr_actor_name_index（:set，named，public，read_concurrency: true）
键：{session_id, name}
值：{pid, actor_id}
```
使用 `:ets.insert_new/2` 保证原子唯一性检查。

**索引 3 — (session_id, role)（新增）：**
```
表：:esr_actor_role_index（:bag，named，public，read_concurrency: true）
键：{session_id, role}
值：{pid, actor_id}
```
`:bag` 策略支持同 session 同 role 多个条目（multi-CC 场景）。

### 5.3 注册生命周期

每个 stateful peer 声明模块属性：

```elixir
@role :cc_process  # 或 :pty_process, :feishu_chat_proxy 等
```

在 `init/1` 中，完成现有 actor_id 注册后，调用：

```elixir
Esr.Entity.Registry.register_attrs(actor_id, %{
  session_id: session_id,
  name: instance_name,
  role: @role
})
```

Registry monitor 此 pid。收到 `:DOWN` 时，从三个索引中清除所有对应条目。

### 5.4 Role atom 词汇表

| Role atom | 模块 | 来源 |
|---|---|---|
| `:cc_process` | `Esr.Entity.CCProcess` | `cc_process.ex:110` |
| `:pty_process` | `Esr.Entity.PtyProcess` | `pty_process.ex:116` |
| `:feishu_chat_proxy` | `Esr.Entity.FeishuChatProxy` | `feishu_chat_proxy.ex:63` |
| `:feishu_app_proxy` | proxy 模块 | `agent_spawner.ex` |
| `:cc_proxy` | proxy 模块 | `cc_process.ex:17` |

Proxy peer 不是 GenServer，不在 role 索引中注册。

---

## §6 — Session 结构（spec 落地后）

### 6.1 /session:new：空 session（Q5.3 sub-1）

`/session:new` 仅 spawn 基础 pipeline：
- `Esr.Entity.FeishuChatProxy`（FCP）
- Admin scope peers（slash handler 等）

不 spawn CC，不 spawn PTY，无默认 agent。

### 6.2 Per-session DynamicSupervisor（Q5.3 sub-3）

```
Esr.Scope.Supervisor（顶层）
└── Esr.Scope（per-session supervisor）
    ├── Esr.Entity.FeishuChatProxy
    ├── <其他基础 pipeline peers>
    └── Esr.Scope.AgentSupervisor（DynamicSupervisor，per-session）
        ├── agent-subtree-1（Supervisor，:one_for_all）
        │   ├── Esr.Entity.CCProcess  （实例 "helper-A"）
        │   └── Esr.Entity.PtyProcess （实例 "helper-A"）
        └── agent-subtree-2（Supervisor，:one_for_all）
            ├── Esr.Entity.CCProcess  （实例 "helper-B"）
            └── Esr.Entity.PtyProcess （实例 "helper-B"）
```

`/session:end` 通过 OTP shutdown 级联终止所有子树，无需手动枚举。

### 6.3 (CC, PTY) :one_for_all 策略（Q5.3 sub-2）

PTY 是 CC 的 IO 通道。PTY 崩溃则 CC 也重启；CC 崩溃则 PTY 也重启。孤存的 CC 没有输出路径，没有语义价值。建议设置 `max_restarts: 3, max_seconds: 60`，防止快速崩溃风暴导致 agent 永久下线。

### 6.4 /session:add-agent 原子分发（Q5.3 sub-4）

`Esr.Commands.Session.AddAgent` 从当前（仅写 ETS 记录）改为调用：

```elixir
InstanceRegistry.add_instance_and_spawn(%{
  session_id: sid, type: type, name: name, config: config
})
```

`add_instance_and_spawn/1` 是新增的 InstanceRegistry GenServer 回调，将 ETS 写入和 `DynamicSupervisor.start_child` 合并为一次串行 GenServer call。若 start_child 失败，ETS 占位记录被删除（回滚）。

---

## §7 — Legacy 删除清单

以下所有条目均通过 508a834 HEAD 实地 grep 核实。

### M-2 删除：state.neighbors + backwire/rewire

**`runtime/lib/esr/session/agent_spawner.ex`**
- 263–282：backwire 说明注释
- 308：`:ok = backwire_neighbors(...)` 调用
- 337–395：`backwire_neighbors/3` 实现（~59 LOC）
- 426–430、457–470：`build_neighbors/1` 及调用点（~19 LOC）
- M-2 在此文件净删约 -99 LOC

**`runtime/lib/esr/entity/pty_process.ex`**
- 107–116：state struct 中 `:neighbors` 字段
- 138–145：延迟 rewire 触发器
- 317–325：`handle_downstream(:rewire_siblings, state)` 子句
- 329–355：`rewire_session_siblings/1`（~27 LOC）
- 357–367：`patch_neighbor_in_state/3`（~11 LOC）
- M-2 在此文件净删约 -60 LOC

**`runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`**
- 63：`:neighbors` struct 字段
- 666：`Keyword.get(state.neighbors, :cc_process)` 替换为 `ActorQuery.list_by_role/2`
- 711：`Keyword.get(state.neighbors, :feishu_app_proxy)` 替换为 ActorQuery

**`runtime/lib/esr/plugins/claude_code/cc_process.ex`**
- 17、110：`:neighbors` state 字段
- 374–414：`find_chat_proxy_neighbor/1` + `Keyword.get(state.neighbors, ...)` 调用（~41 LOC）替换为 ActorQuery

**M-2 合计：约净 -200 LOC**

---

### M-3 删除：legacy diffusion

**`runtime/lib/esr/topology.ex`** — 整文件删除（257 LOC）

**`runtime/lib/esr/plugins/claude_code/cc_process.ex`**
- 103、115：`reachable_set` 初始化
- 119–145：`build_initial_reachable_set/1`（~27 LOC）
- 205–220：`handle_info` 中的 reachable_set 追加（~16 LOC）
- 498–540：`maybe_put_reachable/2` + `reachable_json/1`（~43 LOC）
- 592–614：PR-C C4 handler 中的 reachable_set union（~23 LOC）

**`runtime/lib/esr/resource/workspace/describe.ex`**
- 61–66：`neighbor_workspaces` 输出字段
- 122–123、164–191：`legacy_neighbors/1` + `resolve_neighbour_workspaces/2`（~26 LOC）

**`runtime/lib/esr/entity/server.ex`**
- 820–832：`build_emit_for_tool("describe_topology", ...)` 整个私有函数（~22 LOC）
- 291：`describe_topology` cap bypass 分支

**`runtime/lib/esr/plugins/claude_code/mcp/tools.ex`**
- 89–115：`@describe_topology` 模块属性（~27 LOC）
- 124、127：工具列表中的引用

**`runtime/lib/esr/resource/workspace/registry.ex`**（M-3 部分）
- 55：`neighbors: []` struct 字段
- 587、604：`_legacy.neighbors` 的读写

**M-3 合计：约 -300 LOC**

---

### M-4 删除：_legacy.* compat shim + legacy %Workspace{} struct

**`runtime/lib/esr/resource/workspace/registry.ex`**
- `defmodule Workspace do ... end`（41–60 行，~20 LOC）
- `@legacy_table :esr_workspaces` + 全部 ETS 操作（~15 LOC）
- `to_legacy/1`（563–590 行，~28 LOC）
- `normalize_to_struct/1`（592–615 行，~24 LOC）
- `do_put(%Workspace{} = legacy)` 子句（495–515 行，~21 LOC）
- `start_cmd_for/2`（177–195 行，~19 LOC）
- 合计约 -127 LOC

**`runtime/lib/esr/commands/workspace/info.ex`**
- `lookup_legacy/1`（107–167 行，~61 LOC）
- `build_legacy_result/1`（~30 LOC）
- `_legacy.*` Map.get 读取（124–126 行，~3 LOC）
- 合计约 -108 LOC

**`runtime/lib/esr/resource/workspace/describe.ex`**
- `legacy_metadata/1`（168–174 行，~7 LOC）
- `_legacy.role` / `_legacy.metadata` 读取（~8 LOC）
- 合计约 -16 LOC

**`workspace_for_chat/2` 的 8 个调用方——M-4 不动**

`workspace_for_chat/2` 内部使用 UUID-keyed Struct 表，不依赖 `@legacy_table`。8 个调用方无需修改（已 grep 核实）。

**M-4 合计：约 -256 LOC 纯删除，含关联死代码清理后约 -400 LOC**

---

## §8 — 迁移计划（5 阶段，顺序依赖，硬切换）

### M-1：ActorQuery + Registry 索引（加法，不改现有代码）

- 新增 `runtime/lib/esr/actor_query.ex`
- 升级 `runtime/lib/esr/entity/registry.ex`：新增 Index 2/3、`register_attrs/2`、`deregister/1`
- 修改 `runtime/lib/esr/application.ex`：启动两个新 ETS 表
- 三个 peer 模块加 `@role` 声明（additive）
- 估算：+250 LOC，4–6 commits

### M-2：迁移 + 删 state.neighbors / backwire / rewire（最高风险）

- `agent_spawner.ex`：删 `backwire_neighbors/3`、`build_neighbors/1`、`:sys.replace_state/2`
- `pty_process.ex`：删 `rewire_session_siblings/1`、`patch_neighbor_in_state/3`、`:neighbors` state 字段
- `feishu_chat_proxy.ex` + `cc_process.ex`：替换 `state.neighbors` 为 ActorQuery
- 新增 per-session `Esr.Scope.AgentSupervisor`
- `add_agent.ex`：调用 `add_instance_and_spawn`
- 估算：净 -200 LOC，8–10 commits
- 每个文件一个 commit，每 commit 后跑 `mix test`

### M-3：删 legacy diffusion（-300 LOC 纯删）

- 删 `topology.ex` 整文件
- 删 `cc_process.ex` 中 reachable_set 相关所有代码
- 删 `describe.ex` 中 neighbor_workspaces 输出
- 删 `server.ex` 中 describe_topology 工具函数
- 删 `tools.ex` 中 `@describe_topology`
- 估算：-300 LOC，5–6 commits

### M-4：删 _legacy.* compat shim（-400 LOC 纯删）

- 删 `%Workspace{}` legacy struct、`@legacy_table`、`to_legacy/1`、`normalize_to_struct/1`
- 删 `info.ex` 中 `lookup_legacy/1`、`build_legacy_result/1`
- 删 `describe.ex` 中 `legacy_metadata/1`
- 估算：-400 LOC，4–5 commits

### M-5：测试 + e2e sweep + 新 multi-CC 场景

- 重写被删代码的测试
- 新增 `actor_query_test.exs`、`registry_indexes_test.exs`
- 新增 scenario 18（multi-CC session 全生命周期）
- 估算：+200 / -100 LOC，6–8 commits

---

## §9 — 风险登记

| 风险 | 级别 | 缓解 |
|---|---|---|
| M-2 四个 peer 模块同时改 state | 高 | 每个文件单独 commit；每 commit 跑 `mix test` |
| agent_spawner/pty_process/cc_process 测试必然 break | 已知 | M-5 统一重写；M-2–M-4 PR 描述中预告 |
| e2e scenario 04（topology integration）会失败 | 中 | M-5 决定重写或删除 |
| workspace_for_chat 8 个调用方 | 低 | 函数不依赖 legacy_table，调用方无需改动 |
| PTY 快速崩溃触发 :one_for_all 重启风暴 | 低 | 设 max_restarts: 3, max_seconds: 60 |

---

## §10 — 测试计划

### ActorQuery 单元测试（M-1 新增）

- `find_by_name/2`：found / not_found / 注销后 not_found
- `list_by_role/2`：空 session / 单实例 / 同 role 多实例（返回 2 个 pid）
- `find_by_id/1`：found / not_found

### Registry 索引测试（M-1 新增）

- `register_attrs/2`：成功写入 Index 2 + Index 3
- 名称重复：返回 `{:error, :name_taken}`
- `deregister/1`：清除 Index 2 + Index 3
- Monitor DOWN 自动清理
- ETS 并发写同名：恰好一个成功

### /session:add-agent 原子性测试（M-2 新增）

- spawn 失败时回滚：ETS 无残留记录
- 重名拒绝：返回 `{:error, {:duplicate_agent_name, _}}`
- start_child 中途崩溃：无孤立 ETS 条目

### Multi-CC 集成测试——scenario 18（M-5 新增）

1. `/session:new` → `list_by_role(sid, :cc_process) == []`
2. `/session:add-agent name=helper-A type=cc` → `find_by_name(sid, "helper-A") == {:ok, pid}`
3. `/session:add-agent name=helper-B type=cc` → `list_by_role(sid, :cc_process)` 返回 2 个 pid
4. 发送 `@helper-A` mention → 路由到 helper-A 的 pid，不路由到 helper-B
5. `/session:remove-agent name=helper-A` → `find_by_name(sid, "helper-A") == :not_found`；`list_by_role` 返回 1 个 pid
6. `/session:end` → `list_by_role(sid, :cc_process) == []`

e2e 截图要求：
1. PTY 输出显示两个 agent 同时存在并回复。
2. Feishu 消息显示 @mention 正确路由到命名 agent。

---

## §11 — 参考文档

- Brainstorm 输入：`docs/futures/multi-instance-routing-cleanup.md`
- 元模型词汇：`docs/notes/concepts.md`
- PR-3 PubSub 纪律（本 spec 不动）：`docs/notes/pubsub-audit-pr3.md`
- Cap-based DSL 后续（Q5.5 推迟）：`docs/futures/peer-session-capability-projection.md`

---

## §12 — 后续待办（不阻塞本 spec）

1. **`Esr.Topology` 未来替换：** Cap-based DSL spec 落地时设计；M-3 删除后 LLM 不再收到 `<reachable>` 上下文。
2. **workspace.role / workspace.metadata：** M-4 删除后如有需要，单独设计新 API，不沿用 `_legacy.*` 模式。
3. **todo.md 更新：** M-1 合并后，将"Migrate to session-first model"标记为已完成；将"Multi-instance routing cleanup（M-1–M-5）"加为新的进行中项目。
4. **describe_topology 替换：** M-3 删除后无同等工具。如 CC 需要在 prompt 中获取 peer 信息，基于 ActorQuery 语义另行设计（如 `list_session_agents` 返回 name + role + actor_id）。
