# Plugin Config 热重载

**日期**: 2026-05-07
**状态**: rev-2 — e2e 验证范围扩展（用户反馈 2026-05-07）
**英文版**: `docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md`
**扩展自**: `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` §6（plugin config 3 层）
**不替换任何现有 spec** — 本 spec 是增量设计

---

## 锁定决策（Feishu 2026-05-07）

| ID | 决策 |
|----|------|
| **Q1** | **显式 slash**：`/plugin:reload <plugin>` 触发重载。无 fs-watcher，无自动重载。 |
| **Q2** | **逐 plugin opt-in**：manifest 里声明 `hot_reloadable: true` 才允许热重载。默认 false（重启才生效）。 |
| **Q3** | **callback 强制**：`hot_reloadable: true` 的 plugin 必须实现 `Esr.Plugin.Behaviour.on_config_change/1`。 |
| **Q4** | **trigger-only callback**：`on_config_change(changed_keys :: [String.t()]) :: :ok \| {:error, reason}`。Plugin 通过 `Esr.Plugin.Config.get/3` 读新值（始终返回当前状态）。 |
| **Q5** | **best-effort + plugin 自行 fallback**：yaml 先写；callback 再触发；plugin 返回 `:error` → 记 warning，plugin 进入自己的"配置不一致"fallback 状态。框架层**不回滚**（VS Code 一致性）。 |
| **Q6** | **共用 cap**：`/plugin:reload` 与 `/plugin:set` 用同一 cap：`plugin/manage`。 |
| **Q7** | **不支持批量 reload**：只有 `/plugin:reload <plugin_name>`，**不支持** `/plugin:reload`（不传名字 = 报错）。原因：plugin 之间可能有依赖，失败要可定位，operator 必须逐个 reload。 |

---

## §1 动机

今天（Phase 7）plugin config 修改后必须重启 `esrd` 才能生效。`/plugin:set` 写入 `plugins.yaml`，但运行中的进程依然用旧值。重启会杀掉所有活跃 session，Feishu 用户看到 agent 消失，重连需要 10–30 秒。对于只影响出站 HTTP 行为的配置项（proxy、log_level 等），全量重启没有必要。

**对齐 VS Code**：VS Code 扩展模型在设置变更时触发 `onDidChangeConfiguration` 事件——callback 是 trigger-only（不传 old_config/new_config，扩展自行 `getConfiguration()` 读新值），VS Code 不回滚 `settings.json`。本 spec 采用相同语义。

**目标**：
1. operator 可以在不重启 `esrd` 的情况下更新 plugin config
2. plugin 显式 opt-in（安全保证：旧 plugin 保持重启生效语义）
3. 失败隔离（一个 plugin 的 reload 失败不影响其他 plugin）

**非目标**：fs-watcher 自动重载 / 跨 plugin 原子重载 / Elixir 模块热更新（代码级 reload 超出范围）

---

## §2 Callback API

新建 `Esr.Plugin.Behaviour` 模块，定义唯一 callback：

```elixir
defmodule Esr.Plugin.Behaviour do
  @type changed_keys :: [String.t()]
  @type reason :: term()

  @doc """
  当 /plugin:reload <name> 被调用且 manifest 声明 hot_reloadable: true 时，
  框架调用此 callback。

  changed_keys：当前 effective config 与 plugin 上次成功应用时的快照之间
  发生变化的 key 列表。空列表 = 实际值没变，但 operator 强制触发了 reload
  （callback 仍然触发）。

  Plugin 必须通过 Esr.Plugin.Config.get/3 读新值；不得跨调用缓存配置值。

  返回 :ok → 框架更新快照。
  返回 {:error, reason} → 框架记 [warning]，快照不更新，plugin 自行管理 fallback。
  """
  @callback on_config_change(changed_keys()) :: :ok | {:error, reason()}
end
```

---

## §3 Manifest 字段扩展

新增顶层字段 `hot_reloadable: true/false`（默认 false）：

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml（HR-3 后）
name: claude_code
version: 0.1.0
hot_reloadable: true   # 新增 — 显式 opt-in

# ... 其余字段不变
```

**`Esr.Plugin.Manifest` 改动**：

- struct 增加 `hot_reloadable` 字段（boolean，默认 false）
- `parse/1` 读取该字段；值不是 boolean → `{:error, {:invalid_hot_reloadable, value}}`
- 检查时机：**仅在 `/plugin:reload` 调用时检查**，不在 boot 时检查

当 `hot_reloadable: false` 或未声明时，`/plugin:reload` 返回：

```elixir
{:error, %{
  "type" => "not_hot_reloadable",
  "plugin" => name,
  "message" => "plugin must declare hot_reloadable: true in manifest to support reload; restart esrd to apply config changes"
}}
```

---

## §4 `/plugin:reload` Slash 命令

### slash-routes.default.yaml 新增项

```yaml
"/plugin:reload":
  kind: plugin_reload
  permission: "plugin/manage"    # 与 /plugin:set 共用，per Q6
  command_module: "Esr.Commands.Plugin.Reload"
  requires_workspace_binding: false
  requires_user_binding: false
  category: "Plugins"
  description: "Trigger config reload for one plugin (requires hot_reloadable: true in manifest). No name arg = error (no batch reload, per Q7)."
  args:
    - { name: plugin, required: true }
