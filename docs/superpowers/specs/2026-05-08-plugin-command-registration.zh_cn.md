# Plugin 范围内命令注册机制

**Spec id:** 2026-05-08-plugin-command-registration  
**作者：** Allen Woods + Claude  
**状态：** rev-1（草稿，等待用户审阅）  
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
- **核心 slash 行为零变化**。本 spec 只增加 plugin 扩展点；不在本 PR 搬动任何核心 slash。

## 3. 非目标

- **不** 在本 PR 把 `/user:bind-feishu` 物理迁到 `/feishu:bind`。`bind_feishu` 命令保持原位；本 spec 只保证 *机制* 已就绪，让后续 PR 可以干净搬迁。
- **不** 做动态/运行时命令注册（plugin 在 boot 阶段用代码动态生成命令）。仅声明式——和今天的 `capabilities:` 一致。
- **不** 改 dispatch 逻辑。`Esr.Entity.SlashHandler.dispatch/3` 和 queue-watcher 路径保持完全不变。

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

### 5.5 `/user:bind-feishu` → `/feishu:bind` 迁移路径（非本 PR 范围，但已解锁）

本 PR 之后，后续可以：

1. 加 `Esr.Plugins.Feishu.Commands.Bind`（搬运或重新导出 `Esr.Commands.User.BindFeishu` 的逻辑）。
2. 给 `runtime/lib/esr/plugins/feishu/manifest.yaml` 加 `slash_routes:` 块。
3. 从 `slash-routes.default.yaml` 删 `/user:bind-feishu`。
4. 删 `runtime/lib/esr/commands/user/bind_feishu.ex`。
5. 绑定数据继续保存在用户的 user-default workspace 目录 (`<user_default_ws_root>/bindings/feishu.json`)——这正好和刚 ship 的 session-first spec 兼容，因为 user-default 现在是硬保证的概念。

整个后续 PR 不动核心注册代码——只搬文件。这正是想要的特性。

## 6. 决策日志

- **D1.** Plugin 命令是声明式 yaml-only，不提供代码侧 `slash_hook` 回调。*理由：* 与 `capabilities:` 模式一致；yaml 可静态检查（`/help`、文档、补全）；代码 hook 不透明、难以禁用。
- **D2.** 冲突 = 硬错误，不做静默覆盖、不做优先级裁决。*理由：* 两个 plugin 都声明 `/feishu:bind` 的行为是未定义——启动时大声报出来。
- **D3.** Per-plugin 命名空间前缀是强制的，不是建议。*理由：* 用户明确指出"ad-hoc 添加导致用户理解困难"是要解决的问题。能注册 `/user:foo` 的 plugin 仍然是 ad-hoc。
- **D4.** 本 PR 不做物理命令迁移。*理由：* 控制 PR 范围；#5 的 session-first 工作已经够大。机制本身就是本 PR 的交付物。
- **D5.** `permission:` 字段禁止引用跨 plugin 的 cap。*理由：* `feishu` 引用 `claude_code/spawn` 就有了 `claude_code` 存在性的隐藏耦合——register 时报错给作者一个清晰错误。
- **D6.** Overlay map 存在 SlashRoute.Registry GenServer state 里，不存 ETS 也不存 persistent_term。*理由：* 与现有 snapshot 一致（也是单一 GenServer call 后面）；重建廉价（合并后的 ETS 才是热路径，今天每次变更也都要重建）。

## 7. 实施面（plan 阶段使用）

预估：~150 LOC + ~250 LOC 测试。

