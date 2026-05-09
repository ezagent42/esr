# SessionTemplate + Channel

**状态：** 草稿 — 待用户确认
**日期：** 2026-05-10
**作者：** Claude（与 linyilun）
**姊妹 spec：** `2026-05-09-yaml-layout-v2-per-thing-directories.md`（存储 layout — 互引）
**部分取代：** `docs/issues/02-cc-mcp-decouple-from-claude.md`（channel 抽象那半）

---

## 1. 为什么是现在

三股压力汇合：

1. **同一 instance 共享给多 session 的需求** —— 操作员希望一个 CC 实例同时挂 boss-session 和 junior-session 给两个用户。今天 instance 绑定单一 session_id，做不到。
2. **第二种 agent kind 要来** —— codex / gemini-cli / voice plugin 都会想自己的 agent type。今天的 agent ↔ pipeline 耦合分布在 `agents.yaml` + `Esr.Entity.FeishuChatProxy` + `Esr.Entity.SlashHandler` + `Esr.Entity.Agent.MentionParser` 里。每加一个 agent kind 就要重走每个耦合点。
3. **`docs/issues/02-cc-mcp-decouple-from-claude.md` 运行时那半还开着** —— PR #220（cc_mcp HTTP transport，2026-05-05）解了"cc_mcp 跟 tmux 一起死"那具体 bug（tmux 现在也没了，PR-22 删了），但更广义的"channel 是一等公民、任何 plugin 都能声明依赖"还没做 —— issue 自己的状态行还写着"Brainstorm pending 2026-05-01 / Decision: TBD"，没更新。本 spec 吸收 issue 的运行时部分；本 spec 落地时 issue doc 自己需要写一条收尾。

三股压力指向同一个答案：**把"session 怎么布线"从 plugin 私有代码里提到声明式 template；把 per-session 通信 peer 形式化成一等 primitive**。

`docs/notes/concepts.md` rev-10 已经命名了这个 pattern：Session 是 **Realm**（这种 session 所处的"通信宇宙"）的运行时实例。本 spec 把运行时那半 —— `SessionTemplate` + `Channel` —— 提进 ESR。Realm 留在 `concepts.md` 作为词汇伞概念（不进 runtime；它是 SessionTemplate + Channel 共同实现的 umbrella）。

---

## 2. 目标 & 非目标

### 目标

- **`Esr.Channel` behaviour** —— per-session BEAM peer 抽象。Plugin 提供 Channel 实现（`Esr.Plugins.Feishu.Channels.ChatProxy`、`Esr.Plugins.ClaudeCode.Channels.McpHttp`）。behaviour 标准化 start_link / send / subscribe + lifecycle。
- **`Esr.SessionTemplate`** —— 声明式 yaml 描述一个 session：用哪些 Channel kind、起哪些 Entity、message 怎么流。内置 template 在 `runtime/priv/session_templates/`；操作员自定义放 `~/.esrd-<inst>/<inst>/session_templates/`。
- **Plugin manifest 加 `channels:` + `agent_kinds:` 块** —— 取代今天的 `agents.yaml`（其内容本来就属 plugin 拥有）。
- **Drift prevention** —— 跟 unified-command-grammar 同一 pattern：布线进声明式 yaml、加载时校验、CI gate 防 template 引用消失的 channel kind。
- **Multi-session-per-instance** —— SessionTemplate 的自然产物：instance 独立持久化，session 注册兴趣，channel routing 携带 session_id 上下文。

### 非目标

- **Realm 作为运行时概念。** Realm 留 `concepts.md` 词汇层。SessionTemplate + Channel 是 plugin 作者实际接触的两个具体投影。
- **运行中 session 热更换 template。** 编辑 yaml 只影响**未来**的 session。已有 session 锁住创建时的 template（rewire 活 session 会破坏 in-flight 状态）。
- **GenStream 风格 Channel API。** 不引入 GenStage / Broadway。Channel 是 GenServer-shaped peer，同步 send + 异步 subscribe。背压不是今天的瓶颈。
- **跨 instance 共享 Channel。** 每个 Channel per-session-instance。两个 session 共享 agent 是共享 `Instance{}`；它们各自有自己的 Channel set。

---

## 3. 三层划分

ESR 运行时 taxonomy 已有 Entity / Resource / Commands / Boundary / Pipeline / OTP marker。SessionTemplate + Channel 这样接进来：