```

不提供 `plugin` 参数 → dispatcher 直接报 missing-arg 错误，不进入 command 模块。

### `Esr.Commands.Plugin.Reload` 执行步骤

1. 通过 `Loader.discover()` 解析 manifest → 验证 plugin 存在
2. 检查 `manifest.hot_reloadable == true`（Q2）
3. 解析 plugin 模块（`Esr.Plugins.<Name>.Plugin`），验证 `on_config_change/1` 已导出（Q3）
4. 计算 `changed_keys`：当前 effective config 与 ETS 快照 diff
5. 在 `Task` 里调用 `module.on_config_change(changed_keys)`，5 秒超时（Risk 1）
6. 返回结果：

| 情况 | `"reloaded"` | `"fallback_active"` |
|------|-------------|-------------------|
| callback 返回 `:ok` | `true` | 无此字段 |
| callback 返回 `{:error, _}` | `false` | `true` |
| callback 超时 | `false` | `true` |
| `not_hot_reloadable` | — | `{:error, ...}` |

---

## §5 Best-Effort + Fallback 语义（Q5）

- **框架永不回滚 yaml**：`plugins.yaml` 反映 operator 意图；plugin 运行状态是 plugin 自己的责任
- callback 返回 `{:error, reason}` → 框架记 `[warning] plugin <name> failed to apply config change: <reason>`
- ETS 快照**不更新**（下次 reload 会再次 diff 出相同的 `changed_keys`，operator 可以修正配置后重试）
- Plugin 应当：
  1. 自己记 `[error]`（非 `[warning]`），使 fallback 状态可观测（Risk 2）
  2. 决定 fallback 策略（用旧缓存值 / fail-closed / 优雅降级）

---

## §6 共用 Cap（Q6）

`plugin/manage` cap 已覆盖：`/plugin:set`、`/plugin:unset`、`/plugin:enable`、`/plugin:disable`、`/plugin:install`、`/plugin:list`、`/plugin:info`、`/plugin:show-config`、`/plugin:list-config`。

`/plugin:reload` 加入同一 cap。**不新增 capability**。

如未来需要"只能 reload 不能修改 config"的角色，可新增 `plugin.reload` cap，仅需修改 command 模块的权限检查，不影响本 spec 的其他内容。

---

## §7 实现 Phasing（3 个子阶段）

### HR-1 — Behaviour 模块 + Manifest 解析扩展

**交付物**：
- `runtime/lib/esr/plugin/behaviour.ex` — `Esr.Plugin.Behaviour`（callback 定义）
- `runtime/lib/esr/plugin/config_snapshot.ex` — `Esr.Plugin.ConfigSnapshot`（ETS 快照存储）
- 修改 `Esr.Plugin.Manifest`：struct 加 `hot_reloadable`，`parse/1` 读取该字段
- 修改 `Esr.Plugin.Loader`：plugin 加载后调用 `ConfigSnapshot.init/2`
- 修改 `Esr.Application`：启动时调用 `ConfigSnapshot.create_table/0`

**测试**：manifest 解析（true/false/absent/invalid）+ snapshot ETS 读写

**约 100 LOC + 80 LOC 测试。可独立发布（无 user-visible 变化）。**

---

### HR-2 — `/plugin:reload` Slash 命令

**交付物**：
- `runtime/lib/esr/commands/plugin/reload.ex` — `Esr.Commands.Plugin.Reload`（完整实现见 §4）
- 修改 `runtime/priv/slash-routes.default.yaml`：新增 `/plugin:reload` 项

**测试**：`not_hot_reloadable`、`unknown_plugin`、`callback_not_exported`、happy path（changed_keys 非空）、force reload（changed_keys 为空）、callback 返回 `{:error, _}`、callback 超时

**约 120 LOC + 140 LOC 测试。依赖 HR-1 先合并。**

---

### HR-3 — claude_code + feishu 接入

**交付物**：

#### claude_code
- `manifest.yaml` 加 `hot_reloadable: true`
- 新建 `runtime/lib/esr/plugins/claude_code/plugin.ex`

`on_config_change/1` 逻辑：
- `http_proxy` / `https_proxy` / `no_proxy` / `esrd_url`：这些配置在 session 启动时注入 PTY 环境，新值对**新 session** 自动生效，无需做任何操作
- `anthropic_api_key_ref`：同样是启动时注入，无法对运行中 session 热更。记 `[warning]` 提示 operator 重启 session，然后返回 `:ok`
- 所有 key：返回 `:ok`（callback 故意设计为轻量）

#### feishu
- `manifest.yaml` 加 `hot_reloadable: true`
- 新建 `runtime/lib/esr/plugins/feishu/plugin.ex`

`on_config_change/1` 逻辑：
- `app_id` / `app_secret`：`FeishuAppAdapter` 在每次 Lark REST 调用时读取，不缓存，新值自动生效，无需操作
- `log_level`：Python sidecar 不支持热更 log level。记 `[warning]` 提示重启 sidecar，返回 `:ok`

**约 80 LOC + 80 LOC 测试。依赖 HR-1 + HR-2 先合并。**

---

### Phasing 总览（rev-2 更新）

| 阶段 | 依赖 | LOC（约） | 测试（约） | User-visible？ |
|------|------|-----------|-----------|---------------|
| HR-1 | 无 | 100 | 80 | 否 |
| HR-2 | HR-1 | 120 | 140 | 是 |
| HR-3 | HR-1 + HR-2 | 80 | 80 | 是 |
| HR-4 | HR-1 + HR-2 + HR-3 | ~150 | —（e2e 即测试） | 是（scenario 17）|
| **合计** | | **~550** | **~300 单测** | |

---

## §8 风险登记

| 风险 | 缓解措施 |
|------|---------|
| **R1** callback 慢，阻塞 slash dispatch | Task + 5 秒超时；超时 → `fallback_active: true` |
| **R2** fallback 状态对 operator 不可观测 | Plugin 自记 `[error]`；后续引入 `Esr.Plugin.Status.set_fallback/2`（本 spec 范围外）|
| **R3** 快照在 esrd 重启后丢失 | 有意为之：首次 reload 对所有 key diff，callback 全量重应用，行为正确 |
| **R4** `changed_keys` 为空（无实际变化的 force reload）| callback 仍触发（Q4 by design）；plugin 可用于重建连接等 |
| **R5** cap 粒度将来不够细 | 本 spec 范围外；需要时加 `plugin.reload` cap，仅改 command 模块权限检查 |

---

## §9 测试计划（摘要）

**单元测试（HR-1）**：Manifest 解析 4 个 case + ConfigSnapshot ETS 读写

**单元测试（HR-2）**：Reload command 7 个 case（见上）

**集成测试（HR-3）**：claude_code 3 个 case + feishu 3 个 case

**E2E 测试（rev-2 改为 MANDATORY）**：Scenario 17 — http_proxy 热重载端到端（见下 §9.5）

---

## §9.5 E2E Scenario 17（rev-2 新增）

### 验证目标

> "没 reload 之前 yaml-set 不影响 plugin 行为；reload 之后生效。"

### 5 步流程

| 步骤 | 操作 | 断言 |
|------|------|------|
| a | esrd 启动，`http_proxy` 为空；检查 mock proxy | request count = 0（流量没走 proxy）|
| b | `/plugin:set claude_code http_proxy=http://127.0.0.1:<port>` | yaml 写入；response `ok: true` |
| c | 再次检查 mock proxy | request count 仍 = 0（plugin 没 reload，仍用旧 config）|
| d | `/plugin:reload claude_code` | `"reloaded":true`，`changed_keys` 包含 `"http_proxy"` |
| e | `plugin_show_config layer=effective` | effective config 返回新 proxy URL（reload 已生效）|

