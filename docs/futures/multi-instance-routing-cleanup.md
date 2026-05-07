# Multi-instance routing cleanup —— brainstorm 输入材料

**Status**：brainstorm 输入材料（**不是 spec**）。撰写于 2026-05-07 一次 ESR 架构对话的尾声，作为下一次 brainstorm session 的素材。
**前置依赖**：`docs/futures/todo.md` "Migrate to session-first model" 项落地之后再正式开 brainstorm。
**关联 todo**：`docs/futures/todo.md` "Multi-agent: metadata-vs-runtime gap [待检查]"。

---

## 1. 这是怎么浮出来的

2026-05-07 一次本意是**审计 legacy "routing diffusion" 机制**的对话。原始问题是：

> 最开始添加 workspace `neighbors:` 字段是为了实现自动路由扩散算法。当前 dev 分支这个机制还在用吗？字段还在吗？

审计中发现的事实，按浮现顺序：

1. **`workspace.neighbors:` 字段还在**（`runtime/lib/esr/resource/workspace/registry.ex:55`），`Esr.Topology.symmetric_closure/0` 仍编译它，rendering 到 `<reachable>` 元素喂给 LLM。但**它只是 LLM 通讯录过滤器**——不参与 send 决策、不做访问控制（cap_guard 在接收端兜底）、和 cap grants 在职责上重叠。
2. **真正"路由扩散"意义上的 DSL 不存在**——actor 不声明自己 provides 什么 cap，没有按谓词检索的 lookup 原语。`<reachable>` 只是把 URI 列表给 LLM 自己挑。
3. **`state.neighbors` 这个 GenServer state 字段（PR-3 引入）有结构性 bug**——`Keyword<role_atom, pid>` 的形态**结构性地限定**了 session 内每个 role 只能有一个 entity。`Keyword.get(state.neighbors, :cc_process)` 取 first match。
4. **PR-3 评审通过这个设计是因为当时 spec 就是 1:1**（agent_spawner.ex:263-282 注释里所有 role 都是单数）。这是 **spec 设计阶段的失误**（没把 role 与 instance 分开），不是评审失职。
5. **今晚（2026-05-07）正在落地的 multi-CC 元数据层**（`Esr.Entity.Agent.InstanceRegistry`、`MentionParser`、`/session:add-agent`）让"一个 session 多个 agent"的元数据存在了，但**spawning 层没跟上**——`/session:add-agent` 只往 ETS 插条，不 spawn 真 peer。结果：MentionParser 解析 `@<name>` 找不到对应 pid。

由此本次 brainstorm 的**真问题**不是"加 multi-CC 能力"，而是：

> **PR-3 数据平面纪律落地时遗留了 1:1 role-instance 假设；workspace `neighbors:` 这个 routing-diffusion 字段沦为 LLM context shaper、与设计意图脱节。两件事的根因都是"role 与 instance 没拆开"。要做的是清理 legacy + 把所有寻路（确定性 wire + 动态发现）合并到一个 predicate-based 原语。**

---

## 2. ESR 内"multi" 的四个维度（重要，brainstorm 起点）

| Dim | 含义 | 状态 today | 受 1:1 假设影响 |
|---|---|---|---|
| 1 | esrd 内多 session（每 session 自己一套 pipeline） | ✅ always 工作（PR-3 设计） | 否 |
| 2 | session 关联多 chat（一个 session 路由多条 chat 进出） | 🟡 部分（FCP 在 state.neighbors 仍单数） | **是** |
| 3 | chat 关联多 session（一个 chat 在多个 session 间切换 current） | ✅ 元数据 + 路由都对（`multi_session_test.exs` 通过） | 否 |
| 4 | session 内多 same-role peer（multi-CC + multi-PTY，per agent instance） | ❌ 元数据 only，runtime 不存在 | **是** |

**Dim 2 和 Dim 4 都被 PR-3 的 `state.neighbors :: Keyword<role_atom, pid>` 卡住**。Dim 4 是今晚发现这个 bug 的入口。