| 层 | 概念 | 今天的对应 | Lifecycle |
|---|---|---|---|
| **Agent type** | `cc` 是哪个 binary、什么 caps、什么 config_schema | `agents.yaml` | Plugin 声明、boot 时通过 plugin manifest 加载 |
| **SessionTemplate** | 这种 session 用哪些 Channel + Entity + flow | 硬编码在 FeishuChatProxy / SlashHandler / agents.yaml `pipeline:` 字段 | yaml 声明、template 加载时校验 |
| **Channel** | Per-session 通信 peer（HTTP MCP、Feishu chat 等） | Plugin 内部 —— 每个 plugin 重写一遍 | Plugin shipped 实现、per-session AgentSupervisor 监管 |
| **Agent instance** | `alice`、运行时 UUID、actor_ids、session_ids | `Esr.Entity.Agent.InstanceRegistry` + （今天）内联在 `session.json` | per yaml-v2 spec 持久化在 `sessions/<sid>/agents/<aid>.json` |

Realm 是"哪几个 Channel + Entity + flow 组合 = 一种 session 类型"的词汇伞。一个 SessionTemplate **就是**一种 Realm 的声明式形态。两个 Realm = 两个 SessionTemplate。

---

## 4. 决策（2026-05-09 brainstorm 锁定）

| 问题 | 决策 |
|------|------|
| 命名 | `Esr.Channel`（primitive）+ `Esr.SessionTemplate`（composer）；**不要** Realm 作 code 前缀；Realm 在 `concepts.md` 作词汇伞 |
| A1 Channel behaviour | GenServer-shaped peer；`start_link/1`、`send/2`、`subscribe/3`、`config_schema/0`（可选 callback）。监管在 per-session `Esr.Session.AgentSupervisor`（M-2.6 `:one_for_all` 策略） |
| A2 Channel kind 发现 | Plugin 在 manifest `channels:` block 声明；`Esr.Plugin.Loader` 写入 `Esr.Channel.Registry` ETS。Template 用 `<plugin>.<channel_name>` 引用 |
| B1 Template 文件位置 | 内置：`runtime/priv/session_templates/*.yaml`。操作员：`~/.esrd-<inst>/<inst>/session_templates/*.yaml`。同名 override：操作员胜（mirrors plugins.yaml 三层模式） |
| B2 Template yaml shape | `name + description + channels[] + agents[] + flow{inbound, outbound}`。`<runtime>` 占位符 = session 创建时注入的参数 |
| B3 默认 template | priv 里 `default.yaml` 镜像今天的 feishu-cc 拓扑。`/session:new` 不传 `template=` → 用 default。操作员通过 `/plugin:set plugin=session key=default_template` 改默认 |
| C1 agents.yaml 命运 | 消失。Agent **type** 定义 → plugin manifest `agent_kinds:` block。**Pipeline**（inbound/outbound chain）→ SessionTemplate。**Instance** 不动（per-session JSON、`agent_instance.v1.json` schema） |
| 存储 | Agent instance 从 `session.json` 拆出来 → `sessions/<sid>/agents/<aid>.json`（一文件一 instance）。**实现迁移在 yaml-v2 spec PR**；本 spec 只声明目标形状、互引 |
| D1 stop-gap | drop。80-LOC InstanceRegistry multi-session 补丁不做；multi-session-per-instance 直接当 SessionTemplate 验收 case |

---

## 5. 具体形状

### 5.1 `Esr.Channel` behaviour

```elixir
defmodule Esr.Channel do
  @moduledoc """
  Per-session 通信 peer 抽象。每个 Channel 实现是 plugin shipped
  GenServer-shaped 模块。实现位于 `Esr.Plugins.<plugin>.Channels.<name>`；
  behaviour 要求适用每个实现。

  Channel 监管在 per-session AgentSupervisor 下、`:one_for_all` 策略
  （M-2.6）。崩溃 → 兄弟连锁重启 → 在 per-session Registry 重新注册 pid。
  """

  @callback start_link(opts :: keyword) :: {:ok, pid} | {:error, term}
  @callback dispatch(pid, msg :: term) :: :ok | {:error, term}
  @callback subscribe(pid, listener_pid, topic :: term) :: :ok
  @callback config_schema() :: map
  @optional_callbacks config_schema: 0
end
```

