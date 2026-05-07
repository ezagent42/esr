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

<!-- PLAN_END_M2 — next subagent: append "## Phase M-3" here -->
