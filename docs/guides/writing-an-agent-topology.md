# 编写 Agent 拓扑指南（面向业务开发者）

> 写给：要在 ESR 上接入新 IM 渠道、新 LLM agent 或新业务流程的开发者。
> 阅读时间：~15 分钟。代码量：1 个 yaml + 0–N 个 Elixir/Python 文件，看你
> 的拓扑能不能复用现有 peer。

ESR 的核心是一个 **agent 拓扑** — 你声明"一条消息进来要经过哪些处理
peer，以什么顺序"，runtime 负责按声明 spawn 进程、连线、监控、回收。
本文以 `feishu-cc`（Feishu 消息驱动 Claude Code 会话）为线索，讲清楚怎
么写自己的拓扑。

---

## 一、3 个核心概念

| 概念 | 是什么 | 在哪里定义 |
|---|---|---|
| **Agent** | 一种业务能力的**模板**（"CC 写代码"、"客服机器人"…）。是拓扑的命名包。 | `${ESRD_HOME}/${ESR_INSTANCE}/agents.yaml` |
| **Peer** | 拓扑里的**节点**。每个节点是一个 Elixir 进程，处理 inbound/outbound 一种动作。 | `runtime/lib/esr/peers/*.ex`（or 你写一个新的） |
| **Session** | Agent 模板的**运行实例**。一个 user × 一个 chat = 一个 session = 一棵 supervisor 子树。 | runtime 自动 spawn |

**最关键的一句话**：把业务能力切分成"一条消息流过的 peer 序列"。每
个 peer 干一件事（解析、鉴权、调 LLM、发回 IM…），用 `agents.yaml` 把
它们串起来，runtime 就能跑了。

---

## 二、`agents.yaml` 完整结构

以 cc agent 为例，逐字段注解：

```yaml
agents:
  # 1) Agent 名 — slash command 和 admin CLI 用这个名字引用
  cc:
    # 2) 人类可读描述
    description: "Claude Code"

    # 3) 启动这个 agent 需要的能力（capability）
    # 调用方（用户或其他 agent）必须在 capabilities.yaml 里被授予这些
    # 才能调起本 agent 的 session。
    capabilities_required:
      - session:default/create        # 创建 session 本身
      - tmux:default/spawn            # 启动 tmux pane
      - handler:cc_adapter_runner/invoke  # 调用 cc handler

    # 4) Pipeline — agent 拓扑的核心
    pipeline:
      # 4a) inbound — 收消息时，按这个顺序穿过 peer
      # 一个 IM 消息 → FCP → CCProxy → CCProcess → TmuxProcess
      inbound:
        - name: feishu_chat_proxy        # 局部别名（在本 agent 内引用）
          impl: Esr.Entities.FeishuChatProxy  # 实际 Elixir 模块
        - name: cc_proxy
          impl: Esr.Entities.CCProxy
        - name: cc_process
          impl: Esr.Entities.CCProcess
        - name: tmux_process
          impl: Esr.Entities.TmuxProcess

      # 4b) outbound — 发消息时的反向路径（CC 的 reply 走这条）
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - feishu_chat_proxy

    # 5) Proxies — 跨 session 共享的"无 pid"模块
    # 比如 FeishuAppAdapter 是按 app_id 做单例的（不属于任何 session），
    # 但每个 session 都需要往它发消息 → 用一个 Proxy 模块代理。
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Entities.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"  # ${app_id} 来自 params

    # 6) Params — 创建 session 时必填/可选参数
    params:
      - name: dir
        required: true
        type: path        # tmux session 的工作目录
      - name: app_id
        required: false
        default: "default"
        type: string      # 决定 ${app_id} 替换 + Feishu app 路由
```

### 字段速查

| 字段 | 必填？ | 含义 |
|---|---|---|
| `description` | 否 | UI/日志可读字符串 |
| `capabilities_required` | 否（没列等于"任何人都可以"） | 调用前 Lane B 检查 |
| `pipeline.inbound` | 是 | 按顺序 spawn，串成 peer 链 |
| `pipeline.outbound` | 否 | 反向路径；不写默认 = inbound 反向 |
| `proxies` | 否 | 跨 session 资源的代理 |
| `params` | 否 | 创建 session 时的入参 schema |