> 为什么 `dispatch/2` 不叫 `send/2`：`Kernel.send/2` 自动 import 进每个
> 模块。callback 叫 `send/2` 会让每个 Channel 实现想用 `Kernel.send/2`
> 时被迫显式写 `Kernel.send/2` 或 `import Kernel, except: [send: 2]`。
> `dispatch` 跟 ESR 已有词汇一致（FCP "dispatches" inbound），避开了
> shadow。

### 5.2 Channel kind 发现 —— plugin manifest

`runtime/lib/esr/plugins/<plugin>/manifest.yaml`：

```yaml
name: claude_code
version: 0.1.0
agent_kinds:
  - name: cc
    binary: claude
    exec_args: ["--mcp-config", "<mcp_config_path>"]
    capabilities_required: ["session:default/spawn"]
    config_schema:
      type: object
      properties:
        http_proxy: { type: string }
channels:
  - name: mcp_http              # plugin 内本地名
    module: Esr.Plugins.ClaudeCode.Channels.McpHttp
    config_schema:
      type: object
      properties:
        port: { type: integer }
slash_routes:                   # 已有字段，不变
  - "/claude_code:tui"
```

Loader 走每个启用 plugin 的 manifest，填两个 ETS：
- `:esr_channel_kinds` — `{<plugin>.<channel_name>, module}`
- `:esr_agent_kinds` — `{<plugin>.<kind_name>, definition}`

Template 引用 `<plugin>.<name>`；引用不存在的 kind → loader 拒绝。

### 5.3 SessionTemplate yaml shape

`runtime/priv/session_templates/default.yaml`：

```yaml
schema_version: 1
name: default
description: Feishu chat → Claude Code agent（默认 workspace-bound）

channels:
  - alias: in                   # template 内本地别名
    kind: feishu.chat_proxy     # <plugin>.<channel_name>
    config:
      app_id: <runtime>         # session 创建时注入
      chat_id: <runtime>
  - alias: cc_mcp
    kind: claude_code.mcp_http
    config:
      port: ephemeral

agents:
  - kind: claude_code.cc        # <plugin>.<agent_kind>
    name: <runtime>             # 操作员提供
    consumes: [cc_mcp]          # 此 agent 读/写哪些 channel 别名

flow:
  inbound:
    - source: in.text
      pipeline:
        - Esr.Entity.Agent.MentionParser
        - <route_to_agent>      # 内置 router；从 mention 或 primary_agent
                                # 解析目标 agent 名
  outbound:
    - source: <agent>.reply
      sink: in.send
```

Template 加载时校验：
- 每个 `channel.kind` 必须能在 `Esr.Channel.Registry` 解析
- 每个 `agent.kind` 必须能在 `Esr.Plugin.Registry.agent_kinds` 解析
- 每个 `consumes` 引用必须匹配 `channels[].alias`
- 每个 `flow` source/sink 引用必须匹配 alias 或已知 router 内置
- 拒绝重复 alias

### 5.4 默认 template + 选择

- 初次安装：priv `default.yaml` 在 esrd 首次 boot 时 copy 到 `~/.esrd-<inst>/<inst>/session_templates/`（若不存在）
- `/session:new name=foo`（不带 `template=`）→ 用 default
- `/session:new name=foo template=feishu-cc` → 加载 `feishu-cc.yaml`
- 操作员改默认：`/plugin:set plugin=session key=default_template value=feishu-cc`

### 5.5 存储（互引）

按锁定决策，agent instance 从 `session.json` 拆到 `sessions/<sid>/agents/<aid>.json`（一文件一 instance、按 `agent_instance.v1.json` 校验）。**实际存储迁移**在 `2026-05-09-yaml-layout-v2-per-thing-directories.md` 的 PR（你的并行工作）。本 spec 假设 SessionTemplate Phase 5 跑时新 layout 已就位；如果 yaml-v2 没合，SessionTemplate Phase 5 要么（a）等、要么（b）暂时 ship 内联 in-session.json adapter 等 yaml-v2 收尾时换掉。

---

## 6. 迁移阶段

迁移多 PR、有顺序。详细任务在 `docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`。

