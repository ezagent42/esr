# Session 创建时默认 agent + agent 驱动后续操作

**Status:** Draft —— 待 linyilun 批准（2026-05-11）
**Date:** 2026-05-11
**Author:** Claude（与 linyilun 协作）
**Companion:** [`.md`](2026-05-11-default-agent-and-agent-driven-flow-design.md)

Worktree: `.worktrees/fix-unconsumed-msg`，branch `spec/default-agent-and-agent-driven-flow`。

---

## 1. 为什么现在

2026-05-11 操作员（linyilun）在 Feishu 端手动测试：

```
/workspace:use test-dev    → ok: %{"action" => "default_workspace_set", ...}
/session:list              → workspace test-dev: no live sessions
/session:new name=test-cc  → session started: b6bfbe47-...
hello?                     → (无回复，静默 hang)
```

`hello?` 被静默丢弃。查 `~/.esrd-dev/default/logs/launchd-stdout.log` 发现
一条 5 步 cascade，根因是 2 个生产 bug，被 3 个 silent-drop bug class 放大：

1. **PtyProcess 以 `dir=/tmp` 启 claude**（workspace `test-dev` 0 个 folder；
   解析 dir 的代码兜底用 `/tmp`）。claude 在 cwd 读 `.mcp.json`；
   `/tmp/.mcp.json` 不存在；claude 拒绝启动，退出 256。
2. **PtyProcess GenServer crash** `{:pty_crashed, 256}`。按
   `Esr.Session.AgentInstanceSupervisor` 的 `:one_for_all` 策略（2026-05-07
   spec Q5.3 sub-2 锁定：CC + PTY 必须一起 restart），CC 也被拉死。
3. **PtyProcess `terminate/2` 通过 PubSub 广播 `:pty_closed` 给 FCP**。
4. **`Esr.Plugins.Feishu.FeishuChatProxy.handle_info/2` 没匹配 `:pty_closed`
   的 clause** → `FunctionClauseError` 在 `feishu_chat_proxy.ex:274` →
   FCP crash。
5. **Cascade**: PTY restart → claude 又退 256 → PTY crash → FCP 又收
   `:pty_closed` → FunctionClauseError → `AgentInstanceSupervisor` 在 60s 内
   达 `max_restarts: 3` → instance 子树 terminate（`restart: :transient`，
   不自动重启）。
6. **`:esr_session_chat_routing` ETS entry 仍指向死掉的 FCP pid**。FAA 按
   `(chat_id, app_id)` 查表拿到死 pid，`send(dead_pid, msg)` 在 Erlang 是
   静默 no-op。用户的 `hello?` 消失。

**操作员手动测试反馈（linyilun 2026-05-11 Feishu）：** "session 建立的时候，
就默认帮我创建一个 agent（默认类型是 cc），后续我的操作应该让这个 agent
来帮我完成。如果我需要添加新的 agent，既可以使用 slash 命令，也可以使用
自然语言请主 agent 帮我来操作。"

"默认 agent on session" 这个设计意图**实际已经实现了**（SessionTemplate
+ AgentSpawner.do_create + cc_mcp Channel）。上述 bug 让它在生产里不工作。
本 spec 修这个 cascade，并加上完成操作员心智模型的"自然语言 admin"层。

---

## 2. 术语

本 spec 继承 `docs/notes/concepts.md`（rev-11）和 `CONTEXT.md` 的所有术语。新增：

| 术语 | 定义 |
|---|---|
| **silent-drop cascade** | §1 描述的 5 步链 —— 一个生产 bug 让 chat 可见的回归 disappear 而无 error |
| **lifecycle 消息** | 表示状态转换的 PubSub 或直发消息：`:pty_closed`、`{:agent_crashed, _}`、`{:supervisor_giveup, _}` |
| **effect-level invariant** | 跨 supervisor 的系统级属性（如"没有 inbound 静默丢失"），跟"per-supervisor invariant"对偶 |
| **ChaosScenarios DSL** | 本 spec 引入的测试 macro 库，声明"在 chaos 下杀 X 个 child，断言系统不变量 Y 仍 hold" |

---

## 3. 目标与非目标

### 目标

- `/session:new <name>` 可靠产出可用的 chat → CC 回复闭环（原设计意图最终
  在生产落地）
- 任何 chat inbound 都在 5 秒内产生 chat 可见的回复或 chat 可见的 error。
  **没有静默丢失。**
