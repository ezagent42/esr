# PR-3.4 — feishu 插件启动钩子

**日期：** 2026-05-05
**状态：** 草稿（subagent review 待做；用户 review 待做）
**关闭：** Phase 3 PR-3.4（2026-05-05 自主跑推迟的）；
North Star "feishu 改动不触及 core" 最后一个漏洞。

## 目标

把 `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0`（当前定义在
`runtime/lib/esr/scope/admin.ex`，被 `runtime/lib/esr/application.ex:280`
调用）移进 feishu 插件，使得：

1. **新增 feishu 实例**到 `adapters.yaml` 不再需要任何 core 代码改动。
2. **移除 feishu 插件**（`plugins.yaml` 设 `enabled: []`）干净地禁用
   FAA peer 启动 —— 没有 bootstrap fallback 跑。
3. **未来某个 codex/gemini-cli 插件**有自己的"每实例启动 peer"逻辑，
   可以走同一个 plugin-startup 机制，不再发明并行机制。

## 非目标

- 插件关闭钩子（startup 的镜像）。等需要再做。
- 异步启动回调。同步够了（bootstrap 受 adapters.yaml 行数约束）。
- 插件之间的 startup 依赖图（超出 `enable order`）。今天插件顺序
  就是 `plugins.yaml` 里的列表；如果某个插件 startup 需要别的插件
  的状态再扩展。
- 可热加载插件（运行时启用 feishu 跑 startup；禁用跑 shutdown）。
  今天 enable/disable 需要重启；本 PR 不动这个。
- 删 `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` 本身。本 PR
  把它的调用改到新插件模块后，旧函数就死了；删除是本 PR diff 的
  一部分。

## 架构

### Manifest schema 加 `startup:` 字段

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  entities: [...]
  python_sidecars: [...]
  startup:
    - module: Esr.Plugins.Feishu.Bootstrap
      function: bootstrap
