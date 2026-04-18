# esrd — ESR 协议 v0.3 参考实现

**版本**: 0.3 (Final)
**实现**: ESR 协议 v0.3
**语言**: Elixir/OTP (核心) + Python (handler)
**范围**: 组织内部 agent runtime 和 Socialware 宿主

---

## 0. 定位

esrd 是 ESR 协议 v0.3 的第一个参考实现。它扮演两种角色:

**角色 1**: 作为 **ESR runtime**, esrd 实现协议的契约层——contract 声明、topology 组合、验证、治理

**角色 2**: 作为 **Socialware 宿主**, esrd 提供已安装 Socialware 包执行的 runtime 环境

这两个角色互补。ESR 是治理框架; Socialware 是能力单位; esrd 是让两者可操作的东西。

### 0.1 一个组织, 一个 esrd

关键架构承诺: **一个 esrd 实例代表一个组织**。实例可以跨多台物理机器 (使用 BEAM distributed), 但逻辑上它是一个组织的信任边界。

esrd 显式地不跨组织联邦。跨组织集成在 Socialware 层通过外部接口进行 (在 Socialware Packaging Specification 中描述), 不在 esrd 层。

### 0.2 esrd 提供什么 vs 它依赖什么

| 关注点 | 由谁处理 |
|---------|-----------|
| Agent 调度、生命周期 | OTP (GenServer, Supervisor) |
| 内部消息传递 | Phoenix.PubSub |
| 多节点集群 | BEAM distributed + libcluster |
| 失败恢复 | OTP 监督策略 |
| 外部客户端连接 | Phoenix Channels over WebSocket |
| **Contract 声明** | **esrd_contract (ESR 特有)** |
| **Topology 组合** | **esrd_topology (ESR 特有)** |
| **验证** | **esrd_verifier (ESR 特有)** |
| **治理工作流** | **esrd_governance (ESR 特有)** |
| **Socialware 托管** | **esrd_socialware (ESR 特有)** |
| 业务逻辑 | Socialware 中的 Python handler |
| 外部 API 集成 | Socialware 中的 Python handler |

分工清晰: esrd 复用 OTP 做所有 runtime 相关事, 只实现 ESR 独特提供的 (契约层 + Socialware 托管)。

---

## 1. 架构

```
┌────────────────────────────────────────────────────────────────┐
│ esrd (单个组织的 runtime)                                         │
│                                                                  │
│  多节点 BEAM 集群 (组织内部分布):                                    │
│   node-1 ↔ node-2 ↔ node-3 (via libcluster + BEAM distributed)  │
│                                                                  │
│  每个节点运行这些 OTP application:                                  │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_runtime                                       │          │
│  │  - PeerServer (每个 agent 一个 GenServer)          │          │
│  │  - PeerRegistry (Registry + Horde 用于集群)        │          │
│  │  - PubSub 用于 actor 消息                          │          │
│  │  - DeliveryManager (定向 at-least-once)           │          │
│  │  - DeadLetterChannel                               │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_contract                                      │          │
│  │  - YAML 解析器                                     │          │
│  │  - Contract registry (ETS)                        │          │
│  │  - 运行时契约强制                                    │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_topology                                      │          │
│  │  - YAML 解析器                                     │          │
│  │  - Topology registry                              │          │
│  │  - 激活/停用逻辑                                    │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_verifier                                      │          │
│  │  - 静态验证                                         │          │
│  │  - 基于 trace 的动态验证                             │          │
│  │  - 违反报告生成                                      │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_governance                                    │          │
│  │  - 提议存储和跟踪                                    │          │
│  │  - 影响分析                                         │          │
│  │  - 版本管理                                         │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_socialware                                    │          │
│  │  - Socialware 包安装器                              │          │
│  │  - Manifest 解析器                                 │          │
│  │  - Handler 进程监督者 (Python OS 进程)              │          │
│  │  - 外部接口 registry                                │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_web (Phoenix application)                     │          │
│  │  - Python handler 的 WebSocket 端点                │          │
│  │  - 带契约强制的 Phoenix Channels                     │          │
│  │  - JWT 认证                                        │          │
│  │  - 外部暴露端点 (用于远程调用)                         │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_cli (Elixir escript)                         │          │
│  │  - 低层协议操作                                      │          │
│  │  - 大多数用户更喜欢 `esr` (Python CLI, 上层)         │          │
│  └──────────────────────────────────────────────────┘          │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ WebSocket (Phoenix Channels)
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Python handler 进程 (每个 Socialware 的, 由 esrd 监督)            │
│                                                                  │
│  每个 handler 使用 esr-handler-py SDK:                           │
│  - 连接到 esrd_web                                              │
│  - 代表一个或多个 agent 执行                                       │
│  - 业务逻辑、LLM 调用、外部 API 集成                                │
└────────────────────────────────────────────────────────────────┘
```

