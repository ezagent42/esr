# 统一命令 Grammar + 结构化错误 实施计划

> **给 agentic worker:** 必需 sub-skill：用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 一个 task 一个 task 实施。step 用 checkbox（`- [ ]`）跟踪。

**目标：** 把命令 grammar（slash + CLI + HTTP + URI）和错误词汇表挪进每个 command module 的 `command_meta/0` callback 作为单一源头。从那里生成 `slash-routes.default.yaml` + `docs/grammar/{commands,errors}.md`。CI gate 防漂移。顺带做裸前缀帮助路由。

**架构：** 一层薄 DSL（`use Esr.Commands.Meta` + `command :kind do ... end` 块）编译成 `%Esr.Commands.Meta.Spec{}` struct，由 `command_meta/0` 返回。一个 `Esr.Commands.Render` module 把 spec 变成 help line / module help / error map。两个 mix task（`gen_slash_routes`、`gen_command_docs`）走每个 command module 出 yaml + docs；一个 CI gate（`check_command_docs`）重生成 + diff。slash router 学会三种新形状：`/<resource>`、`/<resource>:help`、`/<unknown>`。

**技术栈：** Elixir 1.19 / Phoenix 1.8 / `yaml_elixir`（解析）+ `Ymlr`（emit，Phase 1 加进 deps）/ ExUnit / GitHub Actions。

**Spec：** `docs/superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md`（HEAD commit 95b7670 在分支 `spec/unified-command-grammar`，PR #286）。用户 2026-05-09 已确认。

**分支策略：** 新 feature branch `feat/unified-command-grammar` 从 `origin/dev` 切。每个 phase 单独开自己的 PR（6 个 PR 串栈）；按内存规则 subagent + 用户 review 后用 `gh pr merge --admin --squash --delete-branch` 合进 dev。

**英文版：** 完整 step-by-step 在 `docs/superpowers/plans/2026-05-09-unified-command-grammar-and-errors-plan.md`（828 行）。这份中文版是一份概要 + 关键 Phase 的总结，避免双重维护两份等长的 step-by-step。**实施时以英文版为准**，本文用作快速复盘 / 给中文 reviewer 看脉络。

---

## 文件 map（速览）

### Phase 1 新增

- `runtime/lib/esr/commands/meta.ex` — `Esr.Commands.Meta` behaviour + DSL 宏 + `Spec`/`Arg`/`ErrorDecl` struct
- `runtime/lib/esr/commands/render.ex` — 渲染器（help_line/1、module_help/1、error/3）
- `runtime/lib/esr/commands/resource_help.ex` — `/workspace`、`/<resource>:help` 处理器
- `runtime/test/esr/commands/{meta,render,resource_help}_test.exs` — 三份 unit test

### Phase 1 修改

- `runtime/mix.exs` — 加 `{:ymlr, "~> 5.0"}` 到 deps
- `runtime/lib/esr/role.ex` — `Esr.Role.Control` 加 `@callback execute(map()) :: {:ok, map()} | {:error, map()}`

### Phase 4 新增

- `runtime/lib/mix/tasks/esr.gen_slash_routes.ex`
- `runtime/lib/mix/tasks/esr.gen_command_docs.ex`
- `runtime/lib/mix/tasks/esr.check_command_docs.ex`
- `docs/grammar/commands.md`（自动生成）
- `docs/grammar/errors.md`（自动生成）

### Phase 5 新增

- `.github/workflows/ci.yml`（从零创建 —— 今天只有 `enforce-pr-from-dev.yml`）

### Phase 6 修改

- `runtime/lib/esr/entity/slash_handler.ex` — 在 `lookup/1` :not_found 之后、`@deprecated_slashes` miss 之后，再调 `Registry.lookup_prefix/1`
- `runtime/lib/esr/resource/slash_route/registry.ex` — 加 `lookup_prefix/1`
- `runtime/test/esr/entity/slash_handler_bare_prefix_test.exs`
- `runtime/test/e2e/scenario_23_bare_prefix_help_test.exs`

---

## Phase 1 — DSL 基础设施

