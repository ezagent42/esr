# SessionTemplate + Channel 迁移 — operator-flow 收口审计 (2026-05-10)

**审计日期:** 2026-05-10 (SessionTemplate + Channel 迁移 Phase 8 收口)
**源迁移:** `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` + plan
**前置审计:** [`2026-05-08-post-multi-instance-audit.zh_cn.md`](2026-05-08-post-multi-instance-audit.zh_cn.md)
**配套文件:** 英文版 [`2026-05-10-session-template-and-channel-closeout.md`](2026-05-10-session-template-and-channel-closeout.md)。

> **结论 (rev-6):** 2026-05-06 baseline 的 12 步 operator path 在 SessionTemplate + Channel 迁移落地后仍 12/12 ✅ ✅ ✅。本次迁移做的是 wiring 层的 refactor — agents.yaml 解散、channels 升为 first-class、bundles 携带 SessionTemplates，operator 直接面对的 slash 接口没变。rev-5.1 关掉的 12 步路径在 rev-6 维持原样。

## 方法论

延续 rev-3/4/5/5.1 的三轴评分（I = interface 接口存在、F = function 工作、G = grammar 词法对齐）。符号：✅ 是 · ⚠️ 部分 · ❌ 否。

本轮 re-score 比 rev-3/4/5 短，因为 SessionTemplate + Channel 迁移是 **wiring 层 refactor** — operator 看到的 slash 没变。Operator 可能注意到的两个变化：

1. `/session:new` 接受可选 `template=<name>` 参数（Phase 5）。不写时，`Esr.Session.DefaultTemplate.auto_elect_if_single/0` 自动选取唯一注册的 template（默认安装下是 `feishu-cc`）— 所以无参形态不靠 operator 配置仍工作。
2. `/plugin:install --source=<dir>` 现在可以接 **bundle 目录**（含 `manifest.yaml` + `template.yaml`），不仅是 plugin 目录（Phase 4）。verb 和 arg 名没变；只是接受的 artifact 形态变宽。

两个变化都不是 regression — 旧的 operator 肌肉记忆仍然管用。

## 总览表 — re-scored

