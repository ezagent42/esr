# Plugin 范围内命令注册机制

**Spec id:** 2026-05-08-plugin-command-registration  
**作者：** Allen Woods + Claude  
**状态：** rev-3（D4 放弃 kind 名稳定承诺：rename 服从命名空间纪律，无后向兼容）  
**对应：** post-multi-instance audit 任务 #6  
**关联：** 2026-05-08-session-first-default-resolution.md（同期 spec）

## 1. 问题陈述

今天每加一条新 slash 或 admin-CLI 命令，都要改 **核心** 文件：

1. `runtime/priv/slash-routes.default.yaml` — 加路由
2. `runtime/lib/esr/commands/<group>/<verb>.ex` — 写命令模块
3. `runtime/lib/esr/resource/permission/bootstrap.ex` — 声明 capability（如果是新的）
4. `runtime/lib/esr/entity/slash_handler.ex` — 如果命令需要 chat 上下文，加一条 envelope-merge 子句（多数命令不用）
5. 在 `runtime/test/esr/commands/...` 下补测试

对于 **核心** 命令（ESR 自带的有限几个），这没问题。对于 **plugin** 命令则不可持续：今天的 `feishu`、`claude_code` 等 plugin 想加一条 slash，就必须给核心提 PR。随着 plugin 增多结果是：

- 核心 `slash-routes.yaml` 会被 plugin 命令撑爆。
- 操作员看不出哪条 slash 属于哪个子系统。
- Plugin 作者无法独立禁用/重载/版本化自己的命令。
- 冒号命名空间 `/<group>:<verb>` 被随意占用——`/feishu:bind` 和 `/user:bind-feishu` 撞在同一个概念上，是因为没机制阻止任意一边占名字。

## 2. 目标

- **唯一标准入口**：plugin 作者注册命令只用一个机制；不需要改核心文件。
- **命名空间纪律**：plugin 名字 `feishu` 只能注册 `/feishu:*`（admin kind 前缀必须是 `feishu_`）。在 manifest 验证阶段就拒绝，不是上线后才发现。
- **与 `capabilities:` / `python_sidecars:` 完全对称**：`Esr.Plugin.Manifest` 里同一种声明位置、同一种生命周期。
- **本 PR 同时迁移真正属于 plugin 的现有命令以验证机制**。审计（§5.5）找到 3 条这样的命令：`bind_feishu`、`unbind_feishu`、`notify`，本 PR 一并迁到 feishu plugin。
- **kind 名字对外稳定**。`kind: notify`、`kind: user_bind_feishu`、`kind: user_unbind_feishu` 不变，escript queue 和外部 caller 不感知；只翻 `command_module:`。

## 3. 非目标

- **不** 做动态/运行时命令注册（plugin 在 boot 阶段用代码动态生成命令）。仅声明式——和今天的 `capabilities:` 一致。
- **不** 改 dispatch 逻辑。`Esr.Entity.SlashHandler.dispatch/3` 和 queue-watcher 路径保持完全不变。
- **不** 迁移 `Workspace.BindChat` / `UnbindChat`。审计判定它们是 channel-agnostic（`chats[]` 数据模型对未来 Slack/Telegram tuple 都兼容），正确归属是核心。Permission `workspace.create` 已经是核心命名空间。

## 4. 当前注册机制（审计摘要）

ESR 的 slash 调度是 **yaml 驱动、单一事实来源**。两个 ETS 表（`:esr_slash_routes`、`:esr_slash_kinds`）由 `Esr.Resource.SlashRoute.FileLoader` 从一个 yaml 文件 (`runtime/priv/slash-routes.default.yaml`) 装载，每次文件事件由 `Esr.Resource.SlashRoute.Registry.load_snapshot/1` 原子替换。

`/<slash>` 路径和 `esr admin submit <kind>` 路径用同一个 registry 查找。**没有独立的 router 或 dispatch 表**——yaml 自身就是 router。

Plugin.Loader (`runtime/lib/esr/plugin/loader.ex:178-196`) 已经支持四种声明类型：

```elixir
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_startup(name, manifest)
```

Loader 文档明确预告了本 spec：

