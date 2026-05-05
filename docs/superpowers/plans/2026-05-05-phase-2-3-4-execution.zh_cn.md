# Phase 2 → 3 → 4 执行计划 + AFK 操作原则

**日期：** 2026-05-05
**状态：** AFK 前待用户预批准的草案。
**前置完成：** Channel-port 债务审计（PR #190）；Option A 清理（PR #191）。
**本计划执行的 spec：**
- Phase 2: `docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md`（Elixir 原生 CLI/REPL/admin 统一）
- Phase 3: `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`（删 voice + 抽 feishu/cc_mcp）
- Phase 4: `docs/superpowers/specs/2026-05-05-phase-4-cleanup.md`（清理收尾）

本文档汇集两部分：(a) 我将执行的 **PR-by-PR 顺序**；(b) 执行中遇到问题时我将遵循的**操作原则**。用户预批准两者后，我执行计划并定期飞书汇报进度。

---

## 一、PR 顺序

### Phase 2 —— Slash / CLI / REPL Elixir 原生统一（约 9 个 PR）

| PR | 范围 | spec 引用 | 风险 |
|---|---|---|---|
| **PR-2.0** | 删除 `runtime/lib/esr/voice/` + agents.yaml 条目 + voice plugin manifest | spec §6.0 | 低 —— 从未使用 |
| **PR-2.1** | 从 `Esr.Admin.Dispatcher` 中提取 `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult`（单纯拆分，行为不变） | spec §3.1 | 中 —— 触及核心 admin 路径 |
| **PR-2.2** | 删除 `Esr.Admin.Dispatcher`；admin 文件提交改走 `Esr.Slash.QueueWatcher` → `SlashHandler.dispatch/3` | spec §3.2 | 中 |
| **PR-2.3** | `Esr.Admin.Commands.*` → `Esr.Commands.*`（机械式 find/replace + 测试） | spec §3.3 | 低 |
| **PR-2.4** | 添加 `Esr.Slash.ReplyTarget` behaviour 及 `ChatPid` / `QueueFile` / `IO` 实现；`SlashHandler.dispatch/3` 通过 behaviour 派发 reply | spec §3.4 | 中 |
| **PR-2.5** | Mix escript 骨架：`runtime/escript/esr_cli.ex` 入口 + 通过 dist-Erlang RPC 到运行中 esrd | spec §4.1 | 中 —— 新构建产物 |
| **PR-2.6** | 把 `esr {plugin,actor,cap,scope,workspace} *` 子命令实现成 escript 路由，调用 SlashHandler.dispatch/3 + `IO` ReplyTarget | spec §4.2 | 中 |
| **PR-2.7** | `runtime.exs` 从 `plugins.yaml` 读取 `enabled_plugins:`；`Esr.Application.start/2` 不再需要 plugin 特定 bootstrap | spec §5 | 低（Track 0 已完成；只验闸） |
| **PR-2.8** | dev-guide.md 添加 `mix escript.install` 文档；Python `esr` 入口加废弃通知 | spec §6 | 低 |

**Phase 2 完成判据：** 从 escript 跑 `esr plugin list` 输出与 Python 一致；全 e2e 套件通过；`Esr.Admin.Dispatcher` 不再存在。

### Phase 3 —— Plugin 物理迁移（约 7 个 PR）

