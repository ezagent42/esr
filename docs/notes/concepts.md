# ESR 概念词汇 (concepts vocabulary)

**Date:** 2026-05-02 (P1-1 brainstorm 输出)
**Audience:** 任何在 ESR 仓库里读代码、写 spec、或讨论架构的人——人类或 AI
**Status:** prescriptive（目标态定义；今天某些 entity 和这个定义有偏差，由后续 PR 修齐）

---

## 这份文档为什么存在

ESR 长出来的过程中，几个核心 noun 反复被混用：session 和 peer、chat 和 thread、adapter 和 handler、user 和 principal。这些混淆导致 PR 评审时反复绕路，spec 写出来歧义，代码注释相互矛盾。这份文档把所有 load-bearing noun 写下来，每个明确"是什么 / 不是什么 / 在哪持久化 / 跟谁关联"。

读它的目标：

- 写新模块 / 新 yaml entry 时，先确认你要表达的概念在这份文档里叫什么
- review PR 时，如果两个人对同一个 noun 的理解不同，回到这份文档对齐
- 写 spec 时，**只**用这份文档里的 noun，不发明同义词

---

## 一、4 轴 taxonomy 总览

ESR 的所有 noun 落在 4 个**正交**轴上：

| 轴 | 中文 | 含义 | 内含 noun |
|---|---|---|---|
| **A** | Context | 命名的 work container 实例（ESR 代为管理的命名物） | workspace, session, chat, thread |
| **B** | Entity | 有 identity 的命名代码模块 / 配置对象 / 人；通过 **role** trait 分类 | user, principal, agent, adapter, handler, *和具体的 pipeline-node 实体（FCP / cc_process / pty_process / 等等）* |
| **C** | Resource | 有限可数的 OS / wire / runtime 物，由 entity 占有和管理 | OTP actor (process), channel, pty, os process, websocket connection, ETS table, pubsub topic |
| **D** | Interface | cross-cutting 授权 + dispatch 层；连接 B 和 A 的桥 | capability, grant, role (perm preset), slash command, kind, slash route, command module, admin queue |

**4 轴是正交的**：A 加新 container 类型 / B 加新 entity / C 加新 resource / D 加新 cap or slash 这四件事相互独立。一个具体的"东西"可能在多个轴上有投影（一个 running session 在 A 上是 session 实例；在 C 上是若干个 OTP actor），但**轴本身不嵌套**。

OTP supervisor tree 的层级（如 SessionsSupervisor → Session → 个体 actor）是 **C 内部 lifecycle 安排**，不是 A 和 C 的概念层级。代码 supervisor tree 的方向 ≠ 概念抽象的方向。

---

## 二、A Context — 任务空间

### workspace

- **是什么**：一个命名的项目上下文。包含 owner（哪个 esr-user 拥有）、role（这个 workspace 启用的 perm preset）、chats（绑了哪些外部对话）、root（git repo 根目录）。
- **不是什么**：不是 git repo 本身（`root` 字段指向 repo）；不是 session（一个 workspace 可以同时跑多个 session）；不是 chat（一个 workspace 可以绑多个 chat）。
- **标识**：`workspaces/<name>` URI。`name` 全局唯一。
- **持久化**：`~/.esrd-<env>/<instance>/workspaces.yaml` 一个 entry per name。
- **关系**：1 workspace ⊃ N session（A）；1 workspace ⊃ N chat（A）；1 workspace 1 owner（B user）；1 workspace 1 role（D）。
- **例子**：`esr-dev` workspace，owner=`linyilun`，role=`dev`，chats=`[oc_xxx@cli_yyy]`，root=`/Users/h2oslabs/Workspace/esr`。

### session

