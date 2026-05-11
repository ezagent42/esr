# Session 默认 agent + agent 驱动 follow-up flow —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 修 2026-05-11 `/session:new + hello?` hang 背后的 5-bug silent-drop cascade，加 `submit_slash` MCP tool 让 CC 用自然语言跑 admin 命令。

**架构：** Phase A 统一 workspace folder 模型（≥1 folder，ESR-bound 变成 1-folder）、让 `Launcher.prepare_spawn/1` 成唯一 spawn 入口（删死 `spawn_cmd`）、加 FCP `:pty_closed` lifecycle handler（plugin-self-consistent）、SessionTemplate pipeline 完整性 post-spawn 验证、删 ChatRouting 双形态 legacy `register_session/3` 统一到 `attach_session/3`、加 `LifecycleObserver` 在 session 树外清 ETS、加 `ChaosScenarios` DSL + `mix esr.audit_supervision` 把 supervisor invariant 编码。Phase B 把 `submit_slash` 作为 FCP `dispatch_tool_invoke/5` 新分支 + per-call `Task` 避免阻塞 GenServer mailbox + 新 `Esr.Slash.ReplyTarget.RawCollector` 捕获 raw 结果。

**Tech Stack：** Elixir/OTP（GenServer + DynamicSupervisor + ETS）、ExUnit + `:meck` 测试、Phoenix Channels MCP HTTP、PubSub lifecycle 消息、`Esr.ActorQuery` role-keyed pid lookup、Jason JSON。

**Spec 来源：** `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md` rev-3（commit `6dc0c36`）。

**分支策略：**
- 计划落在 `spec/default-agent-and-agent-driven-flow` 跟 spec rev-3 一起 → merge
- 每 PR 从 `origin/dev` 派新 feature branch：
  - PR-1 → `feat/workspace-folders-invariant`
  - PR-2 → `fix/session-spawn-pipeline-and-pty-closed`
  - PR-3 → `feat/chat-routing-unify-and-supervision-invariants`
  - PR-4 → `feat/submit-slash-mcp-tool`

---

## 文件结构

### 新文件

| 路径 | PR | LOC | 职责 |
|---|---|---|---|
| `runtime/lib/esr/session/lifecycle_observer.ex` | 3 | ~70 | 每 session 一个 observer；monitor session sup pid；DOWN 时清 ETS + chat error |
| `runtime/lib/esr/session/lifecycle_observers.ex` | 3 | ~30 | 实例级 DynamicSupervisor |
| `runtime/lib/esr/slash/reply_target/raw_collector.ex` | 4 | ~35 | ReplyTarget impl 发 raw `{:slash_raw, ref, result}` |
| `runtime/lib/mix/tasks/esr.audit_supervision.ex` | 3 | ~80 | Mix task snapshot supervisor 树、diff baseline |
| `runtime/test/support/chaos_scenarios.ex` | 3 | ~80 | 测试 DSL：`invariant_test/2`、`chaos_inject/2`、`eventually/2` 等 |
| `runtime/test/esr/system/invariants_test.exs` | 3 | ~120 | I1-I5 测试 |
| `runtime/test/esr/session/lifecycle_observer_test.exs` | 3 | ~50 | Observer 单测 |
| `runtime/test/esr/slash/reply_target/raw_collector_test.exs` | 4 | ~30 | RawCollector 单测 |
| `runtime/test/esr/plugins/feishu/submit_slash_handler_test.exs` | 4 | ~60 | submit_slash 分支测试 |
| `runtime/test/esr/integration/real_claude_boot_test.exs` | 4 | ~80 | Real-claude e2e（tag :real_claude）|
| `runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md` | 4 | ~30 | CC admin skill prompt |
| `docs/adr/0002-cc-pty-pair-one-for-all-invariant.md` | 3 | ~30 | ADR |
| `docs/notes/system-invariants.md` | 3 | ~40 | I1-I5 不变量声明 + 验证映射 |
| `docs/notes/supervisor-inventory.md` | 3 | ~30 | supervisor baseline snapshot |

### 修改文件