**目标：** 加 `Esr.Commands.Meta` DSL、`Render`、`ResourceHelp`、前置（`Ymlr` deps + `Role.Control.execute/1` callback）。不动任何 command module。

**PR：** `feat/unified-grammar-phase-1-dsl-infra` → `dev`

**任务：**

1. 切分支
2. mix.exs 加 `{:ymlr, "~> 5.0"}`，`mix deps.get` + `mix deps.compile ymlr` 验证
3. role.ex 加 `@callback execute/1`，先写测试断言 `behaviour_info(:callbacks)` 包含 `{:execute, 1}`，跑挂、加代码、跑过、commit
4. `meta.ex` 先写 struct（Spec/Arg/ErrorDecl）—— TDD：测先挂、struct 加上、跑过、commit
5. `meta.ex` 再加 DSL 宏（`__using__`、`command/2`、`slash/1`、`category/1`、`description/1`、`permission/1`、`requires_user_binding/1`、`requires_workspace_binding/1`、`arg/2`、`error/1`、`error/2`）+ 编译期 duplicate-error 检查
6. `render.ex` —— help_line/1 / module_help/1 / error/2 + error/3 + `%{key}` 插值 + 未声明 error code 抛 ArgumentError
7. `resource_help.ex` —— 拿 `Registry.list_slashes/0`，按 resource 前缀 group + 渲染。Phase 6 接进 SlashHandler
8. push + 开 PR + admin-merge

**英文版每一步都有完整代码块，照抄即可。**

---

## Phase 2 — Workspace.New canary

**目标：** Workspace.New 切换到 DSL + `Render.error/3`。先写 meta-equivalence 测试（锁住"现在的 8 个错误码 + 4 个 args + slash row 不能被静默删名"），再做转换。

**PR：** `feat/unified-grammar-phase-2-canary` → `dev`

**任务：**

1. 切分支
2. 写 `new_meta_test.exs` —— 三个旧行为测试 + 两个 command_meta/0 测试
3. 跑测：旧的 pass、新的 fail（因为 command_meta/0 还没加）
4. 改 `new.ex`：在 @moduledoc 之后加 `use Esr.Commands.Meta` + `command :workspace_new do ... end` 块。把每个 `{:error, %{"type" => "...", "message" => "..."}}` 字面量替换成 `Render.error(__MODULE__.command_meta(), :code, %{detail_keys})`，detail 里的 key（name、folder、detail）通过 DSL 错误 message 里的 `%{name}` 占位符回填
5. 跑全套测试，调整任何"断言 error map 里有 type 之外字段"的旧测试 —— 那些字段消失了，都进 message body 了。commit message 注明哪些 test 调了
6. push + PR + admin-merge

---

## Phase 3 — 批量转换（74 core + 4 plugin module）

**目标：** Workspace.New 的转换套到剩下所有 command module 上。机械、按 category 拆 sub-PR 让 diff 易 review。

**PR(s)：** `feat/unified-grammar-phase-3a-...` 多个

**Sub-task 列表：**