| PR | 范围 | spec 引用 | 风险 |
|---|---|---|---|
| **PR-3.1** | `Esr.Plugin.Loader` 启动顺序：manifest 在 `Esr.Application` 注册 fallback Sidecar 映射之前加载；删 fallback | spec §3 | 中 |
| **PR-3.2** | `Esr.Entity.Agent.PlatformProxyRegistry` —— 从 AgentSpawner 当前内联逻辑中提取，由 plugin manifest 声明 | spec §4.1 | 中 |
| **PR-3.3** | 把 feishu 模块从 `runtime/lib/esr/{entity,scope,resource}/...feishu*` 迁到 `runtime/lib/esr/plugins/feishu/<同结构>/`，更新 manifest，更新 agents.yaml 引用 | spec §5.1 | 高 —— 多模块改名 + 跨命名空间调用方 |
| **PR-3.4** | feishu plugin 通过 plugin 启动钩子拥有 `bootstrap_feishu_app_adapters/0`；`Esr.Scope.Admin` 失去该函数 | spec §5.2 | 中 |
| **PR-3.5** | cc_mcp 走 HTTP MCP 传输：用 HTTP POST 替代 stdio，使 cc_mcp 生命周期与 claude tmux 解耦 | spec §6.1, [docs/issues/02 channel-abstraction] | 高 —— 新传输 |
| **PR-3.6** | 把 cc_mcp 模块从 `runtime/lib/esr/entity/cc_*` 迁到 `runtime/lib/esr/plugins/claude_code/...`，更新 manifest | spec §6.2 | 高 |
| **PR-3.7** | 删除 `cc_process.ex` 中 4 处 feishu 命名硬编码 + 5 处跨命名空间调用方；cc plugin 处任何位置不再引用 "feishu" | spec §6.3 | 高 —— 多模块外科手术 |

**Phase 3 完成判据：** `runtime/lib/esr/{entity,scope,resource}/` 下每一行都是 plugin 无关的 core；feishu/cc 各自完整拥有自己的 plugin 目录；全 e2e 套件通过；`tools/esr-debug term-text` 显示与之前一致的 PTY 内容。

### Phase 4 —— 清理收尾（约 7 个 PR）

按 Phase 4 spec —— Group A 到 G 对应 PR-4.1 → PR-4.7。比 Phase 2/3 风险低（纯删除）。Phase 3 干净落地后再启动。

---

## 二、AFK 操作原则

这些是执行中遇到意外时我会遵循的规则。用户预批准后，我无 ping 自处理；除非情况落入 **唤醒用户** 列。

### 原则 1 —— Plan 时刻闸

| 闸 | 动作 |
|---|---|
| spec 对该 PR 范围明确无歧义 | 直接做（用 subagent-driven-development，按 skill 走两阶段 review） |
| spec 留有设计开放点（"TBD" / "implementation 时定"） | **唤醒用户** —— 飞书发开放点 + 我的推荐选择 |
| 中途建议改 Phase 计划（例：发现 PR-3.5 应在 PR-3.3 之前落） | **唤醒用户** —— 飞书发改序方案 + 理由 |

### 原则 2 —— 实现时刻闸

| 情境 | 动作 |
|---|---|
| Implementer subagent 提的澄清问题我从 spec 能答 | 答完继续 |
| Implementer subagent 提的问题需要用户判断（例：spec 未定的命名选择） | **唤醒用户** —— 飞书发问题 + 我的推荐 |
| Spec-reviewer subagent 发现不合规 | Implementer 修，再 review（按 subagent-driven-development skill） |
| Code-quality reviewer 发现 important 问题 | Implementer 修，再 review |
| Reviewer 发现 spec 错了（不是实现错） | **唤醒用户** —— 飞书发矛盾 + 我会选哪边 |

### 原则 3 —— E2E 与 CI 闸

| 情境 | 动作 |
|---|---|
| e2e 失败属于已知 flake（claude latency、网络） | 重试至多 2 次；仍 flaky 则 PR merge comment 标 "passed with known flake"，继续 |
| e2e 失败属于回归 | 阻 PR，用 `tools/esr-debug` + agent-browser 截图做 RCA，修复，再跑 |
| pre-merge-dev-gate 在 agent-browser 内容断言失败 | 阻 PR，做 RCA —— 这是不可动摇的红线（Standard 1+2）。RCA 超 30 分钟则 **唤醒用户** |
| 测试套件命中无关 flaky 测试 | 仅重跑该测试（不跑全套）；若多个 PR 都命中同样 pattern 则 **唤醒用户** 报告 pattern |

### 原则 4 —— 分支与 merge 闸

