# Workspace VS-Code 风格重设计 — 实现 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 按 task 逐个跑这个 plan。Steps 用 checkbox（`- [ ]`）追踪。

**目标：** 把单文件 `workspaces.yaml` 替换成混合 per-workspace 目录（`<repo>/.esr/workspace.json` repo-bound 或 `$ESRD_HOME/<inst>/workspaces/<name>/workspace.json` ESR-bound），引入 UUID 身份让 capability 重写不再必要，同时落地 11 个新 slash command 完成生命周期 CLI 管理。

**架构：** workspace 仍是 Resource（元模型角色不变）。两个 file-loader 路径合流到一个内存 `Esr.Resource.Workspace.Registry`。`workspace.json.id` 里的 UUID 是规范身份；capabilities.yaml 按 UUID 存 caps；CLI 在边界翻译 name↔UUID。Session→workspace 绑定按 UUID 走且 spawn 后不可变。**没有文件 watcher** —— 所有 mutation 走 CLI 的内联 invalidate。

**技术栈：** Elixir/OTP（`Esr.Resource.Workspace.*` GenServer + ETS）、Jason JSON、YamlElixir yaml、ExUnit 测试、JSON Schema 给编辑器校验。

**Spec：** `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`（rev 3，2026-05-06 用户批准）。

**估算：** ~1400-1800 LOC，8 phase（rev-2：subagent code-reviewer 发现 Phase 4.11 slash 数错 [10 新非 8]；加显式 Watcher 删除任务；加 Risk #2 并发 race 测试；加 Risk #3 agents.yaml-存活测试；加 Phase 0.0 UUID 依赖）。每个 phase 一个或多个 commit。Plan 目标单 PR ~28 commit。

---

## 完整 plan 内容

**重要**：完整的 task list、文件清单、code 例子、bash 命令、commit message 全部在英文版：

📄 `docs/superpowers/plans/2026-05-06-workspace-vs-code-redesign-plan.md`（2498 行）

英文版包含每个 task 的：
- 创建 / 修改 / 测试文件路径
- 完整的 ExUnit / Elixir / yaml 代码示例
- 精确的 `mix test` / `git commit` 命令
- 每个 step 的预期结果

中文版只翻译**结构 + 关键决策 + 风险提醒**——code block / commit message / file path 保留英文（执行 task 时直接看英文版即可）。

---

## Phase 概览

### Phase 0 — Scaffolding

**目标**：依赖、JSON Schema、Path helper 准备好。

- **Task 0.0**：加 `:elixir_uuid` (hex: `:uuid_utils`) 进 `runtime/mix.exs`。codebase 当前**没有** UUID 库（已验证 mix.exs / mix.lock），后续所有 task 调 `UUID.uuid4()` 都依赖这个 task 先 land。
- **Task 0.1**：写 `runtime/priv/schemas/workspace.v1.json`（JSON Schema v1，给编辑器 + CI 校验）。
- **Task 0.2**：扩 `Esr.Paths` 加 helper：`workspaces_dir/0`, `workspace_dir/1`, `workspace_json_esr/1`, `workspace_json_repo/1`, `topology_yaml_repo/1`, `registered_repos_yaml/0`, `sessions_dir/0`, `session_dir/1`, `workspace_schema_v1/0`。

### Phase 1 — UUID 身份 + workspace.json 形态（无 UI）

**目标**：底层数据结构 + 文件 IO + 索引模块独立可测。

- **Task 1.1**：`Esr.Resource.Workspace.Struct` —— 内存 workspace 表示。字段：`id`、`name`、`owner`、`folders`、`agent`、`settings`、`env`、`chats`、`transient`、`location`（`{:esr_bound, dir}` 或 `{:repo_bound, repo_path}`）。
- **Task 1.2**：`Esr.Resource.Workspace.FileLoader` —— 读 workspace.json，校验 schema_version、UUID 格式、name vs 父目录匹配（ESR-bound）、transient 在 repo-bound 上禁止。
- **Task 1.3**：`Esr.Resource.Workspace.JsonWriter` —— 原子写（`*.tmp` → fsync → rename）。
- **Task 1.4**：`Esr.Resource.Workspace.RepoRegistry` —— 读写 `registered_repos.yaml` 的纯文件 IO 模块（per-machine repo path 列表）。
- **Task 1.5**：`Esr.Resource.Workspace.NameIndex` —— 双向 ETS-backed name↔id 索引；提供 `put/3`、`id_for_name/2`、`name_for_id/2`、`rename/3`、`delete_by_id/2`、`all/1`。

### Phase 2 — Registry 重写

**目标**：内存 registry 合并两个发现源 + UUID 重复校验。

