# Session-first 默认解析 — 实施计划

> **Agent 工作者：** 必备 sub-skill：用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务推进。每步用 `- [ ]` checkbox 跟踪。

**目标：** 用 per-user default 替代 system "default" workspace；`/user:add` 自动建 `<username>-default`；新增 `/user:use` slash；`/workspace:add-folder name=` 走相同的 fallback 链。最终：fresh-install 上操作员 `/user:add alice` → `/session:new` → `/session:add-agent` 全流程不需要敲 workspace 名。

**架构：** 三个小 primitive、两个新 slash、一个重写的 resolver。(1) `Esr.Entity.User.Registry` 加 `:default_workspace_id` 字段 + ETS-backed `set/get_default_workspace`。(2) `/user:use workspace=<n>` 在 user scope 下对称 `/workspace:use`。(3) `Esr.Commands.Workspace.Resolve` 成为 `Scope.New` 和 `Workspace.AddFolder` 共用的单一链（explicit → chat-default → user-default → error）。(4) `Esr.Resource.Workspace.Bootstrap` 不再写字面量 `default`；改为算 `<bootstrap_user>-default`。(5) `Esr.Commands.User.Add` 自动建 `<username>-default` 并通过 `set_default_workspace` 链接。

**技术栈：** Elixir 1.19 + OTP 27、Phoenix 1.8、ExUnit、ETS、YamlElixir、Jason。E2E shell 脚本在 `tests/e2e/scenarios/`。

**Spec：** [`docs/superpowers/specs/2026-05-08-session-first-default-resolution.md`](../specs/2026-05-08-session-first-default-resolution.md) rev-1，2026-05-07 用户已批。zh_cn 镜像在 `.zh_cn.md`。

**用户硬约束：** *e2e scenario 19 必须和这个 PR 一起走（不能 deferred）。* Phase 8 强制 — Phase 10 开 PR 任务里显式检查 scenario 19 跑过。

---

## 文件结构

| 文件 | 用途 | 动作 |
|---|---|---|
| `runtime/lib/esr/entity/user/registry.ex` | User struct + ETS API | 改 — 加 `:default_workspace_id` 字段、`set/get_default_workspace/2` |
| `runtime/lib/esr/entity/user/file_loader.ex` | yaml + user.json → snapshot | 改 — 从 `user.json` 读 `default_workspace_id` |
| `runtime/lib/esr/commands/user/use.ex` | `/user:use` 命令 | **新建** |
| `runtime/lib/esr/commands/user/add.ex` | `/user:add` 命令 | 改 — 自动建 user-default workspace |
| `runtime/lib/esr/commands/workspace/resolve.ex` | 共享解析链 | **新建** |
| `runtime/lib/esr/commands/scope/new.ex` | `/session:new` 命令 | 改 — fallback 链换成 user-default |
| `runtime/lib/esr/commands/workspace/add_folder.ex` | `/workspace:add-folder` | 改 — `name` 可选，复用 Resolve |
| `runtime/lib/esr/resource/workspace/bootstrap.ex` | First-boot ws seed | 重写 — `<bootstrap_user>-default`，不要字面量 `default` |
| `runtime/priv/slash-routes.default.yaml` | Slash 注册 | 改 — 加 `/user:use`；放宽 `/workspace:add-folder` |
| `runtime/priv/schemas/user.v1.json` | user.json schema | 改 — 加 `default_workspace_id` |
| `runtime/test/esr/entity/user/registry_test.exs` | Registry 测试 | 改 — 加 set/get default_workspace 测试 |
| `runtime/test/esr/commands/user/add_test.exs` | User.Add 测试 | 改 — 断言自动建 ws + link |
| `runtime/test/esr/commands/user/use_test.exs` | `/user:use` 测试 | **新建** |
| `runtime/test/esr/commands/workspace/resolve_test.exs` | 链测试 | **新建** |
| `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs` | 新链测试 | 改 — system-default 分支换成 user-default |
| `runtime/test/esr/commands/workspace/add_folder_test.exs` | AddFolder 测试 | 改 — name 缺省时链 fallback |
| `runtime/test/esr/resource/workspace/bootstrap_test.exs` | Bootstrap 测试 | **新建**（或替换） |
| `runtime/test/esr/application_first_boot_test.exs` | First-boot 集成 | 改 — 删字面量 `"default"` 断言 |
| `runtime/test/support/workspace_fixture.ex` | 测试 fixture | 改 — 接受 `default_for_user:` kwarg |
| `tests/e2e/scenarios/19_session_first_default.sh` | Scenario 19 | **新建** |
| `Makefile` | e2e target | 改 — 加 `e2e-19` |
| `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` + `.zh_cn.md` | 审计 doc | 改 — 闭 §3 + step 9 |
| `docs/futures/todo.md` | 持久 TODO | 改 — 标 "Migrate to session-first model" 闭合（Phase 1 部分） |
| `runtime/lib/esr/paths.ex` | 路径 helper | 不动 — `users_dir/0`、`user_dir/1`、`user_json/1` 已存在 |
| `runtime/lib/esr/resource/chat_scope/registry.ex` | ChatScope | 不动 — `set/get_default_workspace/3` 原样复用 |

