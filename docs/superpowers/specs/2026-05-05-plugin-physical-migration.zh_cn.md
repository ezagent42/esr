# 第三阶段 — Plugin 物理迁移（feishu + claude_code）

**日期：** 2026-05-05
**状态：** 草案，待用户评审。
**前序：** 第二阶段（`docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md`）确立了本阶段消费的 slash/CLI/REPL 契约。
**后继：** 第四阶段清理（`docs/superpowers/specs/2026-05-05-phase-4-cleanup.md`）删除 stub。

> **配套文件**：本文档的英文原版位于 `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`。

---

## 一、为什么需要这个阶段

PR-180（第一阶段，2026-05-04）已经搭好 plugin **机制**：Loader、Manifest 解析器、FragmentMerger、plugins.yaml 运行时配置、5 个 admin 命令、3 个 stub manifest（voice / feishu / claude_code）。Stub 只是**声明**模块和 python sidecar 的归属，模块本身仍在 `runtime/lib/esr/entity/` 和 `py/src/`。

第三阶段把模块**物理移动**。完成后：

- `runtime/lib/esr/plugins/feishu/` 包含全部 FAA / FCP / FAP Elixir 代码 + python `feishu_adapter_runner` + `agents.yaml` 片段 + slash routes。
- `runtime/lib/esr/plugins/claude_code/` 包含全部 CCProcess / CCProxy + python `cc_adapter_runner`（或其继任者，详见 §三 Channel 抽象）+ `agents.yaml` 片段。
- `Esr.Application.start/2` 中的 feishu / cc 特定 bootstrap 逻辑迁到 plugin 启动代码。
- core 不再引用 `Esr.Entity.FCP` / `Esr.Entity.CCProcess` 等名字 —— 这些名字只活在各自 plugin 目录里。

Voice 删除已经在第二阶段 PR-2.0 完成；voice 我们从未真正使用，盘点显示约 3000 LOC 死 Python 围绕它。第三阶段只处理 `feishu` 和 `claude_code`。

### 目标

1. `feishu` 和 `claude_code` 物理 extracted；core 在 `enabled_plugins: []` 时编译并 boot 干净。
2. `cc` agent 的 `agents.yaml` 定义不再硬编码 `feishu_chat_proxy` 在入站 pipeline 中。agent_def 是平台无关的；platform-specific 入站 proxy 在 session_new 时由 Scope.Router 注入，依据来源 chat 的平台。
3. `Esr.Entity.CCProcess` 不再硬编码字符串 `"feishu"`（今天：`Topology.adapter_uri("feishu", app_id)`）。adapter type 来自 `proxy_ctx`。
4. `cc_mcp` 与 `claude` / `tmux` 生命周期解耦 —— claude 崩溃时 cc_mcp 不再丢失 `cli:channel/<sid>` 订阅。（详见 `docs/issues/02-cc-mcp-decouple-from-claude.md`。）
5. **Channel 抽象**：per-session 的 core peer 拥有 esr-channel transport，BEAM 监督，独立于任何具体 MCP server 实现。Cc plugin 的 cc_mcp 变成 HTTP MCP server，通过 channel peer 分配的端口可寻址；未来 agent plugins (codex / gemini-cli) 复用同一 channel 机制。
6. core/plugin 边界审计 + 文档化：清晰列出"core 包含什么"（PtyProcess、Channel、Agent metamodel、SlashHandler 等）vs "plugin 包含什么"（platform adapters、agent-specific MCP servers、agent process pipelines）。

### 非目标

- 新 plugins（如 telegram、codex）—— 目标是干净迁移**现有**功能让加新 plugin 变简单，不是加新 plugin。
- 热加载（第二阶段 spec 的非目标依然成立）。
- 鉴权重构（第二阶段把现有模型沿用过来）。

---

## 二、第三阶段后的架构

### 模块布局