| 情境 | 动作 |
|---|---|
| PR-N 依赖 PR-M；PR-M 还没合 | 等 M；不投机性 stack |
| 分支保护拦 merge（"REVIEW_REQUIRED"） | 用 `gh pr merge --admin --squash --delete-branch`（memory 规则：ezagent42/esr 已授权 admin bypass） |
| GitHub 或 `gh` CLI 报网络错 | 重试至多 3 次；仍失败 **唤醒用户** |
| 与 dev 合并冲突 | 本地 rebase；冲突涉及不熟文件则 **唤醒用户** |

### 原则 5 —— 资源与时间闸

| 情境 | 动作 |
|---|---|
| Claude weekly 限流触发暂停 | 立即 **唤醒用户**，附当前 PR-X of Y 状态 + 预期恢复时间 |
| 单个 PR 墙钟超 60 分钟 | **唤醒用户** 说明卡在哪 + 我的解卡方案 |
| Phase 整体超估算 50% 以上 | **唤醒用户** 给修订 ETA |

### 原则 6 —— 沟通节奏

- **每 PR**：merge 时一条飞书 `[N% — PR-X of Y of Phase-Z]` + 一行总结。
- **每 Phase**：开始时 "starting Phase Z"；结束时 "Phase Z complete (M PRs, K LOC delta)"。
- **唤醒时**：飞书前缀 `🚨 ATTENTION` 明确标注。
- **常规进度**：短、可扫读、不需要用户回应。

### 原则 7 —— 硬停条件

无论上述逻辑如何推荐，遇以下情况我会停下唤醒用户：
1. 需要对共享状态做破坏性操作（例：drop registry、force-push to main）。
2. 发现 spec 的根本性假设错误（例：HTTP MCP 传输破坏 cc_mcp 鉴权；feishu plugin 抽离发现 20+ 跨命名空间调用方而非文档中的 5 个）。
3. e2e Standard 1+2 失败且 30 分钟内无法修复。
4. 用户飞书发消息 —— 我读完先回，再继续。

---

## 三、我**不**会自动决定的事

- **spec 之外的横切重构**：哪怕看起来明显有益。
- **重命名公共 API 表面**：例如 `mcp__esr-channel__reply` 工具名 —— 即便 Phase 3 会因此受益。
- **添加新依赖**（mix deps、npm packages、py packages）：每项都需用户批准。
- **跳过 subagent review** 因为"改动很小"：memory 规则要求所有 spec 和 plan 都过 reviewer-pass；同样适用于实质性 PR。
- **触碰 spec 范围之外的文件** 不先标注。

---

## 四、批准表

用户三选一：

**A) 按当前文本批准。** 我按 PR 顺序执行 Phase 2 → 3 → 4，应用上述操作原则。

**B) 修订后批准。** 告诉我哪些原则需要改。

**C) 推迟。** 暂停执行；用户想先 review spec 细节再授权。

批准后（A 或 B），我会：
1. 用 `superpowers:writing-plans` skill 把每个 Phase 展开成 TDD 任务计划文件（按 memory 规则 subagent code-review）。
2. 每个 phase 实现前先飞书发该 phase 的 plan 路径给用户。
3. 在 `superpowers:subagent-driven-development` skill 下逐 PR 执行。

---

## 五、估算（诚实）

- **Phase 2（约 9 个 PR）**：4–8 小时墙钟，取决于 subagent 迭代次数。最不确定的部分：PR-2.5（escript 构建）、PR-2.6（子命令路由）。
- **Phase 3（约 7 个 PR）**：6–10 小时。最不确定：PR-3.5（HTTP MCP 传输）、PR-3.7（cc_process feishu 解耦）。
- **Phase 4（约 7 个 PR）**：2–4 小时。基本机械删除。

总计约 12–22 小时墙钟。期间会被 claude weekly 限流打断；我会在命中时飞书报告。

若用户现在批准，我**不会**在同一回应里预写 Phase 2 详细计划 —— 那要走 writing-plans + subagent review，作为单独文件落地。批准后 30 分钟内通过飞书送达。