| 阶段 | 内容 | 触及 |
|------|------|------|
| **1** | `Esr.Channel` behaviour + `Esr.Channel.Registry` ETS + 测试 | 新模块；不动现有 |
| **2** | 第一个 Channel 实现：`Esr.Plugins.ClaudeCode.Channels.McpHttp` 包住既有 Elixir 端 MCP HTTP transport（`EsrWeb.McpController` + `cc_mcp_ready` —— PR-3.5 已从 Python 抽出来）让它符合 `Esr.Channel` behaviour。**没有新 transport 代码**，只是 behaviour adapter | claude_code plugin |
| **3** | 第二个 Channel 实现：`Esr.Plugins.Feishu.Channels.ChatProxy` 把 channel 形状那半（inbound dispatch + outbound reply emit）从当前 `Esr.Entity.FeishuChatProxy` 抽出来。注意：**文件**在 `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` 但**模块命名空间**还是 `Esr.Entity.FeishuChatProxy` —— Phase 3 要么把模块改名对齐 plugin 路径，要么保留 legacy 命名只在旁边加 Channel adapter。plan 决定 | feishu plugin |
| **4** | `Esr.SessionTemplate` yaml schema + loader + Registry + 校验 + 测试 | 新模块 |
| **5** | `/session:new` 消费 template；新 session 通过 SessionTemplate 实例化；`default.yaml` 上线、镜像 feishu-cc | session 创建路径 |
| **6** | 迁移：现有 session 隐式分配 `default` template；`agents.yaml` 删；agent kind 元数据移进 plugin manifest `agent_kinds:`。**非 trivial：** `runtime/lib/` 里 13 个消费者，详见下面 §6.1 | 横切清理 |
| **7** | Multi-session-per-instance 验收：同一 `Instance` 注册到两个 session；reply routing 用 incoming session context | `InstanceRegistry`、`CCProcess` |
| **8** | Docs + e2e scenario 24（multi-session）+ CI gate（template + manifest drift check） | docs、tests |

Phase 1-3 各自独立合（无行为变化）。Phase 4 是 loader 没消费者。Phase 5 是切换。Phase 6-8 是清理 + 验收。

### 6.1 agents.yaml 解散 —— 13 个消费者

`git grep -l agents.yaml runtime/lib/`（2026-05-10 实测）13 个文件。Phase 6 必须逐个处理：

| 文件 | 读什么 | 迁移目标 |
|------|--------|----------|
| `application.ex`（4 处函数含 `extract_handler_modules/1`）| boot 时 Python sidecar 发现 | 移到 plugin manifest `agent_kinds[].handler_module` |
| `interface/spawner.ex` | agent spawn 入口 | 读 plugin registry 的 `agent_kinds` |
| `interface/snapshot_registry.ex` | 已声明 agent 的快照 | 从 plugin manifest 组合 |
| `entity/agent/registry.ex` | agents.yaml 的 ETS cache 本体 | **删** （由 plugin agent_kinds registry 取代） |
| `yaml/fragment_merger.ex` | 多层 yaml merge | 迁移语义：今天 merge `core + plugin fragments + user override` 给 agents.yaml；Phase 6 后同样 merge story 应用到 plugin manifest 间的 `agent_kinds[]` |
| `commands/workspace/remove.ex` | 删 workspace 时检查引用它的 agent | 读 plugin agent_kinds + 活实例 |
| `commands/plugin/agent_types.ex` | `/plugin:agent-types` slash | PR-263 后已读 plugin registry；agents.yaml fallback 可删 |
| `resource/capability.ex` | 从 agent 行的 `capabilities_required` 解 cap | cap 源头从 agents.yaml 行迁到 plugin manifest 的 `agent_kinds[].capabilities_required`（语义不变） |
| `commands/session/new.ex` | spawn 时默认 agent lookup | 同 spawner |
| `session/router.ex` | `:agents_yaml_reloaded` pubsub 消息 | 重命名 / 重新源 plugin manifest reload 时的 `:agent_kinds_reloaded` event |
| `session/agent_spawner.ex` | spawn 调用 | 同 spawner |
| `claude_code/cc_process.ex` | 仅 moduledoc 引用 `agents.yaml` | doc 改 |
| `claude_code/manifest.yaml` | doc text 引用 | doc 改 |

关键迁移：**`extract_handler_modules/1`**（Python sidecar bootstrap）+ **`Esr.Yaml.FragmentMerger`**（多层 merge）—— 都需要 Phase 6 显式 sub-task。plan PR 把 Phase 6 拆 sub-phase per consumer。

---

## 7. 哪些不变