- workspace 数据模型 well-formed：workspace ⊇ ≥1 folder，写入时强制
- ESR 暴露 `submit_slash` MCP tool，让 CC 通过自然语言代用户执行 admin 操作
- 测试基础设施（real-claude boot + ChaosScenarios + audit mix task）防止
  这类 bug 复发

### 非目标

- **不**改 `AgentInstanceSupervisor` 的 `:one_for_all` 策略。该决策
  （2026-05-07 spec Q5.3 sub-2）是对的：CC + PTY 必须一起 move。ADR-0002
  记录此事，防止未来工程师误改
- **不**重设计 workspace ↔ folder 关系成 VS Code 风格（workspace 容纳
  全部 per-session state）。按 concepts.md §四，Resource（Dir）是独立、
  可被多 Session 共享的；当前 `workspaces/` + `sessions/` 平级 layout 正确
- **不**给 `submit_slash` 加 rate-limit。如果 CC 失控，invariant I4
  （5 秒 chat reply）兜底；显式 rate-limit 推后
- **不**支持非 CC agent 调 `submit_slash` v1。Bundle 作者后续可以从自己的
  channel 暴露这个 tool

---

## 4. Phase A —— silent-drop cascade 修复（PR-1、PR-2、PR-3）

### 4.1 Workspace ≥1 folder 不变量（PR-1，~120 LOC）

0-folder workspace 是数据损坏：下游所有消费者（session 创建、agent spawn、
claude cwd）都需要一个真实路径。三层强制：

**A. schema：** `runtime/priv/schemas/workspace.v2.json`（或 v3）的 `folders`
字段加 `minItems: 1`。`Esr.Resource.Workspace.JsonWriter.write/2` 写之前
校验 struct；0-folder 写返回 `{:error, :empty_folders}`。

**B. 命令：**
- `/workspace:new name=X path=Y` —— `path` 改为必传（原可选）；成功后
  workspace 携带 1 个由 `path` 生成的 folder。改
  `Esr.Commands.Workspace.New.command_meta/0`
- `/workspace:remove-folder workspace=X path=Y` —— 加 guard：若 remove 后
  剩 0 folder，返回 `:cannot_remove_last_folder`，消息 "workspace %{name}
  只剩 1 个 folder；用 /workspace:remove 删整个 workspace"

**C. boot：** 因用户 2026-05-11 Feishu 指示"esrd-dev 中的文件，全部都可以
删掉重建，不需要考虑后向兼容性"，不写 boot validator。schema 层约束 +
命令 guard 保证不会产生新的 0-folder 状态

**D. 测试：**
- `runtime/test/esr/commands/workspace/new_test.exs` —— 缺 `path` 触发
  meta-DSL 校验 error
- `runtime/test/esr/commands/workspace/remove_folder_test.exs` —— 删最后
  一个 folder 返回 `:cannot_remove_last_folder`
- `flow-bootstrap.md` fence #3（`/workspace:new`）显式传 `path=`

### 4.2 `/session:new` pre-flight + `.mcp.json` 生成（PR-2，~280 LOC）

把 `Esr.Commands.Session.New.execute/2` 中零散的 pre-flight 换成一个
`pre_flight/3` 函数，任一前置条件不满足都 fail-fast。

```elixir
defp pre_flight(args, submitter, chat_ctx) do
  with {:ok, claude_path}    <- check_claude_binary(),
       {:ok, workspace}      <- resolve_workspace(args, chat_ctx),
       {:ok, cwd}            <- pick_primary_folder_path(workspace),
       {:ok, session_dir}    <- prepare_session_dir(args[:sid]),
       {:ok, template_name}  <- resolve_template_name(args),
       {:ok, agent_def}      <- materialize_template(template_name) do
    {:ok, %{claude_path: claude_path, workspace: workspace, cwd: cwd,
            session_dir: session_dir, agent_def: agent_def}}
  end
end
```

**Error 返回是结构化的**（接 `docs/futures/todo.md` 的 `structured-reply-envelope`）。
具体 error kinds：

| Kind | 触发 | Chat 回复 |
|---|---|---|
| `:missing_claude_binary` | `System.find_executable("claude") == nil` | "claude binary 不在 PATH；先安装 Claude Code" |
| `:workspace_not_bound` | M-5 chain 返回空 | "this chat 未绑定 workspace；先运行 /workspace:use <name>" |
| `:empty_workspace` | resolved workspace 0 folder（虽然 §4.1 阻挡了创建，但 defense-in-depth）| "workspace %{name} 没 folder；先运行 /workspace:add-folder" |
| `:template_not_found` | template lookup `:not_found` | "template %{name} 不存在；可用 templates: ..." |