### 概念映射澄清（thread 已不在路由中）

`thread_id` 字段还存在（`feishu_chat_proxy.ex:40,54`），但 `feishu_app_adapter.ex:235` 注释明确：*"PR-21λ: routing key is (chat_id, app_id) only"*。thread 已从路由 key 降级为 vestigial 字段，不影响 brainstorm。

### 真实场景示例

A 用户和 B 用户都和飞书 app "ESR 助手" DM。在飞书侧是两个 chat（`chat_id_A`, `chat_id_B`）。

- A 在自己 DM 里 `/session:new` + `/session:add-agent helper-A`：session_A 创建，ChatScope `{chat_id_A, app}.current = session_A`，InstanceRegistry `{session_A, "helper-A"}`。
- B 同样动作：session_B + helper-B。
- B 执行 `/session:attach session_A`：ChatScope `{chat_id_B, app}.attached += session_A`。**这是 Dim 3。**
- 之后 B 在 session_A 里 `/session:add-agent helper-B-extra`：**这才碰到 Dim 4**——session_A 内同时有 helper-A 和 helper-B-extra；今天 InstanceRegistry 记下了，runtime 不存在 helper-B-extra 的 CC peer + PTY peer。

---

## 3. Legacy 清单（可清/待保/重构）

### 可清

| 项 | 文件 | 理由 |
|---|---|---|
| `workspace.neighbors:` 字段 + 对称闭包 | `resource/workspace/registry.ex:55`、`topology.ex:75-118`、`resource/workspace/describe.ex:122-179` | 沦为 LLM 通讯录过滤器，与 cap grants 重叠；可被 cap-based lookup DSL 完整替代 |
| `<reachable>` JSON 属性 + `Esr.Topology.initial_seed/3` + `cc_process.ex` `reachable_set` 字段 | `cc_process.ex:115,141,526,592-614`，`topology.ex:48-70` | 信息性而非决策性，BGP-style learning 实际无人消费决策 |
| `describe_topology` MCP 工具的 `neighbor_workspaces` 字段 | `entity/server.ex:820`，`plugins/claude_code/mcp/tools.ex:89` | 和上面一并清；改成新的 cap-based 查询工具 |
| `find_chat_proxy_neighbor` 后缀扫描 | `cc_process.ex:374-410` | 是 1:1 时代的多态补丁；DSL 化后可优雅消失 |
| `workspaces.yaml` 旧 `neighbors:` + `workspace.json` 的 `_legacy.neighbors` 写双层 | `resource/workspace/registry.ex:587,604`，`resource/workspace/describe.ex:164-179` | 字段清理后这层 legacy adapter 也无意义 |

### 待重构（不能简单删，要替换）

| 项 | 文件 | 替换思路 |
|---|---|---|
| `state.neighbors :: Keyword<role, pid>` | 各 stateful peer init/1 + 4 个调用点 | 改为 `Esr.ActorQuery.find(predicate, scope) :: [actor_ref]` 原语；state.neighbors 退化为可选 cache 或彻底删除 |
| `agent_spawner.ex` 的 `backwire_neighbors` + `:sys.replace_state/2` 双向 patch | `session/agent_spawner.ex:308,342-384` | 不再需要——peer 重启在 init/1 重新注册到 Registry，下次别人 query 拿到新 pid |
| `pty_process.ex` 的 `rewire_session_siblings` + `patch_neighbor_in_state` | `entity/pty_process.ex:309-335` | 同上，删 |
| `agent_def.pipeline.inbound[].name` 当 role 用 | `priv/agents.yaml` + `agent_spawner.ex:454-457` | 把 `role` 与 `name` 拆成两个字段；name 转为 instance 名（UUID 或操作员命名） |

### 保留（已经对的）

- `Esr.Entity.Registry` 的 `actor_id → pid` 索引（升级成多属性倒排即可，不重写）
- BEAM 原生 `send`/`cast` 数据平面（PR-3 纪律不变）
- PubSub 控制平面 7 topic family（白名单纪律不变）
- ChatScope.Registry（Dim 3 已经对）
- InstanceRegistry（Dim 4 元数据层已经对，仅需 runtime 层补齐）
- cap_guard 接收端访问控制（DSL 是发现层，cap_guard 是授权层，正交）

