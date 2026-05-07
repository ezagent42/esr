# 多实例路由清理实现计划

> **给 Agent 工作者：** 必须使用 superpowers:subagent-driven-development，逐任务执行本计划。

**目标：** 消除 PR-3 中 1:1 role-instance 绑定假设；删除旧版 diffusion 机制；引入 Esr.ActorQuery；让 `/session:add-agent` 真正生成 (CC, PTY) 进程子树。

**架构：** ETS 支撑的 Esr.Entity.Registry（3 个索引：actor_id、(session, name)、(session, role)）；每个会话下的 DynamicSupervisor（Scope.AgentSupervisor），托管 CC+PTY 的 `:one_for_all` 子树；InstanceRegistry GenServer 实现原子化 `/session:add-agent`。

**技术栈：** Elixir/OTP；ETS；复用现有 UUID/NameIndex 模式。

**规范：** `docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md`（rev-1，用户已批准 2026-05-07）。

**迁移：5 个阶段，无向后兼容。** 每步硬切换，每个阶段对应一个 PR。

---

## 文件结构

### M-1 阶段 — 新增文件

| 文件 | 说明 |
|---|---|
| `runtime/lib/esr/actor_query.ex` | 新模块 `Esr.ActorQuery`，包含三个公开查询函数 |
| `runtime/test/esr/actor_query_test.exs` | ActorQuery 全量单测 |
| `runtime/test/esr/entity/registry_indexes_test.exs` | Index 2（name）和 Index 3（role）生命周期测试 |

### M-1 阶段 — 修改文件

| 文件 | 修改概述 |
|---|---|
| `runtime/lib/esr/entity/registry.ex` | 增加两张 ETS 表；新增 `register_attrs/2`、`deregister_attrs/2`；新增 DOWN monitor 处理 |
| `runtime/lib/esr/application.ex` | 在 Entity.Registry 之前启动两张 ETS 表 |
| `runtime/lib/esr/entity/pty_process.ex` | 添加 `@role :pty_process`；在 `init/1` 调用 `register_attrs`；在 `terminate/2` 调用 `deregister_attrs` |
| `runtime/lib/esr/plugins/claude_code/cc_process.ex` | 同上，role 为 `:cc_process` |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | 同上，role 为 `:feishu_chat_proxy` |

### M-2 阶段 — 新增文件

| 文件 | 说明 |
|---|---|
| `runtime/lib/esr/scope/agent_supervisor.ex` | `Esr.Scope.AgentSupervisor` — DynamicSupervisor，托管 per-agent 子树 |
| `runtime/lib/esr/scope/agent_instance_supervisor.ex` | per-agent `:one_for_all` Supervisor |

### M-2 阶段 — 修改文件

| 文件 | 修改概述 |
|---|---|
| `runtime/lib/esr/session/agent_spawner.ex` | 删除 `backwire_neighbors/3`、`build_neighbors/1`、全部 `:sys.replace_state/2` 邻居连线逻辑 |
| `runtime/lib/esr/entity/pty_process.ex` | 删除 `rewire_session_siblings/1`、`patch_neighbor_in_state/3`、延迟 rewire 触发；从 state 移除 `:neighbors` |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | 将 `Keyword.get(state.neighbors, ...)` 替换为 `ActorQuery.list_by_role/2` |
| `runtime/lib/esr/plugins/claude_code/cc_process.ex` | 将 `find_chat_proxy_neighbor/1` 替换为 `find_reply_target/1` |
| `runtime/lib/esr/entity/agent/instance_registry.ex` | 新增 `add_instance_and_spawn/1`、`remove_instance_and_stop/2` |
| `runtime/lib/esr/entity/factory.ex` | `spawn_peer/5` → `spawn_peer/4`（移除 `neighbors` 参数） |
| `runtime/lib/esr/commands/session/add_agent.ex` | 调用 `add_instance_and_spawn` 替代 `add_instance` |
| `runtime/lib/esr/scope.ex` | 在 per-session `init/1` 中增加 `Esr.Scope.AgentSupervisor` 子进程 |

### M-3 至 M-5 阶段文件

由下一个子 Agent 在 M-3、M-4、M-5 中补充。

---

## M-1 阶段：Esr.ActorQuery + Registry 索引（纯增量）

**依赖：** 无，规范批准后可立即开始。

**目标：** 在不修改任何现有调用路径的前提下，添加三索引 Registry 和 `Esr.ActorQuery` 模块。M-1 合并后，`state.neighbors` 仍然存在，所有已有路径不受影响。M-1 是 M-2 的前置条件。

**LOC 估算：** +250

**风险：** 低——纯增量，现有测试无法因此失败。

**完成门控（Invariant Test）：** M-1 完成后，在同一个测试进程中先调用 `Esr.Entity.Registry.register_attrs/2`，紧接着调用 `Esr.ActorQuery.find_by_name/2`，必须返回 `{:ok, pid}`。该测试绿色才可声明 M-1 完成。

---

### M-1.1 任务：新建 `Esr.ActorQuery` 模块

**文件：** `runtime/lib/esr/actor_query.ex`（新建）

采用标准 5 步 TDD：