> "Phase-1 supports `python_sidecars` + `capabilities`; remaining declaration types (**slash_routes**, agent_defs, entities, http_routes, …) arrive when the corresponding registries grow `register/3`-style APIs in subsequent tasks."

`runtime/lib/esr/yaml/fragment_merger.ex` 已经存在 yaml 片段合并器的 stub，对应"基础 + per-plugin 覆盖层"模式。

## 5. 设计

### 5.1 Manifest schema 扩展

Plugin 的 `manifest.yaml` 增加一个 `declares.slash_routes:` 块，schema 与 `slash-routes.default.yaml` 完全一致，scope 限定为该 plugin：

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  capabilities:
    - feishu/manage
    - feishu/bind

  slash_routes:
    schema_version: 1
    slashes:
      "/feishu:bind":
        kind: feishu_bind
        permission: feishu/bind
        command_module: Esr.Plugins.Feishu.Commands.Bind
        requires_workspace_binding: false
        requires_user_binding: false
        category: feishu
        description: "把 Feishu 身份 (ou_xxx) 绑定到 ESR user"
        args:
          - name: name
            required: true
          - name: feishu_id
            required: true
    internal_kinds:
      feishu_bind:
        permission: feishu/bind
        command_module: Esr.Plugins.Feishu.Commands.Bind
