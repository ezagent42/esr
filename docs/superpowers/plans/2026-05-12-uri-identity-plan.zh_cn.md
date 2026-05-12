# URI 身份子系统实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans。

**目标：** 在 6 个 PR 内落地 URI 身份子系统（spec `docs/superpowers/specs/2026-05-12-uri-identity-design.md`）。PR-0 落地新基础设施（`Esr.Uri.Store`、handler behaviour、`Esr.Uri.Compat` migration shim、CI 门、feishu UriHandler），不动任何 caller。PR-1..PR-4 各迁移一个 domain（User / Workspace / Session / Agent）。PR-5 删 Compat shim、加编译断 test、ship e2e。

**架构：** 单 `Esr.Uri.Store` GenServer + public ETS table 同时持有 alias 映射 + entity 数据（tagged value）。`Esr.Uri` 伞门面暴露 `resolve/1`、`alias/2`、`put_entity/3`、`get_entity/1`、`delete/1`。Plugin 通过 manifest `uri_subtrees:` block + `Esr.Uri.Plugin` behaviour 声明 URI 子树。Migration 用 `Esr.Uri.Compat` 保 return shape 的 wrapper，让大部分 call site 改动是机械 sed 替换。

**Tech Stack：** Elixir 1.18 / OTP 27 / Phoenix / ExUnit / `:elixir_uuid`（`UUID.uuid4()` —— `mix.exs:74` 声明的是 `elixir_uuid`，**不是** `ecto_uuid`）。

**分支**（各从 `origin/dev`，admin-squash-merge 顺序合）：
- `feat/uri-store`（PR-0）
- `feat/uri-migrate-user`（PR-1）
- `feat/uri-migrate-workspace`（PR-2）
- `feat/uri-migrate-session`（PR-3）
- `feat/uri-migrate-agent`（PR-4）
- `feat/uri-cleanup`（PR-5）

**Spec 引用：** `docs/superpowers/specs/2026-05-12-uri-identity-design.md`（PR #353，rev-2）

**Migration 范围：** ~387 个 call site 跨 4 个 registry（115 User.Registry + 94 Workspace.Registry + 91 InstanceRegistry + 38 Workspace.NameIndex + 21 User.NameIndex + 16 Session.NameIndex + 12 Session.Registry）

---

## 计划结构

完整代码 + 命令 + 断言见英文 plan `docs/superpowers/plans/2026-05-12-uri-identity-plan.md`。中文 mirror 列阶段标题 + 决策点：

### PR-0：URI store + handler behaviour + Compat shim + CI 门

- **Task 0.1**：`Esr.Uri.Store` GenServer + ETS `:esr_uri_store`，加 supervision tree
- **Task 0.2**：`Esr.Uri.Plugin` behaviour + `Esr.Uri` facade（`resolve/1` / `alias/2` / `put_entity/3` / `get_entity/1` / `delete/1`）
- **Task 0.3**：per-API 单元测试（happy + error 各 case）
- **Task 0.4**：`Esr.Uri.Compat` migration shim（保 return shape 的 wrapper）
- **Task 0.5**：manifest `uri_subtrees:` parser + plugin loader 注册 + feishu UriHandler 实现 + feishu manifest 加 block
- **Task 0.6**：`mix esr.check_uri_drift` CI 门（L1' 路径模式）+ baseline 文件
- **Task 0.7**：PR-0 push + admin-merge

### PR-1：User domain migration（115 + 21 = 136 sites）

- **Task 1.1**：跳过（PR-1 只需 User wrapper，PR-0 已写好）
- **Task 1.2**：用 LSP `find references` 收集 call site 清单（fall back: grep）
- **Task 1.3**：sed 替换调用方到 `Esr.Uri.Compat.*` —— **fat-function-first pattern**（用户 2026-05-12 建议）：
  > 先把 Compat wrapper 写成把老函数 body 机械搬运进来（"fat function"），sed 重命名，跑测试 —— 因为 body 字节级一致，测试**全过**才证明 rename 本身没破坏；**再**把 Compat 简化为 delegate 到 `Esr.Uri.resolve/1`，简化失败回到原 fat 形态。永远不一次"rename + 行为变更"。

  详细模式见英文 plan Task 1.3 开头说明。
