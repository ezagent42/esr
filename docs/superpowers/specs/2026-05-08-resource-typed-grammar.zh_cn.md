# 资源类型化语法重构

**Spec id:** 2026-05-08-resource-typed-grammar
**作者：** Allen Woods + Claude
**状态：** rev-3（元模型重新对齐：**Realm = class、Session = instance** —— concepts.md 待同步更新）
**对应：** rev-4 审计 follow-ups #1、#2、#7（`docs/manual-checks/2026-05-08-post-multi-instance-audit.md` § rev-4）
**关联：** 2026-05-08-session-first-default-resolution.md、2026-05-08-plugin-command-registration.md（rev-3）

> 本中文版仅做导航说明 + 关键决策摘要。完整 spec（每条命令的 LOC 估算、PtySocket 签名 token 设计、5 phase 实施计划、不变量、open question）在英文版 source-of-truth：[`2026-05-08-resource-typed-grammar.md`](2026-05-08-resource-typed-grammar.md)。

## rev-3 修正（2026-05-08）—— 元模型重新对齐

rev-2 落地后用户深入提问，发现 Scope/Session 整套词汇定位需要反转。**rev-3 把元模型映射对换：**

| 层级 | 旧（concepts.md 当前）| 新（rev-3） |
|---|---|---|
| **Class / declarative** | Session | **Realm**（新词） |
| **Instance / runtime** | Scope | **Session**（与操作员词汇对齐） |

**理由：** 操作员说 `/session:new` 想的是"创建新实例" —— 是 instance 语感。concepts.md 当前"Session = class"映射和操作员直觉冲突；"Scope = instance"在英语 + 编程语境里都不天然。对换之后 code 和 operator 词汇都对齐到 instance，新词 Realm 占据 class 槽位（"Realm of admin operations"、"the workspace Realm" 读作 kind/category 自然）。

新元模型：
- **4 runtime primitives**：**Session**、Entity、Resource、Interface（之前 Scope/Entity/Resource/Interface）
- **1 declarative primitive**：**Realm**（之前 Session）
- "类比 OOP：**Realm 是 class、Session 是 instance**"

**rev-3 修正：**

- **Q4-revised**：cleanup PR 前置（在本 spec 实施前 land），三件事打包：
  1. `Esr.Scope.* → Esr.Session.*`（runtime 层 ~7 模块、~80 处引用）
  2. `Esr.Commands.Scope.* → Esr.Commands.Session.*`（admin 命令层 ~6 模块）+ 合并两个 New（保留 449-LOC 的 Scope.New 当 canonical Session.New）
  3. **拆 `Esr.Resource.ChatScope.Registry`** 成两个 registry：
     - `Esr.Session.ChatRouting.Registry` —— `(chat_id, app_id) → session_id` 路由
     - `Esr.Session.NameIndex.Registry` —— session URI 唯一性约束（mirror `Esr.Resource.Workspace.NameIndex`）
- concepts.md 同步更新 PR 在 cleanup PR 之前 ship —— 元模型对齐文档先行。
- §6 实施面更新 —— 新增模块全部用 `Esr.Commands.Session.*`（cleanup 后的 canonical 名字）。

**操作员面不变。** Operator 词汇 `/session:*` 本来就和 instance 对齐，rev-3 只是让 code 跟 operator 同步。

**rev-1/rev-2 既定的 3 项保持：**

- Q1. `/plugin:agent-types`
- Q2. 本 PR 不做 PtySocket auth
- Q3. `/cc:tui` 落 claude_code plugin

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
