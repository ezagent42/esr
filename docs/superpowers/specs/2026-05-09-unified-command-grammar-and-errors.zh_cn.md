# 统一命令 grammar + 结构化错误

**状态:** 草稿 — 待用户确认
**日期:** 2026-05-09
**作者:** Claude（与 linyilun）
**取代:** 任务 #220（仅结构化错误那部分）

---

## 1. 为什么是现在

最近 30 天有三次 drift 事件，根因是同一个：

1. **Doctor 模块 hardcode grammar drift**（PR #285，今天）。`next_steps_text/5`
   在 grammar refresh 之后还在渲染 `esr --env=dev feishu bind ...`。CI 没失败。
   操作员复制粘贴拿到错指令。
2. **`/help` 是数据驱动的，但每个 command module 自己手写帮助/usage 串。**
   slash 总览从 `slash-routes.default.yaml` 生成，但每个 module 在 error 返回里
   自己手写一份 usage 文本。两边静默漂移。
3. **`/workspace`（裸前缀）什么都不返回** —— 操作员必须先知道 `workspace:new`
   才能用。module-level 没有 help affordance。

这三次都是**一类**bug，不是单点。修法是把 grammar 做成一份数据 + 多个 presenter，
把所有手写副本删掉。

**错误返回**有一模一样的问题：每个 command 自己写
`%{"type" => "...", "message" => "..."}`，message 经常和公开文档复制或冲突。
任务 #220 已经叫过这个号。两件事一起做意味着每个 command module 只动一次。

---

## 2. 目标

一个 command 的身份、签名、help 文本、错误词汇表，**只**在 command module 用一份
结构化 DSL 声明。从这一份源头我们生成：

- Slash 路由（`/<resource>:<method> ...`）
- CLI dispatch（`esr exec <kind> --key=value`）
- HTTP/URI 形式（`POST /api/exec/<kind>` body `{args: ...}`）
- 帮助渲染（`/help`、`/<resource>`、`/<resource>:help`）
- 操作员参考文档（`docs/grammar/commands.md`）
- 类型化错误目录（`docs/grammar/errors.md`），`type` 码稳定
- 编译期强制：drift 进不来

裸前缀帮助（`/workspace` → 列方法、`/<unknown>` → 列 resource）随这次迁移一起
落地，让操作员不用读 help 文件就能发现命令。

### 非目标

- **不**做运行时 DSL 让 plugin 在启动时 ship 自定义 grammar。（Plugin-scoped
  command registration 已经被 2026-05-08 plugin-command-registration spec 覆盖；
  这份 spec 消费那个 surface，不替代它。）
- **不**改 slash 调用 / admin queue payload 的 wire 格式。`kind` 串、slash 文本、
  args key 已经被 FAA + CLI + HTTP 消费 —— 向后兼容是硬要求。
- **不**给 help/error 文本做本地化。文本仍然是 zh_cn-with-en-fallback，
  本地化是后续单独的 followup。

---

## 3. 三个设计决策（已批准）

用户在 2026-05-09 chat 确认：

| #  | 问题                                  | 选择                                                        |
| -- | ------------------------------------- | ----------------------------------------------------------- |
| Q1 | grammar 的权威源头放哪？              | **B** — 每个 `Esr.Commands.*` module 内的 module-attribute 宏 |
| Q2 | 模块怎么渲染 help / error 文本？      | **C** — 每个 module 暴露一个 `command_meta/0` 给 renderer 读 |
| Q3 | slash-routes.yaml 和 module 漂移时？ | **A** — 编译期硬错，build 失败                              |

这三选把所有 author affordance 推到 module 自身，让 `slash-routes.default.yaml`
变成派生状态、不是源头。yaml 留作 read-time artifact（FAA + Adapter 路由从它加载），
但由 `mix esr.gen_slash_routes` 从 `command_meta/0` 重新生成，CI gate 检查。

---

## 4. 四根支柱

### 支柱 1：`command_meta/0` callback（Q1+Q2 落代码）

每个 command module 实现：