- **是什么**：一个 agent（B）在一个 workspace（A）上运行起来的工作实例。有自己的 cwd（从 workspace.root + branch + worktree 推导）、若干 OTP actor（C）实现它的 pipeline、零或多个 chat 绑定。
- **不是什么**：不是 OS 进程（一个 session 通常包含若干 OS 进程，不只是一个）；不是 chat（chat 是外部对话，session 是 ESR 内部的运行实例；一个 chat 在一时刻只有一个"current" session）；不是 OTP supervisor（session 在代码里是 Supervisor，但概念上 session 是它管理的状态聚合，不是 supervisor 这个 OTP 原语）。
- **标识**：`sessions/<sid>` URI；`sid` 是 20 字节 base32 在创建时生成。
- **持久化**：
  - `Esr.SessionRegistry`（ETS 表，运行时态）：两个表 `:esr_session_chat_index`（路由键 `(chat_id, app_id) → sid`，PR-21λ 之后；不再含 thread_id）和 `:esr_session_name_index`（name lookup）。
  - `~/.esrd-<env>/<instance>/session-ids.yaml`（claude resume 索引，跨重启用；由 `scripts/esr-cc.sh` 写入）。
  - 进程结束自动反注册。
- **关系**：1 session 1 agent（B）；1 session ⊂ 1 workspace（A）；1 session 0..1 chat-current 绑定（A）；1 session N OTP actors（C）实现它的 pipeline。
- **例子**：sid=`6SCNL5XF4HW2VPM6TXXQ`，agent=`cc`，workspace=`esr-dev`，cwd=`<root>/.worktrees/<branch>`。

### chat

- **是什么**：外部平台（今天是 Feishu）的对话单元。在 ESR 内部用作路由键，用来找到对应的 session。
- **不是什么**：不是 thread（thread 是 chat 内子对话）；不是 session（chat 是平台标识，session 是 ESR 运行实例）。
- **标识**：`workspaces/<ws>/chats/<chat_id>` URI；`chat_id` 是平台 id（Feishu 的 `oc_xxx`）。
- **持久化**：`workspaces.yaml` 的 `chats[]` 数组，每条带 `{chat_id, app_id, kind}`。
- **关系**：1 chat ⊂ 1 workspace（A）；1 chat 0..1 current session（A）+ N parked sessions（PR-21λ chat-current 模型）。
- **例子**：chat_id=`oc_d9b47511b085e9d5b66c4595b3ef9bb9`, app_id=`cli_a9563cc03d399cc9`, kind=`feishu`。

### thread

- **是什么**：chat 内的子对话。Feishu 平台的 `om_xxx` 标识符。
- **不是什么**：**不是路由维度**（PR-21λ 之后路由键是 `(chat_id, app_id)`，thread_id 不再参与）；不是 session 标识；不是独立可寻址的单元。
- **标识**：仅在 envelope 里以 `thread_id` 字段出现，不进入 ESR 的 URI 命名空间。
- **持久化**：不持久化，仅在 inbound envelope 中携带。
- **关系**：从 envelope 流过 SessionRouter → SessionProcess.metadata，给 cc_mcp 用作 Feishu reply API 的 quoting 参数。
- **例子**：`om_x100b506b466850a0c223a91e803e548`。
- **历史包袱**：thread 之前是路由维度（`SessionRegistry` 的 key 包含它），PR-21λ 显式去掉。今天 thread 是"半活"概念——envelope 里还存在，但只为 reply API 使用，不参与会话定位。未来可能彻底退出（直接由 cc_mcp 自己保留 reply context）。

---

## 三、B Entity — 实体

每个 entity 实现一个 **role trait**（见 `docs/notes/actor-role-vocabulary.md`）。role 是 entity 的二级分类，不是独立的 noun。

### user (esr-user)

- **是什么**：ESR 自己定义的人类用户实体。`username` 是主键，跨多个 principal（外部平台身份）。
- **不是什么**：不是 principal（principal 是外部平台身份；user 是 ESR 抽象身份）；不是 agent（agent 是 AI / 自动化）。
- **标识**：`users/<username>` URI；`username` 全局唯一，由 `esr user add` 创建。
- **持久化**：`~/.esrd-<env>/<instance>/users.yaml`，每条带 `{username, feishu_ids[], ...}`。
- **关系**：1 user N principal（绑定关系）；1 user 拥有 N grant（D）；1 user 拥有 N workspace（A）。
- **例子**：`linyilun`，feishu_ids=`[ou_6b11faf8...]`。