- `Esr.Role.Control` / `Esr.Role.Pipeline` marker 不变
- `Esr.Session.AgentSupervisor` per-session DynSup 不变（M-2.6 策略也覆盖 Channel —— 它们是 child）
- `Esr.Entity.Agent.InstanceRegistry` ETS schema 不变；`Instance.session_ids` 改成 list（原 `session_id` 单值）但其它字段不变。Phase 7
- `slash-routes.default.yaml`（unified-grammar 之后）不变。新 template CI gate 与现有 `mix esr.check_command_docs` gate 分开
- Plugin caps 系统不变。Channel 继承 plugin 的 caps

---

## 8. 这一步解锁什么

- **新 agent plugin（codex / gemini-cli / voice）零核心改动。** Plugin 写 manifest 含 `agent_kinds:`、ship 一个 Channel 实现、ship 一个 template；不动 `Esr.Plugins.Feishu.*` 或核心 dispatch
- **Per-flow Realm 词汇有了着陆。** 未来 docs 可以说"feishu-cc Realm"、"http-codex Realm"，每个名词背后有具体 SessionTemplate yaml
- **可换 transport。** plugin 可以同时 ship `mcp_http_v2`（如双向 streaming）和 `mcp_http`；template 选其一。CC 不分叉
- **Multi-session-per-instance**（Phase 7 验收 case 1）
- **多租户 pattern**：同一 template、多 chat binding、每租户独立 instance —— 不需要 plugin 改

---

## 9. 风险 & 待解

### 风险：SessionTemplate ↔ yaml-v2 存储时序

如果 yaml-v2（per-thing 目录）layout 在 SessionTemplate Phase 5 跑时还没合，agent instance 还内联在 session.json。缓解：SessionTemplate Phase 5 ship 一个薄 adapter 同时读写两种形状；adapter 在 yaml-v2 cleanup 阶段删掉。两个 spec 互相 cite；plan PR 显式 sequence。

### 风险：Channel API 锁死在 CC 怪癖上

今天只有一个 agent kind。如果 Channel behaviour 围绕 CC 的 MCP HTTP 需求锁定，第二个 agent（codex）可能发现 API 不合身。缓解：Phase 4 的 SessionTemplate loader 是 design partner —— 同 Phase 写 CC channel 实现 + 一个 codex/gemini channel stub 实现，两数据点验证抽象后再进 Phase 5。

### 风险：Template drift vs 部署的代码

操作员改的 template 引用已删/改名 channel kind 或 agent kind。缓解：`Esr.SessionTemplate.Registry` 加载时 + plugin reload 时校验；任何无法解析的 ref 失败时附清晰错误指向缺失 manifest。未来：加个类似 `mix esr.check_command_docs` 的 CI gate 走 `runtime/priv/session_templates/` + 所有启用 plugin manifest，校引用完整性。

### 风险：Template 热更换破坏活 session

运行时编辑 template yaml —— 已有 session 要 rewire 吗？按非目标段：**不**。活 session 锁住创建时的 template（session 创建那刻冻结）。reload 只影响未来 session。这点要在 docs 显式说，避免操作员以为 `/plugin:reload` 会 re-route 活会话。

### 待解：Channel 级 caps

今天 caps 是 session-scoped（`/session:default/...`）。Channel 该不该有自己的 cap scope（`/channels/feishu.chat_proxy/...`），让操作员能 grant "send to feishu chat" 不 grant "send to MCP"？初步：不。保留 session-scoped caps；channel 继承。等多租户部署暴露真正的 cap 隔离 gap 再回来。

### 待解：跨 template import

template 该不该能 `extends:` 另一个 template？初步：**v1 不**。YAGNI；template 不大。如果 5+ template 复制同一 boilerplate，再回来。

### 待解：`agent_instance.v2` schema 升级

Phase 7 把 `Instance.session_ids` 从单 UUID 字串改成 list。`agent_instance.v1.json` 必填 `session_id`（单数）—— 升 list 是 schema 版本升（v1 → v2），不是 v1 修补。Phase 7 ship `agent_instance.v2.json` + 一次性迁移：读 v1 文件、写 v2（`session_ids: [old_session_id]`）。运行时不做 on-the-fly fallback；迁移是离散一次性步骤。plan PR 与 yaml-v2 layout 迁移一并做。

### 待解：`config_schema` parser 复用