```

**`Manifest.validate/1` 强制约束：**

- `slashes:` 里的每个 key 必须匹配 `^/<plugin_name>:`（如 `feishu` plugin 必须 `/feishu:*`）。否则拒绝。
- `kind:` 值（`slashes:` 和 `internal_kinds:` 都算）必须以 `<plugin_name>_` 开头。否则拒绝。
- 任何引用的 `permission:` 必须在该 plugin 自己 `capabilities:` 里也声明过。本 spec 不允许跨 plugin cap 引用。
- 任何 `command_module:` 必须能 `Code.ensure_loaded?/1`，且模块名必须以 `Esr.Plugins.<PluginCamel>.` 开头。

### 5.2 Plugin.Loader 整合

加第五个注册步骤：

```elixir
# runtime/lib/esr/plugin/loader.ex (start_plugin/2 with-chain)
:ok <- register_capabilities(name, manifest),
:ok <- register_python_sidecars(manifest),
:ok <- register_entities(manifest),
:ok <- register_slash_routes(name, manifest),    # NEW
:ok <- register_startup(name, manifest) do
```

`register_slash_routes/2` 调用新的 `Esr.Resource.SlashRoute.Registry.register_overlay/2`，传 plugin 名字和已解析的 snapshot。

### 5.3 Registry 覆盖层模型

`Esr.Resource.SlashRoute.Registry` 增加：

```elixir
@spec register_overlay(plugin_name :: String.t(), snapshot :: map()) :: :ok
@spec unregister_overlay(plugin_name :: String.t()) :: :ok
```

State 重构：把"每次文件事件全表替换"改成：

- `@base_table` — 仅由 `slash-routes.default.yaml` 填充（file watcher 路径）。
- `@overlay_state :: %{plugin_name => snapshot}` — GenServer state 里维护的 per-plugin 映射。
- `@slash_table` / `@kind_table` — **合并视图**，base 或 overlays 任一变化时重建。

合并规则：**slash key 或 kind 名字冲突 = 硬错误**（同 `Yaml.FragmentMerger`）。Plugin 的 `register_overlay` 返回 `{:error, {:slash_collision, key, owner}}`，plugin 启动失败。这是正确行为——静默覆盖会让任意 plugin 劫持 `/user:add`。

核心文件 watcher 事件重建 base；overlays 不动。Plugin 重载只重新注册自己的 overlay；其它不动。

### 5.4 命名空间强制点

带保险的双层防御：

- **Manifest validate 时** (`Esr.Plugin.Manifest.validate_slash_routes/2`) — plugin 还没启动就拒绝。这是 plugin 作者开发时看到的错误。
- **Registry register 时** (`SlashRoute.Registry.register_overlay/2`) — 如果 snapshot 不知怎么绕过了 validate（比如 manifest 被运行时手改、或未来代码路径绕过 validate），第二层兜底再拒一次。

### 5.5 plugin-owned 命令物理迁移（本 PR 范围内）

审计结果：核心今天有 **正好 3 条** 命令满足 plugin 归属判据（直接引用 plugin runtime、没有 plugin 就无意义、permission 已在 plugin 命名空间）：

| 命令 | 当前模块 | Plugin | 新模块 |
|---|---|---|---|
| `kind: user_bind_feishu` (CLI-only) | `Esr.Commands.User.BindFeishu` (105 LOC) | feishu | `Esr.Plugins.Feishu.Commands.BindUser` |
| `kind: user_unbind_feishu` (CLI-only) | `Esr.Commands.User.UnbindFeishu` (70 LOC) | feishu | `Esr.Plugins.Feishu.Commands.UnbindUser` |
| `kind: notify` (CLI-only) | `Esr.Commands.Notify` (79 LOC) | feishu | `Esr.Plugins.Feishu.Commands.Notify` |

**迁移范围（按审计）：**
- 3 个源文件搬移（~254 LOC，逻辑原样）。
- 1 个测试文件搬移（`notify_test.exs`，235 LOC）。
- 1 处测试 fixture 整理：`runtime/test/esr/resource/slash_route/registry_test.exs` 用 `Esr.Commands.Notify` 当占位 sentinel 模块（~30 行），换成通用的 `Esr.Test.NoopCommand`（机械 sed；~50 LOC）。
- 0 个硬阻塞。
- 1 处文档更新：`runtime/lib/esr/scope/admin/process.ex:32` 注释。

**迁移保持的稳定契约：**
- `kind:` 名字保留（`user_bind_feishu`、`user_unbind_feishu`、`notify`），只翻 `command_module:`。escript queue + admin dispatcher 调用方式完全不变。
- `permission:` 字符串原则上不动；本 PR 只在三条命令上做：`notify.send` 保持原样（已经在 plugin 命名空间）；`user.manage` 改名 `feishu/user-bind` 让 `permission:` 字段匹配 `<plugin>/<rest>` 模式（小幅改进）。

**Workspace.BindChat / UnbindChat 明确不迁移**：审计判定 workspace `chats[]` 数据模型 channel-agnostic（未来 Slack/Telegram plugin 也共用），它们本来就归核心；permission `workspace.create` 已经是核心命名空间。

**为什么现在做（不留给后续）：**

- 成本 ~675 LOC 大部分机械工作。比纯机制 PR 多约 10–15%。
- 没有真实消费者，机制正确性难判断。迁移真实命令能压力测试 validator（`feishu/user-bind` 是否被接受？kind `<plugin>_` 前缀是否真能拦下 typo？）、loader（plugin 重载是否仍能工作？）、registry collision 检测（从 yaml 删核心条目 + 加 overlay 是否产生零 collision warning？）。
- "机制 + 零使用" 的 PR 发的是未测试的抽象。"机制 + 3 个真实消费者" 发的是已验证的抽象。

User-bind 数据继续保存在 `<user_default_workspace_root>/bindings/feishu.json` —— 与刚 ship 的 session-first spec 兼容（该 spec §5 把 user-default 做成硬不变量，所以这条路径永远 well-defined）。

## 6. 决策日志

- **D1.** Plugin 命令是声明式 yaml-only，不提供代码侧 `slash_hook` 回调。*理由：* 与 `capabilities:` 模式一致；yaml 可静态检查（`/help`、文档、补全）；代码 hook 不透明、难以禁用。
- **D2.** 冲突 = 硬错误，不做静默覆盖、不做优先级裁决。*理由：* 两个 plugin 都声明 `/feishu:bind` 的行为是未定义——启动时大声报出来。
- **D3.** Per-plugin 命名空间前缀是强制的，不是建议。*理由：* 用户明确指出"ad-hoc 添加导致用户理解困难"是要解决的问题。能注册 `/user:foo` 的 plugin 仍然是 ad-hoc。
- **D4.** 本 PR 同时迁移 3 条 plugin-owned 命令（`bind_feishu`、`unbind_feishu`、`notify`）到 feishu plugin。*理由：* 审计 (§5.5) 确认 ~675 LOC 大部分机械工作，零硬阻塞。发"机制无消费者"的 PR 是发未测试的抽象；迁移端到端验证 validator + loader + registry overlay。`kind:` 名字保留，外部 dispatcher（escript queue、admin）零感知。
- **D5.** `permission:` 字段禁止引用跨 plugin 的 cap。*理由：* `feishu` 引用 `claude_code/spawn` 就有了 `claude_code` 存在性的隐藏耦合——register 时报错给作者一个清晰错误。
- **D6.** Overlay map 存在 SlashRoute.Registry GenServer state 里，不存 ETS 也不存 persistent_term。*理由：* 与现有 snapshot 一致（也是单一 GenServer call 后面）；重建廉价（合并后的 ETS 才是热路径，今天每次变更也都要重建）。

## 7. 实施面（plan 阶段使用）

总预估：**~825 LOC + ~500 LOC 测试** = ~1325 LOC。两个独立阶段。

### 7a. 机制（~150 LOC + ~250 LOC 测试）

| 文件 | 改动 |
|------|------|
| `runtime/lib/esr/plugin/manifest.ex` | 把 `slash_routes` 加到 `@allowed_declares`；加 `validate_slash_routes/2`；导出 `slash_route_snapshot/1` |
| `runtime/lib/esr/plugin/loader.ex` | `start_plugin/2` 的 `with`-chain 加 `register_slash_routes/2`；`stop_plugin/1` 调 `unregister_overlay/1` |
| `runtime/lib/esr/resource/slash_route/registry.ex` | 加 `register_overlay/2` + `unregister_overlay/1`；state 重构为 base + overlays + 合并视图；加冲突检测合并函数 |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | 复用现有 `parse_slash_routes/1` 处理 base 和 overlay；不分 schema |
| `runtime/test/esr/plugin/manifest_test.exs` | 用例：合法块、错前缀拒绝、跨 plugin cap 引用拒绝、未知 command_module 拒绝 |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | 用例：overlay 注册、overlay 注销、slash 冲突检测、kind 冲突检测、core 文件事件后 overlay 仍在 |

### 7b. 迁移（~675 LOC，主要是文件搬移）

| 文件 | 改动 |
|------|------|
| 搬：`runtime/lib/esr/commands/user/bind_feishu.ex` → `runtime/lib/esr/plugins/feishu/commands/bind_user.ex` | 模块改名为 `Esr.Plugins.Feishu.Commands.BindUser`；逻辑原样 |
| 搬：`runtime/lib/esr/commands/user/unbind_feishu.ex` → `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex` | 模块改名为 `Esr.Plugins.Feishu.Commands.UnbindUser`；逻辑原样 |
| 搬：`runtime/lib/esr/commands/notify.ex` → `runtime/lib/esr/plugins/feishu/commands/notify.ex` | 模块改名为 `Esr.Plugins.Feishu.Commands.Notify`；逻辑原样 |
| 搬：`runtime/test/esr/commands/notify_test.exs` → `runtime/test/esr/plugins/feishu/commands/notify_test.exs` | 测试中模块名同步更新 |
| 改：`runtime/priv/slash-routes.default.yaml` | 删除 3 条 `internal_kinds:` 条目（`user_bind_feishu`、`user_unbind_feishu`、`notify`）——它们迁到 feishu manifest |
| 改：`runtime/lib/esr/plugins/feishu/manifest.yaml` | 加 `slash_routes:` 块声明 3 条迁移过来的 kind；引用新模块名 |
| 改：`runtime/lib/esr/resource/permission/bootstrap.ex` | bind/unbind 用的 cap 改名：引入 `feishu/user-bind` |
| 改：`runtime/lib/esr/scope/admin/process.ex:32` | 文档注释引用 notify 位置同步更新 |
| 改：`runtime/test/esr/resource/slash_route/registry_test.exs` | ~30 处用 `Esr.Commands.Notify` 当 sentinel 的行 → 切到通用 `Esr.Test.NoopCommand` 测试 fixture |
| 加：`runtime/test/esr/test/noop_command.ex`（或类似） | 通用 test-only 命令模块，让 registry 测试不再依赖某个真实命令的存在 |

## 8. 测试计划（红→绿）

1. **单元** — `Manifest.validate/1` 对前缀不匹配的 `slash_routes` 块返回错误。
2. **单元** — `Manifest.validate/1` 对不以 `<plugin_name>_` 开头的 kind 返回错误。
3. **单元** — `Manifest.validate/1` 对未在同 plugin `capabilities:` 声明的 `permission:` 返回错误。
4. **单元** — `SlashRoute.Registry.register_overlay/2` 对重复 slash key 返回 `{:error, {:slash_collision, key, owner}}`。
5. **单元** — `SlashRoute.Registry.register_overlay/2` 对重复 kind 返回 `{:error, {:kind_collision, kind, owner}}`。
6. **单元** — 触发核心文件事件（touch `slash-routes.default.yaml`）后，已注册的 overlays 还在。
7. **集成** — Loader 启动带 `slash_routes` 块的 feishu plugin，slash 通过 `SlashHandler.dispatch/3` 端到端可派发。
8. **集成** — `Loader.stop_plugin/1`（今天还是 stub）调 `unregister_overlay`；之后 overlay 的 slash 全部消失。
9. **迁移回归** — 迁移后 `kind: notify` 仍能通过 `Esr.Resource.SlashRoute.Registry.command_module_for/1` 解析（解析到新模块 `Esr.Plugins.Feishu.Commands.Notify`）；现有 `notify_test.exs` 用例对搬移后的模块继续通过。
10. **迁移回归** — `kind: user_bind_feishu` admin-CLI dispatch 路径解析到 `Esr.Plugins.Feishu.Commands.BindUser`；user-binding YAML 写入产生与迁移前同样的 on-disk 形态（add 后 `users.yaml` 单字段结构相等）。

## 9. 不变量

- **I1.** 合并后的 ETS 表中不存在两个不同的注册（base + overlays）共享同一个 slash key。违反 = registry 拒绝安装。
- **I2.** 合并后的 ETS 中每个 slash key 都属于已知核心 group (`/user:`、`/workspace:`、`/session:`、`/plugin:`、`/cap:`、`/help`) 之一，或属于已注册 plugin 的命名空间 `/<plugin>:`。无例外。
- **I3.** 合并后的 ETS 中每个 kind 的前缀要么是核心 group 要么是 `<plugin>_`。（kind 世界的 I2。）
- **I4.** Plugin 声明的 `permission:` 值是该 plugin `capabilities:` 的子集。本层不允许跨 plugin 引用。

## 10. 待审阅的开放问题

- **Q1.** Plugin 是否允许声明 `internal_kinds:`（仅 admin-CLI、无 slash）？Spec 假设允许（与核心对称），但扩大表面积。*建议：允许。*
- **Q2.** Plugin overlay 与核心冲突时正确的错误处理？今天 plugin 启动失败——但 daemon 是拒绝启动还是只跳过该 plugin？*建议：跳过该 plugin、记结构化错误日志、daemon 继续启动。和今天 config_schema 不匹配的处理方式一致。*
- **Q3.** **已解决（rev-2）** —— 本 PR 迁移 `bind_feishu` + `unbind_feishu` + `notify`。见 §5.5 与 D4。

## 11. 附录 — 与 session-first spec (#5) 的关系

刚 ship 的 session-first spec 保证每个用户在任何时刻都有 `<username>-default` workspace。本 spec 在迁移讨论 (§5.5) 里依赖该保证：迁移后的 `bind_feishu` 命令把用户→feishu 映射保存在 `<user_default_workspace_root>/bindings/feishu.json`。有了 user-default 作为硬不变量，这条路径永远 well-defined——不需要 fallback / null 检查 / "无 workspace" 分支。

两份 spec 在 *机制* 维度是独立的（本 spec 不依赖任何 session-first 代码），但合在一起就构成了 plugin 作者发布自包含 plugin 的基础：命令注册（本 spec）+ 持久化的 per-user 存储（session-first spec）。