---

## 三、cc agent 一条消息的全链路（精确版）

下图按时间顺序描述用户 DM Feishu bot 一条消息后，runtime 到底干了什么。
理解这个流程之后你写自己的拓扑就有了对照。

```
user (Feishu) → [Feishu open API] → mock_feishu (test) / 真 Feishu WS
                                          │
                                          │ ws frame
                                          ▼
                  feishu_adapter_runner (Python sidecar)
                                          │
                                          │ Phoenix Channel
                                          ▼
              EsrWeb.AdapterChannel  (topic: adapter:feishu/<instance>)
                                          │
                                          ▼
              FeishuAppAdapter.handle_upstream({:inbound_event, env})
                                          │
                            ┌─────────────┴─────────────┐
                            │                           │
                  SessionRegistry.lookup       (chat_id, thread_id) → ?
                            │
                       ┌────┴────┐
                       │         │
                    found       not found
                       │         │
                       │         └──► SessionRouter:new_chat_thread
                       │                       │
                       │                       │  do_create:
                       │                       │  1. fetch_agent("cc")
                       │                       │  2. enrich_params (resolve workspace_name)
                       │                       │  3. start_session_sup
                       │                       │  4. spawn_pipeline (按 inbound 顺序逐个 spawn)
                       │                       │  5. backwire_neighbors（双向 neighbor patch）
                       │                       │  6. register_session
                       │                       │  7. redeliver_triggering_envelope
                       │                       │
                       └─────────┬─────────────┘
                                 │
                                 ▼
              FeishuChatProxy ({:feishu_inbound, env})
                                 │ args=msg.args (chat_id, content, message_id, sender_id, …)
                                 │
                                 │  非 slash 走这条：
                                 ├──► (副作用) 给 inbound 加表情 (react)
                                 │
                                 ▼  send(cc_process_pid, {:text, content, meta})
              CCProcess.handle_upstream({:text, _, meta})
                                 │
                                 │ 1. stash_upstream_meta (存进 last_meta)
                                 │ 2. invoke handler `cc_adapter_runner.on_msg`
                                 │ 3. handler 返回 actions=[%{type: "send_input", text}]
                                 │ 4. dispatch_action(send_input)
                                 │       └─ build_channel_notification(state, text)
                                 │       └─ Phoenix.PubSub.broadcast(
                                 │              "cli:channel/<sid>",
                                 │              {:notification, env})
                                 │
                                 ▼
              EsrWeb.ChannelChannel (cc_mcp 已 join 此 topic)
                                 │
                                 │ push("envelope", env)  → cc_mcp WS
                                 ▼
              cc_mcp (Python, claude 的 MCP server)
                                 │
                                 │ inject_message → claude 看到 <channel> tag
                                 ▼
              claude （在 tmux pane 里）
                                 │
                                 │ 调用 mcp__esr-channel__reply tool
                                 ▼
              cc_mcp → tool_invoke ↑
                                 │
                                 ▼
              ChannelChannel.handle_in("envelope", tool_invoke)
                                 │
                                 │ Registry.lookup("thread:<sid>") → FCP pid
                                 │ send(fcp_pid, {:tool_invoke, …, "reply", args, …})
                                 ▼
              FCP.dispatch_tool_invoke("reply")
                                 │ un-react inbound (FCP 的产品语义)
                                 │ emit_to_feishu_app_proxy(%{kind: "reply", args: …})
                                 ▼
              FeishuAppAdapter.handle_downstream(%{kind: "reply"})
                                 │ wrap_as_directive → broadcast on adapter:feishu/<instance>
                                 ▼
              feishu_adapter_runner 收到 directive
                                 │ on_directive("send_message", args)
                                 ▼
              真 Feishu / mock_feishu /open-apis/im/v1/messages
                                 │
                                 ▼
              user 收到 reply
```

把这张图记住，你写自己的拓扑就是"在某些边/节点替换组件"。

### 三.5 多 app 的扩展（PR-A 之后）

