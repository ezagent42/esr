# 资源类型化语法重构

**Spec id:** 2026-05-08-resource-typed-grammar
**作者：** Allen Woods + Claude
**状态：** rev-2（用户 2026-05-08 已 approve；4 处修正已落地）
**对应：** rev-4 审计 follow-ups #1、#2、#7（`docs/manual-checks/2026-05-08-post-multi-instance-audit.md` § rev-4）
**关联：** 2026-05-08-session-first-default-resolution.md、2026-05-08-plugin-command-registration.md（rev-3）

> 本中文版仅做导航说明 + 关键决策摘要。完整 spec（每条命令的 LOC 估算、PtySocket 签名 token 设计、5 phase 实施计划、不变量、open question）在英文版 source-of-truth：[`2026-05-08-resource-typed-grammar.md`](2026-05-08-resource-typed-grammar.md)。

## rev-2 修正（2026-05-08）

经用户审阅 rev-1 后确认的 4 处修正：

- **Q1 → `/plugin:agent-types`**（rev-1 是 `/agent-type:list`）。agent 类型本质是插件元数据，归在 `/plugin:` 下语义最准。
- **Q2 → 本 PR 不动 PtySocket auth**。单操作员 + Tailscale 网络下今天不需要；将来作为 hardening 任务记到 `docs/futures/todo.md`。规模减少 ~100 LOC。
- **Q3 → `/cc:tui` 落 claude_code plugin**（rev-1 误写"落核心"）。按 rev-3 plugin-scoped command registration spec D3 的强制命名空间规则。这成为 rev-3 机制的第二个真实消费者。
- **Q4 → `Esr.Scope.* → Esr.Session.*` module rename 走单独 PR，本 spec 实施前先 land**。"Scope" 是 M-1..M-5 时代对 Session 的旧称；slash 已经叫 `/session:*` 但 module 名仍叫 Scope，本 spec 实施基底先清理干净。pre-rename PR 纯机械（sed + slash-routes yaml `command_module:` 更新 + 测试），零行为变化。

## 摘要

按 rev-4 审计提出的 4 条原则（P1 资源轴跟操作对象走、P2 list 返回自身资源、P3 attach 是 PTY 操作、P4 统一命令列表文档）重构 slash 命令面，解决 3 个 operator 可见 gap + 1 个安全漏洞：

1. **`/session:list` 不存在** —— 接通
2. **`/agent:list` 命名错误**（实际列的是 plugin 声明的 agent 类型）—— 改成列 session 内运行的 agent 实例；旧的类型目录搬到 `/agent-type:list`
3. **没有 PTY URL 入口** —— 加 `/pty:list` + `/pty:attach pty=<id>` 返回 URL；`/cc:tui name=<agent>` 是其薄壳 shortcut（落 claude_code plugin）
4. ~~`EsrWeb.PtySocket` 零认证~~ —— **rev-2 移出本 PR 范围**，留作未来 hardening 任务（`pty_attach_security_hardening` 在 `docs/futures/todo.md`）

并把 per-agent 命令从 `/session:*` 搬到 `/agent:*`：`/agent:add`、`/agent:remove`、`/agent:set-primary`、`/agent:primary`、`/agent:rename`。把 chat↔session 绑定从 `attach`/`detach` 改名为 `bind-chat`/`unbind-chat`/`switch`，对称于 `/workspace:bind-chat`。

## 关键决策

- **D1.** 改名命令**硬切换、零后向兼容**（与 rev-3 plugin-scoped command registration spec D4 一致）。`/session:add-agent` 落地后立即变 unknown_slash，dispatcher 返回的错误消息提示新形态 `/agent:add`。
- **D3.** PtySocket auth 本 PR 不做（移出范围），单操作员 + Tailscale 不需要；未来 hardening 任务。
- **D4.** `actor_ids` 字段加到 `%Esr.Entity.Agent.Instance{}` struct 上持久化，而不是放到 ActorQuery 索引里。让标识跟数据共置。
- **D5.** `/cc:tui` 落 claude_code plugin（不落核心）。按 rev-3 spec D3 强制命名空间。模块 `Esr.Plugins.ClaudeCode.Commands.Tui`，路径 `runtime/lib/esr/plugins/claude_code/commands/tui.ex`。
- **D7.** `Esr.Scope.* → Esr.Session.*` module rename 走单独 PR，本 spec 实施之前 land。

## 命令列表（落地后）

新命令 15 条、删除命令 5 条（含 `Esr.Commands.Attach` 孤儿模块清理）。详细表见英文版 §4.2 + §4.3。

## 实施计划

5 phase / 单分支单 PR / 每 phase 独立可编译可测：

- **Phase A** —— `actor_ids` 字段加到 Instance struct（基础工作）
- **Phase B** —— `/session:list` + slash-wire `/session:end` + `/help` 的 Users 类目
- **Phase C** —— per-agent 改名（5 命令搬到 `/agent:*`）
- **Phase D** —— chat-binding 改名（`/session:{bind,unbind}-chat` + `/session:switch`）
- **Phase E** —— `/pty:*` 家族 + `/cc:tui` + PtySocket 签名 token；e2e scenario 20 落地

总规模（rev-2，post Scope→Session pre-rename）：~480 LOC 实现 + ~330 LOC 测试 = ~810 LOC。

## 实施先决条件

**`Esr.Scope.* → Esr.Session.*` 单独 PR 必须先 land**（~40 文件机械 sed + slash-routes yaml `command_module:` 更新 + `mix test` + e2e 14/18/19 验证）。本 spec 假设这个 pre-rename PR 已经合 dev。

## rev-2 全部 open question 已解决

详细解决见英文版 §9。简版：Q1 `/plugin:agent-types`；Q2 落 claude_code plugin；Q3 PtySocket auth 移出范围；Q4 走 Scope→Session pre-rename PR。

回 "go" 进入 plan 阶段（先做 Scope→Session pre-rename，再做 grammar 实施）；其它回复继续讨论。