- **Task 2.0**：**删 `Esr.Resource.Workspace.Watcher`**（spec rev-3 显式不要 file watcher）。已确认 `runtime/lib/esr/resource/workspace/watcher.ex` 存在；同时清掉 supervisor child entry。⚠️ 必须在 Phase 6 删 yaml 之前删掉，否则 watcher 会 crash-loop 指向不存在的文件。
- **Task 2.1**：`Esr.Resource.Workspace.Registry` GenServer 重写。
  - boot：扫 `workspaces_dir/0` 拿 ESR-bound + 读 `registered_repos.yaml` 拿 repo-bound + 用 NameIndex + ETS 建 registry。
  - 公开 API：`list_names/0`、`list_all/0`、`get/1`、`get_by_id/1`、`put/1`、`delete_by_id/1`、`rename/2`、`workspace_for_chat/2`、`refresh/0`。
  - 重复 UUID（两个文件用同一个 id）→ boot 失败显示两个文件路径。
  - rename 处理 ETS 索引 + 文件系统 `mv`（ESR-bound）；repo-bound rename 仅改 workspace.json.name（目录在 repo 内不动）。

### Phase 3 — Capability UUID 翻译

**目标**：caps 持久化按 UUID，CLI 输入 / 输出按 name 翻译。

- **Task 3.1**：`Esr.Resource.Capability.UuidTranslator` —— `name_to_uuid/1`、`uuid_to_name/1`。`session:` / `workspace:` 前缀的 cap 翻译；其他（`user.manage`、`adapter.manage` 等全局 perm）不变透传。
- **Task 3.1（续）**：改 `Esr.Commands.Cap.Grant.execute/1` 和 `Esr.Commands.Cap.Revoke.execute/1` 在持久化前调 `UuidTranslator.name_to_uuid/1`。未知 workspace name → `{:error, %{"type" => "unknown_workspace"}}`。
- **Task 3.2**：改 `Esr.Commands.Cap.{List,Show,WhoCan}.execute/1` 在 render 前对每条 cap 调 `UuidTranslator.uuid_to_name/1`。找不到的 UUID 渲染成 `<resource>:<UNKNOWN-7b9f3c1a-...>/<perm>` 让 operator 能 `/cap revoke`。

### Phase 4 — Slash command 模块

**目标**：14 个 slash 全部就位（10 新 + 4 重构）。

| Slash | 状态 | 模块 |
|---|---|---|
| `/new-workspace` | refactor | `Esr.Commands.Workspace.New` |
| `/workspace info` | refactor | `Esr.Commands.Workspace.Info` |
| `/workspace describe` | refactor | `Esr.Commands.Workspace.Describe` |
| `/workspace sessions` | refactor | `Esr.Commands.Scope.List`（已有，按 UUID lookup）|
| `/workspace list` | **新** | `Esr.Commands.Workspace.List` |
| `/workspace edit` | **新** | `Esr.Commands.Workspace.Edit` |
| `/workspace add-folder` | **新** | `Esr.Commands.Workspace.AddFolder` |
| `/workspace remove-folder` | **新** | `Esr.Commands.Workspace.RemoveFolder` |
| `/workspace bind-chat` | **新** | `Esr.Commands.Workspace.BindChat` |
| `/workspace unbind-chat` | **新** | `Esr.Commands.Workspace.UnbindChat` |
| `/workspace remove` | **新** | `Esr.Commands.Workspace.Remove` |
| `/workspace rename` | **新** | `Esr.Commands.Workspace.Rename` |
| `/workspace use` | **新** | `Esr.Commands.Workspace.Use`（+ 改 `Esr.Resource.ChatScope.Registry` 加 `chat_to_default_workspace_id` 字段）|
| `/workspace import-repo` | **新** | `Esr.Commands.Workspace.ImportRepo` |
| `/workspace forget-repo` | **新** | `Esr.Commands.Workspace.ForgetRepo` |

**关键决策摘要**（详细在英文版每个 Task）：

- **Task 4.1 `/new-workspace`**：传 `folder=<path>` → repo-bound（创 `<path>/.esr/workspace.json` + `RepoRegistry.register`）；不传 folder → ESR-bound。`transient=true` 在 repo-bound 上拒绝。生成 `UUID.uuid4()`。
- **Task 4.3 `/workspace edit --set`**：`--set settings.cc.model=opus` → `settings["cc.model"] = "opus"`（settings keys 是扁平 dot-string，**不嵌套**）。`env.<KEY>=<value>` → 嵌套一级。布尔 / 整数 / CSV 列表自动解析。锁定字段：`id`、`name`、`chats`、`folders`、`location`、（repo-bound 的）`transient`。
- **Task 4.6 `/workspace remove`**：repo-bound 仅删 `<repo>/.esr/workspace.json` + `topology.yaml`，**绝不 `rm -rf <repo>/.esr/`**。必须有 sentinel 测试（pre-create `.esr/agents.yaml` 必须存活）。
- **Task 4.8 `/workspace use`**：扩 `Esr.Resource.ChatScope.Registry` 状态加 `chat_to_default_workspace_id :: %{{chat_id, app_id} => uuid}`。`set_default_workspace/3` + `get_default_workspace/2` 公共 API。
- **Task 4.9 `/workspace import-repo` + `forget-repo`**：register / unregister `registered_repos.yaml` + 触发 `Registry.refresh/0`。
- **Task 4.11**：把 10 个新 slash entry + 4 个修改写进 `runtime/priv/slash-routes.default.yaml`。每个 entry 显式列 args / permission / requires_*_binding / category / description。