完整清单见 [英文版 plan](2026-05-11-default-agent-and-agent-driven-flow-plan.md) 的 "Modified files" 表。

---

## PR-1：Workspace folders ≥1 + ESR-bound 统一（~120 LOC，8 个 task）

### Task 1.1：从 dev 派分支

**文件：** 仅 git

- [ ] **Step 1：建 feature 分支**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/fix-unconsumed-msg
git fetch origin
git checkout -b feat/workspace-folders-invariant origin/dev
```

- [ ] **Step 2：验证 clean state**

```bash
git status
```
预期：`On branch feat/workspace-folders-invariant ... nothing to commit, working tree clean`

### Task 1.2：加 `Esr.Resource.Workspace.Struct.valid?/1`

**文件：**
- 修改：`runtime/lib/esr/resource/workspace/struct.ex`
- 测试：`runtime/test/esr/resource/workspace/struct_test.exs`

- [ ] **Step 1：写失败的测试** —— 内容同 EN plan
- [ ] **Step 2：跑测试验证失败** —— `cd runtime && mix test test/esr/resource/workspace/struct_test.exs -v`
- [ ] **Step 3：实现 valid?/1** —— code 见 EN plan 同位置
- [ ] **Step 4：跑测试验证通过**
- [ ] **Step 5：Commit** —— message `"feat(workspace): add Struct.valid?/1 — ≥1 folder invariant"`

### Task 1.3：往 workspace.v1.json schema 加 `minItems: 1`（人类契约）

**文件：** 修改 `runtime/priv/schemas/workspace.v1.json`

- [ ] **Step 1：读现有 schema** —— `grep -A2 '"folders"' runtime/priv/schemas/workspace.v1.json`
- [ ] **Step 2：加 minItems** —— 编辑 schema 文件，在 `"folders": { "type": "array", ... }` 块加 `"minItems": 1`
- [ ] **Step 3：Commit** —— `"docs(schema): workspace.v1 declares folders minItems:1"`

### Task 1.4：JsonWriter 拒 0-folder 写入

**文件：**
- 修改：`runtime/lib/esr/resource/workspace/json_writer.ex`
- 测试：`runtime/test/esr/resource/workspace/json_writer_test.exs`

- [ ] **Step 1：写失败测试** —— 见 EN plan
- [ ] **Step 2：跑测试失败** —— 现有 impl 无视 validity，文件还是写出来了
- [ ] **Step 3：在 `write/2` 加 guard** —— 调 `Esr.Resource.Workspace.Struct.valid?/1`，false 返 `{:error, :empty_folders}`
- [ ] **Step 4：跑全部 writer 测试无回归**
- [ ] **Step 5：Commit** —— `"feat(workspace): JsonWriter rejects 0-folder writes"`

### Task 1.5：统一 `commands/workspace/new.ex` —— ESR-bound 变 1-folder

**文件：**
- 修改：`runtime/lib/esr/commands/workspace/new.ex:119-129`
- 测试：`runtime/test/esr/commands/workspace/new_test.exs`

- [ ] **Step 1：写失败测试** —— ESR-bound workspace 应有 1 folder 含 ESR-managed path
- [ ] **Step 2：跑测试失败** —— `cd runtime && mix test ...new_test.exs -v --only describe:"ESR-bound"`
- [ ] **Step 3：替换 119-129 的代码块** —— 见 EN plan 完整代码块（统一两个分支，mkdir_p! 创建 ESR-bound dir）
- [ ] **Step 4：跑测试验证通过**
- [ ] **Step 5：Commit** —— `"feat(workspace): ESR-bound mode becomes 1-folder workspace (no split state)"`

### Task 1.6：guard `/workspace:remove-folder` 不许减到 0

**文件：**
- 修改：`runtime/lib/esr/commands/workspace/remove_folder.ex`
- 测试：`runtime/test/esr/commands/workspace/remove_folder_test.exs`

- [ ] **Step 1：写失败测试** —— 删唯一 folder 返回 `:cannot_remove_last_folder`
- [ ] **Step 2：跑失败**
- [ ] **Step 3：加 guard** —— `if length(workspace.folders) == 1` 返 error
- [ ] **Step 4：跑通过**
- [ ] **Step 5：Commit** —— `"feat(workspace): /workspace:remove-folder refuses to remove last folder"`

### Task 1.7：集成测试 —— 完整 create + describe + cleanup 流程

**文件：** 新建 `runtime/test/esr/integration/workspace_lifecycle_test.exs`

- [ ] **Step 1：写测试** —— 见 EN plan
- [ ] **Step 2：跑测试** —— `cd runtime && mix test test/esr/integration/workspace_lifecycle_test.exs -v`
- [ ] **Step 3：Commit** —— `"test(workspace): integration test for ESR-bound lifecycle"`

### Task 1.8：开 PR + admin-merge

- [ ] **Step 1：Push 分支** —— `git push -u origin feat/workspace-folders-invariant`
- [ ] **Step 2：开 PR** —— gh pr create，body 引用 spec §4.1
- [ ] **Step 3：等 CI + admin-merge** —— `gh pr checks --watch && gh pr merge --admin --squash --delete-branch`

---

## PR-2：prepare_spawn 唯一入口 + FCP :pty_closed + SessionTemplate 完整性（~250 LOC，9 个 task）

### Task 2.1：从最新 dev 派分支（PR-1 已合）

```bash
git fetch origin
git checkout -b fix/session-spawn-pipeline-and-pty-closed origin/dev
```

### Task 2.2：加 `Esr.Paths.session_mcp_json/1`

**文件：**
- 修改：`runtime/lib/esr/paths.ex`
- 测试：`runtime/test/esr/paths_test.exs`

- [ ] **Step 1：加 helper** —— 见 EN plan Step 1（`Path.join([esrd_home(), instance(), "sessions", sid, "mcp.json"])`）
- [ ] **Step 2：测试**
- [ ] **Step 3：跑 + commit** —— `"feat(paths): add session_mcp_json/1 helper"`

### Task 2.3：删 `Launcher.spawn_cmd/1`；让 `prepare_spawn/1` 成唯一入口

**文件：**
- 修改：`runtime/lib/esr/plugins/claude_code/launcher.ex`
- 测试：`runtime/test/esr/plugins/claude_code/launcher_test.exs`

- [ ] **Step 1：读现有 prepare_spawn** —— 确认它已经 mkdir + write_mcp_json + build_env + 组 argv
- [ ] **Step 2：把 prepare_spawn 返回改成 `{:ok, %{cmd: ..., env: ...}} | {:error, reason}`** —— 见 EN plan 完整代码（含 `ensure_dir/1`、`ensure_claude_binary/0`）
- [ ] **Step 3：删 `spawn_cmd/1`** —— `rg -n "Launcher\.spawn_cmd" runtime/` 应只剩 PtyProcess 一处 caller（Task 2.4 修）
- [ ] **Step 4：调整 launcher 测试** —— 删旧 spawn_cmd 测试；prepare_spawn 测试断言 `{:ok, %{cmd, env}}` shape + mcp.json 文件存在
- [ ] **Step 5：跑 + commit** —— `"refactor(claude_code/launcher): prepare_spawn becomes sole entry; spawn_cmd deleted"`

### Task 2.4：把 PtyProcess 接到 prepare_spawn；删 `/tmp` 兜底

**文件：** 修改 `runtime/lib/esr/entity/pty_process.ex:80, :202-216`

- [ ] **Step 1：改 init 的 dir 解析** —— 删 `|| "/tmp"`；改 `dir: get_param(params, :dir)`；在 init 末尾加 `case state.state.dir do nil -> {:stop, {:error, :missing_dir}}; _ -> {:ok, state, {:continue, :launch}} end`
- [ ] **Step 2：改 spawn 调用（202-216）** —— 见 EN plan，调 `Esr.Plugins.ClaudeCode.Launcher.prepare_spawn/1`，`{:ok, %{cmd, env}}` 用现有 `:exec.run_link`；`{:error, reason}` 走 `{:stop, ...}`
- [ ] **Step 3：加 `:missing_dir` 测试** —— `dir: nil` 时 init 返回 `{:stop, {:error, :missing_dir}}`
- [ ] **Step 4：跑 + commit** —— `"fix(pty_process): use prepare_spawn entry; delete /tmp fallback"`

### Task 2.5：SessionTemplate pipeline 完整性 post-spawn 检查

**文件：**
- 修改：`runtime/lib/esr/session/agent_spawner.ex`
- 测试：`runtime/test/esr/session/agent_spawner_test.exs`

- [ ] **Step 1：写失败测试** —— pipeline 含坏 stage 时 `do_create` 返 `:pipeline_incomplete`
- [ ] **Step 2：加 `verify_pipeline_complete/2` helper** —— 见 EN plan 完整 code（用 ActorQuery 验 expected_roles）；do_create 失败时调 `Esr.Session.Router.end_session(sid)` 拆树
- [ ] **Step 3：跑 + commit** —— `"feat(agent_spawner): verify_pipeline_complete/2 post-spawn integrity check"`

### Task 2.6：FCP `:pty_closed` clause + `notify_chat/2` helper

**文件：**
- 修改：`runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`（line ~274）
- 测试：`runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs`

- [ ] **Step 1：写失败测试** —— send `:pty_closed`，FCP 不 crash，发出 `{:chat_reply, %{kind: :downstream_died}}`
- [ ] **Step 2：跑失败（FunctionClauseError）**
- [ ] **Step 3：加 clause + helper** —— 见 EN plan 完整 code；注意 `notify_chat/2` 通过 FCP 现有 outbound 路径（grep `emit_reply_envelope` / `OutboundEmit` 找正确 helper）
- [ ] **Step 4：跑 + commit** —— `"fix(feishu_chat_proxy): add :pty_closed handler + notify_chat helper (plugin-decoupled)"`

### Task 2.7：把 `:pipeline_incomplete` 从 `/session:new` 上浮到 chat error

**文件：**
- 修改：`runtime/lib/esr/commands/session/new.ex`
- 测试：`runtime/test/esr/commands/session/new_test.exs`

- [ ] **Step 1：在 execute/2 的 error handling 加 `:pipeline_incomplete` 分支** —— 走 `Render.error(..., :session_start_failed, %{...})`
- [ ] **Step 2：测试 + commit** —— `"feat(session/new): surface :pipeline_incomplete to chat reply"`

### Task 2.8：开 PR + admin-merge

```bash
git push -u origin fix/session-spawn-pipeline-and-pty-closed
gh pr create --base dev --title "fix(session): prepare_spawn entry + FCP :pty_closed handler + pipeline integrity (PR-2 of 4)" --body "Spec §4.2 + §4.3 + §4.4."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## PR-3：ChatRouting 统一 + LifecycleObserver + ChaosScenarios + audit + ADR-0002（~400 LOC，13 个 task）