```
runtime/lib/esr/                 ← CORE（第三阶段后）
  application.ex                 ← 仍 boot；无 plugin 特定逻辑
  entity/
    server.ex                    ← Entity 原语
    stateful.ex                  ← Stateful behaviour
    pty_process.ex               ← 留 core（通用 PTY 机制）
    channel.ex                   ← 新增：per-session esr-channel peer（替代临时 subscribe）
    factory.ex
    registry.ex
    agent/registry.ex            ← agents.yaml metamodel registry
    user/...                     ← User Entity 子类型
    capguard.ex                  ← （现状；除非提取为 Resource，否则保留）
    slash_handler.ex             ← 单一 dispatch 入口（依第二阶段）
  scope/
    router.ex                    ← 增加 "platform proxy injection"（详见 §三）
    admin.ex
    process.ex
  resource/
    capability/
    permission/
    sidecar/registry.ex          ← 仍 core：plugins 通过 Loader 写入
    slash_route/
    chat_scope/
    workspace/
  plugin/
    loader.ex
    manifest.ex
    enabled_list.ex
    plugins_yaml.ex
  plugins/                       ← plugin 代码（第一阶段的 plugins/）
    feishu/
      manifest.yaml
      lib/
        app_adapter.ex           ← Esr.Plugins.Feishu.AppAdapter（曾叫 Esr.Entity.FeishuAppAdapter）
        chat_proxy.ex            ← Esr.Plugins.Feishu.ChatProxy
        app_proxy.ex             ← Esr.Plugins.Feishu.AppProxy
      priv/
        agents-fragment.yaml     ← cc-feishu 绑定：声明 feishu 为入站 proxy 类
        slash-routes-fragment.yaml ← 任何 feishu 特定 slash（目前没有，但接口在）
      python/
        feishu_adapter_runner/   ← （从 py/src/feishu_adapter_runner/ 迁移过来）
      test/
        ...
    claude_code/
      manifest.yaml
      lib/
        cc_process.ex            ← Esr.Plugins.ClaudeCode.CCProcess
        cc_proxy.ex
        cc_mcp_process.ex        ← 新增：BEAM 监督的 cc_mcp HTTP server（issue 02）
      priv/
        agents-fragment.yaml     ← cc agent_def（平台无关；入站 proxy 运行时注入）
      python/
        cc_adapter_runner/       ← （从 py/src/cc_adapter_runner/ 迁移过来）
        cc_mcp/                  ← （从 py/src/cc_mcp/ 迁移过来，现在是 HTTP 模式）
        esr-cc.sh                ← （从 runtime 侧 scripts/esr-cc.sh 迁移过来）
      test/
        ...
```

`Esr.Entity.FeishuAppAdapter` 重命名为 `Esr.Plugins.Feishu.AppAdapter` 等。git mv 保留历史；module 名更新是机械的。

### Channel 抽象

参见 `docs/issues/02-cc-mcp-decouple-from-claude.md`（截至 2026-05-05 仍 open）。当前模型 —— review 对照实际代码后澄清：

```
session = FCP + CCProcess + PtyProcess     ← 全部是 BEAM peer
                            ↓
                          claude binary
                            ↓
                          cc_mcp（Python，由 claude 通过 stdio MCP 派生）
                            ↓
                          通过 WebSocket 订阅 cli:channel/<sid>
                            (adapters/cc_mcp/src/esr_cc_mcp/ws_client.py)
```

订阅住在 **Python cc_mcp 的 WebSocket 客户端**里，**不在任何 BEAM peer**（review 修正了原先的 framing）。`Esr.Entity.CCProcess` 是 *broadcaster*；BEAM 侧没人订阅这个 topic（BEAM 中的 channel/server bridge 把 topic 转发出去经 WebSocket transport）。

所以当 tmux/claude 死掉时，cc_mcp 也死了，**cc_mcp 的 WebSocket 死了，BEAM 侧的 topic 仍存在但失去了唯一消费者** —— 之后每次 broadcast 命中空 topic，静默丢弃。

第三阶段后：