| 文件 | 改动 |
|------|------|
| `runtime/lib/esr/plugin/manifest.ex` | 把 `slash_routes` 加到 `@allowed_declares`；加 `validate_slash_routes/2`；导出 `slash_route_snapshot/1` |
| `runtime/lib/esr/plugin/loader.ex` | `start_plugin/2` 的 `with`-chain 加 `register_slash_routes/2` |
| `runtime/lib/esr/resource/slash_route/registry.ex` | 加 `register_overlay/2` + `unregister_overlay/1`；state 重构为 base + overlays + 合并视图；加冲突检测合并函数 |
| `runtime/lib/esr/resource/slash_route/file_loader.ex` | 复用现有 `parse_slash_routes/1` 处理 base 和 overlay；不分 schema |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | 加空的 `slash_routes:` 块（不放 slash——只用作 sanity gate，验证空 manifest 通过 validator） |
| `runtime/test/esr/plugin/manifest_test.exs` | 用例：合法块、错前缀拒绝、跨 plugin cap 引用拒绝、未知 command_module 拒绝 |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | 用例：overlay 注册、overlay 注销、slash 冲突检测、kind 冲突检测、core 文件事件后 overlay 仍在 |

## 8. 测试计划（红→绿）

1. **单元** — `Manifest.validate/1` 对前缀不匹配的 `slash_routes` 块返回错误。
2. **单元** — `Manifest.validate/1` 对不以 `<plugin_name>_` 开头的 kind 返回错误。
3. **单元** — `Manifest.validate/1` 对未在同 plugin `capabilities:` 声明的 `permission:` 返回错误。
4. **单元** — `SlashRoute.Registry.register_overlay/2` 对重复 slash key 返回 `{:error, {:slash_collision, key, owner}}`。
5. **单元** — `SlashRoute.Registry.register_overlay/2` 对重复 kind 返回 `{:error, {:kind_collision, kind, owner}}`。
6. **单元** — 触发核心文件事件（touch `slash-routes.default.yaml`）后，已注册的 overlays 还在。
7. **集成** — Loader 启动带 `slash_routes` 块的 feishu plugin，slash 通过 `SlashHandler.dispatch/3` 端到端可派发。
8. **集成** — `Loader.stop_plugin/1`（今天还是 stub）调 `unregister_overlay`；之后 overlay 的 slash 全部消失。

## 9. 不变量

- **I1.** 合并后的 ETS 表中不存在两个不同的注册（base + overlays）共享同一个 slash key。违反 = registry 拒绝安装。
- **I2.** 合并后的 ETS 中每个 slash key 都属于已知核心 group (`/user:`、`/workspace:`、`/session:`、`/plugin:`、`/cap:`、`/help`) 之一，或属于已注册 plugin 的命名空间 `/<plugin>:`。无例外。
- **I3.** 合并后的 ETS 中每个 kind 的前缀要么是核心 group 要么是 `<plugin>_`。（kind 世界的 I2。）
- **I4.** Plugin 声明的 `permission:` 值是该 plugin `capabilities:` 的子集。本层不允许跨 plugin 引用。

## 10. 待审阅的开放问题

- **Q1.** Plugin 是否允许声明 `internal_kinds:`（仅 admin-CLI、无 slash）？Spec 假设允许（与核心对称），但扩大表面积。*建议：允许。*
- **Q2.** Plugin overlay 与核心冲突时正确的错误处理？今天 plugin 启动失败——但 daemon 是拒绝启动还是只跳过该 plugin？*建议：跳过该 plugin、记结构化错误日志、daemon 继续启动。和今天 config_schema 不匹配的处理方式一致。*
- **Q3.** 本 PR 是否迁移 `/user:bind-feishu` → `/feishu:bind`？*建议：留给后续 PR，本 PR 只交付机制。*

## 11. 附录 — 与 session-first spec (#5) 的关系

刚 ship 的 session-first spec 保证每个用户在任何时刻都有 `<username>-default` workspace。本 spec 在迁移讨论 (§5.5) 里依赖该保证：plugin 绑定数据存在 `user_default_workspace_root/bindings/<plugin>.json`。有了 user-default 作为硬不变量，这条路径永远 well-defined——不需要 fallback / null 检查 / "无 workspace" 分支。

两份 spec 在 *机制* 维度是独立的（本 spec 不依赖任何 session-first 代码），但合在一起就构成了 plugin 作者发布自包含 plugin 的基础：命令注册（本 spec）+ 持久化的 per-user 存储（session-first spec）。