---

## 分支 + PR 策略

- 单分支 off `dev`：`feat/session-first-default-resolution`
- PR target 是 `dev`（多实例工作已在 dev；不需要集成分支）
- scenario 19 绿之后单 squash-merge 进 dev

---

## Phase 0 — Setup

完整步骤参见英文版 [`Phase 0`](2026-05-08-session-first-default-resolution-plan.md#phase-0--setup)。要点：拉最新 dev、建 `feat/session-first-default-resolution` 分支、跑 `mix test` 记录基线失败数（应为 ~10 个 pre-existing flaky），确认 `~/.esrd*` 已 wipe。

---

## Phase 1 — User.Registry default_workspace_id

### Task 1.1：给 User struct 加 `:default_workspace_id` 字段

英文版完整代码见 [`Task 1.1`](2026-05-08-session-first-default-resolution-plan.md#task-11-add-default_workspace_id-field-to-the-user-struct)。

要点：
- 在 `runtime/lib/esr/entity/user/registry.ex:41` 改 `defstruct [:username, feishu_ids: []]` 为 `defstruct [:username, feishu_ids: [], default_workspace_id: nil]`
- 加两个 struct 测试（默认 nil + 构造时携带 UUID）
- TDD：先写测试 → 跑 → fail → 改 struct → 跑 → pass → commit

### Task 1.2：set/get_default_workspace/2 API + ETS

英文版完整代码见 [`Task 1.2`](2026-05-08-session-first-default-resolution-plan.md#task-12-add-setget_default_workspace2-api--ets)。

要点：
- 加 4 个测试（set+get、未 set 时 :not_found、未知用户 {:error, :not_found}、覆盖）
- 在 `User.Registry` 加 `set_default_workspace/2` + `get_default_workspace/1` public API + `handle_call({:set_default_workspace, ...}, ...)` GenServer 处理
- 同步更新 `@by_uuid` 表（如果该用户有 UUID 行的话）

---

## Phase 2 — user.json schema bump + FileLoader 读

### Task 2.1：bump `user.v1.json` schema（加非必填 `default_workspace_id`）

要点：
- 在 `runtime/priv/schemas/user.v1.json` 的 `properties:` 加 `default_workspace_id: {"type": ["string", "null"]}`
- 不放 `required` 数组 — 向后兼容
- 验证 schema 还能 parse

### Task 2.2：FileLoader 从 user.json 读 `default_workspace_id`

英文版完整代码见 [`Task 2.2`](2026-05-08-session-first-default-resolution-plan.md#task-22-fileloader-reads-default_workspace_id-from-userjson)。

要点：
- 加 round-trip 测试（写 user.json 含 `default_workspace_id` → load → 断言 `Registry.get` 返回的 User 含该 id；缺省时为 nil）
- `load_from_users_dir/1` 把 `default_workspace_id` 加到 User struct
- 加伴随 helper `read_default_workspaces_from_dir/1`，yaml-present 路径用它 → `Registry.set_default_workspace` apply

### Task 2.3：User.Add 写 `default_workspace_id`（Phase 2 占位 = nil）

要点：
- 加测试断言 user.json 含 `default_workspace_id` key（值是 nil）
- `write_user_json/2` 的 doc map 加 `"default_workspace_id" => nil`
- Phase 4 会覆盖成真实 UUID

---

## Phase 3 — `/user:use` slash 命令

### Task 3.1：建 `Esr.Commands.User.Use`

英文版完整代码见 [`Task 3.1`](2026-05-08-session-first-default-resolution-plan.md#task-31-create-esrcommandsuseruse)。

要点：
- 4 个测试：成功（按 name 解析 → 链接 user-default）、未知 workspace、缺 args、submitter 解析失败
- `execute/1` 解 submitter（优先 `submitter_username`，否则通过 `lookup_by_feishu_id` 解 `submitted_by`），通过 `Workspace.NameIndex.id_for_name` 解 workspace name → UUID，调用 `User.Registry.set_default_workspace`
- 返回结构：`{"action" => "user_default_set", "username" => ..., "workspace" => ..., "workspace_id" => ...}`

### Task 3.2：把 `/user:use` 接进 slash-routes.default.yaml

要点：
- 在 `/user:whoami` 之后加 `/user:use` slash 块（`kind: user_use`、`permission: "workspace.create"`、`command_module: "Esr.Commands.User.Use"`）
- 同步在 yaml 末尾的 kind overlay 区加 `user_use` 条目（让 admin-submit 能跑）
- 验证 yaml parse + slash schema controller 测试通过

---

## Phase 4 — User.Add 自动建 user-default workspace

### Task 4.1：User.Add 建 `<username>-default` workspace + 设为 user-default

英文版完整代码见 [`Task 4.1`](2026-05-08-session-first-default-resolution-plan.md#task-41-useradd-creates-username-default-workspace--sets-as-user-default)。

要点：
- 加两个测试：
  1. user_add 后 `<username>-default` workspace 在 registry，owner 是新用户，user-default link 已立
  2. result map 含 `"default_workspace"` + `"default_workspace_id"` keys
- 改 `Esr.Commands.User.Add.execute/1`：
  - 先生成 ws_uuid
  - `with` 链：写 yaml → 写 user.json（含 ws_uuid）→ 创建 workspace → set_default_workspace
  - 部分失败回滚
- 加 helper `create_user_default_workspace/3`（按 ws_uuid + ws_name + owner 建 ws struct + 写 disk 通过 `Registry.put`）
- 改 `write_user_json/2` 接受 `default_workspace_id` 参数

### Task 4.2：更新 Phase-2 占位测试

要点：
- 把 Phase 2 那个 `assert doc["default_workspace_id"] == nil` 改成 `assert is_binary(doc["default_workspace_id"])`
- 跑测试确认

---

## Phase 5 — Bootstrap 重写（无字面量 `default`）

### Task 5.1：`Esr.Resource.Workspace.Bootstrap` 建 `<bootstrap_user>-default`

英文版完整代码见 [`Task 5.1`](2026-05-08-session-first-default-resolution-plan.md#task-51-esrresourceworkspacebootstrap-creates-bootstrap_user-default)。

要点：
- 3 个测试：
  1. `ESR_BOOTSTRAP_PRINCIPAL_ID` 未设时 no-op，**且字面量 "default" workspace 不存在**
  2. env 设了 + user 已加载 → 创建 `<username>-default` + 立 user-default link
  3. 幂等（重跑两次 ws id 相同）
- 重写 `Bootstrap` 模块：
  - 通过 `lookup_by_feishu_id` 把 env id 解析到 username
  - 如果 user 已有 default_workspace_id 跳过；否则建 `<username>-default` ws + 链
  - 全过程 try/rescue 兜底（早期 boot 阶段 ETS 表可能没起来）

### Task 5.2：更新 `application_first_boot_test.exs`

要点：
- 老的 `describe "ensure_default_workspace"` 整段删
- 替换为新的 `describe "bootstrap user-default workspace"` — 测试：
  1. 创建 `<user>-default` + 链
  2. 幂等
  3. 删 legacy yaml + 留下 bootstrap workspace
- 每个测试 setup 注入一个已知 user 到 `User.Registry` + 设 `ESR_BOOTSTRAP_PRINCIPAL_ID` env

---

## Phase 6 — Workspace.Resolve helper + Scope.New 链重写

### Task 6.1：建 `Esr.Commands.Workspace.Resolve`

英文版完整代码见 [`Task 6.1`](2026-05-08-session-first-default-resolution-plan.md#task-61-create-esrcommandsworkspaceresolve)。

要点：
- 5 个测试覆盖链每一层（explicit、chat-default 胜过 user-default、user-default 在无 chat-default 时胜、空时 :no_match、submitter 通过 feishu_id 解析）
- `resolve_workspace_for_args/1` 返回 `{:explicit | :chat_default | :user_default, name}` 或 `:no_match`
- 返回 **name** 而非 UUID（链保持纯净；调用方按需 `NameIndex.id_for_name`）
- submitter 优先 `args["submitter_username"]`，否则 `args["submitted_by"]` → `lookup_by_feishu_id`
- 加 `workspace_name_for_args/1` 和 `workspace_id_for_args/1` 两个便利 helper

### Task 6.2：把 `Scope.New.resolve_workspace` 切到共享链

英文版完整代码见 [`Task 6.2`](2026-05-08-session-first-default-resolution-plan.md#task-62-switch-esrcommandsscopenewresolve_workspace-to-the-shared-chain)。

要点：
- 加 3 个测试：
  1. no_workspace_resolvable 当链所有层都不命中
  2. user-default 在无 chat-default 时胜
  3. **字面量 `default` workspace 即使存在也不再作为 fallback**
- 改 `resolve_workspace_if_needed/1` 调用 `Esr.Commands.Workspace.Resolve.resolve_workspace_for_args/1`
- 删掉 `resolve_workspace/1`、`lookup_chat_default/1`、`workspace_exists?/1` 这些 dead helper（搬到 Resolve）
- 错误信息更新为提示用户跑 `/user:use` 或显式传 workspace=

---

## Phase 7 — `/workspace:add-folder name=` 可选

### Task 7.1：AddFolder 通过 Resolve 链支持隐式 `name=`

英文版完整代码见 [`Task 7.1`](2026-05-08-session-first-default-resolution-plan.md#task-71-addfolder-accepts-implicit-name-via-resolve-chain)。

要点：
- 3 个测试：
  1. name= 缺省时 fallback 到 chat-current
  2. name= 缺省时 fallback 到 user-default（无 chat-current）
  3. name= 缺省 + 链全空 → no_workspace_target error
- 在 `AddFolder.execute/1` 加新 clause：当 `name` 不在 args 中、`path` 在时，走 Resolve 链，把解析出来的 name 塞进 args 后递归调用既有 clause
- 加 `merge_submitter/2` 把 cmd 顶层的 submitter 信息合到 args（让 Resolve 看得到）
- 更新 `/workspace:add-folder` slash 描述：name 标 `required: false`，描述加 "name= 缺省时 fallback ..."

---

## Phase 8 — E2E scenario 19（PR 前必跑，user 硬性要求）

### Task 8.1：建 scenario 19 — 第一次操作员 session-first 路径

英文版完整代码见 [`Task 8.1`](2026-05-08-session-first-default-resolution-plan.md#task-81-create-scenario-19--first-time-operator-session-first-path)。

要点：
- 6 步流：
  1. `user_add` → 断言 result 含 `default_workspace`、名为 `<username>-default`
  2. `session_new`（无 workspace= arg、无 chat-default）→ 断言绑到 user-default
  3. `workspace_add_folder`（无 name=）→ 断言 fallback 到 user-default
  4. `user_use` 切到第二个 workspace
  5. 再 `session_new` → 断言绑到新 user-default
  6. `workspace_describe workspace=default` → 断言 `unknown_workspace`（M-5/D4 不变量）
- chmod +x、加 `e2e-19` Makefile target、syntax check
- 跑：先 `tools/wipe-esrd-home.sh --dev`，再 `make e2e-19` → 期待 tail 含 `PASS: 19_session_first_default`

---

## Phase 9 — 文档梳理

### Task 9.1：闭合审计 doc

要点：
- 在 `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` 的 §3 cross-cutting 部分加一个 closure 块标记本 spec 闭合 step 9
- zh_cn 镜像同步

### Task 9.2：更新 `docs/futures/todo.md`

要点：
- 把 "Migrate to session-first model" 那条标 Phase 1 已落地（PR #X，2026-05-08），Phase 2（`/session:add-folder` 改运行 scope）deferred

### Task 9.3：更新 `tools/wipe-esrd-home.sh` docstring

要点：
- 在 `# SPEC:` 注释里加一行引用本 spec

---

## Phase 10 — Code review + PR + merge

### Task 10.1：最终回归扫

要点：
- 全 unit suite，失败数应 ≤ Phase 0 基线
- M-5 不变量 grep：`bootstrap.ex` 无字面量 `"default"`，`scope/new.ex` 无 `workspace_exists?("default")` / `fallback.*default`
- scenario 19 从 clean wipe 起跑通
- scenario 14 + 18 仍绿（回归）

### Task 10.2：subagent code-reviewer pass

英文版有完整 prompt。要点：dispatch superpowers:code-reviewer，model="opus"，brief 让它检查 6 项（无字面量 default、auto-create 原子、user:use 解 submitter、Resolve 不漏 UUID、Bootstrap 幂等、scenario 19 真跑过）。如有发现 inline 修。

### Task 10.3：push + 开 PR + admin merge

要点：
- `git push -u origin feat/session-first-default-resolution`
- `gh pr create --base dev` 标题 "feat: session-first default workspace resolution (M-5)"，body 含 spec 链接 + Test plan checklist（其中 scenario 19 必标 ✅）+ 迁移说明
- `gh pr merge --admin --squash --delete-branch`
- `git fetch origin dev && git log origin/dev -1 --oneline` 验证
- 飞书通知 chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9`，含 commit hash + scenario 19 result

---

## Self-review

- ✅ Spec 覆盖：D1（§4.6）、D2（§4.6）、D3（§4.4 → Tasks 4.1-4.2）、D4（§4.5 → Tasks 5.1-5.2）、D5（§4.7 → Task 7.1）、D6（Phase 0 step 3 + scenario 19 wipe）
- ✅ 占位扫描：无 "TBD" / "implement later" / "TODO" / "类似 Task N"
- ✅ 类型一致：`set_default_workspace/2`、`Resolve.resolve_workspace_for_args/1`、`{:explicit, name}` / `{:chat_default, name}` / `{:user_default, name}` / `:no_match` tag、User struct `:default_workspace_id`、result map keys 在所有任务中一致

## 执行交接

Plan 写好并存到 `docs/superpowers/plans/2026-05-08-session-first-default-resolution-plan.zh_cn.md`（英文原版同目录 `.md`）。两条执行路：

1. **Subagent-Driven（推荐）** — 我每个任务派一个 fresh subagent，任务间 review，迭代快
2. **Inline Execution** — 在本会话里按 executing-plans 批量跑，每批 checkpoint review

选哪个？
