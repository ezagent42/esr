# Session 创建时默认 agent + agent 驱动后续操作

**Status:** Draft rev-2 —— 待 linyilun 批准（2026-05-11）
**Date:** 2026-05-11
**Author:** Claude（与 linyilun 协作）
**Companion:** [`.md`](2026-05-11-default-agent-and-agent-driven-flow-design.md)

Worktree: `.worktrees/fix-unconsumed-msg`，branch `spec/default-agent-and-agent-driven-flow`。

rev-2 改动：subagent 代码 review 找到 7 个 critical mis-grounded claims
（commit `5d81734` → 当前 commit）。本 rev 把所有提议都锚定到 `runtime/lib/`
里可验证的 file:line。

---

## 1. 为什么现在

2026-05-11 linyilun 手动测试：

```
/workspace:use test-dev    → ok: %{"action" => "default_workspace_set", ...}
/session:list              → workspace test-dev: no live sessions
/session:new name=test-cc  → session started: b6bfbe47-...
hello?                     → （无回复，静默 hang）
```

`~/.esrd-dev/default/logs/launchd-stdout.log` 显示 4 步 cascade
（2026-05-11 14:33:41 GMT+8 验证，session `b6bfbe47-91ae-...`）：

1. **PtyProcess 以 `dir: "/tmp"` 启 `claude`**，尽管 `workspace_name:
   "test-dev"` 已设。PtyProcess init 的 `dir: get_param(params, :dir) ||
   "/tmp"`（`runtime/lib/esr/entity/pty_process.ex:80`）silently 走兜底，
   因 `params[:dir]` 是 nil。workspace `test-dev` 是通过 `/workspace:new
   name=test-dev`（无 `folder=`）建的，目前写 `folders: []` + `location:
   {:esr_bound, ...}`（`runtime/lib/esr/commands/workspace/new.ex:119-129`）。
   `/session:new` 的 `resolve_dir_from_workspace/1` 读 `workspace.folders[0].path`
   —— 0-folder 时返回 nil。
2. **`claude` 立即退 256**：
   ```
   Error: Invalid MCP configuration:
   MCP config file not found: /private/tmp/.mcp.json
   ```
   生产 spawn 路径**没人**写 `.mcp.json`。`Esr.Plugins.ClaudeCode.Launcher`
   有 `prepare_spawn/1` 和 `write_mcp_json/1`（`runtime/lib/esr/plugins/
   claude_code/launcher.ex:68-183`）—— **只在测试里调用**。生产 PTY 在
   `runtime/lib/esr/entity/pty_process.ex:202-216` 调 `Launcher.spawn_cmd/1`，
   把 `--mcp-config .mcp.json` 加到 argv 但不写文件。`claude` 读 cwd
   （`/tmp`）找不到 `.mcp.json` → 拒绝启动。
3. **PtyProcess crash** `{:pty_crashed, 256}`。`Esr.Session.AgentInstanceSupervisor`
   （`runtime/lib/esr/session/agent_instance_supervisor.ex`）按 spec Q5.3
   sub-2（2026-05-07）用 `:one_for_all` —— CC+PTY 一致性是对的；CC 也死掉。
   PtyProcess `terminate/2` PubSub 广播 `:pty_closed` 到 topic `pty:<actor_id>`。
4. **FCP 收到 `:pty_closed` 但没匹配 `handle_info/2` clause**。
   `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:162` init 时
   subscribe topic；line 274 无 `:pty_closed` clause。**FunctionClauseError**
   → FCP crash → 它的 supervisor restart → 循环 → `AgentInstanceSupervisor`
   60s 内达 `max_restarts: 3` → 子树 `restart: :transient` terminate（不
   自动重启）。
5. **`:esr_session_chat_routing` ETS entry 仍指向死 FCP pid**。FAA 在
   `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238` 按
   `(chat_id, app_id)` 查表，match 旧形态 `{key, sid, %{feishu_chat_proxy:
   pid}}`，`send(dead_pid, msg)` —— Erlang 静默 no-op。**用户的 `hello?`
   消失。**