### 1.1 OTP 监督树

```
Esrd.Application
├── Esrd.Runtime.Supervisor
│   ├── Esrd.PeerRegistry
│   ├── Esrd.PeerSupervisor (DynamicSupervisor)
│   │    └── Esrd.PeerServer (每个 agent 一个)
│   ├── Esrd.DeliveryManager
│   └── Esrd.DeadLetterChannel
├── Esrd.Contract.Supervisor
│   └── Esrd.Contract.Registry
├── Esrd.Topology.Supervisor
│   └── Esrd.Topology.Registry
├── Esrd.Verifier.Supervisor
├── Esrd.Governance.Supervisor
│   └── Esrd.Governance.ProposalStore
├── Esrd.Socialware.Supervisor
│   └── Esrd.Socialware.HandlerSupervisor (DynamicSupervisor)
│        └── Esrd.Socialware.HandlerProcess (OS 进程包装)
├── EsrdWeb.Endpoint (Phoenix)
└── Cluster.Supervisor (libcluster)
```

### 1.2 为什么这个结构

每个关注点是一个 OTP application。这遵循 OTP 最佳实践, 让每个关注点可独立测试、升级、推理。底部的 `esrd_runtime` 提供 actor 机制; 上层 application 提供 ESR 特有的治理; `esrd_socialware` 通过托管使用两者的 Socialware 包把它们连起来。

---

## 2. Contract 实现

### 2.1 存储

Contract 是 YAML 文件。加载时, 它们被解析为 Elixir 结构并存储在 ETS 中供快速查找:

```elixir
defmodule Esrd.Contract do
  defstruct [
    :schema_version,
    :identity,
    :incoming,
    :outgoing,
    :targeting,
    :forbidden,
    :state,
    :failure_disposition,
    :version
  ]
end

defmodule Esrd.Contract.Registry do
  @moduledoc "ETS 支持的契约存储, 带模式匹配"
  
  def load(contract_yaml_path), do: ...
  def lookup_for(agent_id), do: ...
  def list_all(), do: ...
  def remove(contract_id), do: ...
end
```

### 2.2 运行时强制

通过 esrd_runtime 的每次 `publish` 调用都会对照 agent 的契约检查:

```elixir
defmodule Esrd.PeerServer do
  use GenServer
  
  def handle_call({:publish, message}, _from, state) do
    contract = Esrd.Contract.Registry.lookup_for(state.agent_id)
    
    case Esrd.Contract.check_publish(contract, message) do
      :ok ->
        do_publish_internally(message, state)
      {:violation, reason} ->
        :telemetry.execute([:esrd, :contract, :violation], 
                           %{count: 1}, 
                           %{agent: state.agent_id, reason: reason})
        {:reply, {:error, {:contract_violation, reason}}, state}
    end
  end
end
```

违反被立即拒绝并发射 telemetry 事件供 verifier 消费。

### 2.3 模式匹配

Contract 的 `id_pattern` 默认使用 glob 风格匹配:

- `cc:*` 匹配 `cc:allen-main`, `cc:alice`, `cc:anything`
- `feishu:app1:*` 匹配 `feishu:app1:user_a`, `feishu:app1:user_b`
- `journal` 只匹配 `journal`

更复杂的匹配 (正则、中间通配符等) 可用, 但**应**谨慎使用以保持契约可读。

---

## 3. Topology 实现

### 3.1 存储和生命周期

Topology 是 YAML 文件, 解析为结构。它们在 registry 中跟踪显式生命周期状态:

```elixir
defmodule Esrd.Topology do
  defstruct [
    :name, :description, :trigger,
    :participants, :flows, :branches,
    :acceptance_criteria, :contract_dependencies,
    :version, :state  # :defined, :valid, :active, :retired
  ]
end

defmodule Esrd.Topology.Registry do
  def load(path), do: ...            # file → :defined
  def validate(topology_id), do: ... # :defined → :valid 或错误
  def activate(topology_id), do: ... # :valid → :active
  def retire(topology_id), do: ...   # 任何 → :retired
  def list_active(), do: ...
end
```

### 3.2 验证

验证是 `(topology, [contracts])` 上的纯函数:

