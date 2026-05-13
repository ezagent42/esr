# register_adapter 原子化 FAA Spawn 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务执行。Steps 用 checkbox (`- [ ]`) 跟踪。

**目标：** `register_adapter` 在 spawn Python sidecar 的同时，原子地 spawn Elixir 端的 `FeishuAppAdapter` GenServer，让 boot 之后注册的 adapter 一次性形成完整可达的 plumb（不再 silent drop）。

**架构：** `Esr.Commands.RegisterAdapter.execute/2` 增加 `:startup_fn` opt，默认 `&Esr.Plugin.Loader.run_startup/0`。`spawn_adapter`（sidecar）成功之后，call `startup_fn.()` 重跑所有已启用 plugin 的 idempotent startup hook —— 跟 `adapter_refresh` 走同一条路径。Feishu 的 hook (`Esr.Plugins.Feishu.Bootstrap.bootstrap/0`) 会枚举 `adapters/<name>/config.yaml`（刚被 `Esr.Adapters.add/3` 写好），spawn FAA peer；`DynamicSupervisor.start_child` 对已运行实例幂等。新增 integration test 启动真实 Application 监督树，断言 `Esr.Entity.Registry.lookup("feishu_app_adapter_<name>")` 返回 pid —— 关掉让本 bug 漏出的 e2e 覆盖缺口。

**Tech Stack:** Elixir 1.18 / OTP 27 / Phoenix / ExUnit `:integration` tag。

**Bug 背景：** 2026-05-12 在 Feishu 群 oc_d9b47511b085e9d5b66c4595b3ef9bb9 实测定位。`tools/wipe-esrd-home.sh --dev` + esrd boot + `register_adapter` 之后，Feishu 入站消息被 silent drop，伴随 `[warning] adapter_channel: no FeishuAppAdapter for app_id=esr_helper_dev`。根因：`register_adapter.ex:80` 只 call `WorkerSupervisor.ensure_adapter`（sidecar）；Elixir 端 FAA peer 只由 `Esr.Plugins.Feishu.Bootstrap.bootstrap/0`（被 `Esr.Plugin.Loader.run_startup/0` 调用）spawn，而这条 hook 只在 esrd boot 或 `adapter_refresh` 时跑。Operator 手动跑 `esr exec adapter_refresh` 之后 bind 立刻可用，验证了修复路径。

**Branch:** `fix/register-adapter-spawns-faa`，base `origin/dev`，admin-squash-merge。

**预估：** ~70 LOC（15 源代码 + 50 测试 + 5 文档）。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `runtime/lib/esr/commands/register_adapter.ex` | 修改 | 加 `:startup_fn` opt；`spawn_adapter` 之后 call |
| `runtime/test/esr/commands/register_adapter_test.exs` | 修改 | 新单元测试：`:startup_fn` 在 `spawn_fn` 之后被调用 |
| `runtime/test/esr/integration/register_adapter_spawns_faa_test.exs` | 创建 | Integration test：真实 Application boot，断言 FAA 在 Registry |
| `docs/guides/flow-bootstrap.md` | 修改 | 第 3 步加 1 句"atomic"说明（sidecar + FAA 一次完成） |
| `docs/futures/todo.md` | 修改 | 关掉 `unconsumed-message-errors-not-hangs` 相关行（adapter-spawn 这条 flavor） |

---

## 任务

英文版的 plan（`docs/superpowers/plans/2026-05-12-register-adapter-spawns-faa-plan.md`）有完整的逐步代码 + 命令 + 断言。中文 mirror 不再重复贴代码，只列任务标题供操作员对照：

### Task 1: 写失败的单元测试（`:startup_fn` 在 `spawn_fn` 之后被调用）

文件：`runtime/test/esr/commands/register_adapter_test.exs` 末尾新增 `describe "post-spawn startup hook (2026-05-12 FAA atomicity fix)"` 块（2 个 test：happy path + spawn 失败时 startup 不跑）。

跑 `mix test test/esr/commands/register_adapter_test.exs`，预期：新增 1 个 test 失败（默认 path 还不 call startup_fn）。

### Task 2: `register_adapter.ex` 加 `:startup_fn` opt + call site

文件：`runtime/lib/esr/commands/register_adapter.ex:71-95`（`execute/2` happy path 子句）。
- 改用 `with :ok <- spawn_adapter(...) <- :ok <- run_startup_hooks(opts) do ... end` 结构
- 新增私有 `run_startup_hooks/1`：默认 `&Esr.Plugin.Loader.run_startup/0`，错误 3 种返回（`:ok` / `{:error, _}` / `other`）跟 `spawn_adapter/4` 对称处理