1. 编写失败测试（见 EN 版完整测试代码）
2. 确认测试失败：`Esr.ActorQuery` 模块不存在
3. 实现三个函数：`find_by_name/2`、`list_by_role/2`、`find_by_id/1`
4. 确认测试通过
5. 运行 `mix test` 确认无回归

**关键决策（Q5.1）：** 严禁谓词 DSL、scope 枚举、多属性查询语言。三个函数对应三种实际访问模式，不做任何扩展。

`find_by_name/2` 查询 `:esr_actor_name_index`（`:set` 表，唯一性由 `:ets.insert_new/2` 保证）。

`list_by_role/2` 查询 `:esr_actor_role_index`（`:bag` 表，支持同 role 多实例）。

`find_by_id/1` 委托给 `Esr.Entity.Registry.lookup/1`（Index 1，actor_id → pid）。

---

### M-1.2 任务：为 `Esr.Entity.Registry` 添加 `(session_id, name) → pid` 索引

**文件：** `runtime/lib/esr/entity/registry.ex`（修改）

新增两个函数：

- `register_attrs/2`：写入 Index 2（name）和 Index 3（role）；使用 `:ets.insert_new/2` 保证 name 唯一性；调用 `Process.monitor(self())` 后立即通知 `IndexWatcher` 追踪 DOWN 事件
- `deregister_attrs/2`：从 Index 2 删除 name 条目；从 Index 3 删除匹配 pid+actor_id 的条目；幂等操作

**关键点：** `register_attrs/2` 只能由 peer 进程自身调用（`self()` == 注册者）。返回 `{:error, :name_taken}` 时，Index 3 不写入。

---

### M-1.3 任务：ETS 表创建 + `(session_id, role) → [pid]` 索引（bag 表）

**文件：** `runtime/lib/esr/application.ex`（修改）

在 `Esr.Entity.Registry` 子进程之前，增加两个 ETS 表创建子进程：

- `:esr_actor_name_index`：`[:named_table, :set, :public, read_concurrency: true]`
- `:esr_actor_role_index`：`[:named_table, :bag, :public, read_concurrency: true]`

使用 `spawn_link` 进程作为表所有者（与 `NameIndex` 模式一致）。

---

### M-1.4 任务：`IndexWatcher` GenServer — 进程崩溃时自动清理 Index 2 + 3

**文件：** `runtime/lib/esr/entity/registry/index_watcher.ex`（新建）

**职责：** 接收 `register_attrs/2` 设置的 monitor 的 DOWN 消息；收到 DOWN 后从 Index 2 和 Index 3 删除对应条目。

内部维护 `monitors :: %{reference() => metadata}` 映射，O(1) per-DOWN 清理。

**Invariant：** 进程死亡后 200ms 内，Index 2 和 Index 3 中对应条目必须消失（测试使用 `Process.sleep(200)` 验证）。

---

### M-1.5 任务：向三个 peer 模块添加 `@role` 常量 + `register_attrs` / `deregister_attrs` 调用

**文件：** `pty_process.ex`、`cc_process.ex`、`feishu_chat_proxy.ex`

每个 peer 模块：

1. 添加 `@role :<role_atom>` 编译期常量
2. 在 `init/1` 末尾（现有 Entity.Registry.register 调用之后）添加 `register_attrs` 调用，包裹在 `try/catch` 中（保证测试环境下 ETS 表未启动时不崩溃）
3. 新增 `terminate/2`，调用 `deregister_attrs`

actor_id 使用与 Index 1 相同的字符串（`"pty:" <> sid`、`"cc:" <> sid`、`"thread:" <> session_id`）。

name 从 args 中取，若无则使用默认值（`"pty-" <> sid` 等）。

---

### M-1.6 任务：PR + admin-merge

提交所有 M-1 文件，PR 标题：`feat(m-1): Esr.ActorQuery + Registry indexes — additive`

Admin-merge：`gh pr merge --admin --squash --delete-branch`

---

## M-2 阶段：迁移调用方 + 删除 state.neighbors + per-session DynSup + 原子 add-agent

**依赖：** M-1 已合并到 `dev`。

**目标：** 完成从 `state.neighbors` 到 `ActorQuery` 的全面迁移；删除 `backwire_neighbors` 和 `rewire_session_siblings`；添加 per-session `AgentSupervisor`；让 `/session:add-agent` 真正生成活跃 BEAM 进程。

**LOC 估算：** -200 net

**风险：** 高——同时修改四个热路径 peer 模块。每模块一个 commit，每次提交后运行 `mix test`。PR 保持草稿状态直到四个模块均独立通过审查。

**完成门控（Invariant Test）：** 调用 `InstanceRegistry.add_instance_and_spawn/1` 返回 `{:ok, _}` 后，立即调用 `Esr.ActorQuery.find_by_name/2` 必须返回 `{:ok, pid}`——不允许 `:not_found`。

---

### M-2.1 任务：迁移 `feishu_chat_proxy.ex` — 替换 `Keyword.get(state.neighbors, ...)`

