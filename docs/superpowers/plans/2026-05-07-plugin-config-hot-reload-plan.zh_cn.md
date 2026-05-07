# Plugin Config Hot-Reload 实施计划（中文版）

> **给 agentic worker 的说明：** 必须使用 `superpowers:subagent-driven-development` skill 逐 task 执行本计划。步骤用 checkbox（`- [ ]`）语法追踪。

**目标：** 实现 operator 触发的 plugin config 热重载，无需重启 esrd；通过 `/plugin:reload <plugin>` slash 命令 + 每个 plugin 的 manifest opt-in 控制。

**架构：** 触发式回调（VS Code 风格）；manifest `hot_reloadable: true` opt-in；`Esr.Plugin.Behaviour.on_config_change/1` 回调；尽力而为 + plugin 自管理 fallback，框架层不回滚；仅支持单 plugin（无 batch）。配置 snapshot 差异通过 ETS 追踪。

**技术栈：** Elixir/OTP；ETS backed config snapshot；YAML manifest 扩展；现有 slash routing 机制。

**Spec：** `docs/superpowers/specs/2026-05-07-plugin-config-hot-reload.md`（rev-1，用户已于 2026-05-07 确认）。

**执行顺序：** HR-1 → HR-2 → HR-3。严格依赖链：HR-2 需要 HR-1 的 `Behaviour` 和 `ConfigSnapshot`；HR-3 需要 HR-2 的 `/plugin:reload`。

---

## 文件结构总览

### 新建文件

| 文件 | Phase | 职责 |
|------|-------|------|
| `runtime/lib/esr/plugin/behaviour.ex` | HR-1 | `Esr.Plugin.Behaviour` — 定义 `on_config_change/1` 回调契约 |
| `runtime/lib/esr/plugin/config_snapshot.ex` | HR-1 | `Esr.Plugin.ConfigSnapshot` — ETS 存储每个 plugin 的"最后成功"配置快照 |
| `runtime/lib/esr/commands/plugin/reload.ex` | HR-2 | `Esr.Commands.Plugin.Reload` — `/plugin:reload` 命令实现 |
| `runtime/lib/esr/plugins/claude_code/plugin.ex` | HR-3 | `Esr.Plugins.ClaudeCode.Plugin` — claude_code opt-in，实现 `on_config_change/1` |
| `runtime/lib/esr/plugins/feishu/plugin.ex` | HR-3 | `Esr.Plugins.Feishu.Plugin` — feishu opt-in，实现 `on_config_change/1` |

### 修改文件

| 文件 | Phase | 变更内容 |
|------|-------|---------|
| `runtime/lib/esr/plugin/manifest.ex` | HR-1 | 添加 `hot_reloadable` 字段到 struct；扩展 `parse/1` 读取并验证该字段 |
| `runtime/lib/esr/plugin/loader.ex` | HR-1 | `start_plugin/2` 加载 plugin 后调用 `ConfigSnapshot.init/2`；暴露 `default_root/0` |
| `runtime/lib/esr/application.ex` | HR-1 | `load_enabled_plugins/0` 之前调用 `ConfigSnapshot.create_table/0` |
| `runtime/priv/slash-routes.default.yaml` | HR-2 | 新增 `/plugin:reload` 条目 |
| `runtime/lib/esr/plugins/claude_code/manifest.yaml` | HR-3 | 添加 `hot_reloadable: true` |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | HR-3 | 添加 `hot_reloadable: true` |
| `runtime/test/esr/plugin/manifest_test.exs` | HR-1 | 添加 `hot_reloadable` 测试用例 |

---

## Sub-phase HR-1：Behaviour + Manifest 解析扩展 + ConfigSnapshot

**前置条件：** 无。HR-1 可独立发布，无用户可见变更。

**估算规模：** ~100 LOC + ~80 LOC 测试，共 5 个 task。

---

### Task HR-1.1：创建 `Esr.Plugin.Behaviour`

**文件：** 新建 `runtime/lib/esr/plugin/behaviour.ex`

回调契约模块，只包含 `@callback` 声明。任何 manifest 中声明 `hot_reloadable: true` 的 plugin 必须实现此 behaviour。

```elixir
defmodule Esr.Plugin.Behaviour do
  @type changed_keys :: [String.t()]
  @type reason :: term()

  @callback on_config_change(changed_keys()) :: :ok | {:error, reason()}
end
```

步骤：
- [ ] 创建文件，写入完整模块代码（见英文版 Task HR-1.1 Step 1）
- [ ] `mix compile --force` 验证无编译错误
- [ ] `git commit`

---