### principal

- **是什么**：外部平台（Feishu）的人类身份；`ou_xxx` 形态。inbound envelope 里以 `principal_id` 字段携带。
- **不是什么**：不是 esr-user（虽然 bind-feishu 之后 `linyilun` 是 esr-user，`ou_xxx` 是 principal，二者通过 binding 关联，但身份语义不同）；不是 user 的别名（一个 user 可以有多个 principal）。
- **标识**：URI 形式 `users/<ou_xxx>`（注意：URI namespace 共享 `users/` 前缀，但 path id 是 ou_xxx 还是 username 取决于上下文，未来 PR 计划纯 esr-username 化）。
- **持久化**：作为 `feishu_ids` 数组项存于 `users.yaml`；运行时 envelope 字段。
- **关系**：principal → bind → user（B）；inbound envelope 携带 principal_id，handler 通过 user binding resolve 到 esr-username。
- **例子**：`ou_6b11faf8e93aedfb9d3857b9cc23b9e7`（linyilun 在 Feishu app `cli_a9563cc03d399cc9` 下的 open_id）。

### agent

- **是什么**：可在 session 里运行的 AI / 自动化的**类型**。在 `agents.yaml` 里声明，包含 `description`、`capabilities_required`、`pipeline.{inbound, outbound}`、`proxies`、`params`。
- **不是什么**：不是 session（agent 是 type，session 是 instance）；不是 adapter（adapter 是外部协议桥，agent 是 ESR 内部的 pipeline 配方）；不是任何具体 entity（agent 只是声明它的 pipeline 由哪些其他 entity 组成）。
- **标识**：在 `agents.yaml` 里以 key 出现（如 `cc`, `cc-voice`）；没有独立 URI namespace。
- **持久化**：`<runtime_home>/agents.yaml`（即 `~/.esrd-<env>/<instance>/agents.yaml`，由 `Esr.Application.load_agents_from_disk/0` 在 boot 时加载到 `Esr.SessionRegistry`）+ test fixture（`runtime/test/esr/fixtures/agents/{simple,voice}.yaml`）。
- **关系**：1 agent → N session 实例（A）；1 agent → declares pipeline of B entities (FCP / cc_proxy / cc_process / pty_process / 等)。
- **例子**：`cc`（claude code agent）；pipeline: `[feishu_chat_proxy, cc_proxy, cc_process, pty_process]`。

### adapter

- **是什么**：外部协议桥的代码模块 + 实例配置。**类型**（`feishu` adapter 类型代码）通过 `feishu_adapter_runner` Python 包实现；**实例**（`feishu/app_dev`, `feishu/app_prod`）通过 `adapters.yaml` 声明，每个实例对应一个 OS process（Python sidecar）。
- **不是什么**：不是 handler（adapter 是和外部世界通信的桥；handler 是事件处理函数）；不是 agent（adapter 是 transport-level，agent 是 application-level pipeline）；不是 OS process 本身（OS process 是 C 资源，承载 adapter 代码）。
- **标识**：`adapters/<platform>/<instance_id>` URI（如 `adapters/feishu/app_dev`）。
- **持久化**：实例配置在 `~/.esrd-<env>/<instance>/adapters.yaml`；类型代码在 `adapters/<name>/` 目录。
- **关系**：1 adapter type N instance（type 复用，instance 各占一个 sidecar process）；adapter instance ↔ external platform connection（C 资源：WS / HTTP）。
- **role trait**：Boundary（`*Adapter` 后缀）。
- **例子**：`adapters/feishu/cli_a9563cc03d399cc9`（生产 Feishu adapter 实例）。

### handler