```elixir
defmodule Esrd.Topology.Validator do
  def validate(topology, contracts) do
    with :ok <- check_participants_have_contracts(topology, contracts),
         :ok <- check_flows_within_contracts(topology, contracts),
         :ok <- check_message_shapes(topology, contracts),
         :ok <- check_no_forbidden_violations(topology, contracts),
         :ok <- check_acceptance_criteria_valid(topology, contracts) do
      {:ok, topology}
    end
  end
end
```

验证失败产生结构化错误报告, 命名准确的违反和涉及的契约条款。

### 3.3 激活影响

激活一个 topology:

1. 在 registry 中标记为 `:active`
2. 更新监控层以观察此 topology 的预期流
3. 发射 telemetry 事件用于审计

激活**不**创建或销毁 agent——agent 由 Socialware 或显式命令生命周期管理。Topology 激活只影响哪些流在监控期间被视为"预期"vs"意外"。

---

## 4. 验证实现

### 4.1 静态 Verifier

对已注册 contract 和 topology 的纯函数:

```elixir
defmodule Esrd.Verifier.Static do
  def verify_all(), do: ...              # 所有 contract + 所有 topology
  def verify_contract(id), do: ...       # 单个 contract 有效性
  def verify_topology(id), do: ...       # 单个 topology 有效性
  def verify_compatibility(topology_id, contract_ids), do: ...
end
```

返回 `{:ok, []}` 或 `{:violations, [%Violation{...}]}`。报告结构化供机器消费。

### 4.2 动态 Verifier

消费 telemetry trace 并对比活跃 topology + contract:

```elixir
defmodule Esrd.Verifier.Dynamic do
  def verify_trace(trace, scenario_id) do
    topology = Esrd.Topology.Registry.active_for_scenario(scenario_id)
    contracts = Esrd.Contract.Registry.all_for_participants(topology)
    
    %{
      expected_flows_missing: find_missing(trace, topology),
      unexpected_flows_observed: find_unexpected(trace, topology),
      contract_violations: find_contract_violations(trace, contracts),
      acceptance_met: check_acceptance(trace, topology)
    }
  end
end
```

### 4.3 Trace 收集

Trace 来自 esrd_runtime 发射的 `:telemetry` 事件:

```elixir
:telemetry.execute(
  [:esrd, :message, :published],
  %{timestamp: System.monotonic_time()},
  %{source: source_id, topic: topic, payload_size: size}
)

:telemetry.execute(
  [:esrd, :message, :delivered],
  %{timestamp: ..., duration: ...},
  %{source: ..., target: ..., topic: ...}
)
```

这些事件被捕获、结构化, 传递给动态 verifier 或存储供事后分析。

### 4.4 运行时监控 (可选)

生产环境中, `Esrd.Monitor` 作为 GenServer 运行, 订阅所有 telemetry 事件, 实时对比活跃 topology。异常发射到 `esr._system.monitor.violations`, 操作员可订阅。

监控不阻塞流量——它是观察性的。

---

## 5. 治理实现

### 5.1 提议存储

提议是结构化 YAML 文件, 存储在指定目录, 同时在 ETS 中跟踪:

```yaml
# /var/lib/esrd/proposals/open/2026-04-20-expand-cc.proposal.yaml
schema_version: "esr/v0.3"
id: "2026-04-20-expand-cc"
type: contract_change
target: "cc-responder"
change_type: additive

requested_by: "Allen"
requested_at: "2026-04-20T10:00:00Z"

proposed_change:
  add_outgoing:
    - topic: "autoservice.cc_debug"
      trigger: "当调试模式启用时"
      message_shape: { content: string }

rationale: |
  调试工作流要求 CC 在单独通道发射调试信息。

impact_analysis:
  affected_contracts: ["cc-responder"]
  affected_topologies: []
  required_code_changes: "最小, handler 新增 publish 调用"
  migration_strategy: "追加性; 无破坏性变更"

status: pending
```

### 5.2 影响分析

提议创建时自动生成:

```elixir
defmodule Esrd.Governance.ImpactAnalyzer do
  def analyze(proposal) do
    %{
      affected_contracts: find_affected_contracts(proposal),
      affected_topologies: find_affected_topologies(proposal),
      required_code_changes: assess_code_changes(proposal),
      migration_strategy: derive_strategy(proposal)
    }
  end
end
```

### 5.3 批准工作流

CLI 命令驱动工作流:

```bash
esr proposal create --target cc-responder --type contract_change
esr proposal review 2026-04-20-expand-cc
esr proposal approve 2026-04-20-expand-cc   # 要求显式授权
esr proposal reject 2026-04-20-expand-cc --reason "..."
```