跑 `mix test test/esr/commands/`，预期：全绿。

Commit message 解释：why（原子化、防 half-state），不解释 what（diff 看得到）。

### Task 3: Integration test —— 真实 boot 证 FAA 在 Registry

文件（创建）：`runtime/test/esr/integration/register_adapter_spawns_faa_test.exs`，tag `:integration`。
- Test 1：execute 后 `Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_<name>")` 返回 pid 且 alive
- Test 2：注册第二个 adapter（不同 name）不扰动第一个，两个 FAA pid 都 alive、互不相同

为什么这个 test 重要：它走真实 `Esr.Plugin.Loader.run_startup/0`（不 DI），覆盖单元测试覆不到的"call default 真的跑通"链路。同时关掉 scenario 23 没断言 FAA 起没起的 e2e 缺口。

**测试环境 caveat**：`config/test.exs:23` 设了 `enabled_plugins: []` —— `mix test` 时 feishu plugin 不加载，`Esr.Plugin.Loader` 的 `:startup_callbacks` persistent_term 是空的。Setup 必须先 seed `{"feishu", Esr.Plugins.Feishu.Bootstrap, :bootstrap}` 到 persistent_term，on_exit 还原。否则 `run_startup/0` no-op、FAA 不 spawn、`Registry.lookup` 返回 `[]`，integration test 会假阴性通过或直接 fail。英文 plan 的 setup block 已经把这层处理写完。

跑：`mix test --include integration test/esr/integration/register_adapter_spawns_faa_test.exs`（`--include integration` 必加，test_helper 默认 exclude 这个 tag）。

### Task 4: 文档扫尾

`docs/guides/flow-bootstrap.md`：在第 3 步 `register_adapter` 例子后加 1 句 atomic 说明（一次 call 完成 config.yaml + sidecar + FAA，不再需要 `adapter_refresh` 收尾）。Mirror 到 `flow-bootstrap.zh_cn.md`（若存在）。

`docs/futures/todo.md`：
- `unconsumed-message-errors-not-hangs` 行：标记 ✅ PARTIALLY CLOSED 2026-05-12（adapter-spawn flavor 已修；session 无 agent flavor 由 PRs #341-#344 修；两种 flavor 都覆盖了）
- `phase-3-fence-cc-reply` 行：标记 UNBLOCKED 2026-05-12（上游卡点已修，剩下的工作是 ~10 LOC 加 fence #5）

### Task 5: Subagent code-quality review

按 memory rule `feedback_subagent_review_plans.md`：subagent review diff 再 push。Subagent model 必须是 `opus`（memory rule `feedback_subagent_model_parity.md`）。Reviewer 检查 8 个点（见英文 plan Task 5）；有 finding 就 fix + 再 review，干净才 push。

### Task 6: Push + 开 PR + admin merge

按 memory rule `feedback_feishu_notify_before_remote_ops.md`：push 前 1-2 句 Feishu heads-up。
然后：
```bash
git push -u origin fix/register-adapter-spawns-faa
gh pr create --base dev --head fix/register-adapter-spawns-faa --title "..." --body "..."
gh pr merge --admin --squash --delete-branch
```
Merge 后简短 Feishu 通报。

---

## 自审 checklist

- [x] Bug 根因 plan 头部已写清楚
- [x] 修复路径已被用户手动 `adapter_refresh` 验证 → 高信心
- [x] 单元测试证调用点
- [x] Integration test 证端到端注册
- [x] E2E gap 关闭（integration test 顶 e2e 的作用，不用拉 shell 脚本）
- [x] 双语文档
- [x] 无 placeholder（每步都有完整代码 + 命令）
- [x] 无 anti-pattern（没 shim / default / whitelist；纯结构修复）

---

## 执行衔接

**Plan 完成，保存在 `docs/superpowers/plans/2026-05-12-register-adapter-spawns-faa-plan.zh_cn.md`（英文同名）**。

两种执行选项：

**1. Subagent 驱动（推荐）** —— Controller 每个 task dispatch 一个 fresh subagent（永远 `model: "opus"`），中间 review，快速迭代。

**2. Inline 执行** —— Controller 在当前 session 用 `superpowers:executing-plans` 批量执行 + checkpoint review。

默认走 subagent 驱动（跟刚收尾的 4-PR plan workflow 一致）。