- **是什么**：在事件流中处理特定 actor_type 事件的纯函数模块。Python `@handler(actor_type=..., name=...)` 装饰；要求 purity（只 import `esr` SDK + 自己的 package）。
- **不是什么**：不是 adapter（handler 不直接和外部通信，只处理 envelope）；不是 stateful（handler 是 pure，state 由 SDK 在外部托管）；不是 OS process（handler 实例是 invocation-临时的，跑完即结束）。
- **标识**：`handler/<name>` URI（legacy 形式）；name 在装饰器 + `esr.toml` 声明（如 `feishu_thread`, `cc_session`）。
- **持久化**：代码在 `handlers/<name>/`；运行时由 `cc_adapter_runner` / `feishu_adapter_runner` 等 sidecar 加载并 dispatch。
- **关系**：handler 接收某 actor_type 的 event，返回 (new_state, [Action])；不持有跨 invocation 的 state。
- **role trait**：Pipeline（功能上属于消息链节点，虽然在 actor-role-vocabulary 里 "*Handler" 落 Pipeline 后缀）。
- **例子**：`feishu_thread.on_msg`：actor_type=`feishu_thread_proxy`，处理 `msg_received` 和 `cc_output`。

### pipeline-node entity（FCP, cc_process, pty_process, 等）

> 旧代码里这些被叫 "peer"，今天概念上避免使用 "peer" 这个词——它会和 "OTP actor / process" 混淆。

- **是什么**：在 session 的 inbound / outbound 消息链上担任固定 role 的命名 Elixir 模块。每个模块在 `agents.yaml.pipeline` 里以 `{name, impl: Esr.Peers.<Module>}` 声明。
- **不是什么**：不是 OTP actor（actor 是 C 资源；这是它的代码定义）；不是 session 的子概念（session 在运行时实例化它们；模块本身是跨 session 复用的）；不是 trait（这是带 role trait 的具体 entity）。
- **标识**：模块名（如 `Esr.Peers.FeishuChatProxy`），运行时 actor 通过 `Esr.PeerRegistry` 用 binary actor_id 注册（如 `pty:<sid>`）。
- **持久化**：代码在 `runtime/lib/esr/peers/`；运行时实例由 SessionsSupervisor → Session → PeerSupervisor 管理。
- **关系**：1 entity → N session（每个 session 各起一份 actor）；entity 通过 role trait 分类（Pipeline / State / Boundary 等）。
- **role trait** 列举（举例）：
  - `Esr.Peers.FeishuChatProxy`（FCP）— Pipeline，会话级路由代理
  - `Esr.Peers.CCProcess` — Pipeline + State，cc-mcp 的 Elixir 端
  - `Esr.Peers.PtyProcess` — State（OS process 句柄持有者）
  - `Esr.Peers.CCProxy` — Pipeline，stateless
  - `Esr.Peers.FeishuAppProxy` — Pipeline，stateless
- **例子**：FCP 实例 PID `<0.1234.0>`，注册为 `actor/feishu_chat_proxy:<sid>`，跑在 Esr.SessionsSupervisor → Session(<sid>) → PeerSupervisor 之下。

### admin entity（FAA / SlashHandler / Dispatcher / 等）

- **是什么**：admin tier 的实体——不绑某个 session，全局存活。包括 `Esr.AdminSession.Dispatcher`（管理员命令分发）、`Esr.Peers.SlashHandler`（slash 命令解析）、`Esr.Peers.FeishuAppAdapter`（Feishu app 实例 admin proxy）。
- **不是什么**：不是 session 一部分（admin 跨 session 全局可达）；不是 user-facing entity（user 看不到它们；通过 slash → dispatcher 间接交互）。
- **标识**：`admin/<instance_kind>_<id>` URI（如 `admin/feishu_app_adapter_cli_a956...`）；`Esr.PeerRegistry` 注册。
- **持久化**：单例 / DynamicSupervisor 子，由 `Esr.AdminSession.Supervisor` 启动。
- **关系**：admin entity 接收来自 session 的请求（如 FAA 收到来自 session FCP 的 send_message 请求）；admin entity 全局共享。
- **role trait**：Control（Dispatcher、Watcher）+ Boundary（FAA 是 admin tier 的 boundary）。
- **例子**：`Esr.AdminSession.Dispatcher` 管 admin queue 文件；FAA 实例 `feishu_app_adapter_cli_a9563cc03d399cc9` 担任 Feishu app `cli_a956...` 的 outbound 代理。