批准时, 提议的变更被原子应用, 所有依赖 topology 被重新验证, 提议归档。

---

## 6. Socialware 托管

### 6.1 安装

用户运行 `esr install my-socialware` 时:

1. Socialware 包被下载 (从文件系统、git 或 registry)
2. 解析 `socialware.yaml`
3. 对当前 esrd 版本检查兼容性
4. 通过 `esrd_contract` 加载 contract
5. 加载 topology (尚未激活)
6. 解析 handler 依赖 (每个 handler 创建 Python virtualenv)
7. 外部接口注册到 `esrd_socialware`
8. 以 OS 进程启动 handler, 由 esrd 监督
9. 激活 topology
10. 运行冒烟测试场景
11. 成功时提交安装

任何步骤失败会回滚先前步骤。

### 6.2 Handler 监督

每个 Socialware handler 是 OS 级 Python 进程, 包装在 OTP 兼容接口中:

```elixir
defmodule Esrd.Socialware.HandlerProcess do
  use GenServer
  
  # 启动 Python 子进程, 监控, 崩溃时重启
  def init(config) do
    port = Port.open({:spawn_executable, "python3"}, [
      {:args, [config.handler_script]},
      {:env, prepare_env(config)},
      :exit_status,
      :stderr_to_stdout
    ])
    {:ok, %{port: port, config: config, restarts: 0}}
  end
  
  def handle_info({port, {:exit_status, status}}, state) when port == state.port do
    # Handler 崩溃; OTP 监督决定重启策略
    {:stop, {:handler_exit, status}, state}
  end
end
```

OTP 监督在 Elixir 层处理重启策略 (one_for_one、速率限制等)。Python handler 干净地崩溃然后重启——Python 侧不需要监督逻辑。

### 6.3 外部接口 Registry

Socialware 在 `interfaces/*.yaml` 中声明外部接口时, 它们被注册:

```elixir
defmodule Esrd.Socialware.InterfaceRegistry do
  def register(interface), do: ...
  def list_public(), do: ...
  def list_exposed(), do: ...
  def describe(interface_id), do: ...
end
```

接口可以是:

- **仅内部**: 组织内部 agent 可访问
- **组织内公开**: 任何已认证用户可访问
- **已暴露**: 从组织外可访问 (需要显式 `esr expose`)

### 6.4 升级

升级 Socialware:

1. 解析新 manifest, 检查兼容性
2. Major 版本升级时, 向用户显示破坏性变更
3. 优雅停止受影响 handler
4. 应用新 contract 和 topology
5. 重新验证一切
6. 启动新 handler
7. 运行冒烟测试
8. 任何失败时回滚

---

## 7. Python Handler SDK (esr-handler-py)

### 7.1 角色提醒

Python handler **不是** agent。Agent (身份、状态、订阅、路由) 存在于 BEAM GenServer 中。Python handler 是 agent 背后的**业务实现**——LLM 调用、外部 API 交互、领域逻辑发生的地方。

### 7.2 核心 API

```python
from esr_handler import Handler, Message
from pathlib import Path

# 契约感知初始化
handler = Handler.connect(
    url="wss://esrd.localhost:4000/socket",
    agent_id="cc:allen-main",
    token="<jwt>",
    contract_path=Path("contracts/cc-responder.contract.yaml")
)

# 订阅 (根据契约进行客户端验证)
@handler.on("autoservice.customer_messages")
def on_customer_message(msg: Message):
    reply_text = call_claude_api(msg.content)  # 业务逻辑
    
    # 发布 (也进行客户端验证)
    handler.publish(
        topic="autoservice.cc_replies",
        content=reply_text,
        metadata={"in_reply_to": msg.id}
    )

# 阻塞主循环
handler.run()
```

### 7.3 客户端验证

SDK 加载本地契约副本并在发送前验证所有外发 publish/subscribe/target 调用。这意味着:

- 违反在开发时被 SDK 捕获
- IDE 可集成提供实时反馈
- esrd 的运行时拒绝是第二层防御

### 7.4 静态分析器

与 SDK 捆绑:

```bash
$ esr-handler-lint handlers/cc-responder/handler.py \
    --contract contracts/cc-responder.contract.yaml
```

扫描 Python AST 中的 publish/subscribe/target 调用, 对照契约验证每个, 生成 `CONTRACT_COMPLIANCE.md` 报告。

这是 CC Mode B 的主要工具——它让 AI 编写的代码在提交 PR 之前自我验证。

---

## 8. BEAM REPL 作为原生管理接口