**影响行：**
- 第 63 行：删除 `neighbors: Map.get(args, :neighbors, [])` 字段
- 第 666 行：`Keyword.get(state.neighbors, :cc_process)` → `Esr.ActorQuery.list_by_role(state.session_id, :cc_process)`
- 第 711 行：`Keyword.get(state.neighbors, :feishu_app_proxy)` → `Esr.ActorQuery.list_by_role(state.session_id, :feishu_app_proxy)`

```elixir
# 迁移后 — 第 666 行附近
case Esr.ActorQuery.list_by_role(state.session_id, :cc_process) do
  [pid | _] -> send(pid, envelope); state
  []        -> Logger.warning("..."); state
end

# 迁移后 — 第 711 行附近
case Esr.ActorQuery.list_by_role(state.session_id, :feishu_app_proxy) do
  [pid | _] -> GenServer.call(pid, {:send_msg, payload})
  []        -> :error
end
```

---

### M-2.2 任务：迁移 `cc_process.ex` — 替换 `find_chat_proxy_neighbor`

**影响行：**
- 第 17 行：删除 `:neighbors` 字段文档
- 第 110 行：删除 `neighbors: Map.get(args, :neighbors, [])` 字段
- 第 374–414 行：删除 `find_chat_proxy_neighbor/1`；替换两处 `Keyword.get(state.neighbors, ...)` 调用

```elixir
# 迁移后 — 新增私有函数
defp find_reply_target(session_id) do
  case Esr.ActorQuery.list_by_role(session_id, :feishu_chat_proxy) do
    [pid | _] -> {:ok, pid}
    [] ->
      case Esr.ActorQuery.list_by_role(session_id, :cc_proxy) do
        [pid | _] -> {:ok, pid}
        []        -> :not_found
      end
  end
end
```

---

### M-2.3 任务：删除 `agent_spawner.ex` 中的 `backwire_neighbors` 逻辑

**删除内容：**
- 第 263–282 行：backwire 设计说明注释块
- 第 308 行：`:ok = backwire_neighbors(refs, proxies, params)` 调用点
- 第 342–395 行：`defp backwire_neighbors/3` 完整实现（含 `:sys.replace_state/2` 循环）
- 第 420–430 行：`neighbors = build_neighbors(refs_acc)` 局部变量 + 传给 `spawn_peer` 的参数
- 第 457–470 行：`defp build_neighbors/1`

同步删除 `agent_spawner_test.exs` 中的对应测试，标注：`# deleted in M-2 — replaced by spawn-via-InstanceRegistry tests in M-5`

---

### M-2.4 任务：删除 `pty_process.ex` 中的 `rewire_session_siblings`

**删除内容：**
- 第 116 行：`neighbors: Map.get(args, :neighbors, [])` 字段
- 第 138–145 行：`Process.send_after(self(), :rewire_siblings, 50)` 延迟触发块
- 第 317–324 行：`handle_downstream(:rewire_siblings, state)` 子句
- 第 329–355 行：`def rewire_session_siblings/1`（含两个 clause）
- 第 357–367 行：`defp patch_neighbor_in_state/3`

`handle_downstream/2` 的 catch-all 子句（line 326）保留，其他 downstream 消息仍需处理。

---

### M-2.5 任务：审计三个 peer 模块中不存在 `state.neighbors` 残留

执行 grep 确认零结果：

```bash
grep -rn "state\.neighbors\|Keyword\.get.*neighbors\|:sys\.replace_state.*neighbors" \
  runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/entity/pty_process.ex \
  runtime/lib/esr/session/agent_spawner.ex
```

添加静态回归测试（见 EN 版 `Esr.M2.NoNeighborsFieldTest`）。

---

### M-2.6 任务：添加 per-session `Esr.Scope.AgentSupervisor`

**新增文件：**
- `runtime/lib/esr/scope/agent_supervisor.ex`：DynamicSupervisor，`add_agent_subtree/2` 方法负责启动 agent 实例子树
- `runtime/lib/esr/scope/agent_instance_supervisor.ex`：`:one_for_all` Supervisor，包含 CC + PTY 两个子进程；`max_restarts: 3, max_seconds: 60`

**修改文件：** `runtime/lib/esr/scope.ex` — 在 `init/1` 的 children 列表中增加 `AgentSupervisor` 子进程，通过 `{:via, Registry, {Esr.Scope.Registry, {:agent_sup, sid}}}` 注册。

**会话树结构（M-2 后）：**

```
Esr.Scope.Supervisor (DynamicSupervisor)
└── Esr.Scope (per-session, :one_for_all)
    ├── Esr.Scope.Process
    ├── :peers DynamicSupervisor (FCP、SlashHandler 等基础 peer)
    └── Esr.Scope.AgentSupervisor (DynamicSupervisor)
        └── Esr.Scope.AgentInstanceSupervisor (Supervisor, :one_for_all)
            ├── Esr.Entity.CCProcess (instance "helper-A")
            └── Esr.Entity.PtyProcess (instance "helper-A")
```

---

### M-2.7 任务：原子 `InstanceRegistry.add_instance_and_spawn/1`

**文件：** `runtime/lib/esr/entity/agent/instance_registry.ex`（修改）

新增 `add_instance_and_spawn/1` GenServer call，内部串行执行：

