# PR-3.4 — feishu 插件启动钩子

**日期：** 2026-05-05
**状态：** Rev 3（按用户反馈，删除 workaround / 白名单 / 默认值 / warn-and-degrade）
**关闭：** Phase 3 PR-3.4；North Star "feishu 改动不触及 core" 最后一个漏洞。

## 目标

把 `Esr.Application.start/2:278` 调用 `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0`
这一行的 boot-time bootstrap 移进 feishu 插件本身。本 PR 之后：

1. **新增 feishu 实例**到 `adapters.yaml` 不动 `runtime/lib/esr/{application,
   scope,entity,resource}/` 下任何文件。
2. **禁用 feishu 插件**（`plugins.yaml` 设 `enabled: []`）= feishu
   的 startup callback 不跑 — core 没有 fallback 路径偷偷起 FAA peer。
3. **未来某个 codex/gemini-cli 插件**走同一个 plugin-startup 机制，
   不需要发明并行逻辑。

## 非目标

- 插件 shutdown 钩子。等需要再加。
- Per-instance 生命周期回调（`cli:adapters/rename` 用的 terminate-old
  + spawn-new）。范围外；rev 3 让 rename dispatch 留在 cli_channel.ex
  里直接调新插件模块。
- 可热加载插件。今天 enable/disable 需要重启；本 PR 不动这个。

## 架构

### 插件 manifest 加 `startup:` 字段

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  entities: [...]
  python_sidecars: [...]
  startup:
    module: Esr.Plugins.Feishu.Bootstrap
    function: bootstrap
```

**必需字段**：`module:` 和 `function:`。**没有默认值** — manifest 缺
任一字段，`Esr.Plugin.Loader.start_plugin/2` 直接 raise。让 boot 大
声崩，typo 立即暴露。

shape 是单 map（`startup: %{module:, function:}`），不是列表。一个
插件多个 bootstrap 关注点就包到一个顶层函数里 — 保持 manifest
schema 简单。后期升级到 list 是非 breaking change。

### `Esr.Plugin.Loader` 加 startup 编排

两个新职责，全是普通模块函数（Loader 没 GenServer）：

1. **`register_startup/1`** — `start_plugin/2` 注册完 entities/sidecars
   后调。读 manifest 的 `startup:` 块，验证 `Code.ensure_loaded?(module)`
   和 `function_exported?(module, function, 0)`。**任一失败 raise** —
   带清晰错误信息（插件名 + 缺哪个）。校验通过才把
   `{plugin_name, module, function}` 推到 `:persistent_term` 列表
   （key `{__MODULE__, :startup_callbacks}`）。

2. **`run_startup/0`** — `Esr.Application.start/2` 在
   `restore_adapters_from_disk/1` 返回之后调一次。读
   `:persistent_term` 列表，按 plugin-enable 顺序调每个
   `module.function.()`。**没 try/rescue。** startup callback raise
   就传上去把 esrd boot 崩掉。用户明确要 let-it-crash；warn-and-
   degrade 会埋事故（PR-K/L 那次 bootstrap-miss → 静默丢帧的模式
   就是这一类）。

`:persistent_term` 是合适的存储：写只有 boot 时（GC 摊销没事），读
是 O(1)，不走 GenServer 序列化。Loader 是纯模块函数没现成 owner
process，为这点存储引入一个 GenServer 比 storage 本身重。

### `Esr.Application.start/2` 顺序

```elixir
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()                  # 注册 entities + sidecars + startup callbacks
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
Esr.Plugin.Loader.run_startup()         # 新 — 替换下面那行
# 删除：_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

Boot-time 调用（278 行）**直接删除**。Loader 的 `run_startup/0`
通用地替代它。

### `Esr.Plugins.Feishu.Bootstrap`（新模块）