**5 个生产 bug 联动：**

| # | Bug | File:line |
|---|---|---|
| **B1** | 0-folder workspace 合法但不可用（数据模型撕裂：`folders: []` + `location: {:esr_bound, ...}`）| `commands/workspace/new.ex:119-129` |
| **B2** | `PtyProcess.init` 没 `:dir` 时兜底 `/tmp` | `entity/pty_process.ex:80` |
| **B3** | `Launcher.prepare_spawn` 和 `write_mcp_json` 死代码 —— 只测试用；生产走 `spawn_cmd` 跳过文件写 | `plugins/claude_code/launcher.ex:68-183` |
| **B4** | FCP 没 `handle_info(:pty_closed, _)` clause | `plugins/feishu/feishu_chat_proxy.ex:274` |
| **B5** | `:esr_session_chat_routing` ETS 双形态共存（`register_session/3` 写 3-tuple 含 refs；`attach_session/3` 写 2-tuple 无 refs）；FAA 用 `other -> Logger.warning + drop` 静默吸收新形态 | `session/chat_routing/registry.ex` + `feishu_app_adapter.ex:270` |

**操作员意图（linyilun, 2026-05-11）：** "session 建立的时候，就默认帮我
创建一个 agent（默认类型是 cc），后续我的操作应该让这个 agent 来帮我完成。
如果我需要添加新的 agent，既可以使用 slash 命令，也可以使用自然语言请主
agent 帮我来操作。"

本 spec 修 B1-B5 + 加自然语言 admin 层。

---

## 2. 术语

继承 `docs/notes/concepts.md`（rev-11）+ `CONTEXT.md`。新增：

| 术语 | 定义 |
|---|---|
| **silent-drop cascade** | §1 描述的 4 步链 —— 单个生产 bug 让 chat 可见的回归 disappear 而无 error 到达操作员 |
| **lifecycle 消息** | 表示状态转换的 PubSub 消息：`:pty_closed`、`:agent_crashed`、`:supervisor_giveup` |
| **effect-level invariant** | 跨 supervisor 的系统级属性（如"无 inbound 静默丢失"）|
| **死代码** | 编译过、测试引用、但生产代码路径永不到达 |

---

## 3. 目标与非目标

### 目标

- `/session:new <name>` 可靠产出 chat → CC 回复闭环
- 每条 chat inbound 在 5 秒内产生 chat 可见的回复或 error —— **没有静默丢失**
- workspace 数据模型 well-formed：每个 workspace ≥1 folder；ESR-bound 模式继续工作但变成真正的 1-folder workspace（不是 0-folder 撕裂状态）
- ESR 暴露 `submit_slash` MCP tool，CC 通过自然语言执行 admin
- 本 rev 所有提议路径都锚定到验证过的真实 API
- 保留 plugin 边界：feishu plugin **不**知道 cc plugin 的 process 类型（linyilun 2026-05-11："feishu 和 cc 是两个独立的 plugin"）

### 非目标

- **不**改 `Esr.Session.AgentInstanceSupervisor` 的 `:one_for_all` —— CC+PTY 一致性 invariant（spec Q5.3 sub-2，2026-05-07）正确。ADR-0002 记录
- **不**重设计 workspace ↔ folder 成 VS Code 风格 —— 按 concepts.md §四，
  Dir 是 Session 引用的 Resource，不被拥有。（2026-05-11 brainstorm 决定）
- **不**给 `submit_slash` 加 rate-limit
- **不**保留 esrd-dev fixture 后向兼容 —— linyilun 2026-05-11："全部都
  可以删掉重建"

---

## 4. Phase A —— silent-drop cascade 修复（PR-1 至 PR-4）

每个子节命名要改的 file:line + 把改动锚定到当前代码 shape。

### 4.1 Workspace folders ≥1 + ESR-bound 当 1-folder（修 B1）—— PR-1

**当前状态**（`commands/workspace/new.ex:119-129`）：
```elixir
location = case folder do
  nil -> {:esr_bound, Esr.Paths.workspace_dir(name)}
  path -> {:repo_bound, path}
end
folders = case folder do
  nil -> []                                  ← 0-folder 撕裂状态
  path -> [%{path: path, name: Path.basename(path)}]
end
```