1. ETS 唯一性检查（`ets.lookup`）
2. 生成 cc_actor_id + pty_actor_id（UUID v4）
3. 调用 `Esr.Scope.AgentSupervisor.add_agent_subtree/2` 启动 CC+PTY 子树
4. 从 `Supervisor.which_children/1` 提取 CC pid 和 PTY pid
5. 写入 InstanceRegistry ETS 记录

失败回滚：若第 3 步失败，删除 `:esr_actor_name_index` 中的占位条目，返回 `{:error, {:spawn_failed, reason}}`。

---

### M-2.8 任务：更新 `add_agent.ex` + PR + admin-merge

将 `add_agent.ex` 中的 `InstanceRegistry.add_instance(...)` 替换为 `InstanceRegistry.add_instance_and_spawn(...)`，更新返回值包含 `actor_ids`。

运行完成门控 Invariant Test：

```bash
mix test runtime/test/esr/entity/agent/instance_registry_spawn_test.exs
```

提交所有 M-2 文件，PR 标题：`feat(m-2): migrate callers to ActorQuery + delete state.neighbors + per-session AgentSupervisor + atomic add-agent`

Admin-merge：`gh pr merge --admin --squash --delete-branch`

---

## M-3 阶段：删除 legacy diffusion

**依赖：** M-2 已合并到 `dev`。

**目标：** 删除整个 `workspace.neighbors` / `reachable_set` / `describe_topology` / `symmetric_closure` 代码面。本阶段所有操作均为纯删除——不引入任何替代代码。M-3 完成后，LLM 不再接收 `<reachable>` prompt 元素（后续设计见 §12 F-1 和 F-4，不在 M-3 范围内）。

**LOC 估算：** -488（实际值；见规范 §7 注释，超出 brainstorm 阶段 -300 估算的原因说明）

**风险：** 中——`cc_process.ex` 的 `reachable_set` 变更分散在 `handle_info`、`handle_cast` 和多个私有函数中。每个删除点需逐一确认。每次编辑后使用 `mix compile --force` 确认无悬空引用。

**完成门控（Invariant Test）：** M-3 完成后，`grep -rn "Esr.Topology\|reachable_set\|describe_topology\|build_initial_reachable_set\|neighbor_workspaces" runtime/lib/` 必须返回零结果。

---

### M-3.1 任务：删除 `runtime/lib/esr/topology.ex`（整文件，257 LOC）

**文件：** `runtime/lib/esr/topology.ex`（删除）、`runtime/test/esr/topology_test.exs`（删除）、`runtime/test/esr/topology_integration_test.exs`（删除）

标准 5 步 TDD：

1. 编写门控测试：`grep -rn "Esr.Topology" runtime/lib/` 必须返回零结果（在 M-3.2 完成后）
2. 确认 M-3 前测试失败（topology.ex 仍有多处引用）
3. 先确认 M-2 后无残留调用方，再执行 `rm runtime/lib/esr/topology.ex` + 对应测试文件
4. 确认门控测试通过
5. 运行 `mix compile --force` 确认无 `undefined module Esr.Topology` 错误

**提交消息：** `refactor(m-3.1): delete Esr.Topology + topology tests (Phase M-3.1)`

---

### M-3.2 任务：删除 `cc_process.ex` 中的 `reachable_set`（~145 LOC）

**文件：** `runtime/lib/esr/plugins/claude_code/cc_process.ex`

**删除内容（对应规范 §7 M-3 清单）：**
- 第 87–103 行：reachable_set 播种注释块 + `initial_reachable = build_initial_reachable_set(proxy_ctx)` 调用
- 第 115 行：state map 中的 `reachable_set: initial_reachable`
- 第 119–145 行：`defp build_initial_reachable_set/1`（调用 `Esr.Topology.initial_seed/3` 等）
- 第 205–220 行：向 `reachable_set` 添加 URI 的 `handle_info` 子句
- 第 240–248 行：meta handler 中的 `reachable_set` 变更
- 第 428–438 行：`reachable_present` 日志行 + 注释
- 第 498–538 行：`maybe_put_reachable/2` + `reachable_json/1`
- 第 592–621 行：PR-C C4 handler（URI union 进 `state.reachable_set`）+ `user_uri/1`

从下到上依次删除，避免行号偏移干扰。`cc_process_test.exs` 中对应测试用 `# deleted in M-3` 注释替代。

```elixir
# 门控测试（新建 cc_process_m3_gate_test.exs）
test "cc_process.ex has no reachable_set references after M-3" do
  content = File.read!("runtime/lib/esr/plugins/claude_code/cc_process.ex")
  refute String.contains?(content, "reachable_set")
  refute String.contains?(content, "Esr.Topology")
  refute String.contains?(content, "build_initial_reachable_set")
end
```

**提交消息：** `refactor(m-3.2): delete cc_process reachable_set + Topology calls (~145 LOC) (Phase M-3.2)`

---

### M-3.3 任务：删除 `describe.ex` 中的 `neighbor_workspaces`（~32 LOC）

**文件：** `runtime/lib/esr/resource/workspace/describe.ex`

**删除内容：**
- 第 61–66 行：`neighbours = resolve_neighbour_workspaces(...)` + `"neighbor_workspaces" => ...` map 条目
- 第 122–123 行：`base_neighbors = legacy_neighbors(ws)` 局部变量
- 第 164–170 行：`defp legacy_neighbors/1`
- 第 175–191 行：`defp resolve_neighbour_workspaces/2`