### Task HR-1.2：`Esr.Plugin.Manifest` 扩展 `hot_reloadable` 字段

**文件：**
- 修改 `runtime/lib/esr/plugin/manifest.ex`
- 修改 `runtime/test/esr/plugin/manifest_test.exs`

Struct 新增 `hot_reloadable :: boolean()`（默认 `false`）。`parse/1` 读取该字段：

```elixir
defp parse_hot_reloadable(parsed) do
  case parsed["hot_reloadable"] do
    nil   -> {:ok, false}
    true  -> {:ok, true}
    false -> {:ok, false}
    other -> {:error, {:invalid_hot_reloadable, other}}
  end
end
```

测试用例：
- `hot_reloadable: true` → `manifest.hot_reloadable == true`
- `hot_reloadable: false` → `manifest.hot_reloadable == false`
- 字段缺失 → `manifest.hot_reloadable == false`（默认值）
- `hot_reloadable: "yes"`（字符串）→ `{:error, {:invalid_hot_reloadable, "yes"}}`
- `hot_reloadable: 1`（整数）→ `{:error, {:invalid_hot_reloadable, 1}}`

步骤：
- [ ] 在 manifest_test.exs 写入 5 个新测试
- [ ] `mix test test/esr/plugin/manifest_test.exs` 验证失败
- [ ] 修改 manifest.ex（defstruct + @type + parse_hot_reloadable/1 + parse/1 with 链）
- [ ] `mix test test/esr/plugin/manifest_test.exs` 验证全部通过
- [ ] `git commit`

---

### Task HR-1.3：创建 `Esr.Plugin.ConfigSnapshot`

**文件：**
- 新建 `runtime/lib/esr/plugin/config_snapshot.ex`
- 新建 `runtime/test/esr/plugin/config_snapshot_test.exs`

纯 ETS 封装，无 GenServer。ETS 表在应用启动时由 `create_table/0` 创建一次。

```elixir
defmodule Esr.Plugin.ConfigSnapshot do
  @table :esr_plugin_config_snapshots

  def create_table/0     # 创建 ETS 表，应用启动时调用一次
  def get/1              # 获取快照，不存在返回 %{}
  def init/2             # 存储初始快照（Loader 在 plugin 加载后调用）
  def update/1           # 重新 resolve 并替换快照（成功回调后调用）
  def update_with_path/2 # 带路径参数的 update（测试用）
end
```

测试：
- `get/1` 不存在 plugin → 返回 `%{}`
- `init/2` 后 `get/1` → 返回存储的 map
- `init/2` 两次同一 plugin → 后写覆盖前写
- 不同 plugin 的快照相互独立
- `update_with_path/2` 后 `get/1` → 返回当前 Config.resolve 结果

步骤：
- [ ] 写测试文件
- [ ] 验证测试失败（模块不存在）
- [ ] 创建 config_snapshot.ex 实现
- [ ] `mix test test/esr/plugin/config_snapshot_test.exs` 全部通过
- [ ] `git commit`

---

### Task HR-1.4：`Application` + `Loader` 接线

**文件：**
- 修改 `runtime/lib/esr/application.ex`（在 `load_enabled_plugins()` 前加 `ConfigSnapshot.create_table()`）
- 修改 `runtime/lib/esr/plugin/loader.ex`（`start_plugin/2` 成功后加 `ConfigSnapshot.init/2`；暴露 `default_root/0`）

步骤：
- [ ] 修改 application.ex
- [ ] 修改 loader.ex（添加 alias、修改 start_plugin/2、添加 default_root/0）
- [ ] `mix compile --force && mix test test/esr/plugin/` 全部通过
- [ ] `git commit`

---

### Task HR-1.5：开 PR + admin-merge

```bash
git push -u origin feat/hr-1-behaviour-manifest
gh pr create --base dev --head feat/hr-1-behaviour-manifest \
  --title "feat(hr-1): Esr.Plugin.Behaviour + manifest hot_reloadable + ConfigSnapshot"
gh pr merge --admin --squash --delete-branch
```

---

## Sub-phase HR-2：`/plugin:reload` Slash 命令

**前置条件：** HR-1 已合并。

**估算规模：** ~120 LOC + ~140 LOC 测试，共 3 个 task。

---

### Task HR-2.1：`Esr.Commands.Plugin.Reload` 模块

**文件：**
- 新建 `runtime/lib/esr/commands/plugin/reload.ex`
- 新建 `runtime/test/esr/commands/plugin/reload_test.exs`

6 步 `with` 执行链（完整代码见英文版 Task HR-2.1）：