---

## 4. 目标（brainstorm 开始时要确认）

1. **统一寻路原语**：所有 actor lookup 走 `Esr.ActorQuery.find(predicate, scope)`。"确定性 wire" 与 "动态发现" 是同一个原语的不同 predicate / 不同 scope。
2. **消除 1:1 role 假设**：role 与 instance 拆字段，一个 session 内可以有 N 个同 role 的 peer，每个有独立 actor_id (UUID)。
3. **删 legacy diffusion 表层**：`workspace.neighbors:` 字段、`<reachable>` 元素、对称闭包、describe_topology 的 neighbor_workspaces——全部按 §3 清单清掉。
4. **multi-CC runtime 跑通**：`/session:add-agent` 真的 spawn (CC, PTY) 子树；`/session:remove-agent` teardown；MentionParser 解析的 name 能 lookup 到真 pid。

---

## 5. 关键开放问题（brainstorm 时要逐条回答）

### 5.1 ActorQuery 原语的形状

- **predicate 的语法**：keyword list (`[role: :cc_process, name: "helper"]`) ？map ？小型 DSL 节点 (`{:and, [...]}`)？
- **scope 的枚举**：`{:session, sid}` / `{:workspace, ws}` / `{:neighborhood, ws}` / `:global`。还要不要 `{:chat, chat_id}`（覆盖 Dim 2）？
- **返回值**：`[pid]` 还是 `[%ActorRef{actor_id, pid, attrs}]`？后者更利于调用方决定 first / round-robin / fan-out。
- **失效语义**：query 返回的 pid 之后死了怎么办？调用方负责 monitor 还是 ActorQuery 给 staleness signal？

### 5.2 Esr.Entity.Registry 升级

- 当前键是 `actor_id`。要扩成多属性倒排，怎么存？(a) 单 ETS 表多 secondary index？(b) `Registry` + 自定义 keys 列表？(c) GenServer + 内部 maps？
- 注册时机：peer `init/1` 同步注册（当前模式），还是异步以避免 init 阻塞？
- 反注册：peer terminate 时（current 模式），还是 monitor DOWN？两者并存？

### 5.3 spawn 模型重构

- **session 创建时 spawn 什么**：今天 spawn 整条 `pipeline.inbound`。multi-instance 之后：spawn "base pipeline"（FAA、admin-scope peers），CC/PTY 等 per-instance 子树由 `/session:add-agent` 触发？
- **(CC, PTY) 子树的 supervision strategy**：`:one_for_all`（PTY 崩则 CC 也重启）还是 `:one_for_one`（PTY 单独重启，CC 通过 query 重新拿到新 pid）？
- **DynamicSupervisor 的位置**：每 session 一个 DynamicSupervisor，挂在 session supervisor 下？
- **失败原子性**：`/session:add-agent` 的"InstanceRegistry insert"和"spawn (CC, PTY)"两个动作怎么保证一致？回滚？补偿？InstanceRegistry 是 SoT 还是 cache？

### 5.4 actor_id 与 name

- actor_id 用 InstanceRegistry 给的 UUID（已确认）。
- name 仅作显示——`/session:set-primary helper2` 这种 rename 不破坏 actor_id，FCP 缓存的 pid 不需要 invalidate。
- query 时是按 name 查（操作员视角）还是按 actor_id 查（runtime 视角）？两者都支持？

### 5.5 cap-based DSL 是后续还是当下

- 这次重构只做 §4.1-4.4？还是顺手把 capability advertisement (entity 声明 provides) 也做了？
- 如果只做寻路统一不做 cap：DSL 是后续 PR；今晚的 brainstorm 输出的 spec 是 unified-routing 不含 cap predicate。
- 如果一并做：spec 范围更大，要包含 capability 在 manifest 中的声明语法、CapabilityIndex 模块、`<peers>` 替换 `<reachable>` 的 LLM prompt 形态。