每条 inbound 现在带 `app_id` 字段，这个字段一路从 Python feishu
adapter（`adapter.py:_emit_events_*` 把 `args["app_id"] =
self.actor_id` 加到 envelope）一直传到 cc_mcp 的
`<channel>` tag attributes。CC 可以读到自己当前 session 是为哪
个 app 服务的。

**Cross-app forward**：CC 调 `mcp__esr-channel__reply` 时显式
指定目标 `app_id`：

  - `app_id == 当前 session 的 home app` → 走原 home-app 路径，
    `forward_reply_pass_through` 维持 reply_to_message_id /
    un_react bookkeeping
  - `app_id != home app` → FCP 走跨 app 分发：
    1. `Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id)`
       拿目标 workspace
    2. `Esr.Capabilities.has?(state.principal_id,
       "workspace:<target_ws>/msg.send")` 校验 cap
    3. `Registry.lookup(Esr.Entity.Registry,
       "feishu_app_adapter_<app_id>")` 找目标 FAA peer
    4. `send(target_pid, {:outbound, %{"kind" => "reply",
       "args" => %{"chat_id" => ..., "text" => ...}}})` 把
       directive 转给目标 app 的 adapter

3 种结构化失败（FCP 都通过 `Logger.info "FCP cross-app deny
type=..."` 给运维暴露同一信号）：

  - `unknown_chat_in_app` — workspaces.yaml 没该 (chat, app)
    映射，CC 写错了 chat_id 或 workspace 没配置
  - `forbidden` — principal 没目标 ws 的 `msg.send`
  - `unknown_app` — 没注册对应的 FAA peer（typo / app 没启动）

跨 app 分发时 `reply_to_message_id` 和 `edit_message_id` 会被
strip——它们属于 source app 的 message_id 空间，target app
不认识。

**E2E 旁路（test-only）**：直接在 admin 端注入 tool_invoke
而不依赖 CC：

  - `runtime/lib/esr/admin/commands/cross_app_test.ex` 暴露
    `cross_app_test` 命令
  - 用 `esr admin submit cross_app_test --arg session_id=<sid>
    --arg chat_id=... --arg app_id=... --arg text=...
    --arg principal_id=...` 把 tool_invoke 同步打到
    指定 session 的 FCP，returncode 包含 FCP 真实 auth-gate
    决定的 envelope（含 `error.type`）

这条 admin 命令存在的目的：scenario 04 §5.4 / §5.5 的 forbidden /
non-member E2E 不能依赖 CC 主动发跨 app reply（CC 把"按指令转发到
其他 chat"识别为 prompt-injection / lateral-movement 信号会
拒绝执行），需要绕开 CC 直接驱动 FCP 的 gate。生产用法不存在
——admin command 仍走完整 capability check 链，注入也只能
到注册了的 session。

参考：
- 设计 spec — `docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`
- 实施 plan — `docs/superpowers/plans/2026-04-25-pr-a-multi-app.md`
- 跨 app 单元测试 — `runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs`
- 多 app E2E — `tests/e2e/scenarios/04_multi_app_routing.sh`

---

## 四、写一个新 agent 的最小步骤

假设你要做一个 `kb-bot`（基于 Feishu 的客服机器人，用 Anthropic SDK 直
连模型，**不用 tmux 也不用 claude CLI**）。

### 步骤 0：能不能复用现有 peer？

| 你需要的能力 | 复用现有 peer？ | 替换方案 |
|---|---|---|
| 接收 Feishu inbound | ✅ `FeishuChatProxy` + `FeishuAppAdapter` | 复用 |
| 把消息塞给 LLM | ❌ `CCProcess` 现在调 `cc_adapter_runner` handler，绑死了 send_input 语义 | 写一个新 peer e.g. `KBProcess` |
| 调 LLM 拿回复 | ❌ tmux + claude 是 CC 特有的 | KBProcess 内部直接用 anthropic SDK |
| 把回复发回 Feishu | ✅ FCP 的 outbound `reply` 已经做了 | 复用 |

### 步骤 1：写 `agents.yaml`

```yaml
agents:
  kb-bot:
    description: "Knowledge-base customer-service bot"
    capabilities_required:
      - session:default/create
      - kb:default/query
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Entities.FeishuChatProxy   # 复用
        - name: kb_process
          impl: Esr.Entities.KBProcess         # 你新写的
      outbound:
        - kb_process
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Entities.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: app_id
        type: string
      - name: kb_id
        type: string
        required: true
```