ESR-bound workspace 的 path 在 `location` 但 `folders` 空。所有下游
（session 创建、dir resolve）读 `folders` → 撕裂状态露出。

**改成：** 统一。两个分支都产生 ≥1 folder workspace；ESR-bound 就用
ESR-managed path 作第一个 folder。

```elixir
folder_path = folder || Esr.Paths.workspace_dir(name)
folders = [%{path: folder_path, name: Path.basename(folder_path)}]
location = case folder do
  nil -> {:esr_bound, folder_path}
  path -> {:repo_bound, path}
end
```

`Esr.Paths.workspace_dir(name)`（ESR-managed 目录）在 workspace 创建时
`File.mkdir_p!`，让 PtyProcess 能 `cd` 进去。

**改动：**
- `runtime/lib/esr/commands/workspace/new.ex` —— body 统一（~20 LOC）
- `runtime/priv/schemas/workspace.v1.json` —— 加 `"folders": { "minItems": 1 }`（~3 LOC）
- `runtime/lib/esr/resource/workspace/json_writer.ex` —— 写入前校验（~15 LOC）
- `runtime/lib/esr/commands/workspace/remove_folder.ex` —— guard：拒绝删最后一个 folder，返回 `:cannot_remove_last_folder`
- 测试（~40 LOC）

**关于 esrd-dev：** 用户 2026-05-11 指示 —— 删 ~/.esrd-dev/ 重建，不需要 migrator。

### 4.2 `Launcher.prepare_spawn` 成唯一 spawn 入口，删 `spawn_cmd`（修 B2 + B3）—— PR-2

**当前**（`plugins/claude_code/launcher.ex:68-183`）：
- `prepare_spawn/1` —— 读 workspace dir、写 `.mcp.json`、build claude argv。**只测试调**。
- `spawn_cmd/1` —— build claude argv 含 `--mcp-config .mcp.json` 但不写文件。**`PtyProcess` 在 `runtime/lib/esr/entity/pty_process.ex:202-216` 调**。

**改成：**

1. **完全删 `Launcher.spawn_cmd/1`。** 把 `entity/pty_process.ex:202-216` 的 caller 改成调 `Launcher.prepare_spawn/1`
2. **`prepare_spawn/1` 成唯一 spawn 入口**，断言（用 `{:ok, _}` / `{:error, _}` 返回，不 `raise`）：
   - `cwd`（workspace folder path）存在为目录
   - `claude` binary 在 PATH
   - `.mcp.json` 成功写到 `session_dir`
   - argv 含 `--mcp-config <session_dir>/mcp.json`（绝对路径）
3. **删 `entity/pty_process.ex:80` 的 `dir || "/tmp"` 兜底。** `dir` 缺失就给 AgentSpawner 返回 `{:error, :missing_dir}`
4. **`.mcp.json` 位置：`$ESRD_HOME/<instance>/sessions/<sid>/mcp.json`**（brainstorm 2026-05-11 定）。新 helper `Esr.Paths.session_mcp_json(sid)`
5. **`.mcp.json` 内容**（按现有 `Launcher.write_mcp_json/1` 验证）：
   ```json
   {
     "mcpServers": {
       "esr-channel": {
         "type": "http",
         "url": "<esrd_http_base>/mcp/<session_id>"
       }
     }
   }
   ```
   `<esrd_http_base>` 来自 `EsrWeb.Endpoint.config(:url)`；path-based session 路由已存在于 `EsrWeb.McpController`（已验证 —— McpHttp Channel 是 PubSub wrapper 不是 per-session port-binding HTTP server）