### 5.6 兼容期 / 迁移路径

- 一次性切换 vs. 分阶段：先实现 ActorQuery 原语并用之，state.neighbors 保留作为 cache 一段时间；待稳定后删 backwire / `state.neighbors`。
- 测试覆盖：哪些现有 ExUnit 必然 break（agent_spawner/_test、pty_process_test 的 patch 测试、cc_process_test 的 reachable_set 测试、entity_server_describe_topology_test 等）？提前列。
- e2e 风险：scenario 04（topology integration）会大改；scenario 07（plugin loader）影响较小。

### 5.7 时间窗

- 必须等 session-first model migration（todo §"Pending — design discussions" 第一行）落地。该工作可能重写 `agent_spawner` 大半，本次 brainstorm 的部分内容可能被它间接覆盖。
- 顺序：session-first 落地 → 复审本文档与 todo "Multi-agent metadata-vs-runtime gap [待检查]" → brainstorm session → spec → implementation worktree → PRs。

---

## 6. 不在范围

- **换消息模型**：BEAM 原生 actor send 不动，PR-3 纪律不动（数据平面 direct send，PubSub 仅控制面 7 topic family）。
- **跨 esrd 路由**：仍是单 esrd 内的 actor query；多 esrd 联邦是另一个 spec。
- **cap_guard 改造**：DSL 是 actor discovery 层，cap_guard 是 authorization 层，互不干扰。
- **新建 broker / NATS / Kafka 之类**：不需要。

---

## 7. 证据指针（避免记忆失真）

| 主题 | file:line |
|---|---|
| state.neighbors 单数 keying | `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:666,711`，`runtime/lib/esr/plugins/claude_code/cc_process.ex:380,409-414` |
| backwire 双向 patch | `runtime/lib/esr/session/agent_spawner.ex:263-282,342-384` |
| restart rewire | `runtime/lib/esr/entity/pty_process.ex:309-335` |
| workspace.neighbors 字段定义 | `runtime/lib/esr/resource/workspace/registry.ex:55,587,604` |
| 对称闭包编译 | `runtime/lib/esr/topology.ex:75-118` |
| `<reachable>` LLM render | `runtime/lib/esr/plugins/claude_code/cc_process.ex:115,141,526,592-614` |
| describe_topology 字段白名单 | `runtime/lib/esr/entity/server.ex:820`，`runtime/lib/esr/resource/workspace/describe.ex:39-46` |
| InstanceRegistry（已存在元数据层） | `runtime/lib/esr/entity/agent/instance_registry.ex` |
| MentionParser | `runtime/lib/esr/entity/agent/mention_parser.ex` |
| ChatScope multi-session | `runtime/test/esr/resource/chat_scope/multi_session_test.exs` |
| add_agent（仅写 InstanceRegistry，不 spawn） | `runtime/lib/esr/commands/session/add_agent.ex` 全文 |
| PR-3 数据平面纪律（PubSub 白名单 + banned patterns） | `docs/notes/pubsub-audit-pr3.md` |
| futures: cap projection（早有预留） | `docs/futures/peer-session-capability-projection.md` |
| spec: actor topology routing 原始设计 | `docs/superpowers/specs/2026-04-27-actor-topology-routing.md`（如果还在 origin/dev）；操作员视角注解：`docs/notes/actor-topology-routing.md` |

---

## 8. 这份材料的用途

不是 spec。是下一次 brainstorm session 的**起点**：

1. 用 `superpowers:brainstorming` skill 跑一次，把 §5 每个问题逐条 grill，落实成决策。
2. 决策落实后，写 spec 到 `docs/superpowers/specs/<date>-multi-instance-routing-cleanup.md`。
3. spec 落实后，再 plan + 实施。
4. 实施前提是 session-first model migration 已落地。

如果在 brainstorm 之前发现本文档中某条事实已过时（例如 session-first 重构间接修复了 §3 的某些项），先更新本文档再开 brainstorm。