### 步骤 2：实现新 peer（如果需要）

`runtime/lib/esr/peers/kb_process.ex`，看现有 peer 当模板：

```elixir
defmodule Esr.Entities.KBProcess do
  use Esr.Entity.Stateful

  @impl Esr.Entity
  def spawn_args(params) do
    %{
      kb_id: Esr.Entity.get_param(params, :kb_id),
      session_id: Esr.Entity.get_param(params, :session_id)
    }
  end

  @impl GenServer
  def init(args), do: {:ok, args |> Map.put(:neighbors, []) |> Map.put(:history, [])}

  @impl Esr.Entity.Stateful
  def handle_upstream({:text, text, _meta}, state) do
    # 1. 调 LLM（同步或异步皆可，本例同步）
    answer = call_kb_llm(text, state.kb_id, state.history)

    # 2. 回信 — 直接 send 给 feishu_chat_proxy neighbor
    case Keyword.get(state.neighbors, :feishu_chat_proxy) do
      pid when is_pid(pid) -> send(pid, {:reply, answer})
      _ -> :ok
    end

    {:forward, [], %{state | history: [{:user, text}, {:bot, answer} | state.history]}}
  end

  def handle_upstream(_other, state), do: {:drop, :unknown, state}
end
```

### 步骤 3：声明能力 + 工作区

`capabilities.yaml`：

```yaml
principals:
  - id: ou_xxxxx          # 用户 open_id
    capabilities:
      - kb:default/query
      - session:default/create
      - workspace:e2e/msg.send  # Feishu inbound 的鉴权门
```

`workspaces.yaml`：

```yaml
workspaces:
  customer-service:
    cwd: "/tmp/kb"   # KBProcess 不用 tmux 时随便填
    chats:
      - {chat_id: oc_xxx, app_id: cli_xxx, kind: dm}
```

### 步骤 4：测试

最窄的 walking-skeleton — 给一个 chat 推个 inbound，看 mock_feishu 收到
回复：

```bash
curl -X POST -d '{"chat_id":"oc_xxx","user":"ou_xxx","text":"What's my account balance?"}' \
  http://127.0.0.1:8201/push_inbound

curl http://127.0.0.1:8201/sent_messages | jq
```

期望看到一条 receive_id="oc_xxx" 的 reply。

---

## 五、常见模式

### 5.1 Slash command (`/foo bar`)

`FeishuChatProxy` 已经把以 `/` 开头的 inbound 路由到 SlashHandler。要
新增 slash 命令，写一个 `Esr.Admin.Commands.<Name>` 模块，并在 admin
dispatcher 里注册 `kind` 字符串。

### 5.2 Auto react on inbound

FCP 已经默认对每条非 slash inbound 加表情，CC reply 时自动 un-react。
不想要这个行为？fork 一个 `MyChatProxy` 改 `forward_text_and_react/4`。

### 5.3 跨 session 共享资源

你需要一个全局 actor（按 app/workspace 单例的，不绑某个 session），把
它放到 `Esr.AdminSession` 子树（参考 `feishu_app_adapter`），然后在
agents.yaml 里用 `proxies` 加一个 `target: "admin::my_singleton"` 引用
它，每个 session 通过 Proxy 把消息送过去。

### 5.4 自定义 inbound 鉴权

`FeishuAppAdapter._is_authorized` 检查 `workspace:<ws>/msg.send`。如果
你要更细的策略（比如限频、白名单），可以：

- 在 capabilities.yaml 里给 principal 加更细的 cap 名
- fork adapter 类，覆写 `_is_authorized`

---

## 六、运维侧检查清单

每接一个新 agent，跑一遍：

- [ ] `agents.yaml` 里 agent 已声明
- [ ] `capabilities.yaml` 里调用方有所需 cap
- [ ] `workspaces.yaml` 里 chat 绑定到 workspace
- [ ] `adapters.yaml` 里 IM 实例的 `app_id` / `app_secret` / `base_url` 配好
- [ ] runtime 已重启或 hot-reload 把新配置吃进去（`SessionRegistry.load_agents/1`）
- [ ] 跑一条最窄 inbound 端到端验证
- [ ] 在 `tests/e2e/scenarios/` 下加一个 walking-skeleton scenario