---

## 四、C Resource — 资源

### OTP actor (process)

- **是什么**：BEAM 的 GenServer / Supervisor 实例，由某个 entity（B）的代码定义产生。有 pid、mailbox、state、lifecycle。
- **不是什么**：不是 entity（entity 是代码模块；actor 是模块的运行时实例）；不是 OS 进程（OTP actor 是 BEAM 内部 lightweight process，N 个 actor 共享一个 OS process = beam.smp）。
- **标识**：pid（运行时短期），actor_id（`Esr.PeerRegistry` 注册的 binary string，如 `pty:<sid>`），URI `actor/<actor_id>`（legacy 形式）。
- **持久化**：不持久化。actor 死亡 → registry 反注册。
- **关系**：1 actor 1 entity（runs the entity's code）；N actor 1 session（session 跑一组 actor 实现 pipeline）。
- **例子**：pid=`<0.1234.0>`，actor_id=`pty:6SCNL5XF4HW2VPM6TXXQ`，跑 `Esr.Peers.PtyProcess` 代码。

### channel

- **是什么**：cc_mcp 和 esrd 之间的双向通知管道。今天用 Phoenix.PubSub topic `cli:channel/<sid>` 实现：cc_mcp 通过 Phoenix Socket 加入这个 topic，esrd 在 topic 上 broadcast notification，cc_mcp 反向通过 socket 发送 tool_invoke 等 envelope。
- **不是什么**：不是 Phoenix.Channel（虽然底层用 Phoenix Channel 实现，但 ESR 概念上 "channel" 是 cc_mcp ↔ esrd 的应用层管道，跟 Phoenix 框架的 Channel 不是一个抽象层）；不是 PubSub topic（PubSub topic 是 BEAM 内部 fan-out 机制；channel 用了它但语义更高级）。
- **标识**：topic name `cli:channel/<sid>`；session_id 是定位 key。
- **持久化**：BEAM 进程态；session 死 → topic 自动消失。
- **关系**：1 session 1 channel（一对一绑定 session）；channel 由 `Esr.Peers.CCProcess` + `EsrWeb.ChannelChannel` 共同管理。
- **lifecycle 现状**：今天 channel 的生命周期和 PTY / cc_mcp 强绑（cc_mcp 死 → channel 失效）；A2 计划解耦 channel 独立于 PTY 生死。

### pty (pseudoterminal)

- **是什么**：Unix 伪终端的 master / slave 一对，由 erlexec 通过 `:pty` 选项创建，PtyProcess entity 占有 master。
- **不是什么**：不是 OS process（pty 是 fd 对，跟 process 是分开的概念）；不是 ws connection（pty 是 OS 层抽象，ws 是 transport 层）。
- **标识**：master fd（运行时态，不暴露 URI）。
- **持久化**：不持久化。OS 内核管理。
- **关系**：1 pty 1 PtyProcess actor（C 内部的 1:1）；N pty N OS process（`bash -c esr-cc.sh ...` 的 stdin/stdout 接到 pty slave）。
- **生命周期事件**：browser attach → WS → 写入 master；OS process 写 stdout → master 读出 → fan-out 到 PubSub topic `pty:<sid>`。

### os process

- **是什么**：操作系统进程。由 erlexec 通过 `:exec.run_link/2` 启动。在 ESR 中典型的 OS process 是：claude（agent 主体）、Python adapter sidecar、Python handler runner。
- **不是什么**：不是 OTP actor（OS process 是 BEAM 外的 process，开销 MB 级；OTP actor 是 BEAM 内 lightweight，KB 级）；不是 entity（entity 是 ESR 抽象，OS process 是 entity 的 runtime 资源之一）。
- **标识**：os_pid（整数）；erlexec 跟踪。
- **持久化**：erlexec 维护 token-based 监控；BEAM 重启 → 旧 OS process orphan（PR-21β 的 ESR_SPAWN_TOKEN 防御此场景）。
- **关系**：1 os process 1 entity actor（PtyProcess 占有一个 OS process；adapter sidecar 占有一个）。
- **例子**：claude pid=`44262`，PPID=PtyProcess actor 通过 erlexec exec-port 间接 own。