**`.mcp.json` 生成在 `session_dir`，不在 workspace folder：**

- 路径：`$ESRD_HOME/<instance>/sessions/<sid>/mcp.json`
- 为什么不放 workspace folder：见 §3 非目标 + concepts.md §四（Dir 是
  shared Resource；multi-session-per-workspace 会冲突一个 `.mcp.json`）
- 生成时机：cc_mcp Channel `start_link/1` 返回 `{:ok, %{port: N}}` 之后（知道了
  ephemeral port），PtyProcess `start_link/1` 之前（claude 才能读到）。spawn
  pipeline：
  ```
  AgentSpawner.do_create
    ↓
    1. 启 cc_mcp Channel → {:ok, %{port: N}}
    ↓
    2. 写 session_dir/mcp.json with port=N
    ↓
    3. 启 CCProcess（纯 Elixir，不 shell out）
    ↓
    4. 启 PtyProcess 命令 = claude --mcp-config $session_dir/mcp.json --cwd $cwd
  ```

**`.mcp.json` schema：**
```json
{
  "mcpServers": {
    "esr-channel": {
      "type": "http",
      "url": "http://127.0.0.1:<port>/mcp"
    }
  }
}
```

**Spawn 失败 cleanup：** 任一 step 1-4 返回 `{:error, _}`，AgentSpawner
调 `Esr.Session.Supervisor.stop_session(sid)`，删 chat 对应的
`:esr_session_chat_routing` ETS entry，error 回 command handler。
**没有半起状态。**

### 4.3 FCP 显式 lifecycle handlers（PR-2，~80 LOC）

`runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` 加每个 lifecycle 消息
的显式 `handle_info/2` clause。§1 步骤 4 的 `FunctionClauseError` 消失。

```elixir
@impl GenServer
def handle_info(:pty_closed, state) do
  notify_chat(state, :agent_died, %{
    message: "claude agent 退出；supervisor 即将重启。如重复，运行 " <>
             "/session:end + /session:new 恢复"
  })
  {:noreply, %{state | agent_state: :pty_restarting}}
end

def handle_info({:DOWN, _ref, :process, pid, reason}, state) when pid == state.cc_process_pid do
  notify_chat(state, :cc_crashed, %{reason: inspect(reason)})
  {:noreply, %{state | agent_state: :cc_restarting}}
end

def handle_info({:supervisor_giveup, sid}, state) when sid == state.session_id do
  notify_chat(state, :session_fatal, %{
    message: "session #{sid} 超 max_restarts 终止。运行 " <>
             "/session:end + /session:new 重建"
  })
  cleanup_routing_entry(state)
  {:stop, :normal, state}
end
```

`notify_chat/3` 格式化结构化 envelope（接 `structured-reply-envelope`），
通过现有 Feishu reply 路径回。

`{:supervisor_giveup, sid}` 由 §4.4 引入的 per-session
**`Esr.Session.LifecycleObserver`** 广播。

### 4.4 ETS cleanup + LifecycleObserver + `Process.alive?` guard（PR-3，~130 LOC）

**`Esr.Session.LifecycleObserver`** —— per-session GenServer，存活于
supervisor 树之外。由 `/session:new` 启（登记到 instance-level
`Esr.Session.LifecycleObservers` registry），`Process.monitor` session
supervisor pid。收到 `:DOWN`：

1. 广播 `{:supervisor_giveup, sid}` 给 FCP（若 FCP 还活）
2. 删 session 对应的 `:esr_session_chat_routing` entry
3. 打 `Logger.warning "session #{sid} terminated; reason=#{inspect(reason)}"`
4. 自停

**FAA 路由前 alive 检查** ——
`runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238` 的
`do_handle_upstream_inbound/5` lookup 站点：

```elixir
case Esr.Session.ChatRouting.Registry.lookup_by_chat(chat_id, app_id) do
  {:ok, _sid, %{feishu_chat_proxy: pid}} when is_pid(pid) ->
    if Process.alive?(pid) do
      send(pid, {:feishu_inbound, envelope})
    else
      :ok = Esr.Session.ChatRouting.Registry.delete_by_chat(chat_id, app_id)
      reply_chat_error(chat_id, app_id, :stale_session,
        "this chat 的 session 死了；运行 /session:new 重建")
    end

  :not_found ->
    # 现有：PubSub 广播 :new_chat_thread 自动 spawn
    handle_unbound_chat(envelope)
end
# 没有 `other ->` 兜底。意外 shape 走 MatchError → crash → supervisor。
```