| # | Operator 输入 | I | F | G | 净 | Δ vs rev-5.1 (2026-05-09) |
|---|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | works | unchanged |
| 2 | `esr add user linyilun` (auto-admin) | ✅ | ✅ | ✅ | works | unchanged |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | colon-namespace 已落；install verb 仍走 local-path | unchanged (registry deferred) |
| 4 | `esr feishu bind linyilun ou_xxx` | ✅ | ✅ | ✅ | works (PR #263) | unchanged |
| 5 | `esr plugin install claude_code` | ✅ | ⚠️ | ⚠️ | 同 #3；默认内置 | unchanged |
| 6 | `esr plugin claude_code set config http_proxy=…` | ✅ | ✅ | ✅ | works (Phase 7 + HR-2) | unchanged |
| 7 | (Feishu) `/help` `/doctor` | ✅ | ✅ | ✅ | works | unchanged |
| 8 | (Feishu) `/session:new` | ✅ | ✅ | ✅ | works (现在走 SessionTemplate) | **内部已迁移**：agent_def 由 `Esr.SessionTemplate.AgentDefBuilder` (template-driven) 产出，不再走旧的 `Esr.Entity.Agent.Registry` (agents.yaml)。外部接口形态不变。 |
| 9 | (Feishu) `/workspace:add` | ✅ | ✅ | ✅ | works (rev-5.1 词法收口) | unchanged |
| 10 | (Feishu) `/agent:add type=cc name=esr-developer` | ✅ | ✅ | ✅ | works | **内部已迁移**：agent kind 元信息现从 claude_code 插件 manifest `agent_kinds:` 块读取（Phase 6）；dispatch 路径不变。 |
| 11 | (Feishu) plain text → reply with cwd | ✅ | ✅ | ✅ | works | unchanged |
| 12 | (Feishu) `/agent:inspect <name>` → URL | ✅ | ✅ | ✅ | works (rev-5 + #314) | unchanged |

**净 (rev-6):** **12/12 全关**，与 rev-5.1 一致。SessionTemplate + Channel 迁移在 operator 接口层是非 regression 的 refactor。

## 本次迁移**新增**的能力（不在 12 步基线里，但扩大了 operator surface）

下面这几条不是关 gap，是新增能力 — 不影响 rev-5.1 的 12/12 score，但扩展了可做的事。

### A. Operator-shipped SessionTemplates — **新增**

放一份 `*.yaml` 到 `${ESRD_HOME}/<inst>/session_templates/foo.yaml`（conflated manifest+template 形式）→ boot 时 `Esr.Bundle.Loader.load_all/0` 把它注册为 `source: :operator`；`/session:new template=foo` 走 operator template 起 session；`/plugin:reload session_templates`（未来）按需重读。e2e scenario 26 验证。

### B. Bundle 通过 `/plugin:install --source=<external-dir>` 安装 — **新增**

外部路径 `/tmp/external_bundle/{manifest,template}.yaml` → `/plugin:install --source=/tmp/external_bundle` 把 bundle 目录复制到 `runtime/lib/esr/bundles/<name>/`，注册到 `Esr.Bundle.Registry`，解析 + 注册 template 到 `Esr.SessionTemplate.Registry`。`/plugin:disable <bundle>` 反注册。e2e scenario 29 验证。

### C. 多 session 共享一个 instance — **新增**

一个 CC instance 可服务两个 session；reply routing 按入站 session 的 chat context（boss session ↔ junior session）。On-disk 状态 `sessions/<sid>/agents/<uuid>.json` 携带 `session_ids: [<A>, <B>]`。e2e scenario 28 + `cc_process_multi_session_test.exs` invariant test 验证。

### D. 双 agent kind 组合 — **新增（证明抽象通用）**

Phase 8 stub_agent 插件 + stub-only bundle 证明 Channel + agent_kind 抽象不是 CC 专属。e2e scenario 30 验证：一个非-CC 插件声明自己的 Channel kind + agent kind；一个 stub-only bundle 组合两者；`/session:new template=stub-only` 起 session 成功，feishu 和 claude_code 插件代码零修改。

## Operator 不可见但架构上变了的

下面这些 **架构层意义重大**，但不改 operator 输入的 surface。列出方便追溯：

- `Esr.Channel` behaviour + `Esr.Channel.Registry` — first-class per-session 通信 peer 抽象
- `Esr.Bundle.{Manifest,Registry,Loader}` — first-class 单 template 安装 artifact
- `Esr.SessionTemplate.{Parser,Registry,AgentDefBuilder,FlowNodeRegistry}` — template 物质化层；替代 `Esr.Entity.FeishuChatProxy` / `Esr.Entity.SlashHandler` / `Esr.Entity.Agent.MentionParser` 里的硬编码 wiring
- `Esr.Plugin.AgentKindRegistry`（Phase 6）— 替代 `Esr.Entity.Agent.Registry`（agents.yaml 缓存）；agent kinds 现在声明在插件 manifest `agent_kinds:` 块
- `mix esr.gen_bundle_docs` + `mix esr.check_bundles`（Phase 8）— bundles 的 auto-gen + drift-gate，照着 unified-grammar 的同套路写
- `agents.yaml` 已删；`git grep -l agents.yaml runtime/lib/` 在生产代码中返回 0 命中（只剩 moduledoc 注释）

## 待办与延期

rev-5/5.1 延期项不变：

- `esr daemon init` + `esr daemon clear` — 头 30 分钟的 UX 打磨
- Plugin install-by-name (registry) — 插件 spec 的 Phase 2，延期
- `pty_attach_security_hardening` — 已 CLOSED 2026-05-09 by PR #314（这里只为按序读审计的人保留）

本次迁移没有新冒出 operator-facing gap。

## 相关文档

- [`2026-05-08-post-multi-instance-audit.zh_cn.md`](2026-05-08-post-multi-instance-audit.zh_cn.md) — 前置审计；rev-5.1 关到 12/12
- [`docs/guides/operator-bootstrap-checklist.zh_cn.md`](../guides/operator-bootstrap-checklist.zh_cn.md) — 12 行可跑 checklist；持续验证用
- [`docs/superpowers/specs/2026-05-10-session-template-and-channel.md`](../superpowers/specs/2026-05-10-session-template-and-channel.md) — 本迁移源 spec
- [`docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`](../superpowers/plans/2026-05-10-session-template-and-channel-plan.md) — 8 phase 实施 plan
- [`docs/grammar/templates.md`](../grammar/templates.md) — 自动生成的 bundle reference
- [`docs/notes/concepts.md`](../notes/concepts.md) — rev 11 把 Bundle 升为 runtime-tier concept
- [`tests/e2e/scenarios/30_two_agent_kind_composition.sh`](../../tests/e2e/scenarios/30_two_agent_kind_composition.sh) — 抽象-validation gate