```

每条命名一个 0-arity 可调用对象。`function:` 省略时默认
`bootstrap`（约定：每个插件的 startup 模块都导出 `bootstrap/0`）。

### `Esr.Plugin.Loader` 加启动编排

两个新职责：

1. **`register_startup/1`** —— `start_plugin/2` 时解析 manifest 的
   `startup:` 条目，存到一个新的 ETS 表里（按插件名 key）。验证：
   - `module:` 经 `Code.ensure_loaded?/1`（Phase F 的 manifest 验证
     测试在 `mix test` 时抓到错配）
   - `function:` 通过 `function_exported?/3` 确认
     `module.function/0` 存在
   - 失败发警告并跳过；不让 boot 崩。

2. **`run_startup/0`** —— 在 `Esr.Application.start/2` 里所有插件
   `start_plugin/2` 都跑完之后调用。按 plugin-enable 顺序遍历 ETS
   表挨个调用。每个回调成功/失败都 log；一个插件 startup 失败不阻
   止下一个。

### `Esr.Application.start/2` 内部顺序

当前序列（只列相关行）：

```elixir
# 226-240 — 注册核心 stateful peer + 跑插件 Loader
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()
# 260-272 — 恢复 yaml-on-disk 状态
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
# 280 — feishu adapter bootstrap（本 PR 要移走的那行）
_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()
```

新序列：

```elixir
:ok = Esr.Entity.Agent.StatefulRegistry.register(Esr.Entity.PtyProcess)
load_enabled_plugins()
load_workspaces_from_disk(...)
load_agents_from_disk()
restore_adapters_from_disk(...)
# 插件启动回调在 yaml-on-disk 状态恢复 ***之后***跑。
# `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` 读 adapters.yaml 起 FAA
# peer —— 函数体跟旧的一模一样。
Esr.Plugin.Loader.run_startup()
```

钩子在 `restore_adapters_from_disk/1` 之后跑，因为 feishu bootstrap
读刚加载的 adapters 表。

### `Esr.Plugins.Feishu.Bootstrap`

新模块，`runtime/lib/esr/plugins/feishu/bootstrap.ex`。函数体就是
`bootstrap_feishu_app_adapters/0` 的代码，私有 `spawn_feishu_app_adapter/3`
helper 同位置。模块沿插件模块约定（住 `runtime/lib/esr/plugins/feishu/`，
core 不编译期 alias 它）。

### `Esr.Scope.Admin` 清理

本 PR 之后：

- `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` 删除。
- `Esr.Scope.Admin.terminate_feishu_app_adapter/1` **保留** —— `/end-session`
  cleanup 路径用，不是 boot 用。重命名/搬这个是另一回事（可以 Phase D-3）。
- `Esr.Scope.Admin.spawn_feishu_app_adapter/3`（私有 helper）跟着公有
  函数搬到 `Esr.Plugins.Feishu.Bootstrap`。

`Esr.Application.start/2` 第 280 行删除。274-279 的注释块剪掉，指向
新插件位置。

## 失败模式

| 时机 | 行为 |
|---|---|
| 插件 manifest 的 startup `module:` load 不出来 | 警告日志；那个插件的 startup 跳过；其他插件继续。|
| 启动回调抛异常 | 带 stacktrace 的日志；esrd boot 退化继续。跟当前 `bootstrap_feishu_app_adapters/0` 的"全吞"一致。|
| 多个插件有 startup 钩子 | 按 `plugins.yaml` 的 `enabled_plugins` 顺序顺序跑，不并行。|
| `adapters.yaml` 损坏 | `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` 警告日志；不起 FAA peer。跟当前一致。|

## 测试策略

| 层 | 测试 | 断言什么 |
|---|---|---|
| Unit | `Esr.Plugin.LoaderTest.register_startup` | manifest 的 startup 条目存住、可取回。|
| Unit | `Esr.Plugin.LoaderTest.run_startup` | 回调按 `enabled_plugins` 顺序跑；失败不级联。|
| Integration | `Esr.Plugins.Feishu.BootstrapTest` | bootstrap/0 + fixture adapters.yaml 起出正确的 FAA peer。|
| **不变量（新）** | `Esr.Plugins.IsolationTest`（新） | grep `runtime/lib/esr/{application,scope,entity,resource}.ex*` 找 `feishu`/`Feishu` —— 必须为空（或白名单合理的注释引用）。**今天会红，转绿就是 "PR-3.4 done" 的定义。** |
| Manifest 验证 | Phase F 的测试（已发） | 新 startup 条目的模块可 load。|

不变量测试是按 2026-05-05 "completion claim requires invariant test"
memory rule 的不可妥协的完成 gate。没有它，"PR-3.4 done" 又退化成
"PR 合了 + 测试过了" —— 就是触发这次 Phase 3/4 收尾的那个虚假完成
模式。

## 范围外的后续

- **插件 shutdown 钩子** —— 哪天 per-session cleanup 需要 per-plugin
  `shutdown/0` 对称时，照 startup 机制镜像出 `shutdown:` manifest 字段。
- **Startup 钩子拓扑排序** —— 今天插件顺序就是普通列表。如果某插件
  必须等另一个先 startup，加 `depends_on_startup:` 到 manifest 拓扑排。
- **`terminate_feishu_app_adapter/1` 移动** —— 同一个插件隔离论点，
  但走不同代码路径（`/end-session`）；单独 PR（D-3 或之后）。

## 回滚方案

如果 startup-hook 机制顺序/时机出错，回滚：

1. 恢复 `Esr.Application.start/2` 里删的
   `_ = Esr.Scope.Admin.bootstrap_feishu_app_adapters()` 调用。
2. 恢复删的 `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` 函数
   （从 `Esr.Plugins.Feishu.Bootstrap` 反向 import）。
3. manifest `startup:` 条目留着 —— `Esr.Plugin.Loader.run_startup/0`
   也回滚的话它就是 no-op。
4. 插件 Loader 改动留下（加性的 —— 注册 startup 条目却没人调，无害）。

这是个可逆改动。Phase D-1 的 "Loader is canonical" 声称不受回滚影响
（只是 feishu bootstrap 的 post-Loader 时机变了）。

## 预估 diff 大小

- `runtime/lib/esr/plugins/feishu/manifest.yaml`: +5 LOC (`startup:` 块)
- `runtime/lib/esr/plugins/feishu/bootstrap.ex`（新）: ~80 LOC（逐行复制）
- `runtime/lib/esr/plugin/loader.ex`: +60 LOC (`register_startup/1` + `run_startup/0`)
- `runtime/lib/esr/scope/admin.ex`: -45 LOC (删 `bootstrap_feishu_app_adapters/0` + `spawn_feishu_app_adapter/3`)
- `runtime/lib/esr/application.ex`: -2 LOC（删调用 + 1 行注释）
- `runtime/test/esr/plugin/loader_test.exs`: +50 LOC（新测试）
- `runtime/test/esr/plugins/feishu/bootstrap_test.exs`（新）: ~80 LOC
- `runtime/test/esr/plugins/isolation_test.exs`（新 —— 不变量）: ~40 LOC

**净：~+270 LOC，-50 LOC = ~+220 LOC。** 比一般 PR 大些，因为同时加
基础设施（插件 Loader startup）+ 不变量测试。

## 用户 review 时的开放问题

1. **manifest 省略 `function:` 时是否默认 `bootstrap`？**（spec 假设是。）
2. **Startup 失败日志 `:warning`（当前）还是 `:error`**（操作员 tail 时
   更显眼）？
3. **插件隔离不变量测试是否允许注释里出现 `Feishu` / `feishu`**
   （core 当前 145+ 处匹配，多数是文档）？还是只看代码？spec 提"只
   看代码"用注释剥离正则。可能脆。
4. **`Esr.Plugins.IsolationTest` 是否白名单 `Esr.Entity.FeishuAppProxy`**
   （`interface/boundary.ex` 的示例还引用）？还是把那些引用也删了？
   （估计先白名单；boundary spec 重写时再消除。）