```elixir
defmodule Esr.Commands.Workspace.New do
  use Esr.Commands.Meta

  command :workspace_new do
    slash         "/workspace:new"
    category      "Workspace"
    description   "创建新 workspace。folder=<path> → repo-bound；不传 → ESR-bound"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name,      required: true,  doc: "workspace 名（ASCII alnum + - + _）"
    arg :folder,    required: false, doc: "绝对路径，必须是 git repo（repo-bound 模式）"
    arg :transient, required: false, default: "false", doc: "true 时 ESR-bound 临时 ws"
    arg :owner,     required: false, doc: "默认取 args.username"

    error :invalid_name,                "workspace 名必须匹配 ^[A-Za-z0-9][A-Za-z0-9_\\-]*$"
    error :unknown_owner,               "owner 未在 users.yaml 注册；先跑 user_add"
    error :folder_not_dir
    error :folder_not_git_repo
    error :transient_repo_bound_forbidden
    error :name_exists
    error :registry_put_failed
  end

  @behaviour Esr.Role.Control
  # ... execute/1 不变 ...
end
```

`use Esr.Commands.Meta` 注入：

- `@behaviour Esr.Commands.Meta`
- `command_meta/0` 返回一个 struct（`%Esr.Commands.Meta.Spec{}`），编译期由 DSL 块填好
- 编译期 validate：kind 必须是 snake_case atom；slash 必须和 kind 配对（或 `:none`
  表示纯内部 kind）；args 是一个 `%Arg{}` 列表；error 不能重复
- 把 module 注册进编译期 manifest，给 gen-yaml + gen-doc 用

DSL 故意做得很薄。背后只展开成一个 `def command_meta, do: %Spec{...}` 子句和几个
`@spec_*` module 属性给宏用。

### 支柱 2：生成的 `slash-routes.default.yaml`（Q3）

`runtime/priv/slash-routes.default.yaml` 变成派生状态：

- `mix esr.gen_slash_routes` 走每个 `Esr.Commands.*` 模块（实现 `command_meta/0` 的），
  按 kind 排序，确定性地生成 yaml。
- `mix esr.check_command_docs`（CI gate）在内存里重新生成 + diff 磁盘上的版本。
  任何 diff 都报错、CI 挂。
- 文件路径不动（FAA / Adapter / 测试都靠路径加载）。手编辑的人会拿到 CI 失败 +
  清楚的 "跑 `mix esr.gen_slash_routes`" 提示。

`internal_kinds:` 段保留：那些没有 slash 形式的 kind（`user_add`、`feishu_bind`、
`register_adapter` 等）。DSL 里写 `slash :none`，emit 进那个段。

### 支柱 3：模块级 help/error 渲染器（Q2 落实）

`Esr.Commands.Render` 是唯一渲染器。吃 `%Spec{}`，emit：

- `Render.help_line/1` — `/help` 用的单行（slash + args + description）
- `Render.module_help/1` — 多行版，给 `/workspace` / `/<resource>:help` 用
- `Render.error/2` — 给 kind + error code，返回
  `%{"type" => ..., "message" => ...}`，message 取自 spec 的 `error/2` 声明

`Esr.Commands.Help`（即 `/help` 命令）、`Esr.Commands.Doctor`、新增的
`Esr.Commands.ResourceHelp`（处理 `/workspace`、`/session` 等）全部代理到
`Render`。command module **再也不**手写 `/help` 行 / bootstrap 错误文案。

错误路径是更大头收益。今天每个 module 写：

```elixir
{:error, %{"type" => "invalid_args", "message" => "workspace_new requires args.name"}}
```

迁移之后写：

```elixir
Render.error(:workspace_new, :invalid_args, %{detail: "args.name 缺失"})
```

renderer 从 spec 的 `error :invalid_args, "..."` 声明取 message body，可选地把
`detail` 插值进去。错误 type 码 + 操作员看到的文案在一处定义，文档生成器都看得到。

### 支柱 4：裸前缀 help 路由（UX）

slash router（`Esr.Entity.SlashHandler` + `Esr.Resource.SlashRoute.Registry`）
新增三种行为：

| 输入                          | 行为                                                                |
| ----------------------------- | ------------------------------------------------------------------- |
| `/`                           | 列 resource（`workspace`、`session`、`agent`...）—— 短列表          |
| `/workspace`                  | 列 `workspace:*` 的所有方法 + 一行说明（从 `command_meta/0` 拼）    |
| `/workspace:help`             | 同 `/workspace`（显式别名，便于发现）                               |
| `/<unknown>`                  | 友好错误 + 列出有效的 top-level resources                           |
| `/workspace:<unknown>`        | 友好错误 + 列出 workspace 下的方法                                  |
| `/workspace:new <bad args>`   | renderer-formatted error（支柱 3），和今天行为不变                  |