### Task 3.1：分支

```bash
git fetch origin
git checkout -b feat/chat-routing-unify-and-supervision-invariants origin/dev
```

### Task 3.2：加 `Esr.ActorQuery.fcp_for_session/1`

**文件：**
- 修改：`runtime/lib/esr/actor_query.ex`
- 测试：`runtime/test/esr/actor_query_test.exs`

- [ ] **Step 1：实现 + 测试** —— 见 EN plan
- [ ] **Step 2：Commit** —— `"feat(actor_query): add fcp_for_session/1"`

### Task 3.3：从 ChatRouting.Registry 删 `register_session/3` + `unregister_session/1`

**文件：** 修改 `runtime/lib/esr/session/chat_routing/registry.ex`

- [ ] **Step 1：删 API + handle_call 分支** —— `rg -n "register_session\|unregister_session"` 找到所有 match 删
- [ ] **Step 2：删 legacy-shape 分支** —— `current_session/2` 在 line 105、`list_sessions/2` 在 :124、`lookup_by_chat/2` 的 shim 在 :175（spec §4.5 步骤 6）
- [ ] **Step 3：Commit** —— `"refactor(chat_routing): delete legacy register/unregister API + 3 shape branches"`

### Task 3.4：迁移 `agent_spawner.ex` 的 caller