1. `resolve_manifest/2` — 查找 plugin manifest（同 Plugin.Set）
2. `check_hot_reloadable/1` — 检查 `hot_reloadable: true` 标志
3. `resolve_module/1` — 名称约定推导模块（`claude_code` → `Esr.Plugins.ClaudeCode.Plugin`）
4. `check_callback_exported/2` — 验证 `on_config_change/1` 已导出
5. `compute_changed_keys/2` — diff 当前 config vs ConfigSnapshot
6. `invoke_callback/3` — `Task.async + Task.yield(5_000)` 超时保护

返回值约定：

| 场景 | `"reloaded"` | `"fallback_active"` |
|------|-------------|-------------------|
| 成功 | `true` | 不存在 |
| 回调返回 `{:error, _}` | `false` | `true` |
| 回调超时（5 s） | `false` | `true`，`"reason" => "callback_timeout"` |
| `not_hot_reloadable` | — | `{:error, %{"type" => ...}}` |
| `unknown_plugin` | — | `{:error, %{"type" => ...}}` |
| `callback_not_exported` | — | `{:error, %{"type" => ...}}` |

关键实现点：
- 回调错误时 **不调用** `ConfigSnapshot.update`（快照保持不变，下次重试时相同 changed_keys 再次出现，给 operator 自然的"重试路径"）
- 使用 `Task.async + Task.yield(5_000) || Task.shutdown(task)` 处理超时
- 回调中的异常通过 `safe_call/2` 捕获，返回 `{:error, {:callback_raised, msg}}`

测试用例（共 8 个，见英文版 Task HR-2.1 Step 1）：
- 未知 plugin
- `hot_reloadable: false`（用临时 manifest 文件）
- `callback_not_exported`（manifest 声明 true 但模块无回调）
- 成功路径（stub 返回 `:ok`）
- 空 changed_keys 强制 reload
- 回调返回 `{:error, _}` + 日志验证
- 快照不更新（回调错误时）
- 超时（`Process.sleep(10_000)` stub）

步骤：
- [ ] 写测试文件（含 5 个 stub 模块定义）
- [ ] 验证测试失败（模块不存在）
- [ ] 实现 reload.ex
- [ ] 在 loader.ex 添加 `def default_root, do: @default_root`
- [ ] `mix test test/esr/commands/plugin/reload_test.exs` 全部通过（超时测试约 5 秒）
- [ ] `git commit`

---

### Task HR-2.2：slash-routes.default.yaml 新增条目

**文件：**
- 修改 `runtime/priv/slash-routes.default.yaml`
- 修改 `runtime/test/esr/resource/slash_route/registry_test.exs`

在 `/plugin:list-config` 之后新增：

```yaml
  "/plugin:reload":
    kind: plugin_reload
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.Reload"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "触发指定 plugin 的 config reload（plugin manifest 必须 hot_reloadable: true；不传 plugin name = 报错，无 batch reload）"
    args:
      - { name: plugin, required: true }
```

测试验证 `kind == "plugin_reload"` + `permission == "plugin/manage"` + `command_module == "Esr.Commands.Plugin.Reload"`。

步骤：
- [ ] 在 registry_test.exs 添加测试
- [ ] 验证测试失败
- [ ] 修改 yaml 文件
- [ ] `mix test test/esr/resource/slash_route/registry_test.exs` 全部通过
- [ ] `git commit`

---

### Task HR-2.3：开 PR + admin-merge

```bash
git push -u origin feat/hr-2-reload-command
gh pr create --base dev --head feat/hr-2-reload-command \
  --title "feat(hr-2): /plugin:reload slash command + ConfigSnapshot wiring"
gh pr merge --admin --squash --delete-branch
```

---

## Sub-phase HR-3：claude_code + feishu Opt-In

**前置条件：** HR-1 + HR-2 已合并。

**估算规模：** ~80 LOC + ~80 LOC 测试 + 2 个 manifest 行变更，共 4 个 task。

---

### Task HR-3.1：claude_code — manifest opt-in + Plugin 模块

**文件：**
- 修改 `runtime/lib/esr/plugins/claude_code/manifest.yaml`（添加 `hot_reloadable: true`）
- 新建 `runtime/lib/esr/plugins/claude_code/plugin.ex`
- 新建 `runtime/test/esr/plugins/claude_code/plugin_test.exs`

`claude_code` 的所有配置 key 都是 spawn-time 值（在 session 启动时注入 PTY 环境）。回调行为：

- `anthropic_api_key_ref` 变更 → 记录 `[warning]`（运行中的 session 不受影响）；返回 `:ok`
- 其他所有 key（`http_proxy`、`https_proxy`、`no_proxy`、`esrd_url`）→ 新 session 自动使用新值；无需操作；返回 `:ok`