---

## 七、关键文件指引

| 你要做… | 看这里 |
|---|---|
| Agent yaml 字段含义 | `runtime/lib/esr/session_registry.ex` (compile_agent/1) |
| Peer.Stateful 接口 | `runtime/lib/esr/peer/stateful.ex` |
| 现有 peer 当模板 | `runtime/lib/esr/peers/*.ex` |
| 新 IM channel adapter | `adapters/<channel>/src/esr_<channel>/adapter.py` |
| 测试一个 scenario | `tests/e2e/scenarios/01_single_user_create_and_end.sh` |
| 概念背景 / 架构图 | `docs/architecture.md`, `docs/design/ESR-Protocol-v0.3.md` |
| 调试时怎么看 esrd 日志 | `${ESRD_HOME}/${ESR_INSTANCE}/logs/stdout.log` |
| 端口在哪 | `${ESRD_HOME}/${ESR_INSTANCE}/esrd.port`（`esr.port` 文件） |

---

## 八、关键陷阱（先知道，少踩）

1. **chat_id="pending" 路径不会 spawn pipeline** — 直接 `esr admin
   submit session_new` 不带 `chat_id` 参数时，走的是 legacy 路径，只
   起 SessionProcess 基座，不会 spawn 你声明的 inbound peer。要触发
   完整 pipeline，需要 (a) 让 inbound 自然到达，由 SessionRouter 的
   `:new_chat_thread` 路径 auto-create，或 (b) submit 时显式传 chat_id
   + thread_id。
2. **Pipeline 中的 peer 顺序就是 spawn 顺序** — 后面的 peer 看不到前
   面的 pid，靠 T6 的 `backwire_neighbors` 把 neighbor 双向 patch 进
   每个 peer 的 state。如果你写的 peer 在 init 阶段就需要 neighbor
   pid，那是错的——只能在 handle_upstream/handle_downstream 里读
   `state.neighbors`。
3. **能力名格式必须是 `prefix:name/perm`** — `cap.foo.bar`、`foo:bar`
   都不会被 `Grants.matches?/2` 解析（见
   `docs/notes/capability-name-format-mismatch.md`）。
4. **proxies 里 `${var}` 替换目前只支持 `${app_id}`** — `target:
   "admin::feishu_app_adapter_${app_id}"` 中的 `${app_id}` 会被替换为
   session params 里的 `app_id` 值。其他 token (e.g. `${chat_id}` /
   `${workspace_name}`) 不会被替换 — `runtime/lib/esr/session_router.ex`
   的 `build_ctx` 只对 `${app_id}` 做这一步。如果你需要其他参数，
   要么扩展 build_ctx，要么在 peer 内部从 `state.proxy_ctx` 读。
5. **Lane A 鉴权门** — Feishu inbound 必须满足 `workspace:<ws>/msg.send`
   才会被 forward（adapter 层就 drop 掉了）。新 chat 第一次发消息前，
   ` capabilities.yaml` 必须把这个 cap 给到对应 principal。

---

## 九、业务拓扑感知（PR-F 2026-04-28）

到这里你已经能写 agent 拓扑、把 peer 串起来。**业务拓扑**（这个 agent
在更大流水线里的角色）是另一层信息——LLM 自己得知道自己是干嘛的、
下一棒是谁、要交什么格式。两条工具：

### 9.1 `metadata:` 字段（声明端）

`workspaces.yaml` 每个 workspace 可以挂一段自由格式的 `metadata:`，
LLM 通过 `describe_topology` 工具按需读取：

```yaml
workspaces:
  ws_dev:
    cwd: /workspaces/dev
    role: dev
    chats: [...]
    neighbors:
      - workspace:ws_kanban
    metadata:
      purpose: "Engineering team's day-to-day discussion"
      pipeline_position: 1
      hand_off_to: "ws_kanban"
      output_format: "markdown with code blocks"
      not_my_job: "task tracking — that's ws_kanban"
```