**文件：** 修改 `runtime/lib/esr/session/agent_spawner.ex:145, :460`

- [ ] **Step 1：line 460 改用 `attach_session(chat_id, app_id, sid)`**
- [ ] **Step 2：line 145 改用 `detach_session_by_id(scope_id)`**（若 chat_routing/registry 还没这个 helper 就加）
- [ ] **Step 3：Commit** —— `"refactor(agent_spawner): migrate to attach_session API"`

### Task 3.5：迁移 `router.ex:121` caller

```elixir
# 旧：
:ok = Esr.Session.ChatRouting.Registry.unregister_session(sid)
# 新：
:ok = Esr.Session.ChatRouting.Registry.detach_session_by_id(sid)
```

```bash
git add runtime/lib/esr/session/router.ex
git commit -m "refactor(router): migrate to detach_session_by_id"
```

### Task 3.6：重写 FAA 路由用 ActorQuery + 显式 clause（no other-> drop）

**文件：** 修改 `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238-275`

- [ ] **Step 1：换路由 case 块** —— 见 EN plan 完整 code（`current_session/2` → `ActorQuery.fcp_for_session/1` → `Process.alive?(fcp_pid)` 决定送 or `cleanup_and_reply`）；helper `cleanup_and_reply/4` 加在文件底
- [ ] **Step 2：Commit** —— `"fix(faa): route via ActorQuery; explicit clauses; no other-> drop"`