- **Task 1.4**：重写 `Esr.Entity.User.FileLoader` 灌入 URI store（`put_entity/3` + `alias/2`）
- **Task 1.5**：删 `User.Registry` + `User.NameIndex`，先把 `User` struct 搬到 `Esr.Entity.User.Struct`，再 sed 重命名所有 struct 引用；更新 baseline；admin-merge

### PR-2：Workspace domain（94 + 38 = 132 sites）

按 PR-1 模式：sed 替换 → FileLoader 重写 → 删模块 → baseline 更新

- 模块：`Esr.Resource.Workspace.Registry` + `Esr.Resource.Workspace.NameIndex`
- Sed 映射：get_by_id / workspace_for_chat / id_for_name / name_for_id → 对应 Compat wrapper
- FileLoader：`Esr.Resource.Workspace.FileLoader` 灌入 URI store
- baseline：~190 → ~58

### PR-3：Session domain（12 + 16 = 28 sites）

- Task 3.1：往 Compat 加 Session wrappers（`session_by_uuid` / `session_uuid_in_scope`）
- 模块：`Esr.Resource.Session.Registry` + `Esr.Session.NameIndex.Registry`
- baseline：~58 → ~30

### PR-4：Agent domain（91 sites + breaking change）

- Task 4.1：往 Compat 加 Agent wrappers，含 `primary_agent_uuid/1`（**breaking** —— 返 UUID 不返 name）
- 5 prod + 4 test 不是简单 sed，是手工改 caller：
  - Prod：`feishu_chat_proxy.ex:631`、`slash_handler.ex:370`、`commands/key.ex:155`、`commands/agent/primary.ex:30`、`resource/session/registry.ex:224`（PR-3 已删，verify）
  - Test：`instance_registry_test.exs:38,44,134,142`、`slash_handler_mention_test.exs:32,47,54`
- baseline：~30 → 0

### PR-5：Cleanup

- Task 5.1：把所有 `Esr.Uri.Compat.*` call 改成直接 `Esr.Uri.*`；删 `Esr.Uri.Compat` 模块
- Task 5.2：`old_api_unreachable_test.exs` —— `Code.ensure_compiled` 断言 4 个 registry + Compat 都 `:nofile`
- Task 5.3：E2E scenarios 31 + 32（用现有 mock-feishu pattern；读 users.yaml 拿 UUID）
- Task 5.4：docs 扫尾 + 关 todo.md 相关行 + admin-merge

---

## 关键技术决策

| 决策 | 选项 | 理由 |
|---|---|---|
| Storage schema | 单 ETS table，tagged value `{:entity, kind, data}` 或 `{:alias, canonical}` | 单 lookup pattern；clear semantics |
| 读写并发 | `:public, read_concurrency: true` 直查 + GenServer 序列化写 | O(1) 读；alias→canonical 一致性 |
| Migration 模式 | Compat wrapper 保 return shape + sed 批量替换 + fat-function-first 安全模式 | 让 ~80% call site 机械处理 |
| Plugin 扩展 | manifest `uri_subtrees:` + `Esr.Uri.Plugin` behaviour | 加新 plugin = 写 manifest + 一个 handler 文件，core 无感 |
| Enforcement | 路径模式 CI 门（`mix esr.check_uri_drift`） | 新 PR 引入老 API 即 FAIL；不靠人工白名单 |
| LSP 用法 | `find references` 收集 call site；`rename symbol` 大模块改名 | 比 grep 准（认 alias / import / unquote） |

---

## 自审

- ✅ Spec 每节都映到 PR/Task
- ✅ 无 placeholder（PR-2/3/4 描述"按 PR-1 模式 + 这些 substitution"是清晰引用，sed 映射全列）
- ✅ 真 API（API inventory 验证过）
- ✅ Real UUIDs（`UUID.uuid4/0` from `:elixir_uuid`，不是 `Ecto.UUID`）
- ✅ Fat-function-first 安全 pattern（用户建议）已写进 Task 1.3
- ✅ LSP 用法在 Task 1.2 标明
- ✅ 5 PR + 1 setup PR = 6 PR 拆分（你认可）

---

## 执行衔接

**Plan v1 完成。**两种执行方式：

**1. Subagent 驱动**（推荐）—— controller 每 task 一个 fresh subagent，`model: "opus"`，PR 之间 review
**2. Inline 执行** —— `superpowers:executing-plans`，批量 + checkpoint

默认走 subagent 驱动。
