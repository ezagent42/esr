# Plugin 范围内命令注册机制 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 增加 manifest 驱动的机制让 plugin 在不改核心文件的情况下注册 slash 和 admin-CLI 命令；通过物理迁移 3 条已有的 plugin-owned 命令（`bind_feishu`、`unbind_feishu`、`notify`）到 feishu plugin 来端到端验证机制。

**架构：** `Esr.Plugin.Manifest` 增加 `slash_routes:` 声明块（与 `capabilities:` / `python_sidecars:` 平行）。`Esr.Plugin.Loader.start_plugin/2` 调用新的 `register_slash_routes/2` 步骤把 overlay 注册到 `Esr.Resource.SlashRoute.Registry`。Registry 从"单 ETS 替换"重构成"base 表 + per-plugin overlay map + 合并视图"——base 与 overlays 之间的冲突 = 硬错误。命名空间双层兜底：manifest validate 时 + registry register 时各拦截一次。

**技术栈：** Elixir 1.19、OTP 27、ExUnit、ETS、YamlElixir、Jason

**Spec：** `docs/superpowers/specs/2026-05-08-plugin-command-registration.md` rev-2（用户 2026-05-08 已 approve）

**分支：** 实施落在已有的 `feat/session-first-default-resolution` 分支（让 #6 与 #5 一并 ship 到同一个 PR）。Spec 提交 `5424fd5` + `3d882c9` 在 Phase 0 cherry-pick 上去。

**预估总规模：** ~825 LOC + ~500 LOC 测试 = ~1325 LOC，分 7 phase / 22 task。

---

## 文件结构

### 新增文件

| 路径 | 职责 |
|------|------|
| `runtime/lib/esr/plugins/feishu/commands/bind_user.ex` | `Esr.Plugins.Feishu.Commands.BindUser` —— `Esr.Commands.User.BindFeishu` 的原样搬迁 |
| `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex` | `Esr.Plugins.Feishu.Commands.UnbindUser` —— `Esr.Commands.User.UnbindFeishu` 的原样搬迁 |
| `runtime/lib/esr/plugins/feishu/commands/notify.ex` | `Esr.Plugins.Feishu.Commands.Notify` —— `Esr.Commands.Notify` 的原样搬迁 |
| `runtime/test/esr/plugins/feishu/commands/notify_test.exs` | 已有 notify_test 搬迁 + 模块名更新 |
| `runtime/test/support/noop_command.ex` | `Esr.Test.NoopCommand` —— 通用 `Esr.Role.Control` stub，给 slash-route registry 测试用 |
| `runtime/test/esr/resource/slash_route/overlay_test.exs` | 新测试模块覆盖 overlay 行为（register/unregister/collision/preserve） |

### 修改文件

| 路径 | 职责 |
|------|------|
| `runtime/lib/esr/plugin/manifest.ex` | 加 `slash_routes` 到 allowed declares；加 `validate_slash_routes/1`；加 `slash_route_snapshot/1` reader |
| `runtime/lib/esr/plugin/loader.ex` | `start_plugin/2` 的 with-chain 插入 `register_slash_routes/2`；`stop_plugin/1` 调用 `unregister_overlay/1` |
| `runtime/lib/esr/resource/slash_route/registry.ex` | state 重构为 `base + overlays + merged_view`；加 `register_overlay/2` + `unregister_overlay/1` 含冲突检测 |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | 抽出 `parse_block_to_snapshot/1` 让 base yaml 和 plugin manifest 共用一个 parser |
| `runtime/priv/slash-routes.default.yaml` | 删除 3 条 internal_kinds：`notify`、`user_bind_feishu`、`user_unbind_feishu` |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | 加 `slash_routes:` 块声明迁移过来的 3 条 kind |
| `runtime/lib/esr/resource/permission/bootstrap.ex` | 增加 `feishu/user-bind` cap；bind/unbind 命令切到这条 |
| `runtime/lib/esr/scope/admin/process.ex` | 一行注释更新引用新位置 |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | 33 处 `Esr.Commands.Notify` sentinel 用例换成 `Esr.Test.NoopCommand` |
| `runtime/test/esr/plugin/manifest_test.exs` | 加 slash_routes 校验测试用例 |
| `runtime/mix.exs` | 测试 elixirc_paths 没加 `test/support` 的话补上 |

---

> 注：以下任务的步骤说明、失败/通过检查、shell 命令与待落 Elixir 代码片段，与英文版完全对应。本中文版只翻译描述与文件结构；为避免 spec/code 二次翻译造成漂移，每条任务的具体 Elixir/yaml 代码请直接参考英文版同名段落。在执行 plan 时，建议两份并查（英文是 source-of-truth，中文是导航）。

---

## Phase 0: 分支 + 准备

- **Task 0.1: Cherry-pick spec 到实施分支** —— `git cherry-pick 5424fd5 3d882c9` 到 `feat/session-first-default-resolution`。
- **Task 0.2: Cherry-pick plan 到实施分支** —— 在 docs branch 上 commit plan 后再 cherry-pick。
- **Task 0.3: 确认 `test/support` 在 `mix.exs` 的 test elixirc_paths 中** —— 缺则加 `defp elixirc_paths(:test), do: ["lib", "test/support"]`。

## Phase 1: `Esr.Test.NoopCommand` sentinel fixture

- **Task 1.1: 创建 noop 命令模块** —— `runtime/test/support/noop_command.ex`，实现 `@behaviour Esr.Role.Control`。
- **Task 1.2: registry_test.exs 中 33 处 sentinel 替换** —— `sed -i '' 's/Esr\.Commands\.Notify/Esr.Test.NoopCommand/g'`。

## Phase 2: Manifest schema 扩展