plugin manifest 自己有个 JSON-Schema-lite parser（`Esr.Plugin.Manifest.parse_config_schema/1`，支持 `string` + `boolean`）。`Esr.Channel.config_schema/0` callback 返 `map()` —— 同方言、还是扩展？初步：同方言、复用 parser；Channel 实现需要更丰富类型（integer、array、ref）就**一次**扩 parser、不 fork。Phase 4 收尾。

### 待解：Template 占位符语法

§5.3 出现三种占位符形状：
- `<runtime>` —— session 创建时注入（如 `name`、`app_id`）
- `<route_to_agent>` —— 内置 router by name
- `<agent>` —— flow 引用 "本 template 声明的 agents"

Phase 4 形式化：
- `<runtime>` 是字面 string 占位符。Loader 收集所有 `<runtime>` 出现并暴露给 `/session:new` 作为 template 参数列表
- `<route_to_agent>` 是注册在 `Esr.Flow.NodeRegistry` 的 N 个内置 flow node 之一。Plugin 可以通过 manifest 的 `flow_nodes:` block 加更多
- `<agent>` 是 flow 语言的 token，解析为"本 template `agents:` 数组里任一 agent"

### 待解：agents.yaml 解散时 cap 继承

今天 `Esr.Resource.Capability` 从 agents.yaml 行读 `capabilities_required`（capability.ex line 63）。Phase 6 必须把这个读移到 plugin manifest `agent_kinds[].capabilities_required`，**保持 cap 解析语义完全一致**。加 Phase 6 sub-task：" cap 源迁移前后跑一次 capabilities.yaml + 代表性 session spawn 的快照测试，断言解析后的 cap 集合相同"。

### 待解：内置 flow 节点

例子里 `flow.inbound[].pipeline:` 引用 `Esr.Entity.Agent.MentionParser` 和 `<route_to_agent>`。我们需要个小注册表登录"内置 flow node"供 template composition（mention parser、primary-agent router 等）。Phase 4 列举这些。Plugin 作者也能 ship 自定义 flow node 通过 manifest 的 `flow_nodes:` block（类比 `channels:`）。

---

## 10. 验收标准

迁移"完成"判据：

- [ ] `Esr.Channel` behaviour 存在，至少 2 个 plugin 实现（claude_code MCP HTTP + feishu chat proxy）
- [ ] `Esr.SessionTemplate` loader 加载时校 template against `Esr.Channel.Registry` + `Esr.Plugin.Registry.agent_kinds`；无法解析 ref 大声失败
- [ ] `runtime/priv/session_templates/default.yaml` 上线，端到端复刻今天的 feishu-cc 行为（e2e scenario 22 + 新 scenario 24 验证）
- [ ] `/session:new` 消费 template；默认行为不变（既有操作员无感知）
- [ ] 操作员能 drop `~/.esrd-<inst>/<inst>/session_templates/foo.yaml`、用 `template=foo` 创建 session，无需 restart esrd（`/plugin:reload` 触发 template registry 热重载）
- [ ] **Multi-session-per-instance**（验收 case 1）：一个 Instance 注册到两个 Session；reply routing 用 incoming session 的 chat context。新 e2e scenario 24 验证
- [ ] **agents.yaml 已删**；agent kind 元数据在 plugin manifest 里；pipeline 在 template 里。`git grep -l agents.yaml runtime/lib/` 零 hit（moduledoc 里的迁移说明除外）。Phase 6 §6.1 的 per-consumer sub-task 全部关闭
- [ ] CI gate：template 引用缺失 channel kind → CI 失败

---

## 11. 引用

- `docs/notes/concepts.md` rev-10 — Realm 词汇
- `docs/issues/02-cc-mcp-decouple-from-claude.md` — Channel 抽象那半（本 spec 吸收 runtime portion）
- `docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md` — 姊妹 spec（存储 layout）
- `docs/superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md` — 同一 drift-prevention pattern，作用于命令而非布线
- `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` — 本 spec 扩展的 plugin manifest 基线
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — 当前单体 chat proxy（Phase 3 抽 channel 那半）
- `runtime/lib/esr_web/mcp_controller.ex` — 当前 MCP HTTP transport（Phase 2 抽到 Channel 下）
- `runtime/lib/esr/entity/agent/instance.ex` + `agent_instance.v1.json` schema — agent instance 形状（Phase 7 把 `session_ids` 扩 list）
- M-2.6 监管策略 — Channel 继承 `:one_for_all` per-session DynSup