```
session（BEAM 监督的 peers）：
  + FCP / CCProxy / CCProcess / PtyProcess        ← 现有
  + Channel               ← 新增：per-session core peer；拥有 cli:channel/<sid> 订阅；
                            分配 HTTP 端口；把 notification 路由到 MCP server
  + CCMcpProcess          ← plugin 特定；HTTP MCP server (Python)，
                            由 OSProcess 派生；可重启；生命周期独立于 claude
                            
  esr-cc.sh 写 .mcp.json: { mcpServers: { "esr-channel": {type: "http", url: "http://127.0.0.1:<port>" } } }
                            ↓
  claude binary             ← 通过 HTTP 消费 MCP
                            ↓
  HTTP 请求                 → CCMcpProcess → 转发去/来自 Channel peer
```

`Esr.Entity.Channel` 是 **core**。它暴露：

- `notify(sid, envelope)` —— 把 notification 广播给当前绑定的任意 MCP server。
- `register_mcp_server(sid, port)` —— plugin 的 MCP server peer 注册其 HTTP 端口。
- `tool_invoke_callback(sid, fn)` —— plugin 的 MCP server 注册一个回调，用于接收来自 claude（或其他 agent backend）的入站 tool invoke。

Plugin 的 MCP server peer（如 cc plugin 的 `CCMcpProcess`）**只跟 Channel 通信**，不直接和 PubSub 交互。未来 plugins (codex_mcp / gemini_mcp) 实现同一形态 —— 它们从 BEAM 拿到端口，注册到自己 session 的 Channel peer，按其 agent backend 期望的格式暴露 MCP wire format。

这解耦了：
- BEAM 侧的 notification 路由（Channel）与 MCP wire format（per-plugin）。
- 订阅生命周期（Channel，BEAM 监督）与 agent process 生命周期（cc_mcp / claude / pty，plugin 或 OS 管理）。
- 多 agent type 支持：一个 Channel 实现，多个 MCP-server 实现。

### agents.yaml 解耦

今天：

```yaml
agents:
  cc:
    pipeline:
      inbound:
        - feishu_chat_proxy   ← 硬编码到 feishu
        - cc_proxy
        - cc_process
        - pty_process
```

第三阶段后：

```yaml
agents:
  cc:
    pipeline:
      inbound:
        - cc_proxy
        - cc_process
        - pty_process
    requires_platform_proxy: true   ← AgentSpawner 在 spawn 时 prepend 平台 proxy
```

#### 注入实际发生在哪里

Subagent review 抓到原草案把注入放到 `Esr.Scope.Router`，但 **Router 自 R6 之后不再组装 pipeline** —— `Esr.Session.AgentSpawner` 才是。具体：

1. `Esr.Entity.Agent.Registry.compile_agent/1`（`runtime/lib/esr/entity/agent/registry.ex:139`）解析 `agents.yaml`，今天忽略未知键。**PR-3.0 的 schema 增量**：解析 `requires_platform_proxy: true` 并暴露在编译后的 agent_def 上。
2. `Esr.Session.AgentSpawner.spawn_pipeline/3`（`agent_spawner.ex:289`）构建入站 pipeline。**PR-3.5 的 spawn 时逻辑增量**：当 `agent_def.requires_platform_proxy == true` 时，从 spawn `params[:source_platform]` 查平台（由 Scope.Router 从来源 chat envelope 串接），prepend 解析出的 proxy 模块。
3. Platform-proxy 查找走新 registry（详见下方"Platform-proxy registry 落点"）。

#### Platform-proxy registry 落点

原草案提议 `Esr.Resource.PlatformProxy.Registry`。Subagent review 抓到这不符合 True-Resource 准则（`docs/notes/structural-refactor-plan-r4-r11.md:34`：「被 ≥2 Entity types 消费」）。Platform-proxy lookup 只被 `Esr.Session.AgentSpawner` 消费 —— 一个 Pipeline 层级的协调者，不是 Entity type。