`workspace_describe_test.exs` 中对应 `neighbor_workspaces` 断言用 `# deleted in M-3` 注释替代。

**提交消息：** `refactor(m-3.3): delete neighbor_workspaces output + legacy_neighbors from describe.ex (Phase M-3.3)`

---

### M-3.4 任务：删除 `server.ex` 中的 `describe_topology`（~22 LOC）

**文件：** `runtime/lib/esr/entity/server.ex`

**删除内容：**
- 第 284–291 行：PR-F 注释块 + `if tool == "describe_topology" or ...` 旁路条件（简化为 `if capability_granted?(...)`）
- 第 820–833 行：`defp build_emit_for_tool("describe_topology", args, _state)` 完整私有函数

`entity_server_describe_topology_test.exs` 中 topology 相关断言用 `# deleted in M-3` 注释替代。

**提交消息：** `refactor(m-3.4): delete describe_topology MCP tool + cap bypass from server.ex (Phase M-3.4)`

---

### M-3.5 任务：删除 `mcp/tools.ex` 中的 `@describe_topology`（~29 LOC）

**文件：** `runtime/lib/esr/plugins/claude_code/mcp/tools.ex`

**删除内容：**
- 第 89–115 行：`@describe_topology` 模块属性完整 map 字面量
- 第 124 行：diagnostic role 工具列表中的 `@describe_topology` 引用
- 第 127 行：默认工具列表中的 `@describe_topology` 引用

两处工具列表变更：
```elixir
# diagnostic role — 删除后：
do: [@reply, @send_file, @echo]
# default — 删除后：
do: [@reply, @send_file]
```

**提交消息：** `refactor(m-3.5): delete @describe_topology from mcp/tools.ex (Phase M-3.5)`

---

### M-3.6 任务：从 `registry.ex` 的 `%Workspace{}` struct 删除 `:neighbors` 字段（~3 LOC）

**文件：** `runtime/lib/esr/resource/workspace/registry.ex`

**删除内容：**
- 第 55 行：`defstruct` 中的 `neighbors: []`
- 第 587 行：`to_legacy/1` 中的 `neighbors: Map.get(ws.settings, "_legacy.neighbors", [])`
- 第 604 行（约）：`normalize_to_struct/1` 中的 `"_legacy.neighbors" => legacy.neighbors || []`

注：`to_legacy/1` 和 `normalize_to_struct/1` 函数本体在 M-3 中保留，整体删除留待 M-4。

M-3 全阶段最终门控扫描：

```bash
grep -rn "Esr.Topology\|reachable_set\|describe_topology\|build_initial_reachable_set\|neighbor_workspaces" runtime/lib/
# 必须返回零结果
mix compile --force && mix test
```

**提交消息：** `refactor(m-3.6): remove :neighbors field from %Workspace{} + _legacy.neighbors reads (Phase M-3.6)`

---

### M-3.7 任务：PR + admin-merge

```bash
git rm runtime/lib/esr/topology.ex runtime/test/esr/topology_test.exs \
        runtime/test/esr/topology_integration_test.exs
git add runtime/lib/esr/plugins/claude_code/cc_process.ex \
        runtime/lib/esr/resource/workspace/describe.ex \
        runtime/lib/esr/entity/server.ex \
        runtime/lib/esr/plugins/claude_code/mcp/tools.ex \
        runtime/lib/esr/resource/workspace/registry.ex \
        runtime/test/esr/plugins/claude_code/cc_process_test.exs \
        runtime/test/esr/m3_topology_dead_code_test.exs \
        # ... 其余门控测试文件
```

PR 标题：`feat(m-3): delete legacy diffusion — Topology + reachable_set + describe_topology + neighbor_workspaces`

Admin-merge：`gh pr merge --admin --squash --delete-branch`

---

## M-4 阶段：删除 `_legacy.*` compat shim + legacy `%Workspace{}` struct

**依赖：** M-3 已合并到 `dev`。

**目标：** 删除整个 `@legacy_table` ETS 基础设施、`%Workspace{}` legacy 内嵌 struct、`to_legacy/1`、`normalize_to_struct/1`、`do_put(%Workspace{})` 子句，以及所有读取 `_legacy.*` key 的调用方。M-4 完成后，代码库中不再有 `_legacy.*` key 读取，不再有双表 workspace 存储。`registry.ex` 从约 678 LOC 缩减至约 539 LOC。

**LOC 估算：** -263（纯删除）；含 caller 中的级联死代码约 -400

**风险：** 中——`workspace_for_chat/2` 内部使用 `@uuid_table`（不是 `@legacy_table`），M-4 不影响其行为，8 处调用方无需修改。在 PR 描述中明确注明。4 处 `Registry.get/1` 调用方须先迁移至 `NameIndex.id_for_name + get_by_id`（M-4.1），再删除 `get/1`。

**完成门控（Invariant Test）：** `grep -rn "@legacy_table\|_legacy\.\|defmodule Workspace\b\|normalize_to_struct\|to_legacy\|start_cmd_for" runtime/lib/` 必须返回零结果。