| 编号 | 类别 | 模块 |
|------|------|------|
| 3.2 | Workspace（除 new 外） | runtime/lib/esr/commands/workspace/*.ex（14 文件） |
| 3.3 | Sessions | runtime/lib/esr/commands/session/*.ex（9） |
| 3.4 | Agents | runtime/lib/esr/commands/agent/*.ex（6） |
| 3.5 | PTY | runtime/lib/esr/commands/pty/*.ex（3）+ key.ex（1） |
| 3.6 | Plugins | runtime/lib/esr/commands/plugin/*.ex（10） |
| 3.7 | Capabilities | runtime/lib/esr/commands/cap/*.ex（5） |
| 3.8 | Users | runtime/lib/esr/commands/user/*.ex（5） |
| 3.9 | Adapters | runtime/lib/esr/commands/{adapter,adapters}/*.ex（5）+ register_adapter.ex |
| 3.10 | 诊断 + misc | doctor/help/whoami/reload/trace/cross_app_test + deadletter/debug/actors |
| 3.11 | Plugin commands | claude_code/commands（1）+ feishu/commands（3） |

**每个 sub-task 流程：**

1. 切分支 `feat/unified-grammar-phase-3-<category>`
2. 对每个文件套 Phase 2 canary 的相同变换：
   - 加 `use Esr.Commands.Meta` + DSL 块（kind/slash/permission/binding 从 yaml row 抄；errors 从 grep 当前模块的 `"type" => "..."` 字面量得到）
   - 替换 error 字面量为 `Render.error/3`
   - 加 `alias Esr.Commands.Render`
3. 跑该类别的 test + 全套
4. commit：每个 sub-PR 一个 commit，message 列出调整的旧测试
5. push + PR + admin-merge

**Phase 3 收尾：** Task 3.12 跑一个 iex script 确认没有 command module 漏 `command_meta/0`：

```elixir
{:ok, mods} = :application.get_key(:esr, :modules)
without_meta =
  for m <- mods,
      Atom.to_string(m) =~ ~r/^Elixir\.Esr\.Commands\.[A-Z]/,
      not Atom.to_string(m) =~ ~r/(Meta|Render|ResourceHelp)/,
      not function_exported?(m, :command_meta, 0),
      do: m
IO.inspect(without_meta, label: "MISSING")
```

期望：`MISSING: []`。

---

## Phase 4 — yaml + docs 变派生

**目标：** 用 mix task 取代手编辑 `slash-routes.default.yaml`。新增 `docs/grammar/{commands,errors}.md`。验证语义相同（解析后同 map）。每个生成文件带 AUTOGENERATED banner。

**PR：** `feat/unified-grammar-phase-4-derived-yaml-docs` → `dev`

**任务：**

1. **`mix esr.gen_slash_routes`** ——
   - `runtime/lib/mix/tasks/esr.gen_slash_routes.ex`：走 `Esr.Commands.*` + `Esr.Plugins.*.Commands.*`（同时支持 core 和 plugin），`function_exported?(m, :command_meta, 0)` 过滤、`command_meta/0` 收集 specs、按 kind 排序、用 `Ymlr.document!(... sort_maps: true)` emit。`@banner` 字符串以 `# AUTOGENERATED ...` 开头
   - 测试：`emit/0` 含 banner、含每个已知 slash、两次调用输出字节相同、解析后和磁盘 yaml 的 schema_version + 所有 slash key 一致
2. **重 emit yaml 建立 baseline** —— `cp slash-routes.default.yaml{,.bak}` 备份、`mix esr.gen_slash_routes`、diff 检查（只该是空白 + 顺序 + banner 差异）、跑校验脚本确认 schema/slash keys/internal_kinds keys 三组都相等、删 .bak、commit
3. **`mix esr.gen_command_docs`** ——
   - `emit_commands_md/0`：按 category group + 排序、每条 slash 单 section（slash + args + description + kind + permission + binding flags + errors）
   - `emit_errors_md/0`：把所有 (code, kind, message) 合在一张表里、按 (code, kind) 排序
   - banner 用 `<!-- ... -->` HTML 注释形式
   - 写到 `docs/grammar/commands.md` + `docs/grammar/errors.md`
   - 测试：包含 banner、包含已知 category、包含已知 kind、两次调用输出相同
4. **`mix esr.check_command_docs`** ——
   - 调 `GenSlashRoutes.emit/0` + 两个 `GenCommandDocs.emit_*_md/0`
   - 用 `strip_banner/1`（regex 剥 `# AUTOGENERATED ...` 块和 `<!-- AUTOGENERATED ... -->` 块）
   - `verify_banner!/2` 在文件没 banner 时 raise
   - on-disk vs in-memory diff，drift 时 exit non-zero + 友好提示
5. push + PR + admin-merge

---

## Phase 5 — CI gate

**目标：** 让 `mix esr.check_command_docs` 拦下任何漂移 PR。今天只有 `enforce-pr-from-dev.yml`，**新建** `ci.yml`。

**PR：** `feat/unified-grammar-phase-5-ci-gate` → `dev`

**任务：**

1. 创建 `.github/workflows/ci.yml`：jobs.build-and-test runs-on ubuntu-latest，env MIX_ENV=test，steps：checkout、`erlef/setup-beam@v1`（Elixir 1.19 / OTP 27）、cache deps（hash mix.lock）、`mix deps.get`（cwd `runtime`）、`mix compile --warnings-as-errors`、`mix esr.check_command_docs`（独立 step，让漂移失败时 log 直接指明）、`mix test`
2. push + PR
3. 看 PR checks 全绿
4. 可选：开 scratch branch 改 yaml 触发漂移、看 CI 失败、丢分支（验证 gate 是真的）
5. admin-merge

---

## Phase 6 — 裸前缀路由 + e2e

**目标：** 接 `Esr.Commands.ResourceHelp` 进 `Esr.Entity.SlashHandler`，让 `/workspace`、`/<resource>:help`、`/<unknown>` 都给有用的回复。e2e scenario 23 锁住。

**PR：** `feat/unified-grammar-phase-6-bare-prefix` → `dev`

**任务：**

1. **`Registry.lookup_prefix/1`** —— 在 `runtime/lib/esr/resource/slash_route/registry.ex` 的 `lookup/1` 旁边加。返回值：
   - `{:resource_help, nil}` —— 输入是 `/`
   - `{:resource_help, "workspace"}` —— `/workspace` 或 `/workspace:help`
   - `{:unknown_method, "workspace", "bogus"}` —— `/workspace:bogus`，workspace 是已知 resource、bogus 不是方法
   - `{:unknown_resource, "name"}` —— 第一段都不对
   - `:no_match` —— 输入是真 slash（caller 应该用 `lookup/1`）
   - 6 个 unit test
2. **接进 SlashHandler** —— 在 `handle_cast({:dispatch, ...})` 的 `Registry.lookup/1 → :not_found → @deprecated_slashes miss` 那一臂之后调 `Registry.lookup_prefix/1`，按返回 4 个分支分别 dispatch（resource_help → 调 `ResourceHelp.execute`、unknown_method/resource → 友好错误文本、no_match → 通用错误）。`@deprecated_slashes` **优先**于裸前缀（`/new-workspace` 还是拿迁移提示，不是 workspace help）—— 4 个 unit test 覆盖每个分支 + deprecated 优先
3. **e2e scenario 23** —— 在 chat envelope 里 dispatch `/workspace`、`/workspace:help`、`/zzzznotreal`，断言 reply 文本
4. push + PR + admin-merge

---

## 验收（全部 phase 合并后）

- [ ] iex script 跑 `MISSING command_meta` 列表 —— 必须 `[]`
- [ ] `mix esr.check_command_docs` 退 0
- [ ] Feishu chat 里手 post `/workspace` 看回复
- [ ] scratch branch 手改 yaml 验证 CI 失败
- [ ] `docs/grammar/{commands,errors}.md` 存在 + committed

---

## Spec coverage 自查

- §3 决策 Q1/Q2/Q3 → Phase 1 task 4-6（DSL + Render）+ Phase 5 task（CI gate）
- §4.1 支柱 1（command_meta/0）→ Phase 1 task 4-5（infra）+ Phase 2（canary）+ Phase 3（批量）
- §4.2 支柱 2（生成 yaml）→ Phase 4 task 1（gen）+ task 2（重 emit baseline）+ task 4（gate）
- §4.3 支柱 3（Render error/help）→ Phase 1 task 6（Render）+ Phase 2/3 转换
- §4.4 支柱 4（裸前缀路由）→ Phase 6
- §5 docs/grammar/ → Phase 4 task 3（gen）+ task 4（gate 验证）
- §6 CI gate → Phase 5（workflow file）+ Phase 4 task 4（mix task）
- §7 迁移顺序 → Phase 1-6 一一对应
- §10 风险 → Ymlr deps（Phase 1 task 2）+ execute/1 callback（Phase 1 task 3）+ banner verification（Phase 4 task 4）
- §11 验收标准 → 上面验收 block

**英文版 step-by-step 完整代码：** `docs/superpowers/plans/2026-05-09-unified-command-grammar-and-errors-plan.md`