**更好的归属**：`Esr.Entity.Agent.PlatformProxyRegistry` —— 紧邻 `Esr.Entity.Agent.Registry`（agents.yaml registry）。同一个消费者（agent 编译/spawn 路径），同一个生命周期（boot 时从 plugin manifest 加载）。镜像 `Esr.Entity.User.Registry` 紧邻 user 相关概念的模式。

```elixir
Esr.Entity.Agent.PlatformProxyRegistry.register("feishu", Esr.Plugins.Feishu.ChatProxy)
Esr.Entity.Agent.PlatformProxyRegistry.lookup("feishu") # → Esr.Plugins.Feishu.ChatProxy
```

Plugin manifest 增加新的 `platform_proxies:` 声明。第一阶段的 `Esr.Plugin.Manifest.atomize_declares/1`（`runtime/lib/esr/plugin/manifest.ex:139`）接受任意 `declares:` 键，不需 parser 改动 —— 新键在解析侧真正零成本。

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  platform_proxies:
    - platform: feishu
      module: Esr.Plugins.Feishu.ChatProxy
```

Plugin Loader 的 `start_plugin/2`（第一阶段）增加 `register_platform_proxies/1` 步骤（镜像现有的 `register_python_sidecars/1` 和 `register_capabilities/2`）。

#### Silent-fail guard

Subagent review 抓到一个危险的现存 failure mode：`AgentSpawner.spawn_pipeline/3` 的 `resolve_impl/1` 用 `String.to_existing_atom/1`，miss 时返回 nil；`spawn_one` 然后"静默 swallow"（`agent_spawner.ex:447-453`）。引用了重命名模块的测试 fixture 或 operator yaml 编译通过、测试通过，生产则静默 spawn 空 pipeline。

**PR-3.2 缓解**：`resolve_impl/1` 在未知 impl 时 raise（或 log FATAL）。Pre-merge gate 加入对 fixture yaml 文件的 grep，断言每个 `impl:` 都解析为已知模块。CI gate 防止 silent-fail 在重命名阶段成为生产 bug。

### CCProcess 硬编码修复 —— 多模块手术，不是单点

Subagent review (2026-05-05) 抓到原草案对范围估错了。`cc_process.ex` 中**至少 4 处**硬编码 "feishu"：

1. **第 131 行**：`Topology.adapter_uri("feishu", app_id)` 在 `build_initial_reachable_set` —— adapter URI 硬编码。
2. **第 374 行**：`Keyword.get(state.neighbors, :feishu_chat_proxy)` —— neighbor key 硬编码；`dispatch_action(:reply)` 优先通过它路由。
3. **第 385 行**：warning 日志文本提到 `feishu_chat_proxy` —— 美观但反映设计假设。
4. **第 450 行**：`"source" => Map.get(ctx, "channel_adapter") || "feishu"` —— fallback 默认到 feishu。

加上 `cc_process.ex` 之外**至少 3 处**：
- `Esr.Scope.Router`（约 259 行）和 `Esr.Resource.ChatScope.Registry` 的 `refs` shape —— 都把 `feishu_chat_proxy` neighbor 名编码进 wire shape。
- `Esr.Session.AgentSpawner.backwire_neighbors`（`runtime/lib/esr/session/agent_spawner.ex:343-389`）按 `:feishu_chat_proxy` 这种字面 atom 名连线 neighbor。
- `EsrWeb.CliChannel`（319, 343, 394, 408 行）调 `bootstrap_feishu_app_adapters` / `terminate_feishu_app_adapter`。
- `Esr.Admin.Commands.Notify`（70 行）用 `"feishu_app_adapter_" <> app_id` registry key 前缀匹配。
- `Esr.Topology`（32 行）host 字符串匹配。

**修复表面是多模块的**，不局限于 CCProcess。正确的形态：

- 把 neighbor key `:feishu_chat_proxy` 替换为 **role-based key** `:platform_chat_proxy`（或在 neighbor list 上按 role 查找，类似今天的 `Keyword.get/2` 但作用于 spec 中存的 role tag）。
- `proxy_ctx` 增加 `adapter_type` 和 `platform` 字段，由 AgentSpawner 从 spawn 时 params 串接（params 通过 `params[:source_platform]` 携带 chat 来源）。
- CCProcess 用 `state.proxy_ctx.adapter_type` 喂给 `Topology.adapter_uri/2`，未提供时 fallback 到 `"unknown"`。
- Notify 和 CliChannel 调用方用通用 `"<platform>_app_adapter_" <> app_id` 模板 —— 但这些是 FAA 特定路径，仍归 feishu plugin（只是模块迁动时一并重命名）。
- PR-3.2 的 gate 加 audit grep `feishu_chat_proxy` / `feishu_app_adapter`，确保没有 silent 不匹配残留。

这个修复比单模块大得多。仍是单 PR (PR-3.2)，但 diff 涉及 5+ 文件 + 几个测试 fixture。

---

## 三、迁移顺序（PR 序列）

| PR | 范围 | 测试门 |
|---|---|---|
| **PR-3.0** | `Esr.Entity.Agent.PlatformProxyRegistry`（约 50 LOC）+ Loader 的 `register_platform_proxies/1` 步骤 + manifest schema 增加 `platform_proxies:`。无行为变化 —— registry 为空。 | registry register/lookup unit 测试 |
| **PR-3.1** | `Esr.Entity.Channel` core peer（约 150 LOC）。拥有 `cli:channel/<sid>` 订阅；暴露 `notify` / `register_mcp_server` / `tool_invoke_callback`。**没有 plugin 用它** —— 现有 cc_mcp 仍 stdio。 | Channel peer unit 测试 |
| **PR-3.2** | 修 `CCProcess` 多处硬编码 `"feishu"`（多模块 diff）。`proxy_ctx` 增加 `adapter_type` 字段从 Scope.Router 串接。加 silent-fail CI guard。 | scenario 01/07 仍绿；proxy_ctx 串接的新 unit 测试 |
| **PR-3.3** | 移 feishu Elixir 模块：`runtime/lib/esr/entity/feishu_*.ex` → `runtime/lib/esr/plugins/feishu/lib/`。模块名更新。Manifest 的 `entities:` 声明更新。Plugin 的 `priv/agents-fragment.yaml` 声明 feishu 为 `platform_proxies` 提供方。 | scenario 01/07 绿 |
| **PR-3.4** | 移 feishu Python：`py/src/feishu_adapter_runner/` → `runtime/lib/esr/plugins/feishu/python/feishu_adapter_runner/`。更新所有 sidecar registry 引用。 | sidecar 测试 + scenario 07 绿 |
| **PR-3.5** | 解耦 `agents.yaml`：cc agent 的 `inbound` 不再硬编码 `feishu_chat_proxy`。AgentSpawner 在 spawn 时从 registry 注入平台 proxy。 | scenario 01/07 绿 |
| **PR-3.6** | 移 cc Elixir：`runtime/lib/esr/entity/cc_*.ex` → `runtime/lib/esr/plugins/claude_code/lib/`。模块名更新。**review 后顺序换了** —— Elixir 移动**先于** HTTP cc_mcp，让 HTTP server 在最终命名空间出生。Diff geography 更干净。 | scenario 01/07 绿 |
| **PR-3.7** | 新建 `Esr.Plugins.ClaudeCode.CCMcpProcess`（BEAM 监督 OSProcess；HTTP MCP server）。cc_mcp Python 切到 HTTP transport。esr-cc.sh 写 `.mcp.json` 用 `type: "http"` + BEAM 分配的端口。**前置条件：开 PR-3.7 diff 之前必须先有 Issue 02 决定 pass（Q1 端口发布、Q3 HTTP transport 功能等价性尤其 streaming、Q4 鉴权 token）** —— 这些决定塑造接口。建议：在 `docs/issues/02-cc-mcp-decouple-from-claude.md` 落一个 1 页 ADR / decision note 解决 Q1, Q3, Q4，再开始 PR-3.7。 | scenario 07 + 新 e2e `tests/e2e/scenarios/12_cc_mcp_survives_claude_crash.sh` |
| **PR-3.8** | 移 cc Python：`py/src/cc_adapter_runner/`、`adapters/cc_mcp/` → `runtime/lib/esr/plugins/claude_code/python/`。esr-cc.sh 也移到 plugin。`agents.yaml` 的 `proxies:` 段（当前 `target: "admin::feishu_app_adapter_${app_id}"`）泛化为 `${platform}_app_adapter_${app_id}` 模板 —— 解决 `agent_spawner.ex:472` `build_ctx` for FeishuAppProxy 的 feishu 形态接缝。 | sidecar 测试 + scenario 07 绿 |
| **PR-3.9** | `Esr.Application.start/2` 清理：移除 feishu / cc fallback registration（第一阶段加它们作过渡辅助）。第三阶段后 plugin manifest 全权注册；fallback 已 vestigial。 | 完整 unit suite + scenario 01/07/08/11 |

PR 大体顺序。PR-3.0 / 3.1 / 3.2 独立可先 ship。feishu (3.3 + 3.4) 内部和 cc (3.6 + 3.7 + 3.8) 内部有强排序。

---

## 四、风险与缓解

### 模块重命名 blast radius

`Esr.Entity.FeishuAppAdapter` → `Esr.Plugins.Feishu.AppAdapter` 是机械的，但引用散落在多种文件类型。Subagent review 列了具体 touch list：

- **测试**：6+ integration 测试 `alias Esr.Entity.FeishuAppAdapter` / `FeishuChatProxy`（如 `runtime/test/esr/integration/cc_e2e_test.exs:116`、`feishu_react_lifecycle_test.exs:34-35`）。
- **Fixtures**：3 个 yaml 文件用 `impl:` 引用旧模块字符串 —— `runtime/test/esr/fixtures/agents/{simple,voice,multi_app}.yaml`。这些被 `String.to_existing_atom/1` atom 化 —— miss 静默返回 `nil`，`spawn_one` 静默跳过（`agent_spawner.ex:447-453`）。**没更新的 fixture 通过测试编译，生产静默 spawn 空 pipeline。**
- **文档**：`runtime/test/esr/fixtures/agents/README.md` 记录旧名。
- **跨命名空间调用方**：`runtime/lib/esr_web/cli_channel.ex:319,343,394,408` 调 `bootstrap_feishu_app_adapters` / `terminate_feishu_app_adapter`；`runtime/lib/esr/admin/commands/notify.ex:70` 用 `"feishu_app_adapter_" <> app_id` registry key 前缀匹配；`runtime/lib/esr/topology.ex:32` host 字符串匹配。

**缓解**：

1. 用 R1-R3 机械重命名（2026-05-04）的同一方法：每 PR 单一 rename、整 suite green。
2. 模块重命名是**命名空间层级** —— 在每个调用点用显式 `alias Esr.Plugins.Feishu.AppAdapter`，**不要** alias collapse（R3v1 "cascade" failure mode：过激 collapse 导致 118 测试断）。
3. **加 CI guard**（PR-3.2 起，PR-3.3、PR-3.7 重申）：grep 所有 `runtime/test/esr/fixtures/**.yaml` 中的 `impl:` 字符串，断言每个都用 `Code.ensure_loaded?` 解析到已知模块。fixture 引用了重命名但没更新的模块时 PR fail。关闭 silent-`nil`-impl 路径。

### CCMcpProcess HTTP transport 正确性

claude 的 MCP HTTP transport（`.mcp.json` 的 `type: "http"`）需要对 cc_mcp 的 tool 表面（reply、send_file、react 等）做兼容矩阵验证。大部分 MCP 特性 stdio/HTTP 等价，但 **streaming** 语义不同。PR-3.6 之前先做 smoke：起一个 no-op HTTP MCP server，让 claude 指向它，验证 tool invocation round-trip。某特性坏了就先做 per-feature 审计再继续。

### Operator-facing slash 命令

今天的 slash 命令（`/notify`、`/end-session` 等）可能落到 FCP 调 Esr.Entity.SlashHandler —— 这些路由会被模块重命名。第二阶段的 schema 驱动 dispatcher 吸收重命名：slash-routes.yaml 的 `command_module:` 字段拿到新名，operator slash 文本不变。

### .mcp.json 端口 lifecycle

`CCMcpProcess` 必须在 `esr-cc.sh` 跑之前发布 HTTP 端口（esr-cc.sh 写 claude 读的 `.mcp.json`）。竞争是真的：`CCMcpProcess.init/1` bind + 写端口到 `Esr.Entity.Registry`；`PtyProcess.os_env` 从 registry 读；但 `os_env` 在 `OSProcess.init/1` 内部调用，跟 `CCMcpProcess.init/1` 之间有自己的竞争。

缓解：`CCMcpProcess` 在 agent pipeline 声明顺序中**先于** `PtyProcess`。Agent 的 spawn_args wiring 保证声明顺序；`Entity.Factory.spawn_peer/5` 尊重它。加一个 integration 测试：起 session、dump `os_env`、断言 `ESR_CC_MCP_PORT` 存在并指向活端口。

### Auth-less localhost binding

cc_mcp HTTP server bind 127.0.0.1:<port>。同主机任何人都能打。今天的 stdio 模型有隐式 auth（claude 是唯一 stdio peer）。HTTP 需要共享 secret 或严格 localhost-only 检查。

缓解：per-session token 由 `CCMcpProcess.init/1` 生成，同时传给 claude（通过 .mcp.json `headers: {"X-Esr-Token": "<token>"}`）和 HTTP server（env var）。Server 拒绝没匹配 header 的请求。约 30 LOC；常见模式。

### 回滚计划

每个 PR 独立 `git revert`。PR-3.6 (HTTP MCP) 是唯一难局部回滚的 —— cc_mcp 的 stdio 路径被重写 —— 所以 PR-3.6 把 stdio 路径**注释保留**（不删除）直到 PR-3.9 清理。

---

## 五、不在本阶段范围

- 第二阶段交付物（slash/CLI/REPL 统一）—— 独立 spec。
- Plugin 热加载。
- 新 plugin 类型（telegram、codex 等）。
- 分发 / mix release 打包 —— 第四阶段清理。
- `docs/issues/02` 关于 session_ids.yaml 写侧的讨论（claude --resume）—— 与生命周期解耦正交，推迟。

---

## 六、待决问题

1. **`platform_proxy` 落点** —— `Esr.Entity.Agent.PlatformProxyRegistry` 已确认（review 后）。
2. **CCMcpProcess 端口分配策略** —— ephemeral（让 kernel 选，从 getsockname 获取）vs deterministic（hash session_id mod 10000+）。建议 ephemeral；更简单且避免冲突。
3. **`Esr.Entity.PtyProcess` 落点** —— **留 core**。审计确认：PtyProcess 被 `EsrWeb.PtySocket`（75、85 行）、`EsrWeb.DebugController.pty_send/2`、`Esr.Entity.FeishuChatProxy.boot_bridge`、`Esr.Entity.CCProcess` 和 `tools/esr-debug`（`esr-debug send-keys` operator 表面）消费。多消费者；作为通用机制满足 True-Resource 准则。
4. **Channel peer 命名** —— `Esr.Entity.Channel` 读起来太通用。备选：`Esr.Entity.AgentChannel`、`Esr.Entity.EsrChannel`、`Esr.Channel`。建议先用 `Esr.Entity.Channel`；metamodel 层的名字 OK，因为实现跨 agent plugin 通用。
5. **`bootstrap_voice_pools/1`** —— voice 删除是第二阶段 PR-2.0 的 scope。第三阶段 PR-3.9 只验证它没了，不重做。