实现：当 `Registry.lookup/1` 返回 `:not_found`，SlashHandler 落进新的
`Registry.lookup_prefix/1` —— 输入匹配某个 resource 前缀就 dispatch 到
`Esr.Commands.ResourceHelp.execute(%{"args" => %{"resource" => "workspace"}})`。
该命令查 registry 里所有 kind 以 `workspace_*` 开头的路由、渲染 module help。
显式 `/<resource>:help` 走同一条路径。

---

## 5. 文档生成（`docs/grammar/`）

`mix esr.gen_command_docs` 写两份操作员文档：

- `docs/grammar/commands.md` — 所有命令、按 category 分组、slash + CLI 形式、
  args、description、error 词汇表。确定性排序。
- `docs/grammar/errors.md` — flat catalog，`type` 码、哪些 kind 会 emit 它、
  权威 message。给 adapter 作者构造结构化通知 surface 用（任务 #220 原始诉求的
  支柱 4）。

两份文件放在 `docs/grammar/`（新目录），committed。CI 像 yaml 一样
重生成 + diff。

---

## 6. CI gate：`mix esr.check_command_docs`

一个 mix task 包三件事：

```bash
mix esr.check_command_docs
# 1. 走每个 Esr.Commands.* module，确认 command_meta/0 存在。
# 2. 内存里生成 slash-routes.default.yaml；diff 磁盘版本。
# 3. 内存里生成 docs/grammar/{commands,errors}.md；diff 磁盘版本。
# 任何非零 diff → exit 1，附清楚的修复建议。
```

接到 `.github/workflows/ci.yml` 作为独立 step，让失败时操作员看到正确指令
（`mix esr.gen_slash_routes && mix esr.gen_command_docs`）。

---

## 7. 迁移：一锤子，~74 个 module

按用户意见：不渐进。

模块数，2026-05-09 实测：core 在 `runtime/lib/esr/commands/` 下 74 个 `.ex`
文件 + plugin 在 `runtime/lib/esr/plugins/*/commands/` 下 4 个 plugin command
模块。plugin module 一并迁移，因为它们 wire 形状一致，跳过会让 manifest 不全。

迁移在一个 PR（或一小串 stacked PR 让 diff 易 review）里把现有所有 command
module 全部转过来。顺序：

1. **Phase 1 — DSL 基础设施。** `Esr.Commands.Meta` module + `Spec` struct
   + 宏实现 + `Esr.Commands.Render` + `Esr.Commands.ResourceHelp`。这一阶段
   不动 command module，只加新代码。

   Phase 1 还要补两个之前 spec 默认存在的前置条件：

   - **加 `Ymlr` deps。** `runtime/mix.exs` 现在只有
     `{:yaml_elixir, "~> 2.11"}`，那是 parser 不是 emitter。gen task 需要确定性
     emitter。引入 `{:ymlr, "~> 5.0"}`（按 key 排序、行尾稳定）。
   - **`Esr.Role.Control` callback 形式化。** 今天 `execute/1` 是每个
     command module 都遵守的约定，但 `Esr.Role.Control` 只声明了 `__role__/0`。
     加 `@callback execute(map()) :: {:ok, map()} | {:error, map()}`。
     一行 behaviour 改动，让 Phase 2 那句"DSL 接到现有 contract"变成字面成立、
     不只是约定上的。

2. **Phase 2 — 一个 canary。** 把 `Esr.Commands.Workspace.New` 转成 DSL。
   验证生成的 yaml 那一行和现在的 `slash-routes.default.yaml` 字节相同。
   验证错误返回结构相同（用快照测试）。
3. **Phase 3 — 批量转。** 剩下 ~73 个 core module + 4 个 plugin module。每个
   转换都是机械的：把现有 yaml 行 + 现有 error 返回挪进 DSL，删手写串。