esrd 一个常被低估的特性: 因为它基于 OTP, 生产 esrd 集群完全可通过 BEAM REPL 检查和管理。

```bash
$ iex --remsh esrd@host1
iex> Esrd.Contract.Registry.list_all()
[...]
iex> Esrd.Topology.Registry.list_active()
[...]
iex> Esrd.Runtime.PeerRegistry.count()
42
iex> Esrd.Monitor.current_violations()
[]
```

所有高级 CLI 命令 (`esrd-cli`, `esr`) 都是这些 Elixir 函数调用的薄包装。对于深度诊断或异常运维, 管理员可以直接进入 REPL。

这也"免费"获得工具:

- `:observer.start()` — 可视化进程树和监督
- `:recon` — 性能分析
- `Phoenix.LiveDashboard` — 基于 Web 的实时监控

---

## 9. 部署拓扑

### 9.1 单节点 (开发 / 小组织)

```
一台机器:
  - Elixir release 运行 esrd
  - Phoenix endpoint 在 :4000
  - Python handler 通过 localhost 连接
```

对单用户开发、演示和小团队使用 (高达数百个 agent) 足够。

### 9.2 多节点集群 (生产)

```
三台或更多机器:
  - 同一 Elixir release, 通过 libcluster 连接
  - 负载均衡器前置 WebSocket 连接
  - Handler 根据负载分布到节点
```

使用 BEAM distributed 跨节点通信。不需要自定义联邦协议——一切都是内部的。

### 9.3 存储

- **Contract 和 topology**: 文件系统 (单节点) 或共享存储 (S3 等, 用于集群)
- **提议归档**: 同上
- **运行时状态**: 内存 (ETS), 带周期性检查点
- **消息保留** (如使用 JournalPeer): 外部 DB (PostgreSQL 等)

### 9.4 可观察性

- Telemetry → Prometheus
- 日志 → journald 或结构化 logger
- 违反 → 专门 topic, 通过仪表板可观察
- LiveDashboard 用于实时健康

---

## 10. 开发路线 (Phase A)

### Sprint 0 (1 周): Elixir 熟悉

Allen 和 CC 熟悉 Elixir/OTP/Phoenix。

### Sprint 1 (1 周): Contract 核心 + Registry

- `esrd_contract` OTP application
- YAML 解析器
- 静态 verifier (仅 contract)
- `esrd-cli contract {load, list, inspect, verify}`

### Sprint 2 (1 周): Runtime + Topology

- 带 PeerServer、PeerRegistry、基础 pub/sub 的 `esrd_runtime`
- 带 YAML 解析和验证的 `esrd_topology`
- 运行时契约强制

### Sprint 3 (1 周): Phoenix Channels + Python SDK

- `esrd_web` Phoenix application
- PeerChannel 实现
- `esr-handler-py` 最小版本
- SDK 中的客户端验证

### Sprint 4 (1 周): 验证 + 治理

- 带 telemetry trace 消费的动态 verifier
- 带提议存储的 `esrd_governance`
- 提议的 CLI 命令

### Sprint 5 (1-2 周): Socialware 支持 + 官方 Handler

- 带 manifest 解析和 handler 监督的 `esrd_socialware`
- 官方 handler: MCP Bridge (CC 集成)
- 官方 handler: 飞书 adapter
- 端到端演示: 安装 Socialware, 运行, 验证合规

### Phase A 完成标准

1. esrd release 在 Linux 上可安装
2. `esr` CLI 可用 (install, use, talk, status)
3. Python 开发者可以在一个下午写出一个 handler
4. CC 通过 MCP Bridge 成功使用 esrd
5. 飞书消息双向流过 esrd
6. 至少一次吃狗粮成功: esrd 团队用 esrd 协调 esrd 开发

---

## 11. esrd 明确不做的事

防止范围蔓延:

- **Actor 调度算法**: OTP 处理这个
- **监督策略设计**: OTP 有既知策略; esrd 使用它们
- **消息传输优化**: Phoenix Channels 足够
- **LLM 集成**: 属于 Socialware handler
- **领域词汇**: "customer", "operator", "takeover" 等不在 esrd 任何地方
- **跨组织联邦**: 显式范围外 (见 ESR Reposition v0.3 Final §11.1)
- **用户管理**: 委托给外部 IAM 系统
- **支付/计费**: ezagent 的关注点, 不是 esrd 的

如果某功能请求落入这些类别, 答案是"不, 那不是 esrd 的工作"。

---

*esrd 参考实现 v0.3 Final 结束*