**改动：**
- `runtime/lib/esr/plugins/claude_code/launcher.ex` —— 删 `spawn_cmd/1`，让 `prepare_spawn/1` 返回 `{:ok, args}` / `{:error, reason}`（~40 LOC）
- `runtime/lib/esr/entity/pty_process.ex:80, :202-216` —— 删兜底、call `prepare_spawn`、透传 error（~30 LOC）
- `runtime/lib/esr/paths.ex` —— 加 `session_mcp_json/1`（~10 LOC）
- `runtime/lib/esr/plugins/claude_code/launcher_test.exs` —— 测试适配（~20 LOC）

### 4.3 SessionTemplate pipeline 完整性检查（plugin 解耦角度）—— PR-2

**用户洞察（2026-05-11）：** "feishu 和 cc 是两个独立的 plugin，最终形态下，
按照 feishu 的用户不一定会安装 cc... 问题出在 SessionTemplate 没有被编译好，
导致这里面环节中出现了 process 被丢失的情况"

原 spec rev-1 想让 FCP monitor CCProcess —— **违反 plugin 解耦**。正确的
架构修复是：**SessionTemplate 的 materializer 在宣告 session ready 前验证
pipeline 完整。**

**当前：** `AgentSpawner.do_create/1`（`runtime/lib/esr/session/
agent_spawner.ex:178-188`）迭代 `pipeline.inbound` 调 `spawn_one/5`
（line 364）。任一 spawn 失败 throw `{:spawn_failed, spec, reason}` 被
catch + 返回。**但是：** throw 清理可能漏掉已 spawn 的中间 peer。

**改成：**
1. `agent_spawner.ex` 把 `spawn_pipeline/3` 包 try/throw，部分失败时调
   `Esr.Session.Router.end_session(sid)` 拆掉已 spawn 的（API 验证位于
   `runtime/lib/esr/session/router.ex:67-69`）
2. 加 post-spawn assertion：**所有 stage 完成后，验证每个声明的 pipeline
   stage 在 per-session `Esr.Entity.Agent.InstanceRegistry` 都有 live pid**。
   任何 stage 缺失 → 拆掉 + 返回 `:pipeline_incomplete`
3. `/session:new` 把 error 以结构化 reply 上浮给操作员，列出哪个 stage 失败

**改动：**
- `runtime/lib/esr/session/agent_spawner.ex` —— wrap + 后置完整性检查（~50 LOC）
- `runtime/lib/esr/commands/session/new.ex` —— 把 `:pipeline_incomplete` 上浮成 chat reply（~10 LOC）
- 测试（~30 LOC）

### 4.4 FCP `:pty_closed` clause（plugin-self-consistent）（修 B4）—— PR-2

FCP init 时 subscribe `pty:<actor_id>` PubSub（验证位于
`feishu_chat_proxy.ex:162`）。加缺失的 clause：

```elixir
@impl GenServer
def handle_info(:pty_closed, state) do
  # 下游 PTY（谁拥有的 FCP 不关心；FCP 不知道具体 agent kind）已 exit。
  # 告诉 chat；让 supervisor 决定 restart。Plugin 边界保留：本 clause 不提 CC。
  notify_chat(state, %{
    kind: :downstream_died,
    message: "agent 进程退出；supervisor 会重启（如有可能）。如重复，运行 " <>
             "/session:end + /session:new 重建"
  })
  {:noreply, state}
end
```

`notify_chat/2` 通过现有 FCP reply 路径构造 chat 回包。消息文本**不**提
"CC" 或 "claude" —— 说"agent process"，保持 plugin neutrality。

**没有 `{:DOWN, _, _, cc_pid, _}` monitor** —— FCP 不知道 cc_process。这是
plugin 解耦的体现。Lifecycle 信号通过 pty PubSub topic 传递，任何 plugin
的 PTY 都能发。

**supervisor giveup 通知：** `AgentInstanceSupervisor` 退出（max_restarts）
时，FCP 不直接观察到 —— `:pty_closed` 每次 PTY 死都触发，不是最终 supervisor
exit。§4.6 的 LifecycleObserver 补这个 gap。