4. **Phase 4 — yaml + docs 变派生。** 用 `mix esr.gen_slash_routes` 重生成
   `slash-routes.default.yaml` 替换手编辑版本。第一次跑 diff 是 no-op（因为
   Phase 2 + 3 已经字节相同）。新增 `docs/grammar/commands.md` + `docs/grammar/errors.md`。
5. **Phase 5 — CI gate。** 把 `mix esr.check_command_docs` 接到 CI 作为
   blocking step。今天唯一的 workflow 是
   `.github/workflows/enforce-pr-from-dev.yml`（PR base-branch 检查，不跑 build/test）。
   Phase 5 **新建** `.github/workflows/ci.yml`，至少包含：`mix deps.get`、
   `mix compile --warnings-as-errors`、`mix esr.check_command_docs`、`mix test`。
   check_command_docs 单独一行 step，让漂移失败时直接指向正确指令。
6. **Phase 6 — 裸前缀路由。** 把 `/workspace`、`/<resource>:help`、
   `/<unknown>` 路径接进 SlashHandler。加 e2e 场景：在 chat 里 post `/workspace`
   断言响应里列了 workspace 方法。

Phase 5 是 gate。落地之后，未来任何 command module 不写 DSL 就 build 失败。

---

## 8. 哪些不变

- `Esr.Role.Control` behaviour（`execute/1` callback）不动。DSL 是元数据；
  执行路径还是每个 module 今天有的 function clause stack。
- `slash-routes.default.yaml` 保持当前 schema（`schema_version: 1`）。
  只是**作者**变了（人 → mix task）。
- CLI 入口（`runtime/lib/esr/cli/main.ex`）保持当前形状：`esr exec <kind> --key=value`
  通过同一份 kind→module map 解析。
- FAA / Telegram / 未来 adapter 保持当前 loader 路径。它们读 yaml、永远不直接
  调 `command_meta/0`。（这条边界让 adapter 保持笨：还是单纯的 yaml 消费者。）

---

## 9. 这一步解锁什么

- **Plugin-scoped 命令**（2026-05-08 spec）接到同一个 `Spec` struct。plugin 自己的
  command_meta/0 在 plugin module 里；gen-yaml + gen-doc task 通过 plugin manifest
  发现它。
- **本地化。** help/error 文本一旦是数据，换翻译表是 renderer 的事，不是逐 module
  改写。
- **adapter 通知 surface** 可以渲染结构化错误，type 码稳定。Telegram adapter
  开张那天，跟 Feishu 用同一份错误词汇表，没有代码重复。
- **Schema export。** 未来 `GET /api/grammar/commands.json` endpoint 把 manifest
  以 JSON 返回，给工具用（自动补全、IDE 插件、即将到来的 web TUI 命令面板）。

---

## 10. 风险 & 待解

### 风险：宏复杂度

DSL 必须可读。如果宏太花，未来作者会复制粘贴调试几个小时。缓解：宏保持薄
（一个块、一个 struct 输出、unquote 之外不做 AST 操作）。如果实现者发现宏长牙，
退回一个普通 map 字面量 —— 收益是单一源头，不是语法糖。

### 风险：yaml 字节相同重生成

Phase 2 的"验证字节相同"这关不轻松，因为 Elixir map 序列化顺序不是 yaml-stable。
缓解：用确定性 emitter 出 yaml（`Ymlr`，Phase 1 加进 deps），把 ordering 规则冻在
gen task 里。Phase 4 第一次跑几乎肯定相对当前手编辑版本有非零 diff（空白、注释保留、
key 顺序）。所以 Phase 4 的 PR 拆两个 commit：一个用新 emitter 重新 emit 当前 yaml
建立 baseline（无语义变化），一个把 `mix esr.gen_slash_routes` 接为作者。Phase 2
canary 只验证语义相同（parsed yaml → 同 map），不验证字节相同，把字节工作隔离在
Phase 4。

### 风险：错误码 churn

今天的错误 `type` 字符串（`invalid_args`、`unknown_workspace` 等）已经是事实标准
—— adapter 在用。DSL **不能**静默重命名任何一个。缓解：Phase 2 的 canary 验证
错误 map 形状一模一样。如果想改名，单独 followup PR + deprecation note。

### 风险：裸前缀路由打架 adapter