| 常用字段 | 含义 |
|---|---|
| `purpose` | 这个 workspace 在系统里扮演什么角色（一句话） |
| `pipeline_position` | 多阶段流水线里的序号（1, 2, 3, …） |
| `hand_off_to` | 自己干完之后下一棒交给谁 |
| `output_format` | 下游期望的格式 / schema |
| `not_my_job` | 显式声明哪些事不归自己管，让下游接 |

schema **是开放的** —— 运维按业务需要加字段，不需要改代码。LLM 自己会
读懂并据此决策。

⚠️ **`metadata:` 会被原样暴露给 LLM**。不要放：
- API key、secret → 用 `env:`（响应里被过滤）
- 私有路径 → 用 `cwd:`（也过滤）
- 跟 `chats[]` 已经有的 PII 重复

### 9.2 `describe_topology` MCP 工具（消费端）

CC（或任何接入 esr-channel MCP 的 LLM）能调：

```python
# Claude 在 prompt 里看到的工具签名是无参的：
mcp__esr-channel__describe_topology()
```

cc_mcp 桥（`adapters/cc_mcp/src/esr_cc_mcp/channel.py:_invoke_tool`）
会把 `ESR_WORKSPACE` 环境变量注入成 `workspace_name` 参数；运行时
（`EsrWeb.CliChannel.dispatch("cli:workspaces/describe", …)`) 返回：

```json
{
  "ok": true,
  "data": {
    "current_workspace": {
      "name": "ws_dev",
      "role": "dev",
      "chats": [{"chat_id": "oc_…", "app_id": "cli_…", "kind": "group", "name": "dev-room"}],
      "neighbors_declared": ["workspace:ws_kanban"],
      "metadata": {"purpose": "...", "pipeline_position": 1, ...}
    },
    "neighbor_workspaces": [
      { "name": "ws_kanban", "metadata": {...}, ... }
    ]
  }
}
```

只有 `workspace:<name>` 类型的邻居会被展开成 `neighbor_workspaces`；
`chat:` / `user:` / `adapter:` 邻居留在 `neighbors_declared` 里让 LLM
自己解释（参考 `docs/notes/actor-topology-routing.md`）。

**LLM 何时该调？** Tool 描述里的"when to call"会引导：
- 用户提到了一个不认识的 workspace / 团队名
- 需要流水线上下文（自己的角色、下游期望、输出格式）
- 不确定该把 reply 路到哪个 chat

不要每轮都调——它是 on-demand 的"看说明书"动作，不是入参。

### 9.3 写新 agent 时的 metadata checklist

每加一个新 agent 的 workspace 时，过一遍：

- [ ] `metadata.purpose` 是否一句话讲清这个 workspace 干啥
- [ ] 多阶段流水线里有 `pipeline_position` + `hand_off_to`
- [ ] 下游期望的格式写在 `output_format` 里
- [ ] 边界（什么事不该自己干）写在 `not_my_job` 里
- [ ] 不含 secret / 不重复 chats[] 已有的 PII
- [ ] 测试时验证返回值符合预期 —— 没有专门的 CLI 子命令；要验证就在
  CC 会话里直接让 LLM 调 `mcp__esr-channel__describe_topology`，或写
  Elixir 单元测试打 `EsrWeb.CliChannel.dispatch("cli:workspaces/describe", %{"arg" => "ws_dev"})`
  （参考 `runtime/test/esr_web/cli_channel_test.exs`）。

### 9.4 相关文件

- 设计 spec — `docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`
- 运维笔记 — `docs/notes/actor-topology-routing.md` §"Authoring workspaces.yaml" → `metadata:`
- 运行时端点 — `runtime/lib/esr_web/cli_channel.ex` `dispatch("cli:workspaces/describe", …)`
- cc_mcp 工具 schema — `adapters/cc_mcp/src/esr_cc_mcp/tools.py` `_DESCRIBE_TOPOLOGY`
- 单元测试 — `runtime/test/esr_web/cli_channel_test.exs`、`adapters/cc_mcp/tests/test_describe_topology_invoke.py`

---

如有具体场景困惑，看 `docs/notes/`（按主题切的小笔记）或问 channel。