---

### M-4.1 任务：迁移 4 处 `Registry.get/1` 调用方至 `NameIndex.id_for_name + get_by_id`

**文件及行号：**
- `runtime/lib/esr/resource/workspace/bootstrap.ex:44` — `Registry.get("default")`
- `runtime/lib/esr/resource/capability/file_loader.ex:157` — `Registry.get(name)`
- `runtime/lib/esr/plugins/claude_code/cc_process.ex:565` — `Registry.list()`（枚举所有 workspace）
- `runtime/lib/esr/commands/doctor.ex:57` — `Registry.list()`（仅用于计数）

先确认迁移目标路径功能等价（migration test），再逐一替换：

```elixir
# bootstrap.ex — 迁移后
defp ensure_default_workspace do
  case NameIndex.id_for_name(:esr_workspace_name_index, "default") do
    nil  -> create_default_workspace()
    uuid -> case Registry.get_by_id(uuid) do
              {:ok, _} -> :ok
              :error   -> create_default_workspace()
            end
  end
rescue
  _ -> :ok
end

# doctor.ex — 迁移后（仅计数）
workspace_count =
  try do
    Esr.Resource.Workspace.NameIndex.all(:esr_workspace_name_index) |> length()
  rescue
    _ -> 0
  end
```

完成后验证：

```bash
grep -rn "Registry\.get\b\|Registry\.list()" \
  runtime/lib/esr/resource/workspace/ \
  runtime/lib/esr/resource/capability/ \
  runtime/lib/esr/plugins/claude_code/cc_process.ex \
  runtime/lib/esr/commands/doctor.ex
# 必须返回零结果（Registry 模块自身除外）
```

**提交消息：** `refactor(m-4.1): migrate 4 Registry.get/list callers to NameIndex + get_by_id (Phase M-4.1)`

---

### M-4.2 任务：删除 `defmodule Workspace` legacy 内嵌 struct（~20 LOC）

**文件：** `runtime/lib/esr/resource/workspace/registry.ex` 第 41–60 行

删除 `defmodule Workspace do ... end` 整块（含 `@moduledoc`、`defstruct`、`@type t`）。

门控测试：

```elixir
test "Esr.Resource.Workspace.Registry.Workspace module does not exist after M-4" do
  refute Code.ensure_loaded?(Esr.Resource.Workspace.Registry.Workspace)
end
```

**提交消息：** `refactor(m-4.2): delete %Workspace{} legacy embedded struct from registry.ex (Phase M-4.2)`

---

### M-4.3 任务：删除 `@legacy_table` + `to_legacy/1` + `normalize_to_struct/1` + `start_cmd_for/2`

**文件：** `runtime/lib/esr/resource/workspace/registry.ex`

**按从下到上顺序删除：**
1. `defp normalize_to_struct/1`（592–615 行）
2. `defp to_legacy/1`（563–590 行）
3. `def start_cmd_for/2` 两个 clause + `@spec`（177–195 行）
4. legacy `get/1` clause（127–135 行）
5. legacy `list/0` 从 `@legacy_table` 读取的 clause（139 行）
6. 所有 `:ets.insert(@legacy_table, ...)` 调用（373, 487, 513, 538, 539 行）
7. `:ets.delete(@legacy_table, ...)` 调用（342, 485, 538 行）
8. `:ets.delete_all_objects(@legacy_table)` in clear（357 行）
9. `@legacy_table :esr_workspaces` 声明（63 行）
10. `init/1` 中创建 `@legacy_table` ETS 表的代码块（237–239 行）

保留：`@uuid_table`、所有 `@uuid_table` ETS 操作、`workspace_for_chat/2`、`get_by_id/1`、`NameIndex` 相关操作。

门控测试（file content 断言，见 EN 版 `registry_m4_legacy_deleted_test.exs`）。

**提交消息：** `refactor(m-4.3): delete @legacy_table ETS + to_legacy/1 + normalize_to_struct/1 + start_cmd_for/2 from registry.ex (Phase M-4.3)`

---

### M-4.4 任务：删除 `do_put(%Workspace{})` clause（~21 LOC）

**文件：** `runtime/lib/esr/resource/workspace/registry.ex` 第 495–515 行

`do_put(%Workspace{} = legacy)` clause 在 M-4.3 中 `normalize_to_struct/1` 已删除后将无法编译。在同一个 commit 或紧接其后的 commit 中删除该 clause。保留 `do_put(%Struct{} = ws)` clause。

**提交消息：** `refactor(m-4.4): delete do_put(%Workspace{}) legacy clause from registry.ex (Phase M-4.4)`

---

### M-4.5 任务：删除 `info.ex` 中的 `lookup_legacy/1` + `build_legacy_result/1` + `_legacy.*` 读取（~111 LOC）

**文件：** `runtime/lib/esr/commands/workspace/info.ex`

**删除内容：**
- 第 26–35 行：result map 中 `"role"`、`"neighbors"`、`"metadata"` 字段（来源于 `_legacy.*`）
- 第 78 行：`{:ok, build_legacy_result(w)}` → 替换为 Struct 路径 result 构建
- 第 104–106 行：`ArgumentError -> lookup_legacy(ws_name)` rescue clause
- 第 107–167 行：`defp lookup_legacy/1`
- 第 167–200 行：`defp build_legacy_result/1`