FAA 今天用 deprecated-slash 提示拒未知 slash。新的 `/<resource>` 和
`/<resource>:help` 路径不能和它冲突。缓解：deprecated-slash 表
（SlashHandler 里的 `@deprecated_slashes`）优先级高于新前缀路由 —— 有人输
`/new-workspace`（已删）还是拿到迁移提示，不是 workspace help。

### plugin command 发现

DSL 必须能触达 `Esr.Commands.*`（core）和 `Esr.Plugins.*.Commands.*`（in-tree
plugin，比如 `claude_code` 和 `feishu`）。今天的 plugin command module 在
`runtime/lib/esr/plugins/{claude_code,feishu}/commands/*.ex`，跟 core 同样用
`@behaviour Esr.Role.Control` + `execute/1` 约定。2026-05-08
plugin-command-registration spec 定义了 plugin manifest，每个 plugin 暴露一个
`command_modules/0` 列出自己的 command module 名字。

结论：`mix esr.gen_slash_routes` 先走 `Esr.Commands.*`（core），再调每个启用 plugin
的 `command_modules/0`、走那些 module。CI 只检 core + 默认 plugin manifest 里包含的
plugin。out-of-tree plugin 自己负责跑 check。

值得标注的耦合：plugin command module 采用 DSL 把 2026-05-08
plugin-command-registration spec 拉到这份 spec 的关键路径上。如果那份 spec 的
`command_modules/0` manifest hook 还没 merge，这份 spec 退回成 in-tree plugin
模块名白名单（`Esr.Plugins.ClaudeCode.Commands.*`、`Esr.Plugins.Feishu.Commands.*`）
直到 manifest 落地。

---

## 11. 验收标准

迁移"完成"的判据：

- [ ] 每个 `Esr.Commands.*` module 都暴露 `command_meta/0`（编译期 behaviour 强制）。
- [ ] `slash-routes.default.yaml` 由 `mix esr.gen_slash_routes` 重生成、第一次跑
      字节相同（和迁移前那份手编辑的）。
- [ ] `docs/grammar/commands.md` + `docs/grammar/errors.md` 存在 + committed。
- [ ] `mix esr.check_command_docs` 是 blocking CI step。
- [ ] 在 chat 里 post `/workspace`（不带方法）返回 `workspace:*` 方法清单。
      （e2e 场景断言。）
- [ ] post `/<unknown>` 返回友好错误 + 列有效 resources。
- [ ] 改 command module 的 DSL 不重跑 `mix esr.gen_slash_routes` → CI 挂 + 提示
      "regenerate the yaml"。
- [ ] 没有任何 command module 在 error 返回里手写 `/help` 行或
      `%{"type" => ..., "message" => ...}` 串。全部走 `Esr.Commands.Render`。

---

## 12. 估算

- **Phase 1（DSL 基础设施）：** 1 PR，~400 LOC。宏 + Spec struct + Render + ResourceHelp。
- **Phase 2（canary）：** 1 PR，Workspace.New 上 ~50 LOC delta + 一个快照测试。
- **Phase 3（批量）：** 1-2 PR，~1500 LOC delta（多数是删除：手写 yaml 行消失；
  错误 message 串从 `:error` 返回挪进 DSL）。
- **Phase 4（gen task + docs）：** 1 PR，~300 LOC mix task + docs commit。
- **Phase 5（CI gate）：** 1 PR，~50 LOC `.github/workflows/ci.yml` + 一次 failing-CI
  演示。
- **Phase 6（裸前缀）：** 1 PR，~200 LOC SlashHandler 改 + e2e 场景。

合计：~6 PR，~2500 LOC delta。Phase 3 多数机械，一个聚焦的工作周可以完。

---

## 13. 引用

- 任务 #220 — 结构化错误的最初诉求（现在以支柱 3 + docs/grammar/errors.md 落地）
- 2026-05-08 plugin-command-registration spec — 定义这份 spec 消费的 plugin 边界
- 2026-05-08 resource-typed-grammar spec — 定义 DSL 继承的 colon-namespace 形状
- 2026-05-08 session-first-default-resolution spec — 最后一次手编辑
  slash-routes.default.yaml 的 spec；这份 spec 让那是最后一次
- PR #285（今天）— 直接触发：Doctor 里 hardcoded grammar，DSL 在编译期就拦下了
