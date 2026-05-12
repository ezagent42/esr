# Entity Resolver 实施计划（rev-2）

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans。Steps 用 checkbox (`- [ ]`)。

**目标：** 单个 PR 内落地 `Esr.Entity` 统一身份 resolver（spec `docs/superpowers/specs/2026-05-12-entity-resolver-design.md`），完整 alpha enforcement —— 所有 caller migrate、老 API 私有化、`InstanceRegistry.primary/2` 的 breaking change 一并吸收、2 个 e2e scenario。

**架构：** 单 public API `Esr.Entity.resolve_by(kind, by, value) :: {:ok, {kind, uuid}} | :not_found | :invalid_format`。4 个私有 store（`UserStore`/`WorkspaceStore`/`SessionStore`/`AgentStore`）在 migration 窗口期包裹现有 registry；Phase 6 把被包裹的表面私有化。

**Tech Stack：** Elixir 1.18 / OTP 27 / Phoenix / ExUnit / ESR e2e harness。

**分支：** `feat/entity-resolver` off `origin/dev`。单 PR，admin-squash-merge。

**Spec 引用：** `docs/superpowers/specs/2026-05-12-entity-resolver-design.md`（2026-05-12 merge, commit b4695a9）。

**rev-2 相对 rev-1 的修正**（修了 reviewer 揪的 5 个 P0）：

1. **不再编造函数签名**：plan 引用的所有 API 都已 grep 验证存在于 `origin/dev`（详见英文 plan 顶部 "Verified API inventory"）。
2. **真 UUID 字符串**（`Ecto.UUID.generate/0` 或预 mint 的 hex-only fixture），不再用 `"regress-uuid-..."` 之类 49-byte 非 hex 形态。
3. **Phase 0 加 2 个 minimal net-new helper**（不是编造的 mutator）：
   - `Esr.Entity.Agent.InstanceRegistry.get_by_uuid/2` —— `:agent :uuid` resolver 必需的反向索引
   - `Esr.Resource.Workspace.Registry.workspace_id_for_chat/2` —— `:workspace :chat_binding` 直接返 UUID
4. **测试 fixture 用真 mutator path**：`load_snapshot_with_uuids/2`（User）、`Workspace.Registry.put/1`（per-row）、`Grants.load_snapshot/1`（Caps）。共享 helper 在 `runtime/test/support/entity_fixtures.ex`。
5. **`InstanceRegistry.primary/2` breaking change 包括 rev-1 漏的 3 处 test site**：`slash_handler_mention_test.exs:32,47,54`。
6. **E2E 用现有 mock-feishu pattern**（参考 scenario 23），不引入伪造的 `mock_feishu_inbound` / `user_show` 命令。读 UUID 直接从 `users.yaml` + `user.json` grep。

---

## 阶段 + Task 摘要

完整代码 + 命令见英文 plan `docs/superpowers/plans/2026-05-12-entity-resolver-plan.md`。

### Phase 0：Setup + minimal helpers
- 0.1 分支 + baseline grep（39 lines / 29 files）
- 0.2 `InstanceRegistry.get_by_uuid/2` 新增（必需，反向索引）
- 0.3 `Workspace.Registry.workspace_id_for_chat/2` 新增（避免 name hop）
- 0.4 `Esr.TestSupport.EntityFixtures` 共享 fixture helper

### Phase 1：Store 实现 + per-by-clause 测试
- 1.1 `UserStore` + 3 个 `:user` by-clause（8 tests）
- 1.2 `WorkspaceStore` + 4 个 `:workspace` by-clause（10 tests）
- 1.3 `SessionStore` + 3 个 `:session` by-clause（7 tests）
- 1.4 `AgentStore` + 3 个 `:agent` by-clause + `actor_for_agent/2`（7 tests）

### Phase 2：今天 drift bug 的回归测试（红相）
- 2.1 `chat_cap_check_regression_test.exs` —— ou_xxx → username → UUID 链
- 2.2 `resolve_submitter_uuid_form_test.exs` —— UUID-form `submitted_by` 解析