**改动：**
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:274` —— 加 clause（~30 LOC）
- 同文件加 `notify_chat/2` helper（~30 LOC）
- 测试（~40 LOC）

### 4.5 ChatRouting：删 legacy register_session，统一到 attach（修 B5）—— PR-3

**当前**（`session/chat_routing/registry.ex`）：
- `register_session/3`（line 63）—— 单 caller `agent_spawner.ex:460`，写 ETS `{(chat_id, app_id), sid, peer_refs}`（3-tuple 含 refs）
- `attach_session/3`（line 74）—— `/session:bind-chat` 等，写 ETS `{(chat_id, app_id), %{current: sid, attached: [...]}}`（2-tuple 无 refs）
- `lookup_by_chat/2` 返回三种 shape；FAA 匹配旧形态，新形态走 `other -> drop`

这是双形态 ETS bug class。而且 API 名 `register_session` 是 leaky abstraction
—— 它只是"写一行"，被包装成有语义意义的命名。

**改成：** 删 legacy。一种 ETS shape，一种 API。

1. **删 registry 模块的 `register_session/3` 和 `unregister_session/1`**
2. **迁移单 caller** `agent_spawner.ex:460` 改用 `attach_session(chat_id, app_id, sid)`（不传 peer refs）
3. **迁移 `agent_spawner.ex:145` + `router.ex:121`**（`unregister_session/1` 的两个 caller）到 `detach_session/3` 或 `delete_by_session/1`
4. **FAA 路由**（`feishu_app_adapter.ex:238`）改成：
   ```elixir
   case ChatRouting.Registry.current_session(chat_id, app_id) do
     {:ok, sid} ->
       case Esr.Entity.Agent.InstanceRegistry.fcp_for_session(sid) do
         {:ok, fcp_pid} when is_pid(fcp_pid) ->
           if Process.alive?(fcp_pid) do
             send(fcp_pid, {:feishu_inbound, envelope})
           else
             cleanup_and_reply(chat_id, app_id, sid, :session_dead)
           end
         :not_found ->
           cleanup_and_reply(chat_id, app_id, sid, :session_incomplete)
       end

     :not_found ->
       handle_unbound_chat(envelope)
   end
   ```
   **无 `other ->` 兜底**。每种 case explicit
5. **InstanceRegistry 加 `fcp_for_session/1`** —— 当前 `Esr.Entity.Agent.InstanceRegistry` 按 role 索引；加便捷 helper 过滤 role=`:feishu_chat_proxy` for sid

**改动：**
- `runtime/lib/esr/session/chat_routing/registry.ex` —— 删 legacy API + 持久化（~80 LOC 删）
- `runtime/lib/esr/session/agent_spawner.ex:145, :460` —— 迁移（~10 LOC）
- `runtime/lib/esr/session/router.ex:121` —— 迁移（~5 LOC）
- `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238-275` —— 重写 pattern + 删 `other ->`（~40 LOC）
- `runtime/lib/esr/entity/agent/instance_registry.ex` —— 加 `fcp_for_session/1`（~20 LOC）
- 测试 + 清旧 fixture（~50 LOC）

### 4.6 LifecycleObserver + ETS cleanup —— PR-3

Per-session observer。由 `/session:new` 或 `AgentSpawner.do_create/1`
启动。住在 top-level supervisor（`Esr.Session.LifecycleObservers`）—— 在
session 子树死亡后仍活着。

```elixir
defmodule Esr.Session.LifecycleObserver do
  use GenServer
  require Logger

  def start_link(%{session_id: sid, session_sup_pid: sup_pid,
                   chat_id: chat_id, app_id: app_id}) do
    GenServer.start_link(__MODULE__, %{sid: sid, chat_id: chat_id,
                                       app_id: app_id, sup_pid: sup_pid})
  end

  def init(state) do
    Process.monitor(state.sup_pid)
    {:ok, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("session #{state.sid} supervisor exited: #{inspect(reason)}")
    Esr.Plugins.Feishu.FeishuAppAdapter.reply_chat_error(
      state.chat_id, state.app_id, :session_terminated,
      "session #{state.sid} 异常终止: #{inspect(reason)}"
    )
    Esr.Session.ChatRouting.Registry.detach_session(
      state.chat_id, state.app_id, state.sid)
    {:stop, :normal, state}
  end
end
```

**改动：**
- 新：`runtime/lib/esr/session/lifecycle_observer.ex`（~70 LOC）
- 新：`runtime/lib/esr/session/lifecycle_observers.ex` —— DynamicSupervisor（~20 LOC）
- `agent_spawner.ex` —— spawn 后起 observer（~10 LOC）
- 测试（~40 LOC）

### 4.7 系统级 invariants + ChaosScenarios DSL —— PR-3

`docs/notes/system-invariants.md`（新）：

| ID | Invariant | 验证 |
|---|---|---|
| **I1** | 到达 FAA 的每条 chat inbound 都在 5 秒内产生 chat 可见的回复或 error | `invariant_test/1` + ChaosScenarios |
| **I2** | `:esr_session_chat_routing` ETS 的每条 alive entry 都指向有 live FCP 的 InstanceRegistry session | `eventually` poll |
| **I3** | session_dir 存在 ↔ supervisor 树有 alive root | observer-based |
| **I4** | agent 进程死亡（任何原因，含 supervisor giveup）→ 5 秒内 chat 可见 lifecycle reply | timing 断言 |
| **I5** | 路由层代码无 `other -> Logger.warning + drop` | grep CI gate |

`runtime/test/support/chaos_scenarios.ex`（新）：~80 LOC macro 库，helpers
`chaos_inject/2`、`assert_chat_reply_within/1`、`eventually/2`、
`setup_session_with_listener/0`、`kill_role_in_session/2`。

`runtime/test/esr/system/invariants_test.exs`（新）：I1-I5 实现（~120 LOC）。

### 4.8 Real-claude 集成测试 —— PR-4

`runtime/test/esr/integration/real_claude_boot_test.exs`（新）。tag
`:real_claude`。CI 在 macos-latest 跑（按 guide-driven-e2e Phase 1 CI 政策）：

```elixir
@moduletag :real_claude

setup do
  case System.find_executable("claude") do
    nil -> {:skip, "claude not on PATH"}
    _ -> :ok
  end
end

test "real claude boots, mcp.json written, chat reply round-trip" do
  {:ok, ws} = setup_real_workspace_with_folder()
  {:ok, sid} = Esr.Session.Router.create_session(real_params(ws))

  assert eventually(fn ->
    File.exists?(Esr.Paths.session_mcp_json(sid)) and
    instance_registry_has_role?(sid, :feishu_chat_proxy) and
    instance_registry_has_role?(sid, :cc_process) and
    cc_mcp_ready?(sid)
  end, 30_000)

  send_test_inbound("hello", sid, ws.chat)
  assert_receive {:chat_reply, _}, 60_000

  :ok = Esr.Session.Router.end_session(sid)
end
```

`cc_mcp_ready?/1` subscribe topic `cc_mcp_ready/<sid>`（已验证 ——
`EsrWeb.McpController` 首次 MCP request 时广播）。

**改动：**
- 新：`runtime/test/esr/integration/real_claude_boot_test.exs`（~80 LOC）
- `.github/workflows/ci.yml` —— 加 macos-latest job 跑 `mix test --only real_claude`（~30 LOC YAML）

### 4.9 `mix esr.audit_supervision` —— PR-3

`runtime/lib/mix/tasks/esr.audit_supervision.ex`（新）。`Supervisor.which_children/1`
递归 snapshot，diff `docs/notes/supervisor-inventory.md` baseline。非空
diff CI gate fail。

PR-3 提交初始 snapshot 作 baseline。后续 supervisor 改动要更新 snapshot，
强制 intentional ack。

**改动：**
- 新：mix task（~80 LOC）
- 新：`docs/notes/supervisor-inventory.md`（baseline）
- ci.yml gate（~5 LOC YAML）

### 4.10 ADR-0002 —— PR-3

`docs/adr/0002-cc-pty-pair-one-for-all-invariant.md`（新）。记录
`AgentInstanceSupervisor :one_for_all` 设计选择（spec Q5.3 sub-2，2026-05-07）。

---

## 5. Phase B —— `submit_slash` MCP tool 走真 SlashHandler API（PR-4）

**真实 `SlashHandler.dispatch/2` signature**（`runtime/lib/esr/entity/slash_handler.ex:112-115` 验证）：
```elixir
@spec dispatch(map(), reply_to()) :: reference()
def dispatch(envelope, reply_to)
```
- 第二个 arg 是 reply target，**不是** opts
- 返回 `reference()` —— 异步 dispatch ref
- Submitter 在 envelope 里：`args.submitted_by`

### 5.1 Tool 注册

`runtime/lib/esr/plugins/claude_code/mcp/tools.ex` 加：
```elixir
@admin_tool %{
  name: "submit_slash",
  description: """
  代操作员执行 ESR slash 命令。用户用任何语言说 admin 类的事（加 agent、
  列 session、切 workspace 等）时用。返回结构化结果。
  """,
  input_schema: %{
    type: "object",
    properties: %{
      command: %{type: "string", description: "完整 slash 含开头 /，例如 /agent:add type=cc name=helper"}
    },
    required: ["command"]
  }
}
```

### 5.2 Handler —— 锚定真 dispatch 契约

```elixir
def handle_submit_slash(%{"command" => cmd_str}, mcp_state) do
  sid = mcp_state.session_id

  with {:ok, ctx} <- resolve_chat_ctx_for_session(sid) do
    envelope = %{
      "id" => "submit-#{UUID.uuid4()}",
      "kind" => "event",
      "payload" => %{
        "args" => Map.merge(ctx, %{"content" => cmd_str, "msg_type" => "text"}),
        "event_type" => "msg_received"
      },
      "source" => "esr://localhost/submit_slash",
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => "event",
      "principal_id" => ctx["submitted_by"]
    }

    {collector_pid, ref} = spawn_result_collector()
    _dispatch_ref = Esr.Entity.SlashHandler.dispatch(envelope, collector_pid)

    receive do
      {:slash_result, ^ref, result} -> {:ok, result}
      {:slash_error, ^ref, reason} -> {:error, %{kind: reason}}
    after
      30_000 -> {:error, %{kind: :slash_timeout}}
    end
  end
end

defp resolve_chat_ctx_for_session(sid) do
  case Esr.Resource.Session.Registry.get(sid) do
    {:ok, session} ->
      {:ok, %{
        "chat_id" => session.chat_id,
        "app_id" => session.app_id,
        "submitted_by" => session.principal_id
      }}

    :not_found ->
      {:error, %{kind: :session_not_found}}
  end
end
```

**Auth：** `submitted_by` 是 chat-bound user（session.principal_id），不是
ou_admin。CC 跟操作员同 cap。无 cap 的 slash 返回 `:missing_capability`，
CC 翻译成自然语言。

### 5.3 CC skill prompt

`runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md`（新）：

```markdown
# Admin 操作技能

如果操作员用任何语言让你做 ESR admin 操作 —— 加 agent、列 session、注册
adapter、切 workspace —— 用 `submit_slash` MCP tool。

例子：
- 用户："加个新 agent 叫 helper" → submit_slash(command="/agent:add type=cc name=helper")
- 用户："列出现在的 session" → submit_slash(command="/session:list")
- 用户："换到 my-other workspace" → submit_slash(command="/workspace:use my-other")

submit_slash 返回 error 时，翻译成用户语言，解释下一步。不静默重试；
问操作员该怎么办。可用 slash：/help。
```

cc agent 启动时通过 `--system-prompt` 注入。

### 5.4 测试

- 单测：`submit_slash_handler_test.exs` —— chat_ctx 解析、principal_id 透传、error 翻译
- 集成：扩展 `real_claude_boot_test.exs` —— boot 后 CC 调 `submit_slash(command="/session:list")` 拿当前 session 作 sanity check

---

## 6. Migration 计划 —— 4 PR

| PR | 标题 | LOC | 内容 |
|---|---|---|---|
| **PR-1** | `feat(workspace): folders ≥1 + ESR-bound 1-folder unification` | ~120 | §4.1 |
| **PR-2** | `fix(session): delete spawn_cmd dead code + FCP :pty_closed handler + pipeline integrity check` | ~250 | §4.2 + §4.3 + §4.4 |
| **PR-3** | `feat(supervision): unify ChatRouting on attach + LifecycleObserver + ChaosScenarios + audit + ADR-0002` | ~400 | §4.5 + §4.6 + §4.7 + §4.9 + §4.10 |
| **PR-4** | `feat(agent): submit_slash MCP tool + CC admin skill + real-claude integration test` | ~270 | §4.8 + §5 |

**总 ~1040 LOC。净 LOC 更低因为 §4.5 + §4.2 删 dead/legacy。**

**依赖顺序：**
- PR-1 在 PR-2 前（§4.2 cwd 解析依赖 §4.1 统一 folders）
- PR-2 在 PR-3 前（lifecycle handlers 必须存在 ChaosScenarios 才能验 I4）
- PR-3 在 PR-4 前（real-claude test 依赖 lifecycle 可见性 + unified ChatRouting）

---

## 7. 验收

| # | 验收 | 验证 |
|---|---|---|
| 1 | `/workspace:new name=X`（无 folder=）创建 workspace 含 `folders: [%{path: <esr_managed_dir>}]`，目录存在于磁盘 | 单测 |
| 2 | `/workspace:new name=X folder=/some/dir` 创建 `folders: [%{path: "/some/dir"}]` | 单测 |
| 3 | `/workspace:use test-dev` 后 `/session:new name=test-cc`（test-dev 有 ≥1 folder）成功；PtyProcess 启动时 cwd = workspace folder，**不是** `/tmp` | 手动 replay 2026-05-11 hang + 单测 |
| 4 | 通过 `Launcher.prepare_spawn/1` 启的真 claude binary 正常启动；`.mcp.json` 存在于 `$session_dir/mcp.json` 内容正确 | real-claude 集成测试 |
| 5 | `/session:new` 后发 `hello?` 5 秒内有 chat 可见 reply（来自 CC）或 error | 手动 + I1 |
| 6 | 杀 PtyProcess 5 秒内 chat 收到 `:downstream_died` reply | I4 |
| 7 | `AgentInstanceSupervisor` max_restarts 耗尽产生 chat 可见 `:session_terminated`；ETS routing entry 被 LifecycleObserver 删 | I2 + I4 |
| 8 | `rg "register_session\|unregister_session\|other -> Logger\.warning" runtime/lib/` 0 match | I5 + grep CI |
| 9 | `mix esr.audit_supervision` 跑绿 | CI gate |
| 10 | Real-claude 集成测试 boot + 收到 chat reply | macos-latest CI |
| 11 | 用户说"加个 helper agent" CC 执行 `/agent:add type=cc name=helper` | 手动 Feishu + 集成 |

---

## 8. Open questions / 未来工作

`docs/futures/todo.md` 跟踪。**本 spec 关闭：**
- `phase-3-fence-cc-reply` → §4.8（real-claude test）+ flow-bootstrap.md fence #5 重启
- `unconsumed-message-errors-not-hangs` → §4.4 + §4.5 + §4.6（I1）解决

**仍开放、本 spec 依赖或互动：**
- `structured-reply-envelope`（`docs/futures/todo.md:37`）—— 本 spec 假设
  结构化 reply 可用。若 todo 没先 ship，`notify_chat/2` 用最小本地 envelope
  shape，full schema 在 follow-up 落地。rev-1 引用的 task #220 是 stale，
  rev-2 改成正确的 `structured-reply-envelope`
- `e2e-15-principal-isolation` —— submit_slash 用非 admin principal 需要等
  e2e fixture 有非 admin test principal

---

## 9. Approval gate

linyilun 在 Feishu 批准。批准后：
1. 本 spec 提交 + zh_cn mirror push
2. plan 通过 `superpowers:writing-plans` 写到
   `docs/superpowers/plans/2026-05-11-default-agent-and-agent-driven-flow-plan.md`
3. 从 PR-1 实施