### Task 3.7：`Esr.Session.LifecycleObserver` + `Esr.Session.LifecycleObservers`

**文件：**
- 新：`runtime/lib/esr/session/lifecycle_observer.ex`
- 新：`runtime/lib/esr/session/lifecycle_observers.ex`
- 测试：`runtime/test/esr/session/lifecycle_observer_test.exs`

- [ ] **Step 1：写 observer module** —— 见 EN plan 完整 code
- [ ] **Step 2：写 supervisor module** —— DynamicSupervisor，`start_observer/1` API
- [ ] **Step 3：在 `application.ex` children 列表加 `Esr.Session.LifecycleObservers`**
- [ ] **Step 4：在 `AgentSpawner.do_create/1` 在 pipeline integrity check 后 `start_observer(...)`**
- [ ] **Step 5：写测试** —— supervisor exit → chat 收 `:session_terminated` + ETS 清理
- [ ] **Step 6：跑 + commit** —— `"feat(session): LifecycleObserver outside session tree; cleans ETS on subtree DOWN"`

### Task 3.8：ChaosScenarios DSL

**文件：** 新 `runtime/test/support/chaos_scenarios.ex`

- [ ] **Step 1：写 macro 库** —— 见 EN plan 完整 code（`invariant_test/2`、`chaos_inject/3`、`eventually/3`、`assert_chat_reply_within/1`、`setup_session_with_listener/0`）
- [ ] **Step 2：Commit** —— `"test(support): ChaosScenarios DSL — invariant_test, chaos_inject, eventually"`

### Task 3.9：I1-I5 invariant 测试

**文件：**
- 新：`runtime/test/esr/system/invariants_test.exs`
- 新：`docs/notes/system-invariants.md`

- [ ] **Step 1：写 invariants doc** —— 见 EN plan 完整 markdown
- [ ] **Step 2：写测试** —— I1（chaos 下每条 inbound 5s 内有 reply）+ I2（ETS 无死 pid）+ I3/I4/I5
- [ ] **Step 3：跑 + commit** —— `"test(system): I1-I5 invariant tests + system-invariants.md"`

### Task 3.10：Mix task `esr.audit_supervision` + baseline snapshot

**文件：**
- 新：`runtime/lib/mix/tasks/esr.audit_supervision.ex`
- 新：`docs/notes/supervisor-inventory.md`