删除后 `info.ex` 的 with pipeline 返回结构：

```elixir
{:ok, %{
  "id"             => ws.id,
  "name"           => ws.name,
  "settings"       => ws.settings
    |> Enum.reject(fn {k, _} -> String.starts_with?(k, "_legacy.") end)
    |> Map.new(),
  "workspace_path" => ws.workspace_path
}}
```

更新 `info_test.exs`：删除对 `"role"`、`"neighbors"`、`"metadata"` 字段的断言；更新期望 response shape。

**提交消息：** `refactor(m-4.5): delete lookup_legacy + _legacy.* reads from info.ex (Phase M-4.5)`

---

### M-4.6 任务：删除 `describe.ex` 中的 `legacy_metadata/1` + `_legacy.role` 读取（~13 LOC）

**文件：** `runtime/lib/esr/resource/workspace/describe.ex`

**删除内容：**
- 第 123 行：`base_metadata = legacy_metadata(ws)` 局部变量
- 第 134–136 行：`"role" => Map.get(ws.settings, "_legacy.role", "dev")` 条目
- 第 ~135 行：`"_legacy.metadata"` 读取
- 第 168–174 行：`defp legacy_metadata/1`

产品决策：M-4 后 describe 输出不再包含 `"role"` 字段（工作区级 role 概念随 M-4 一并移除；如需后续支持见 §12 F-2）。

**提交消息：** `refactor(m-4.6): delete legacy_metadata + _legacy.role/_legacy.metadata reads from describe.ex (Phase M-4.6)`

---

### M-4.7 任务：PR + admin-merge

最终 M-4 门控扫描：

```bash
grep -rn "@legacy_table\|_legacy\.\|defmodule Workspace\b\|normalize_to_struct\|to_legacy\|start_cmd_for\|lookup_legacy\|build_legacy_result" runtime/lib/
# 必须返回零结果
mix compile --force && mix test
```

PR 标题：`feat(m-4): delete _legacy.* compat shim + %Workspace{} legacy struct + 4 caller migrations`

PR 描述注明：`workspace_for_chat/2` 内部使用 `@uuid_table`（已在 `registry.ex:149–175` 确认），8 处调用方无需修改。

Admin-merge：`gh pr merge --admin --squash --delete-branch`

---

## M-5 阶段：测试 + e2e sweep

**依赖：** M-4 已合并到 `dev`。

**目标：** 重写覆盖已删除代码的所有测试；扩充 ActorQuery 和 InstanceRegistry 测试套件；新增 e2e scenario 18（多 CC 会话生命周期）；重写或删除 topology e2e 场景。

**LOC 估算：** +200 / -100

**风险：** 低——仅修改测试，无生产代码变更。

**完成门控（Invariant Test）：**
- `bash tests/e2e/18_multi_cc_session.sh` 退出码为 0
- ActorQuery 集成测试全部通过
- `grep -rn "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces" runtime/test/` 返回零可调用代码（`# deleted in M-X` 注释可接受）

---

### M-5.1 任务：删除现有测试文件中的过时测试块

**目标文件：**

```bash
grep -rln "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces" runtime/test/
```

**处理原则：**

- `agent_spawner_test.exs`：删除 `backwire_neighbors`、`:sys.replace_state` 邻居补丁测试；添加 spawn-via-InstanceRegistry 测试（见 EN 版完整测试代码）
- `pty_process_test.exs`：删除 `rewire_session_siblings`、`patch_neighbor_in_state` 测试
- `cc_process_test.exs`：将 M-3.2 的 `# deleted in M-3` 注释整理为正式测试脚手架
- `entity_server_describe_topology_test.exs`：若仅测试 `describe_topology`，整文件删除；若包含其他 server 测试，保留非 topology 部分

**新增两个 spawner 测试（重要）：**

```elixir
test "spawned agent is findable via ActorQuery.find_by_name immediately after add_instance_and_spawn" do
  sid = "spawner-m5-#{System.unique_integer([:positive])}"
  name = "test-agent-#{System.unique_integer([:positive])}"
  {:ok, _result} = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(%{
    session_id: sid, agent_name: name, agent_type: :cc
  })
  assert {:ok, pid} = Esr.ActorQuery.find_by_name(sid, name)
  assert Process.alive?(pid)
end

test "spawn failure leaves no orphan in name index" do
  sid = "spawner-rollback-#{System.unique_integer([:positive])}"
  name = "rollback-agent-#{System.unique_integer([:positive])}"
  {:error, _} = Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn(%{
    session_id: sid, agent_name: name, agent_type: :nonexistent_type
  })
  assert :not_found == Esr.ActorQuery.find_by_name(sid, name)
  assert [] == Esr.ActorQuery.list_by_role(sid, :cc_process)
end
```

**提交消息：** `test(m-5.1): delete obsolete backwire/rewire/reachable_set tests + add spawn-via-InstanceRegistry tests (Phase M-5.1)`

---

### M-5.2 任务：更新测试中对 `%Workspace{}` legacy struct 的模式匹配