### websocket connection (attach socket)

- **是什么**：浏览器和 esrd 之间的二进制 WebSocket 连接，URL 形如 `ws://<host>/attach_socket/websocket?sid=<sid>`，承载 PTY 的 stdin/stdout 双向流。PR-24 之后是裸 binary 而非 Phoenix.Channel JSON。
- **不是什么**：不是 channel（channel 是 cc_mcp ↔ esrd 的通知管道；attach 是浏览器 ↔ esrd 的 PTY pipe）；不是 Phoenix.Channel（虽然基础设施都是 Phoenix，但 attach socket 走 `Phoenix.Socket.Transport` 自定义 transport，不走 Channel）。
- **标识**：URL（`/attach_socket/websocket?sid=<sid>`）。
- **持久化**：BEAM 进程态（`EsrWeb.PtySocket` 的 transport process）；浏览器关页 → connection 关。
- **关系**：1 session N 同时 attach（多个浏览器可以同时看一个 session 的 PTY）；每个 connection 订阅 PubSub topic `pty:<sid>`。

### ETS table

- **是什么**：BEAM 的 in-memory key-value 表。ESR 用作运行时 registry：`Esr.SessionRegistry`（session 路由）、`Esr.Capabilities.Grants`（cap 缓存）、`Esr.PeerRegistry`（actor_id → pid）。
- **不是什么**：不是 yaml file（yaml 是 cold storage，ETS 是 hot in-memory）；不是 GenServer state（ETS 是共享表，多个 process 可读写；GenServer state 是 process-local）。
- **标识**：table name (atom)；e.g. `:esr_session_registry`。
- **持久化**：不持久化。BEAM 重启 → 表清空（部分 registry 通过 yaml file 重建）。
- **关系**：被一组 entity（通常是 `*Registry` entity）封装；外部代码不直接读 ETS，通过 entity 的 API。

### pubsub topic

- **是什么**：Phoenix.PubSub 的命名 fan-out 频道。subscriber 加入 topic，publisher broadcast → 所有 subscriber 收到。
- **不是什么**：不是 channel（channel 是应用层抽象；topic 是底层机制）；不是 Phoenix.Channel（Phoenix.Channel 也用 PubSub，但 Channel 是带 socket 的 client-facing 抽象；topic 是纯 server-internal）。
- **标识**：topic name（string）。
- **持久化**：不持久化。
- **命名约定**（今天的几个 topic）：
  - `pty:<sid>` — PTY stdout fan-out（PtyProcess publishes，attach socket / FCP boot bridge subscribes）
  - `cli:channel/<sid>` — cc_mcp ↔ esrd channel（cc_mcp + ChannelChannel 双方通过这个 topic）
  - `pty_attach/<sid>` — browser attach 通知（PtySocket publishes，FCP subscribes 用来 cancel boot bridge timer）
  - `cc_mcp_ready/<sid>` — cc_mcp 加入 channel 的信号

---

## 五、D Interface — 接口

### capability

- **是什么**：命名的权限 token。形如 `<scope>:<resource>/<action>`（如 `session:default/create`、`pty:default/spawn`）。
- **不是什么**：不是 grant（cap 是声明，grant 是 grant；cap 在代码里声明 "需要这个 cap 才能做 X"，grant 在 yaml 里说 "principal P 拥有这个 cap"）；不是 role（role 是 cap 的预设组合）。
- **标识**：cap string 本身（无 URI）。
- **持久化**：在 slash-routes.yaml 的 `permission` 字段、agents.yaml 的 `capabilities_required` 字段、capabilities.yaml 的 `<principal>: [caps]` 字段中出现。
- **关系**：cap 是 D 的中心 noun，关联 B（用户/agent 拥有 cap）+ A（cap 控制对哪些 container 的操作）+ slash route。
- **例子**：`session:default/create`（创建 session 的权限）、`pty:default/spawn`（启动 OS process 的权限，原 `tmux:default/spawn` PR-25b 改名）。