### Phase 3：Wave A migration（drift-fix + breaking change）
- 3.1 `Esr.Resource.Capability.has?/2`（capability.ex:32-53）—— **注意 rev-2 修正**：今天 chain 已经有 ou_xxx→username hop，缺的是再到 UUID 那一跳；rev-1 描述部分错
- 3.2 `Esr.Commands.Workspace.Resolve.resolve_submitter`
- 3.3 `Esr.Entity.SlashHandler` chat-flow lookup
- 3.4 **Breaking change**: `InstanceRegistry.primary/2` 返 UUID。5 prod + **4 test sites（含 rev-2 补的 slash_handler_mention_test.exs:32,47,54）**

### Phase 4：Wave B migration（5 高频路由文件）
按 Task 3.3 模式：feishu_chat_proxy.ex / feishu_app_adapter.ex / mention_parser.ex / entity/server.ex / session/router.ex。

### Phase 5：Wave C migration（21 剩余文件）
机械替换。最后 grep baseline = 0 验证。

### Phase 6：老 public API 私有化（rev-2 显式枚举每个模块）
- 6.1 `User.Registry`：`get_by_id` / `lookup_by_feishu_id` / `get` → defp。保留 `load_snapshot*` / `set_default_workspace` / `get_default_workspace`（@doc false，FileLoader + 1 测试用）
- 6.2 `User.NameIndex`：`id_for_name` → defp。保留 `name_for_id`（跨命名空间）+ mutator
- 6.3 `Workspace.Registry`：`get_by_id` / `workspace_id_for_chat` → defp。保留 mutator 全套
- 6.4 `Workspace.NameIndex`：`id_for_name` → defp。保留 `name_for_id` + mutator
- 6.5 `Session.Registry`：`get_by_id` → defp。保留 mutator
- 6.6 `Session.NameIndex.Registry`：`lookup_by_name` → defp。保留 `claim_uri` / `release_uri`
- 6.7 `Session.ChatRouting.Registry`：`current_session` → defp。保留 attach/detach/set
- 6.8 `InstanceRegistry`：`get` / `get_by_uuid` / `primary` / `pty_actor_id_for` → defp。保留 add/remove/list/set_primary/rename/attach

**ETS `:named_table` 不在本 PR 移除**（rev-2 修正诚实表述）：今天每个 store 仍保留 `:named_table`，因为 boot-time fixture load 仍需要；移到真正私有 ETS 是后续 PR。**enforcement 通过 Elixir 模块可见性（defp）实现**，不通过私有 ETS。Spec §3 + §6 同步更新。

### Phase 7：老 API 编译断 fixture
`runtime/test/esr/entity/old_api_unreachable_test.exs` —— `function_exported?/3` 断言所有 Phase 6 私有化的函数都 not exported。锁住 enforcement。

### Phase 8：E2E scenarios
- 8.1 `31_entity_resolver_chat_flow.sh`：使用现有 mock-feishu pattern（参考 scenario 23），读 `users.yaml + user.json` 拿 UUID，**不**调用 `cap_grant`（这是回归要锁的点）
- 8.2 `32_entity_resolver_cli_uuid_form.sh`：CLI `submitted_by=<uuid>` 成功

### Phase 9：subagent review + PR + admin-merge

---

## 自审（rev-2）

- ✅ Spec 每节都映到 Task
- ✅ 无 placeholder（Wave B/C 的 "按 Task 3.3 pattern" 是清晰引用，不是 hand-wave —— baseline grep 是清单本身）
- ✅ 真 UUID 全部就位
- ✅ 函数签名全部 grep-verified（详见英文 plan）
- ✅ Reviewer 揪的 5 个 P0 全部处理

---

## 执行衔接

**Plan v2 完成。**两种执行方式：

**1. Subagent 驱动**（推荐）—— controller 每 task 一个 fresh subagent，`model: "opus"`。
**2. Inline 执行** —— `superpowers:executing-plans`，批量 + checkpoint。

默认走 subagent 驱动。