### 4.5 `other ->` catch-all 大扫除（PR-3，~60 LOC 跨多文件）

grep 目标：`rg -n "other ->" runtime/lib/`。逐处决策：

| 类型 | 重写 |
|---|---|
| 路由 / lifecycle 关键代码（FAA、Router、SlashHandler）| 改 explicit `:ok` / `:not_found`；意外 shape 让 MatchError crash |
| 非 critical GenServer.handle_info 该忽略陌生消息 | 改 `_other -> :ok`，加注释 "intentional ignore" |
| 值兜底（`other -> default`）| 改 `:error`，让 caller 决定 |

invariant I5 跟踪（见 §4.6）。

### 4.6 系统级 invariants + ChaosScenarios DSL（PR-3，~150 LOC）

把跨 supervisor 的 effect-level invariant 集中放在一处。

**`docs/notes/system-invariants.md`** —— 强制性清单：

| ID | Invariant | 验证位置 |
|---|---|---|
| **I1** | 到达 FAA 的每条 chat inbound 都在 5 秒内产生 chat 可见的回复或 chat 可见的 error | `chaos_invariant_test/1` 在 `invariants_test.exs` |
| **I2** | `:esr_session_chat_routing` ETS 表每条 entry 都指向 `Process.alive?(pid) == true` 的进程 | chaos 后 `eventually` |
| **I3** | session 有 on-disk state（`session_dir/`）↔ 它的 supervisor 树活着 | observer 模式 |
| **I4** | agent 死亡（任意原因，含 supervisor giveup）→ 5 秒内 chat 可见 lifecycle reply | 直接 timing 断言 |
| **I5** | 路由层代码没有 `other -> Logger.warning + drop` 兜底 | grep CI gate（静态扫描，非 runtime）|

**`Esr.Test.ChaosScenarios` macro**（`runtime/test/support/chaos_scenarios.ex`）：

```elixir
defmodule Esr.Test.ChaosScenarios do
  defmacro invariant_test(description, do: block) do
    quote do
      test "INVARIANT: " <> unquote(description) do
        unquote(block)
      end
    end
  end

  def chaos_inject(targets, opts \\ []) do
    times = Keyword.get(opts, :times, 1)
    Enum.each(1..times, fn _ ->
      target = Enum.random(List.wrap(targets))
      pid = resolve_chaos_target(target)
      if pid && Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.sleep(50)
    end)
  end

  def assert_chat_reply_within(timeout_ms) do
    assert_receive {:chat_reply, _}, timeout_ms
  end
end
```

测试在 `runtime/test/esr/system/invariants_test.exs`：

```elixir
use Esr.Test.ChaosScenarios

invariant_test "I1: chaos 下每条 inbound 都有回复" do
  {:ok, sid} = setup_session_with_chat_listener()
  chaos_inject([:kill_pty, :kill_cc, :kill_channel], times: 5)
  send_chat_text("hello?")
  assert_chat_reply_within(5_000)
end

invariant_test "I2: ETS routing 没死 pid" do
  {:ok, sid} = setup_session()
  chaos_inject(:kill_pty)
  eventually(fn ->
    Enum.all?(ets_routing_entries(), fn {_key, _sid, refs} ->
      Enum.all?(Map.values(refs), &Process.alive?/1)
    end)
  end, 3_000)
end

# I3、I4、I5 类似
```

### 4.7 Real-claude boot 集成测试（PR-4，~80 LOC）

`runtime/test/esr/integration/real_claude_boot_test.exs` —— **能抓住今天那
个 regression 的测试**。tag `:real_claude`；CI step 在 macos-latest 跑
`mix test --only real_claude`（按 guide-driven-e2e Phase 1 CI 政策）。

```elixir
@moduletag :real_claude

setup do
  case System.find_executable("claude") do
    nil -> {:skip, "claude not on PATH"}
    _ -> :ok
  end
end

test "real claude boots and responds via cc_mcp end-to-end" do
  {:ok, workspace} = setup_real_workspace_with_folder()
  {:ok, sid} = Esr.Session.Router.create_session(real_session_params(workspace))

  assert eventually(fn ->
    Process.alive?(pid_of(sid, :cc_process)) and
    File.exists?(session_dir(sid) <> "/mcp.json") and
    claude_handshake_complete?(sid)
  end, 30_000)

  send_test_inbound("hello", sid)
  assert_receive {:chat_reply, _text}, 60_000

  :ok = Esr.Session.Router.stop_session(sid)
end
```