### Phase 5 — Session 集成

**目标**：workspace 解析链 + immutable 绑定 + transient cleanup。

- **Task 5.1**：`Esr.Commands.Scope.New.execute/1` 加 `resolve_workspace/2` 三步链：
  1. 显式参数 `args["workspace"]`
  2. 通过 envelope chat_id+app_id 查 `ChatScope.Registry.get_default_workspace/2`
  3. fallback `default` workspace（确认 `Workspace.Registry.get("default")` 存在）
  4. 都没 → `{:error, :no_workspace_resolvable}`
- **Task 5.2**：transient cleanup hook + **Risk #2 并发 race 测试**。最后一个 session 退出时调 `Workspace.Registry.delete_if_no_sessions/1`（GenServer.call 自带 serialisation）。测试 fork 两个并发 task：(a) end_session（触发 cleanup） (b) new_session（同 workspace）—— assert 二者 XOR：要么 cleanup 赢，要么 new spawn 赢，确定性。
- **Task 5.3**：把 5.1 的 `chat_default_workspace/1` helper 实际接到 `ChatScope.Registry.get_default_workspace/2`（在 Task 4.8 已实现）。

### Phase 6 — Boot 集成

**目标**：第一次 boot 删旧 yaml + 自动建 default workspace。

- **Task 6.1**：`Esr.Resource.Workspace.Bootstrap` Task child（短期 transient）。
  - 检测 `workspaces.yaml` legacy 文件 → `File.rm!` + WARN log 写删除路径
  - 没 default workspace → 创建 ESR-bound `default`（owner = `ESR_BOOTSTRAP_PRINCIPAL_ID` 或 fallback `"admin"`）
  - 测试：tmp ESRD_HOME 放 stale yaml → boot → assert (a) yaml 没了 (b) WARN log 有 (c) default workspace 在 registry 里。

### Phase 7 — describe_topology 集成

**目标**：`Esr.Resource.Workspace.Describe.describe/1` 叠加 `<folders[0]>/.esr/topology.yaml`。

- **Task 7.1**：refactor `describe.ex`。读顺序：workspace.json identity → overlay topology.yaml → chats[]。security allowlist（PR-222）不变。多 folder 仅读 `folders[0]/.esr/topology.yaml`（spec rev-3 决策）。所有 PR-21z 的 5 个安全测试必须继续 pass。

### Phase 8 — Docs sweep + e2e + PR

**目标**：所有过期 docs 同步、e2e 全链路覆盖、PR 开。

- **Task 8.1**：sweep 这些文件（grep `workspaces.yaml` / `workspace.root` 替换或加 deprecation pointer）：
  - `README.md` + `README.zh_cn.md`
  - `docs/dev-guide.md`
  - `docs/cookbook.md`
  - `docs/notes/actor-topology-routing.md`
  - `docs/futures/todo.md`（关掉 workspace-redesign 条目，update init redesign 依赖）
  - `docs/architecture.md`（如存在）
  - 所有 `docs/superpowers/specs/*` 引用 workspace.yaml 形态的文件
- **Task 8.2**：e2e scenario `tests/e2e/scenarios/14_workspace_lifecycle.sh` —— 全生命周期：create repo-bound → list → edit settings.cc.model → info → rename → cap grant 引用新名字 → remove --force。
- **Task 8.3**：subagent code-reviewer pass on the impl branch。修复发现的 issue。
- **Task 8.4**：开 PR（base = dev）；PR description 包含 ⚠️ operator pre-merge checklist：升级前 cat workspaces.yaml 备份，升级后用 `/new-workspace` 重建。

---

## Self-review checklist（plan 完成前过一遍）

- [ ] **Spec coverage**：spec 每个章节都映射到 ≥1 task
- [ ] **Placeholder scan**：没有 "TBD"、"TODO"、"implement later"
- [ ] **Type 一致性**：`Esr.Resource.Workspace.Struct` 字段名跨 phase 一致（id, name, owner, folders, agent, settings, env, chats, transient, location）
- [ ] **Docs sweep**：Phase 8.1 列出 spec 提到的所有 doc 路径
- [ ] **Self-review final**：一坐下来从头到尾读一遍
- [ ] **Spec-rev parity**：确认 spec HEAD commit 和 plan 写时一致（当前 spec rev-3 EN: `354d8a8`；zh: `14dd8d3`；plan v1: `cc23a17`；plan v2: 本 rev）。任何 implementation subagent dispatch 之前重新 check spec 没被悄悄改过。

---

## Execution

**Plan 写完保存在 `docs/superpowers/plans/2026-05-06-workspace-vs-code-redesign-plan.md`（英文，2498 行）+ `.zh_cn.md`（本文件）。两个执行选项：**

**1. Subagent-Driven（推荐）** —— per-task 派发新 subagent + task 间 review，迭代快。

**2. Inline Execution** —— 在本 session 跑 task，分批 checkpoint review。

**选哪个？**