### Mock Proxy 策略

**选型：Plug/Cowboy 本地 server（内联在 scenario 脚本里）**

不新建 `_helpers/` 文件——逻辑 <25 行，内联在 bash 脚本的 `mix run --eval` 字符串里。监听随机端口，ETS 记录所有入站请求，暴露 `GET /request_count`。

**选 Plug 而不用 HTTP client spy 的原因**：用户反馈是"走一次 e2e"——要证明实际网络路径变了，不是只证明 callback 被调用了。spy 只证后者。

### 文件

- `tests/e2e/scenarios/17_plugin_config_hot_reload.sh`（新建）
- `Makefile` — 新增 `e2e-17` target（及 `e2e-14/15/16` 补全）

---

## §10 交叉引用

- `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` §6 — 本 spec 所扩展的 plugin config 3 层设计
- `runtime/lib/esr/plugin/manifest.ex` — 当前 manifest 解析器
- `runtime/lib/esr/plugin/config.ex` — 3 层 config 解析器
- `runtime/lib/esr/commands/plugin/set.ex` — `/plugin:set`（本 spec 的模式参考，共用 cap）
- `runtime/priv/slash-routes.default.yaml` — slash 路由表
- VS Code `vscode.workspace.onDidChangeConfiguration` — trigger-only + no-rollback 设计灵感