- [ ] **Step 1：实现 mix task** —— `run/1` 启 app、build_snapshot、diff baseline，diff 非空 `System.halt(1)`
- [ ] **Step 2：生成初始 baseline** —— `cd runtime && mix esr.audit_supervision > ../docs/notes/supervisor-inventory.md`
- [ ] **Step 3：Commit** —— `"feat(mix): esr.audit_supervision + baseline snapshot"`

### Task 3.11：ADR-0002

**文件：** 新 `docs/adr/0002-cc-pty-pair-one-for-all-invariant.md` —— 内容见 spec §4.10 逐字

```bash
git add docs/adr/0002-cc-pty-pair-one-for-all-invariant.md
git commit -m "docs(adr): 0002 — :one_for_all on CC+PTY pair invariant"
```

### Task 3.12：CI 加 audit gate + I5 grep gate

**文件：** 修改 `.github/workflows/ci.yml`

- [ ] **Step 1：加两步** —— 见 EN plan（`mix esr.audit_supervision` + `rg "other -> Logger\.warning"` 检 0 match）
- [ ] **Step 2：Commit** —— `"ci: add audit + I5 grep gate steps"`

### Task 3.13：开 PR + admin-merge

```bash
git push -u origin feat/chat-routing-unify-and-supervision-invariants
gh pr create --base dev --title "feat(supervision): ChatRouting unify + LifecycleObserver + ChaosScenarios + audit + ADR-0002 (PR-3 of 4)" --body "..."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## PR-4：submit_slash MCP tool + RawCollector + CC skill + real-claude test（~270 LOC，8 个 task）

### Task 4.1：分支

```bash
git fetch origin
git checkout -b feat/submit-slash-mcp-tool origin/dev
```

### Task 4.2：`Esr.Slash.ReplyTarget.RawCollector`

**文件：**
- 新：`runtime/lib/esr/slash/reply_target/raw_collector.ex`
- 测试：`runtime/test/esr/slash/reply_target/raw_collector_test.exs`

- [ ] **Step 1：实现** —— 见 EN plan 完整 code（3 个 `respond/3` clause）
- [ ] **Step 2：测试** —— 验 `{:ok, _}` + `{:error, _}` 都正确转发
- [ ] **Step 3：Commit** —— `"feat(slash): Esr.Slash.ReplyTarget.RawCollector"`

### Task 4.3：注册 `submit_slash` tool

**文件：** 修改 `runtime/lib/esr/plugins/claude_code/mcp/tools.ex`

- [ ] **Step 1：加 tool 定义** —— 见 EN plan 完整 attribute；schema 含 `command` required string
- [ ] **Step 2：Commit** —— `"feat(mcp): register submit_slash tool"`

### Task 4.4：FCP `dispatch_tool_invoke/5` 新分支 + per-call Task

**文件：**
- 修改：`runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`（line ~307）
- 测试：`runtime/test/esr/plugins/feishu/submit_slash_handler_test.exs`

- [ ] **Step 1：写失败测试** —— send `{:tool_invoke, "req-1", "submit_slash", %{"command" => "/session:list"}, self(), "ou_test_linyilun"}`，expect `assert_receive {:tool_result, "req-1", {:ok, _result}}, 10_000`
- [ ] **Step 2：在 FCP 加 handler 分支** —— 见 EN plan 完整 code（`dispatch_tool_invoke/5` 新 clause + `run_submit_slash/3` + `pick_origin_chat/1` + `build_internal_envelope/3`）；用 `Task.start` 避免阻塞 mailbox
- [ ] **Step 3：跑 + commit** —— `"feat(feishu): submit_slash dispatched via per-call Task; uses RawCollector"`

### Task 4.5：CC admin skill prompt + Launcher 注入

**文件：**
- 新：`runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md`
- 修改：`runtime/lib/esr/plugins/claude_code/launcher.ex`

- [ ] **Step 1：写 skill prompt** —— 见 spec §5.3 完整 markdown
- [ ] **Step 2：Launcher 注入** —— 在 `prepare_spawn/1` 加 `--system-prompt <admin.md content>` 到 claude argv
- [ ] **Step 3：Commit** —— `"feat(cc): inject admin skill prompt for submit_slash"`

### Task 4.6：Real-claude 集成测试

**文件：** 新 `runtime/test/esr/integration/real_claude_boot_test.exs`

- [ ] **Step 1：写测试** —— 见 EN plan 完整 code（tag `:real_claude`，setup 检 claude 在 PATH，`eventually` 等 mcp.json + cc_process + cc_mcp_ready，发 inbound，等 chat reply 60s）
- [ ] **Step 2：Commit** —— `"test(integration): real-claude boot end-to-end"`

### Task 4.7：CI macos-latest job for `:real_claude`

**文件：** 修改 `.github/workflows/ci.yml`

- [ ] **Step 1：加 macos job** —— 见 EN plan YAML（setup-beam + check claude 在 PATH + `mix test --only real_claude`）
- [ ] **Step 2：Commit** —— `"ci: add macos-latest real_claude integration job"`

### Task 4.8：开 PR + admin-merge

```bash
git push -u origin feat/submit-slash-mcp-tool
gh pr create --base dev --title "feat(agent): submit_slash MCP tool + CC admin skill + real-claude test (PR-4 of 4)" --body "..."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## Self-Review

