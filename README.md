# ESR — Elixir Social Runtime

> Reference implementation of the [ESR Protocol v0.3](docs/design/ESR-Protocol-v0.3.md).
> An Elixir/OTP runtime + Python adapter SDK that connects IM channels (Feishu, …)
> to LLM sessions (Claude Code, …) via a declarative actor topology.

[English](#english) · [中文](#中文)

---

## English

### What ESR is

ESR ("Elixir Social Runtime") routes inbound messages from IM platforms through
a per-user **session** — a supervisor subtree of typed peers — into an LLM
process, and routes the LLM's tool calls back out as outbound IM directives.

The runtime is one fixed substrate; **agents** are declarative pipelines authored
in `agents.yaml` (see [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md)).

```
Feishu user ─► feishu sidecar ─► FeishuAppAdapter ─► FeishuChatProxy ─► CCProxy
                                                                              │
                                                                              ▼
            Feishu user ◄── feishu sidecar ◄── FeishuAppAdapter ◄── … ◄── CCProcess ◄── tmux ◄── claude
```

The chain is bidirectional and per-session — declared once in `agents.yaml`,
spawned on first inbound, and reaped when the user ends the conversation.

### Quick start (5 minutes)

Prerequisites: Elixir 1.16+, Erlang/OTP 26+, Python 3.11+, [`uv`](https://docs.astral.sh/uv/),
tmux 3.3+, a Claude Code CLI installed, a Feishu app (or use mock_feishu for local dev).

```bash
# 1. Install runtime deps
(cd runtime && mix deps.get)

# 2. Boot esrd (long-running supervisor — registers under launchctl by default)
bash scripts/esrd.sh start --instance=default

# 3. Register a Feishu app (or skip and use mock_feishu)
./esr.sh adapter add feishu-prod --type feishu \
    --app-id <app_id> --app-secret <app_secret>

# 4. Register a workspace
./esr.sh workspace add esr-dev \
    --cwd ~/Workspace/esr --start-cmd scripts/esr-cc.sh \
    --role dev --chat <chat_id>:<app_id>:dm

# 5. In Feishu, DM the bot:  /new-session esr-dev tag=root
#    A tmux window appears hosting a Claude Code session with esr-channel MCP loaded.
```

See [`docs/dev-guide.md`](docs/dev-guide.md) for handler / adapter / pattern authoring.

### Status (2026-04-28)

| Layer | State | Reference |
|---|---|---|
| Actor runtime (Elixir) | shipped through PR-F | [`docs/architecture.md`](docs/architecture.md) |
| Multi-app routing | shipped (PR-A) | [`docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`](docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md) |
| Single-lane auth | shipped (Lane A drop) | [`docs/notes/auth-lane-a-removal.md`](docs/notes/auth-lane-a-removal.md) |
| Actor topology + reachable_set | shipped (PR-C) | [`docs/superpowers/specs/2026-04-27-actor-topology-routing.md`](docs/superpowers/specs/2026-04-27-actor-topology-routing.md) |
| Business-topology MCP tool | shipped (PR-F) | [`docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`](docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md) |
| Voice (Volcengine pivot) | partial — voice-web demo only | [`docs/notes/voice-gateway-never-materialized.md`](docs/notes/voice-gateway-never-materialized.md) |

### Repository layout

| Path | Contents |
|---|---|
| `runtime/` | Elixir/OTP runtime — peers, supervisors, session router, capability gates |
| `adapters/cc_mcp/` | Python MCP bridge for Claude Code; renders inbound as `<channel>` tags |
| `adapters/feishu/` | Per-channel sidecar |
| `handlers/` | Pure-function `(state, event) → (state, actions)` handlers |
| `patterns/` | Declarative command patterns (DSL → yaml) |
| `py/` | `esr` CLI + shared Python helpers |
| `scripts/` | `esrd.sh`, scenario spawners, daemoniser |
| `tests/e2e/scenarios/` | End-to-end shell scenarios (mock_feishu driven) |
| `roles/{dev,diagnostic}/CLAUDE.md` | Per-role CC session prompt prelude |
| `docs/` | All long-form documentation (see map below) |

### Documentation map

**Architecture / design**
- [`docs/architecture.md`](docs/architecture.md) — module tree (engineer's map)
- [`docs/design/ESR-Protocol-v0.3.md`](docs/design/ESR-Protocol-v0.3.md) — canonical protocol spec
- [`docs/design/ESR-Reposition-v0.3-Final.md`](docs/design/ESR-Reposition-v0.3-Final.md) — product framing

**Authoring**
- [`docs/dev-guide.md`](docs/dev-guide.md) — handler / adapter / pattern authoring
- [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md) — agent topology guide (中文)
- [`docs/cookbook.md`](docs/cookbook.md) — recipe-style how-tos

**Operations**
- [`docs/operations/dev-prod-isolation.md`](docs/operations/dev-prod-isolation.md) — running dev + prod side by side
- [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md) — pre-existing test flakes
- [`docs/notes/actor-topology-routing.md`](docs/notes/actor-topology-routing.md) — operator note for topology / `workspaces.yaml`

**Specs (per PR)**
- See [`docs/superpowers/specs/`](docs/superpowers/specs/) — every shipped feature has a `YYYY-MM-DD-<topic>.md` spec.

**Field notes** ([`docs/notes/`](docs/notes/))
Subject-organised lessons. Index at [`docs/notes/README.md`](docs/notes/README.md).

### E2E test scenarios

End-to-end coverage lives in [`tests/e2e/scenarios/`](tests/e2e/scenarios/). Every
new scenario MUST be linked here — that is the single index for running and
discovering live flows.

| Scenario | Covers | Spec |
|---|---|---|
| [`01_single_user_create_and_end.sh`](tests/e2e/scenarios/01_single_user_create_and_end.sh) | Single user — create / use / end session | [`docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md`](docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md) |
| [`02_two_users_concurrent.sh`](tests/e2e/scenarios/02_two_users_concurrent.sh) | Two users in parallel — isolation + capability gating | same |
| [`04_multi_app_routing.sh`](tests/e2e/scenarios/04_multi_app_routing.sh) | Cross-app forward — `app_id` propagation, capability denial | [`docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`](docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md) |
| [`05_topology_routing.sh`](tests/e2e/scenarios/05_topology_routing.sh) | `<channel reachable=…>` + BGP-style reachable_set learn | [`docs/superpowers/specs/2026-04-27-actor-topology-routing.md`](docs/superpowers/specs/2026-04-27-actor-topology-routing.md) |
| [`06_pty_attach.sh`](tests/e2e/scenarios/06_pty_attach.sh) | PTY actor attach — browser xterm renders cc TUI via WS | [`docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md`](docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md) |
| [`07_pty_bidir.sh`](tests/e2e/scenarios/07_pty_bidir.sh) | PTY actor bidirectional — keystroke → process → frame round-trip | same |

> When you add a scenario: register it in this table **and** in
> [`docs/notes/manual-e2e-verification.md`](docs/notes/manual-e2e-verification.md).

### Running tests

| Layer | Command | Count (2026-04-28) |
|---|---|---|
| Elixir runtime | `(cd runtime && mix test)` | 579 |
| cc_mcp Python bridge | `(cd adapters/cc_mcp && uv run --with pytest --with pytest-asyncio pytest)` | 32 |
| Per-scenario E2E | `bash tests/e2e/scenarios/0X_*.sh` | 5 scenarios |

Pre-existing flakes are tracked in [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md).

### CLI conventions

`./esr.sh <subcmd>` is a thin wrapper around `uv run --project py esr <subcmd>`
— call it from anywhere via absolute path or symlink.
A first-class binary on PATH is tracked at
[`docs/futures/esr-cli-binary.md`](docs/futures/esr-cli-binary.md).

### Contributing

- AI-pair-programming convention: see [`CLAUDE.md`](CLAUDE.md) for repo-level Claude
  Code guidance and the per-role primers under [`roles/`](roles/).
- Spec-first: every PR with behaviour change links a `docs/superpowers/specs/<date>-<topic>.md`.

### License

To be added.

---

## 中文

### 项目定位

ESR（Elixir Social Runtime）把 IM 平台的入站消息经过一棵**会话**子树
（typed peer 组成的 supervisor 子树）路由到 LLM 进程，再把 LLM 的工具调用
反向路由为出站 IM 指令。

运行时是固定底座；**agent** 是声明在 `agents.yaml` 里的拓扑（参见
[`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md)）。

```
Feishu 用户 ─► feishu sidecar ─► FeishuAppAdapter ─► FeishuChatProxy ─► CCProxy
                                                                                │
                                                                                ▼
       Feishu 用户 ◄── feishu sidecar ◄── FeishuAppAdapter ◄── … ◄── CCProcess ◄── tmux ◄── claude
```

链路双向且按 session 实例化 —— 在 `agents.yaml` 里声明一次，首条 inbound 触发
spawn，会话结束后回收。

### 5 分钟上手

前置条件：Elixir 1.16+ / Erlang/OTP 26+ / Python 3.11+ / [`uv`](https://docs.astral.sh/uv/) /
tmux 3.3+ / 已安装 Claude Code CLI / 一个 Feishu app（或用 mock_feishu 做本地开发）。

```bash
# 1. 安装 runtime 依赖
(cd runtime && mix deps.get)

# 2. 启动 esrd（常驻 supervisor，默认走 launchctl）
bash scripts/esrd.sh start --instance=default

# 3. 注册 Feishu app（或跳过，用 mock_feishu）
./esr.sh adapter add feishu-prod --type feishu \
    --app-id <app_id> --app-secret <app_secret>

# 4. 注册 workspace
./esr.sh workspace add esr-dev \
    --cwd ~/Workspace/esr --start-cmd scripts/esr-cc.sh \
    --role dev --chat <chat_id>:<app_id>:dm

# 5. 在 Feishu 给 bot 发：  /new-session esr-dev tag=root
#    会出现一个 tmux 窗口，里面是带 esr-channel MCP 的 Claude Code 会话。
```

详见 [`docs/dev-guide.md`](docs/dev-guide.md)（handler / adapter / pattern 写法）。

### 状态（2026-04-28）

| 层 | 状态 | 参考 |
|---|---|---|
| Actor runtime（Elixir） | 已发布到 PR-F | [`docs/architecture.md`](docs/architecture.md) |
| Multi-app 路由 | 已发布（PR-A） | [`docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`](docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md) |
| 单一鉴权门 | 已发布（Lane A 下线） | [`docs/notes/auth-lane-a-removal.md`](docs/notes/auth-lane-a-removal.md) |
| Actor 拓扑 + reachable_set | 已发布（PR-C） | [`docs/superpowers/specs/2026-04-27-actor-topology-routing.md`](docs/superpowers/specs/2026-04-27-actor-topology-routing.md) |
| 业务拓扑 MCP 工具 | 已发布（PR-F） | [`docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`](docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md) |
| 语音（Volcengine 转向） | 仅 voice-web demo | [`docs/notes/voice-gateway-never-materialized.md`](docs/notes/voice-gateway-never-materialized.md) |

### 仓库布局

| 路径 | 内容 |
|---|---|
| `runtime/` | Elixir/OTP runtime —— peers / supervisors / session router / 能力门 |
| `adapters/cc_mcp/` | Claude Code 的 Python MCP 桥；inbound 渲染成 `<channel>` 标签 |
| `adapters/feishu/` | channel sidecar |
| `handlers/` | 纯函数 `(state, event) → (state, actions)` |
| `patterns/` | 声明式命令模板（DSL → yaml） |
| `py/` | `esr` CLI + Python 共享 helper |
| `scripts/` | `esrd.sh`、scenario spawner、daemoniser |
| `tests/e2e/scenarios/` | 端到端 shell scenario（基于 mock_feishu 驱动） |
| `roles/{dev,diagnostic}/CLAUDE.md` | 每个 role 的 CC 会话起手 prompt |
| `docs/` | 所有长文档（下方索引） |

### 文档索引

**架构 / 设计**
- [`docs/architecture.md`](docs/architecture.md) —— 模块树（开发者地图）
- [`docs/design/ESR-Protocol-v0.3.md`](docs/design/ESR-Protocol-v0.3.md) —— 协议规范（canonical）
- [`docs/design/ESR-Reposition-v0.3-Final-zh.md`](docs/design/ESR-Reposition-v0.3-Final-zh.md) —— 产品定位

**写代码**
- [`docs/dev-guide.md`](docs/dev-guide.md) —— handler / adapter / pattern 写法
- [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md) —— agent 拓扑写法（中文）
- [`docs/cookbook.md`](docs/cookbook.md) —— 食谱式 how-to

**运维**
- [`docs/operations/dev-prod-isolation.md`](docs/operations/dev-prod-isolation.md) —— dev / prod 并行运行
- [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md) —— 已知 flaky 测试
- [`docs/notes/actor-topology-routing.md`](docs/notes/actor-topology-routing.md) —— 拓扑 / `workspaces.yaml` 运维笔记

**Spec（按 PR）**
- 详见 [`docs/superpowers/specs/`](docs/superpowers/specs/)。每个落地特性都有 `YYYY-MM-DD-<topic>.md`。

**field note**（[`docs/notes/`](docs/notes/)）
按主题切的小笔记，索引在 [`docs/notes/README.md`](docs/notes/README.md)。

### E2E 测试 scenario

E2E 覆盖在 [`tests/e2e/scenarios/`](tests/e2e/scenarios/)。**新增 scenario 必须在
本 README 表格里登记**，这是唯一入口。

| Scenario | 覆盖什么 | Spec |
|---|---|---|
| [`01_single_user_create_and_end.sh`](tests/e2e/scenarios/01_single_user_create_and_end.sh) | 单用户 create / use / end | [`2026-04-23-pr7-e2e-feishu-to-cc-design.md`](docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md) |
| [`02_two_users_concurrent.sh`](tests/e2e/scenarios/02_two_users_concurrent.sh) | 两用户并发 —— 隔离 + cap 门 | 同上 |
| [`04_multi_app_routing.sh`](tests/e2e/scenarios/04_multi_app_routing.sh) | 跨 app forward —— `app_id` 传递 / cap deny | [`2026-04-25-pr-a-multi-app-design.md`](docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md) |
| [`05_topology_routing.sh`](tests/e2e/scenarios/05_topology_routing.sh) | `<channel reachable=…>` + BGP-style reachable_set 学习 | [`2026-04-27-actor-topology-routing.md`](docs/superpowers/specs/2026-04-27-actor-topology-routing.md) |
| [`06_pty_attach.sh`](tests/e2e/scenarios/06_pty_attach.sh) | PTY actor attach —— 浏览器 xterm 渲染 cc TUI（WS） | [`2026-05-01-pty-actor-attach-design.md`](docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md) |
| [`07_pty_bidir.sh`](tests/e2e/scenarios/07_pty_bidir.sh) | PTY actor 双向 —— keystroke → process → frame 回环 | 同上 |

> 添加新 scenario 时：在本表登记，**并**在
> [`docs/notes/manual-e2e-verification.md`](docs/notes/manual-e2e-verification.md) 里记一笔。

### 跑测试

| 层 | 命令 | 数量（2026-04-28） |
|---|---|---|
| Elixir runtime | `(cd runtime && mix test)` | 579 |
| cc_mcp Python 桥 | `(cd adapters/cc_mcp && uv run --with pytest --with pytest-asyncio pytest)` | 32 |
| 单 scenario E2E | `bash tests/e2e/scenarios/0X_*.sh` | 5 个 |

已知 flaky 见 [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md)。

### CLI 约定

`./esr.sh <subcmd>` 是 `uv run --project py esr <subcmd>` 的薄包装 ——
通过绝对路径或 symlink 从任何目录调用都行。后面会迁到 PATH 上的二进制，
追踪在 [`docs/futures/esr-cli-binary.md`](docs/futures/esr-cli-binary.md)。

### 协作约定

- AI 配对编程约定见 [`CLAUDE.md`](CLAUDE.md)（仓库根）+ [`roles/`](roles/) 下的角色 primer。
- Spec 先行：行为变更的 PR 都会带一篇 `docs/superpowers/specs/<date>-<topic>.md`。

### License

待补充。