```bash
grep -rln "%Esr.Resource.Workspace.Registry.Workspace{" runtime/test/
```

逐一将 `%Esr.Resource.Workspace.Registry.Workspace{...}` 替换为 `%Esr.Resource.Workspace.Struct{...}`，或删除专门测试 `to_legacy/normalize_to_struct` 的测试块（这两个函数已在 M-4 删除）。

添加门控测试：

```elixir
# m5_no_legacy_struct_test.exs
test "no test file references legacy Workspace embedded struct after M-5" do
  {output, _} = System.cmd("grep", ["-rln",
    "%Esr.Resource.Workspace.Registry.Workspace{", "runtime/test/"])
  assert output == ""
end
```

**提交消息：** `test(m-5.2): migrate legacy %Workspace{} struct refs in tests to %Struct{} (Phase M-5.2)`

---

### M-5.3 任务：扩充 `Esr.ActorQuery` 集成测试

**文件：** `runtime/test/esr/actor_query_test.exs`（在 M-1 基础上扩充）

按规范 §10 ActorQuery 单测表补充以下 test case：

- `find_by_name/2` — deregister 后返回 `:not_found`
- `find_by_name/2` — 进程崩溃后（monitor DOWN 清理）返回 `:not_found`（`Process.sleep(200)` 验证）
- `list_by_role/2` — 同 role 两个实例返回长度为 2 的列表
- `list_by_role/2` — 一个实例崩溃后返回长度为 1 的列表
- `find_by_id/1` — 进程退出后返回 `:not_found`

完整测试代码见 EN 版 M-5.3 任务。

**提交消息：** `test(m-5.3): extend ActorQuery integration tests — crash cleanup + multi-instance (Phase M-5.3)`

---

### M-5.4 任务：重写或删除 e2e topology 场景

**目标：**

```bash
grep -n "describe_topology\|neighbor_workspaces" \
  tests/e2e/05_topology_routing.sh \
  tests/e2e/04_multi_app_routing.sh
```

**决策标准（对应规范 §9 R-3）：**
- `05_topology_routing.sh` — 仅测试 `describe_topology` 响应 shape 和 `neighbor_workspaces` 内容：**整文件删除** `rm tests/e2e/05_topology_routing.sh`
- `04_multi_app_routing.sh` — 若有 `neighbor_workspaces` 断言：删除该断言块，保留多 app 路由断言

删除后门控检查：

```bash
grep -rn "describe_topology\|neighbor_workspaces" tests/e2e/
# 必须返回零结果
```

**提交消息：** `test(m-5.4): delete 05_topology_routing.sh + strip neighbor_workspaces from 04_multi_app_routing.sh (Phase M-5.4)`

---

### M-5.5 任务：新增 e2e scenario 18 — 多 CC 会话生命周期

**文件：** `tests/e2e/18_multi_cc_session.sh`（新建）

镜像 scenario 14 模式（post-PR-249），完整脚本见 EN 版 M-5.5 任务。

**6 个验证步骤：**

1. `/session:new` → 断言 `list_by_role(..., :cc_process) == []`
2. `/session:add-agent name=helper-A type=cc` → 断言 `find_by_name` 返回 `{:ok, pid_a}`；`list_by_role` 长度为 1
3. `/session:add-agent name=helper-B type=cc` → 断言 `pid_a != pid_b`；`list_by_role` 长度为 2；**agent-browser 截图（PTY 终端显示两个 CC agent）**
4. `@helper-A ping` → 断言路由至 `actor_id_a`，**不**路由至 `actor_id_b`；**agent-browser 截图（Feishu 中 helper-A 回复）**
5. `/session:remove-agent name=helper-A` → 断言 `find_by_name` 返回 `:not_found`；`pid_a` 进程不再存活
6. `/session:end` → 断言 `list_by_role` 返回 `[]`；`pid_b` 进程不再存活

截图保存路径：`tests/e2e/screenshots/18_step3_two_agents.png` 和 `18_step4_mention_routing.png`。

根据项目 e2e 标准（`feedback_esr_e2e_standards.md`），上述两张 agent-browser 截图是 M-5 完成的必要条件。

**提交消息：** `test(m-5.5): add e2e scenario 18 — multi-CC session lifecycle + @mention routing (Phase M-5.5)`

---

### M-5.6 任务：PR + admin-merge

最终 M-5 门控扫描：

```bash
# 测试代码零引用（注释除外）：
grep -rn "backwire\|rewire_session_siblings\|reachable_set\|neighbor_workspaces\|describe_topology" \
  runtime/test/

# 零 legacy struct pattern：
grep -rln "%Esr.Resource.Workspace.Registry.Workspace{" runtime/test/

# scenario 18 通过：
bash tests/e2e/18_multi_cc_session.sh

# 单元测试全绿：
mix test
```

PR 标题：`feat(m-5): tests + e2e sweep + scenario 18 multi-CC session lifecycle`

Admin-merge：`gh pr merge --admin --squash --delete-branch`

验证：`git log --oneline dev | head -5` — M-1 至 M-5 全部 5 个提交可见。

---

<!-- PLAN_COMPLETE — all 5 phases planned -->