### Spec 覆盖

| Spec 节 | Plan task |
|---|---|
| §4.1 workspace folders ≥1 | PR-1 全部 8 个 task |
| §4.2 prepare_spawn 唯一入口 | PR-2 Tasks 2.2、2.3、2.4 |
| §4.3 SessionTemplate pipeline 完整性 | PR-2 Task 2.5、2.7 |
| §4.4 FCP :pty_closed | PR-2 Task 2.6 |
| §4.5 ChatRouting 统一 | PR-3 Tasks 3.2-3.6 |
| §4.6 LifecycleObserver | PR-3 Task 3.7 |
| §4.7 system invariants + ChaosScenarios | PR-3 Tasks 3.8-3.9 |
| §4.8 real-claude 集成测试 | PR-4 Tasks 4.6-4.7 |
| §4.9 mix esr.audit_supervision | PR-3 Tasks 3.10-3.12 |
| §4.10 ADR-0002 | PR-3 Task 3.11 |
| §5 submit_slash MCP tool | PR-4 Tasks 4.2-4.5 |

无 spec gap。

### Placeholder 扫描

搜了 TBD/TODO 等。Task 3.10 build_snapshot 含 `# ~40 LOC of straightforward iteration` 是描述性的——快照格式 markdown table 可由实施者定。这是唯一需要实施者判断的地方。

### 类型一致性

- `Esr.Slash.ReplyTarget.RawCollector.respond/3` 接 `%{caller: pid, ref: ref}` —— Task 4.2 + 4.4 一致
- `attach_session/3` 签名 `(chat_id, app_id, sid)` —— Tasks 3.3、3.4、3.5 一致
- `Esr.ActorQuery.fcp_for_session/1` 返回 `{:ok, pid} | :not_found` —— Tasks 3.2、3.6、4.4 一致
- `{:tool_invoke, req_id, tool, args, channel_pid, principal_id}` 消息 shape —— MCP dispatch + FCP handler 一致（Task 4.4）

全部一致。

---

## Open risk（非阻塞）

- **`Esr.Plugins.Feishu.FeishuChatProxy.OutboundEmit.emit/2`** Task 2.6 假设 —— FCP 实际 helper 名可能不同。实施者在写 `notify_chat/2` 前先 grep `emit_reply` / `reply_envelope` 找正确入口
- **`reply_chat_error/4` 在 FAA module-level** Task 3.6 假设 —— 同样：grep + 适配
- **`Esr.PubSub` PubSub topic `cc_mcp_ready/<sid>`** Task 4.6 假设 —— 读 `EsrWeb.McpController` 验 topic 名
- **macos-latest runner** `real_claude` job 需要 claude binary —— runner 默认没有。选项：（a）brew 装（无缓存慢），（b）pre-built image，（c）接受 setup-skip 把测试当 dev-machine-only。选 (c) 成本最低，测试在本地 dev run 仍能抓 bug class