```elixir
@impl Esr.Plugin.Behaviour
def on_config_change(changed_keys) do
  if "anthropic_api_key_ref" in changed_keys do
    Logger.warning("claude_code plugin: anthropic_api_key_ref changed but running cc sessions " <>
      "are unaffected (key is injected at spawn time). Restart active sessions to apply.")
  end
  :ok
end
```

测试（7 个）：每个 key 单独测试，验证 `:ok` 返回值；`anthropic_api_key_ref` 验证日志包含关键词；空列表测试。

步骤：
- [ ] 写 plugin_test.exs
- [ ] 验证测试失败
- [ ] 创建 plugin.ex
- [ ] 修改 manifest.yaml（加 `hot_reloadable: true`）
- [ ] `mix test test/esr/plugins/claude_code/plugin_test.exs` 全部通过
- [ ] `git commit`

---

### Task HR-3.2：feishu — manifest opt-in + Plugin 模块

**文件：**
- 修改 `runtime/lib/esr/plugins/feishu/manifest.yaml`（添加 `hot_reloadable: true`）
- 新建 `runtime/lib/esr/plugins/feishu/plugin.ex`
- 新建 `runtime/test/esr/plugins/feishu/plugin_test.exs`

`feishu` 配置 key 行为：

- `app_id`、`app_secret` → `FeishuAppAdapter` 在每次 Lark API 调用时读取（非缓存），新值自动生效；无需 rebind；返回 `:ok`
- `log_level` → 传给 `feishu_adapter_runner` Python sidecar，sidecar 不支持热更日志级别；记录 `[warning]`；返回 `:ok`

```elixir
@impl Esr.Plugin.Behaviour
def on_config_change(changed_keys) do
  if "log_level" in changed_keys do
    Logger.warning("feishu plugin: log_level changed but the feishu_adapter_runner sidecar " <>
      "does not support live log-level changes. Restart the sidecar to apply.")
  end
  :ok
end
```

测试（5 个）：`app_id`、`app_secret` 无日志；`log_level` 有日志；`app_id + log_level` 组合；空列表。

步骤：
- [ ] 写 plugin_test.exs
- [ ] 验证测试失败
- [ ] 创建 plugin.ex
- [ ] 修改 manifest.yaml（加 `hot_reloadable: true`）
- [ ] `mix test test/esr/plugins/feishu/plugin_test.exs` 全部通过
- [ ] `git commit`

---

### Task HR-3.3：全套测试验证

```bash
cd runtime && mix test test/esr/plugin/ test/esr/commands/plugin/ test/esr/plugins/ test/esr/resource/slash_route/
cd runtime && mix test
```

Expected：全部通过，无新失败。

---

### Task HR-3.4：开 PR + admin-merge

```bash
git push -u origin feat/hr-3-cc-feishu-opt-in
gh pr create --base dev --head feat/hr-3-cc-feishu-opt-in \
  --title "feat(hr-3): claude_code + feishu hot-reload opt-in"
gh pr merge --admin --squash --delete-branch
```

---

## 锁定决策对照表（Q1–Q7）

| 决策 | 体现位置 |
|------|---------|
| Q1 显式 slash | HR-2.1 `Reload.execute/1` + HR-2.2 yaml 条目 |
| Q2 per-plugin opt-in | HR-1.2 manifest parser + HR-3.1/HR-3.2 manifest 变更 |
| Q3 回调契约 | HR-1.1 `Esr.Plugin.Behaviour` + HR-2.1 `check_callback_exported/2` |
| Q4 trigger-only | HR-2.1 `invoke_callback/3`（只传 changed_keys，不传 old/new config） |
| Q5 尽力而为，无框架回滚 | HR-2.1 `invoke_callback/3`（错误时不更新快照，不写回 yaml） |
| Q6 共享 `plugin/manage` cap | HR-2.2 yaml 条目 `permission: "plugin/manage"` |
| Q7 无 batch reload | HR-2.2 yaml `args: [{name: plugin, required: true}]` |

---

## 未来工作（spec §9 Risk 2）

本次 3 个 PR 不包含以下内容，已记录为 deferred：

- `Esr.Plugin.Status` ETS 存储 + `set_fallback/2` API（让 operator 查询 plugin 是否处于 fallback 状态）
- `/plugin:status` 命令（读取上述表）

临时缓解：`claude_code` 和 `feishu` 的 Plugin 模块在返回 `{:error, _}` 时记录 `[error]` 级日志，operator 可从 esrd 日志中看到。