```elixir
# runtime/lib/esr/plugins/feishu/bootstrap.ex
defmodule Esr.Plugins.Feishu.Bootstrap do
  @moduledoc """
  按 `adapters.yaml` 里的 `type: feishu` 实例每个起一个
  `Esr.Entity.FeishuAppAdapter` peer。boot 时被
  `Esr.Plugin.Loader.run_startup/0` 调；运行时被
  `cli:adapters/{refresh,rename}` 在 adapter CRUD 时调。
  """

  @spec bootstrap() :: :ok
  def bootstrap, do: bootstrap(Esr.Paths.adapters_yaml())

  @spec bootstrap(Path.t()) :: :ok
  def bootstrap(adapters_yaml_path) do
    # 函数体从旧 Scope.Admin 直接 lift 过来
    ...
  end

  defp spawn_feishu_app_adapter(sup, instance_id, app_id) do
    # 私有 helper，也 lift 过来
    ...
  end
end
```

### `Esr.Scope.Admin` 清理

本 PR 之后：

- **`bootstrap_feishu_app_adapters/0` 和 `/1` 整体删除。** 没 shim，
  没 deprecated wrapper。函数搬到 `Esr.Plugins.Feishu.Bootstrap.bootstrap/0|1`
  函数体不变。
- **`spawn_feishu_app_adapter/3` 删除。** 跟公有函数一起搬。
- **`terminate_feishu_app_adapter/1` 留下。** `/end-session` cleanup
  路径用；搬它是另一回事（per-instance 生命周期，范围外）。

### `cli_channel.ex` 调用方更新

`runtime/lib/esr_web/cli_channel.ex` 两处调用从：