### grant

- **是什么**：principal / esr-user 拥有某个 capability 的 binding。
- **不是什么**：不是 cap 本身；不是 role（role 是 cap 集合，grant 是单条 binding）。
- **标识**：grant 是 `(principal\|user, [caps])` 关系，由 ETS 表 `Esr.Capabilities.Grants` 持有。
- **持久化**：`~/.esrd-<env>/<instance>/capabilities.yaml`（cold）+ ETS 表 `:esr_capabilities_grants`（hot）。
- **关系**：1 user N grant；1 grant 0..1 cap（每条 grant 一个 cap，wildcard `*` 是特殊形式）。
- **例子**：`linyilun: ["*"]`（所有权限）；`ou_xxx: ["session:default/create"]`（仅创建 session）。

### role (perm preset)

- **是什么**：workspace 的权限 + 行为预设，定义"在这个 workspace 里 ESR / agent 的能力是哪些"。包含 settings.json（agent 行为参数）。
- **不是什么**：不是 actor-role-vocabulary 里的 role trait（那是 entity 的功能分类）；不是 user 的"角色"（user 没有"角色"概念，user 通过 grant 取得 cap）。
- **标识**：name（如 `dev`, `diagnostic`），路径 `roles/<name>/`。
- **持久化**：`roles/<name>/settings.json`（仓库内）。
- **关系**：1 workspace 1 role；1 role N workspace 复用。
- **例子**：`dev` role（standard development），`diagnostic` role（带 `_echo` tool 的诊断模式）。

### slash command

- **是什么**：用户在 chat 里敲的 `/X args` 形态命令。inbound envelope 携带原文，SlashHandler 解析。
- **不是什么**：不是 kind（kind 是规范化后的 dispatch key；slash command 是 user-facing 文本）。
- **标识**：原文 string（如 `/new-session esr-dev name=t1`）。
- **持久化**：不持久化（一次性 envelope）。
- **关系**：slash command → SlashHandler 解析 → 输出 (kind, args) → Dispatcher 派发到 command module。

### kind

- **是什么**：slash command 的规范化 dispatch identifier。在 `slash-routes.yaml` 里以 entry key 出现，是 Dispatcher 路由的依据。
- **不是什么**：不是 slash command 字面量（用户敲的是 `/new-session`，kind 是 `session_new`）；不是 command module 名（kind 在 yaml 里映射到 module）。
- **标识**：snake_case 字符串（如 `session_new`, `session_end`, `workspace_new`）。
- **持久化**：runtime 用 `~/.esrd-<env>/<instance>/slash-routes.yaml`（live config，watcher reload 不重启）；模板 `runtime/priv/slash-routes.default.yaml`。
- **关系**：1 slash command 1 kind（解析后映射）；1 kind 1 command module（B：`Esr.Admin.Commands.<Kind>`）。

### slash route

- **是什么**：`slash-routes.yaml` 里的一条 entry，把 kind 映射到 command module + permission + binding requirements。
- **不是什么**：不是 kind 本身；不是 command module 本身（route 是 yaml-level 的连接）。
- **标识**：yaml entry key 是 kind。
- **持久化**：runtime 用 `~/.esrd-<env>/<instance>/slash-routes.yaml`（live config，watcher reload 不重启）；模板 `runtime/priv/slash-routes.default.yaml`。
- **schema**：`{kind: {permission, command_module, requires_workspace_binding, requires_user_binding, ...}}`。
- **例子**：
  ```yaml
  session_new:
    permission: session:default/create
    command_module: Esr.Admin.Commands.Session.New
    requires_workspace_binding: true
    requires_user_binding: true
  ```

### command module

- **是什么**：执行某个 kind 的 Elixir 模块。`Esr.Admin.Commands.<Kind>` 命名，实现 `execute/1` 或 `execute/2`。
- **不是什么**：不是 handler（handler 是事件处理 / Python；command module 是 admin 命令执行 / Elixir）；不是 admin entity 本身（command module 在 Dispatcher 处理一个 admin command 时被调用，不是常驻 GenServer）。
- **标识**：模块名 `Esr.Admin.Commands.Session.New` 等。
- **持久化**：代码在 `runtime/lib/esr/admin/commands/`。
- **关系**：1 kind 1 command module。
- **role trait**：Control（`Commands.<Kind>` 后缀）。