### 4.8 `mix esr.audit_supervision`（PR-3，~50 LOC）

维护性 mix task：给一个跑着的 esrd fixture，递归 snapshot supervision 树
（`Supervisor.which_children/1` + 每个 supervisor 的 strategy），diff 跟
`docs/notes/supervisor-inventory.md`（人审过的快照）的差异。CI gate diff
非空就 fail，逼着任何 supervisor 结构变化得显式 ack。

跟 §4.6 互补 —— invariant 测试抓行为回归；supervision audit 抓结构 drift。

### 4.9 ADR-0002（PR-3）

`docs/adr/0002-cc-pty-pair-one-for-all-invariant.md`：

```markdown
# CC + PTY pair 用 :one_for_all supervisor

**Status:** accepted  **Date:** 2026-05-11

`Esr.Session.AgentInstanceSupervisor` 用 `:one_for_all` 策略管 CC + PTY。
两个 child 必须一起 restart；禁止 lone-survivor restart。

**理由：** CCProcess 通过 PtyProcess 管 active claude session。一个 restart
另一个不 restart → 存活进程持有过期连接（CC 等死的 PTY pipe，或 PTY 管
没人消费的子进程）。两态都无法 in-place 恢复。`:one_for_all` 保证
一致 restart。

**原始来源：** 2026-05-07 Feishu spec Q5.3 sub-2（见
`agent_instance_supervisor.ex` moduledoc）。

**反转该决策需要：** 让 invariant I1-I4 失效（见
`docs/notes/system-invariants.md`）—— ChaosScenarios 测试会抓任何试图
切换策略的改动。

**范围外：** `Esr.Session.AgentSupervisor`（父 DynamicSupervisor）用
`:one_for_one` 也是对的（session 里多个 agent instance 互相独立）。
```

---

## 5. Phase B —— `submit_slash` MCP tool + CC skill（PR-4，~150 LOC）

### 5.1 Tool 定义

`runtime/lib/esr/plugins/claude_code/mcp/tools.ex` 在 cc_mcp Channel 注册
一个新 admin tool：

```elixir
@admin_tool %{
  name: "submit_slash",
  description: """
  代操作员执行一个 ESR slash 命令。用户用任何语言说 admin 类的事
  （加 agent、列 session、切 workspace、注册 adapter 等）时用此 tool。
  返回结构化结果；error 时把它翻译成自然语言再回复。
  """,
  input_schema: %{
    type: "object",
    properties: %{
      command: %{
        type: "string",
        description: "完整 slash 命令，含开头的 /，例如 /agent:add type=cc name=helper"
      }
    },
    required: ["command"]
  }
}
```

### 5.2 Handler

同一模块的 handler 用 cc_mcp Channel state 的 chat_ctx 构造内部 envelope
（cc_mcp 从 init args 知道 chat_id / app_id / principal_id —— bundle
materialize 时由 SessionTemplate 注入）：

```elixir
def handle_submit_slash(%{"command" => cmd_str}, %{chat_ctx: ctx}) do
  envelope = %{
    "payload" => %{
      "args" => Map.merge(ctx, %{"content" => cmd_str, "msg_type" => "text"})
    }
  }
  case Esr.Entity.SlashHandler.dispatch(envelope, submitter: ctx[:principal_id]) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, %{kind: reason, ...}}
  end
end
```

**Auth：** dispatch 用 **chat 当前 bound user 的 principal_id**（不是
ou_admin，不是 system）。CC 的能力跟操作员一致。用户无 cap 的 slash
返回 `:missing_capability`，CC 翻译成 chat reply。

### 5.3 CC skill prompt

`runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md`（cc agent 启动时
通过 `--system-prompt` 或同类机制注入；cc agent_kind 的 launcher 已支持）：