```elixir
_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

改成：

```elixir
_ = Esr.Plugins.Feishu.Bootstrap.bootstrap()
```

这是 cli_channel 到 feishu 插件的**直接跨层调用**。是的，这意味
`cli_channel.ex` 按名字引用插件模块。**插件隔离不变量测试故意
不针对 `cli_channel.ex` 做隔离断言** — 见下文"不变量测试 scope"。

## 不变量测试 scope

新测试 `Esr.Plugins.IsolationTest` 断言：

> `runtime/lib/esr/{application,scope,entity,resource}/` 下任何文件都
> 不引用 `Esr.Plugins.Feishu.*`，也不引用
> `Esr.Scope.Admin.bootstrap_feishu_app_adapters`。

**Scope 是 runtime boot 路径 + per-session state 目录，不是整个 codebase。**
测试**不**检查：

- `runtime/lib/esr_web/` — Phoenix transport 层。cli_channel.ex 调
  `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` 是 transport-layer dispatch，
  不是 runtime-boot 依赖。
- `runtime/lib/esr/interface/` — 接口契约。`@moduledoc` 里提到
  `Esr.Entity.FeishuAppAdapter` 是文档，不是代码依赖。
- `runtime/lib/esr/cli/` — escript CLI 源码。指向插件命令模块的
  引用是 CLI dispatch surface 的一部分。

**没白名单，没例外列表。** scope 故意窄。PR-3.4 的架构目标就是"runtime
boot 路径与插件解耦" — 测试就断言这一条，仅此而已。

如果未来某个 PR 想让 `cli_channel.ex` 也跟插件解耦，那是单独的
spec（Phase D-3 候选）。届时该测试新增 scoped 断言，不是加白名单。

## 失败模式

| 时机 | 行为 |
|---|---|
| manifest 的 startup `module:` 不能 load | `register_startup/1` raise，消息 `"plugin <name>: startup module #{inspect(module)} not loadable"`。esrd boot 崩。|
| manifest 的 startup `function:` 没导出 | 同上 — 带明确消息 raise。|
| `run_startup/0` 中 startup callback raise | 传上去。esrd boot 带 stacktrace 崩。|
| 多个插件 startup 有不相关失败 | 第一个失败胜出；后续不跑。运维查根因再重启。|
| `adapters.yaml` 损坏 | `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` raise（或文件不存在返回 `:ok` — 看现有语义，本 PR 不变行为）。|

**没 `try/rescue`。没 `:warning` log + continue。** startup 失败运
维直接看到大声崩出来的真错误。

## 测试策略

| 层 | 测试 | 断言什么 |
|---|---|---|
| Unit | `Esr.Plugin.LoaderTest.register_startup` | 合法 manifest 存住 `{plugin, module, function}`。缺 `module:` raise。缺 `function:` raise。模块未 load raise。|
| Unit | `Esr.Plugin.LoaderTest.run_startup` | callback 按 `enabled_plugins` 顺序调。raise 的 callback 传上去（不 rescue）。|
| Integration | `Esr.Plugins.Feishu.BootstrapTest` | `bootstrap/1` + fixture `adapters.yaml` 起出正确 FAA peer（旧测试 `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs` 逐字搬过来，仅改模块路径）。|
| 不变量 | `Esr.Plugins.IsolationTest`（新） | scoped grep — 见"不变量测试 scope"。**今天会红，转绿就是 "PR-3.4 done" 的定义。** |
| Manifest 验证 | Phase F 已发的测试 | `startup:` 的 module + function 可 load + exported。沿 `entities:` 验证模式即可。|

## diff 大小预估

- `runtime/lib/esr/plugins/feishu/manifest.yaml`: **+4 LOC**（`startup:` 块）
- `runtime/lib/esr/plugins/feishu/bootstrap.ex`（新）: **+80 LOC**（逐字 lift）
- `runtime/lib/esr/plugin/loader.ex`: **+50 LOC**（`register_startup/1` + `run_startup/0`）
- `runtime/lib/esr/plugin/manifest.ex`: **+10 LOC**（解析 `startup:` + 验证必需字段）
- `runtime/lib/esr/scope/admin.ex`: **−45 LOC**（删 `bootstrap_feishu_app_adapters/0|1` + `spawn_feishu_app_adapter/3`）
- `runtime/lib/esr/application.ex`: **−2 LOC**（删调用 + 注释）
- `runtime/lib/esr_web/cli_channel.ex`: **±0**（重命名调用；行数不变）
- `runtime/test/esr/plugin/loader_test.exs`: **+50 LOC**（新测试）
- `runtime/test/esr/scope_admin_bootstrap_feishu_test.exs`: **删除**（−110 LOC）；替换为：
- `runtime/test/esr/plugins/feishu/bootstrap_test.exs`（新）: **+110 LOC**（逐字搬，仅改模块路径）
- `runtime/test/esr/plugins/isolation_test.exs`（新）: **+40 LOC**

**净：~+200 LOC，~−155 LOC = ~+45 LOC。** 比 rev 2 的 ~+220 小，
因为 shim + 白名单 + 默认值 的复杂度都没了。

## 回滚

可逆：本 PR 的 commit 干净 revert，因为没有 shim 或 compat 层留下。
如果 `run_startup/0` 顺序错了或 `:persistent_term` 表现不如预期：

1. revert 本 PR。
2. 删的 `bootstrap_feishu_app_adapters/0|1` 和 `spawn_feishu_app_adapter/3`
   回来。
3. `Esr.Application.start/2` 里的
   `_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()` 那行回来。
4. cli_channel.ex 调用回退到 Scope.Admin 形式。
5. 新 feishu 模块 + tests + Loader 变更全没。

Phase D-1 的 "Loader is canonical for entity registration" 声称不
受影响 — 只是 post-Loader bootstrap 机制回退了。

## 解决了的设计问题

rev 1/2 留的开放问题，rev 3 取 let-it-crash 立场：

- **`function:` 没默认值。** 必需字段。manifest typo → boot 崩，
  错误清晰。
- **Startup 失败 raise**，不是 `:warning`+continue。
- **不变量测试没白名单。** scope 故意窄（仅 runtime boot 目录）；
  cli_channel.ex 是另一回事，明确不在测试 scope 内。
- **`Esr.Scope.Admin` 没 shim。** 函数直接删；调用方迁到插件模块。
  `cli_channel.ex` 两处（3 LOC 的改动）+ 单元测试（文件搬 + 模块
  路径改名）。