### admin queue

- **是什么**：基于文件系统的 admin command 队列。slash 触发后，Dispatcher 把 admin command 写到 `pending/` 目录；执行完成后移到 `completed/` 或 `failed/`。
- **不是什么**：不是消息队列（不是 RabbitMQ 或类似）；不是 ETS 表（admin queue 是 fs-based，跨 BEAM 重启可见）。
- **标识**：admin_id（26-char base32）；文件路径 `~/.esrd-<env>/<instance>/admin_queue/{pending,completed,failed}/<admin_id>.yaml`。
- **持久化**：fs；显式由 Dispatcher 管理。
- **schema**：`{id, kind, submitted_by, submitted_at, args, [result]}`。
- **例子**：scenario_07 通过写 `pending/<id>.yaml` 来触发 session_new。

---

## 六、跨轴关系

```
       ┌──────────────────────────────────┐
       │  D Interface (cap / grant / role / slash)
       │     │ 控制 B 对 A 的操作
       ▼     ▼
┌──────────┐    通过实例化为 actor (C)    ┌──────────┐
│ B Entity │ ────────────────────────────▶│ C Resource│
│ (user /  │                               │ (actor /  │
│ agent /  │       占有 / 管理              │ pty /     │
│ adapter /│                               │ channel / │
│ handler /│                               │ os proc / │
│ ...)     │                               │ ws conn ) │
└──────────┘                               └──────────┘
      │                                         ▲
      │ 在 A 上工作                              │ 实现 A 的运行
      ▼                                         │
┌──────────────────────────────────────────────┴┐
│ A Context (workspace / session / chat / thread)│
└────────────────────────────────────────────────┘
```

- **B → A**: subject 在 container 上做事
- **D 拦截 B → A**: 每次 B 想作用于 A，D 检查它有没有相应的 cap
- **B 通过 C 实现 B → A**: B 不直接操作 A；它通过 owning C resource 来间接实现操作（agent 通过它的 pipeline 上的 actors 来操作 session）
- **C 实现 A**: A 的运行表现 = 一组 C resource（session 实例 = 它的 pipeline actor 集合 + pty + channel）

---

## 七、命名学约定

- **doc / spec 用语**：本文档列的 noun 是规范用法。讨论时如果发现某个 noun 在本文档没有，先问"这是不是已有 noun 的别名？"，要么对齐到已有 noun，要么提议新 noun 并加进 doc。
- **代码 namespace 不立即跟随**：`Esr.Peers.*` 命名空间今天保留（rename 是 A2 territory）。但**代码注释和 docstring 应当用本文档的 noun**，避免在注释里说 "peer" 这种含糊词。
- **跨语言保持一致**：Python sdk（`py/src/esr/uri.py`）和 Elixir（`runtime/lib/esr/uri.ex`）共享 URI grammar；新增 noun 时两边同步加。
- **role trait** 是 B 的二级分类（actor-role-vocabulary.md 的 5 类：Boundary / State / Pipeline / Control / OTP），不是独立的 noun。

---

## 八、相关文档

- `docs/notes/actor-role-vocabulary.md` — entity 的 role trait 5 类详细定义
- `docs/notes/esr-uri-grammar.md` — URI grammar 完整语法
- `docs/futures/todo.md` — 当前 P2/P3 任务列表，许多任务直接消化本文档定义
- `runtime/lib/esr/uri.ex:33-34` — URI 类型 source of truth

## 九、待办（这份文档没有覆盖但应当有）

- `concept-conflations.md`（独立文档）：列今天还存在的混淆 + 收敛方向（PR-25b 之后的 capability vocab；admin entity 的 URI 命名约定；channel lifecycle 解耦；等等）
- 各 entry 的 P2 引用：当 P2 PR 修齐 conflation 时，回填到本文档"reference PR" 字段