```markdown
# Admin 操作技能

如果操作员用任何语言让你做 ESR admin 操作 —— 加 agent、列 session、
注册 adapter、切 workspace —— 用 `submit_slash` MCP tool。

例子：
- 用户："加个新 agent 叫 helper" → submit_slash(command="/agent:add type=cc name=helper")
- 用户："列出现在的 session" → submit_slash(command="/session:list")
- 用户："换到 my-other workspace" → submit_slash(command="/workspace:use my-other")

submit_slash 返回 error 时，把 error 翻译成用户语言，解释下一步该怎么做。
不要静默重试；问操作员该怎么办。

可用 slash：见 /help。
```

### 5.4 测试

- 单测：`submit_slash_handler_test.exs` —— chat_ctx 注入、principal_id 透传、
  error path 翻译
- 集成：扩展 `real_claude_boot_test.exs` 验 CC 启动后能调一次 `submit_slash`
  （如 `/session:list` 返回当前 session 作 sanity check）

---

## 6. Migration 计划 —— 4 个 PR

| PR | 标题 | LOC | 内容 |
|---|---|---|---|
| **PR-1** | `feat(workspace): enforce workspace ≥1 folder invariant` | ~120 | §4.1（schema、命令 guard、测试）|
| **PR-2** | `fix(session): /session:new pre-flight + mcp.json + FCP lifecycle handlers` | ~360 | §4.2 + §4.3（pre-flight、mcp.json gen、FCP `handle_info/2` clauses）|
| **PR-3** | `feat(supervision): LifecycleObserver + ETS cleanup + ChaosScenarios + system invariants` | ~390 | §4.4 + §4.5 + §4.6 + §4.8 + ADR-0002 + `system-invariants.md` |
| **PR-4** | `feat(agent): submit_slash MCP tool + CC admin skill + real-claude integration test` | ~280 | §4.7 + Phase B（§5）+ e2e fence #5 |

CI 上每 PR 独立但依赖有序：PR-1 必须先合（pre-flight 假设 ≥1 folder）；
PR-2 先于 PR-3（LifecycleObserver 假设 pre-flight 已就绪）；PR-3 先于 PR-4
（real-claude test 依赖 lifecycle 可见性）。

---

## 7. 验收

| # | 验收 | 验证 |
|---|---|---|
| 1 | `/workspace:new name=X path=/some/dir` 成功；`/workspace:new name=X`（无 path）失败带显式 error | 单测 + e2e fence |
| 2 | `/workspace:use test-dev` 后 `/session:new name=test-cc` 产生活的 FCP + CC + PTY + 就绪 cc_mcp 的 session | 手动 replay 2026-05-11 hang 场景 |
| 3 | `/session:new` 后 `hello?` 在 5 秒内产生 chat 可见的 reply（来自 CC）或 chat 可见的 error | 手动 + invariant I1 |
| 4 | 杀 PtyProcess 不产生静默状态 —— chat 5 秒内收到 `:agent_died` lifecycle reply | invariant I4 |
| 5 | 杀整个 session supervisor（`max_restarts` 耗尽）→ chat 收到 `:session_fatal` reply；ETS routing entry 删掉 | invariant I2 + I4 |
| 6 | `rg "other ->" runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex` 0 match | invariant I5（静态扫描）|
| 7 | `mix esr.audit_supervision` 对当前 dev 树跑绿 | CI gate |
| 8 | Real-claude 集成测试启动 + 收到 reply | macos-latest CI step |
| 9 | 用户说"加个 helper agent" 时 CC 能执行 `/agent:add type=cc name=helper` | Feishu 手动测试 + 集成测试 |

---

## 8. Open questions / 未来工作

`docs/futures/todo.md` 跟踪。本 spec **显式关闭**以下条目：

- `phase-3-fence-cc-reply` → §4.7 重新打开 `flow-bootstrap.md` fence #5
- `unconsumed-message-errors-not-hangs` → §4.3 + §4.4 + §4.6（I1）解决

仍开放、本 spec 可能影响但**未**解决：

- `structured-reply-envelope`（现有 todo）—— 本 spec 假设结构化 reply 可用；
  若 task #220 没先 ship，FCP `notify_chat/3` helper 先用最小本地 envelope，
  full schema 跟随 follow-up
- `e2e-15-principal-isolation` —— submit_slash 用非 admin principal 需要等
  e2e fixture 里有非 admin test principal 后才能测

---

## 9. Approval gate

linyilun 在 Feishu 批准。批准后：
1. 本 spec 提交 + zh_cn 镜像 push
2. plan 通过 `superpowers:writing-plans` 写到
   `docs/superpowers/plans/2026-05-11-default-agent-and-agent-driven-flow-plan.md`
3. 实施从 PR-1 开始