- **Task 2.1: 加 `slash_routes` 到 allowed declares + parser** —— `validate/1` chain 加 `validate_slash_routes/1`；body 包含 4 个子 validator（slash 前缀、kind 前缀、permission cap 子集、command_module 可加载）。
- **Task 2.2: Manifest 校验测试 —— slash 前缀错被拒** —— 一条 plugin=feishu 但 slash key 是 `/user:bind-feishu` 的失败用例。
- **Task 2.3: Manifest 校验测试 —— kind 前缀、permission 子集、模块可加载** —— 三条新用例追加。

## Phase 3: SlashRoute.Registry overlay 模型

- **Task 3.1: state 重构为 base + overlays + merged view** —— `init/1` 初始化 `%{base: ..., overlays: %{}}`；`handle_call({:load, ...})` 走 `rebuild_merged_view/1`。
- **Task 3.2: 加 `register_overlay/2` + `unregister_overlay/1`** —— 公共 spec + GenServer handlers；冲突时 reply error 并 rollback to pre-call view。
- **Task 3.3: Overlay 测试 —— register / unregister / collision / base-preserve** —— 新建 `overlay_test.exs`，6 条用例覆盖。

## Phase 4: Plugin.Loader 整合

- **Task 4.1: `start_plugin/2` with-chain 加 `register_slash_routes/2`** —— 插在 `register_entities` 与 `register_startup` 之间；helper 调 `Esr.Resource.SlashRoute.FileLoader.parse_block_to_snapshot/1`。
- **Task 4.2: FileLoader 抽出 `parse_block_to_snapshot/1`** —— 把现有 `validate_slash_entry/2`、`validate_kind_entry/2` 提为 `def`；新公共函数把 manifest 块转 snapshot。
- **Task 4.3: `stop_plugin/1` 调 `unregister_overlay/1`** —— 当前若是 stub `defp` 则提为 `def`，加调用。
- **Task 4.4: 集成测试 —— feishu plugin 带空 `slash_routes` 块启动，daemon 不死** —— 加空块到 feishu manifest，跑 `mix test test/esr/plugins/feishu/ test/esr/plugin/`。

## Phase 5: 迁移 `notify`

- **Task 5.1: 搬源文件 + 改模块名** —— `git mv` + 改 `defmodule` 为 `Esr.Plugins.Feishu.Commands.Notify`。
- **Task 5.2: 搬测试文件 + 改模块名** —— `git mv` + sed 替换模块引用。
- **Task 5.3: 加 `notify` 到 feishu manifest 的 `slash_routes:` 块 + 删除核心 yaml** —— manifest 写 internal_kinds + capabilities 加 `notify.send`；slash-routes.default.yaml 删除 3 行；admin/process.ex 注释更新；commit 单合一。

## Phase 6: 迁移 `bind_feishu` + `unbind_feishu`

- **Task 6.1: permission/bootstrap.ex 改 `user.manage` 注释** —— 表明 bind/unbind 改用 `feishu/user-bind`（由 feishu manifest 声明）；`user.manage` 现在仅 identity。
- **Task 6.2: 搬 BindFeishu 源 + 改模块名** —— `git mv` 到 `runtime/lib/esr/plugins/feishu/commands/bind_user.ex`；`defmodule Esr.Plugins.Feishu.Commands.BindUser`。
- **Task 6.3: 搬 UnbindFeishu 源 + 改模块名** —— 同上，模块名 `UnbindUser`。
- **Task 6.4: 注册迁移（manifest + 删核心 yaml）** —— feishu manifest `capabilities:` 加 `feishu/user-bind`；`internal_kinds:` 加 `user_bind_feishu` + `user_unbind_feishu`；slash-routes.default.yaml 删除 591-597。
- **Task 6.5: 迁移回归测试 —— 通过 kind 名走 admin-CLI dispatch** —— 新建 `migration_test.exs`，3 条 case 验证 kind → 新模块。

## Phase 7: 最终回归 + PR

- **Task 7.1: mix test 全量** —— ≤ Phase 0 baseline 的 9 条失败（pre-existing），无新增 deterministic 失败。
- **Task 7.2: e2e 14 / 18 / 19 from clean wipe** —— `tools/wipe-esrd-home.sh --dev` + `make e2e-XX`。
- **Task 7.3: subagent code-reviewer pass** —— 用 `superpowers:code-reviewer`、`model: "opus"`，关键文件清单见英文版 §Phase 7.3 Step 1。
- **Task 7.4: push + open PR + admin-merge to dev** —— 飞书先发 heads-up；`gh pr create --base dev`；`gh pr merge --admin --squash --delete-branch`；最后飞书发 PR 链接。

---

## 不变量（测试套件验证，非 plan 自身）

完成 Phase 7 后必须满足：

- **I1.** 合并后的 ETS 不存在两个不同注册（base + overlays）共享同一 slash key。违反 → registry 拒绝安装。
- **I2.** 合并后的 ETS 中每个 slash key 都属于已知核心 group (`/user:`、`/workspace:`、`/session:`、`/plugin:`、`/cap:`、`/help`) 之一，或属于已注册 plugin 的命名空间 `/<plugin>:`。无例外。
- **I3.** 合并后的 ETS 中每个 kind 前缀要么是核心 group 要么是 `<plugin>_`。
- **I4.** Plugin 声明的 `permission:` 值是该 plugin `capabilities:` 的子集。本层禁止跨 plugin 引用。
- **I5.** `kind: notify`、`kind: user_bind_feishu`、`kind: user_unbind_feishu` 通过 `SlashRoute.Registry.command_module_for/1` 正确分派（Task 6.5 的 `migration_test` 验证）。
