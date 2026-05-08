# 资源类型化语法实施计划

> **执行 agent 注意：** 必读 sub-skill — superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按 task 逐项落地。step 用 `- [ ]` checkbox 跟踪。

**Spec id：** 2026-05-08-resource-typed-grammar
**作者：** Allen Woods + Claude
**对应 spec：** [`2026-05-08-resource-typed-grammar.md`](../specs/2026-05-08-resource-typed-grammar.md)（rev-3，2026-05-08 用户已确认）

> 本中文版仅做导航 + 关键决策摘要。完整 plan（每条 task 的 step 编号、确切代码块、TDD red→green 检查命令、提交命令）在英文版 source-of-truth：[`2026-05-08-resource-typed-grammar-plan.md`](2026-05-08-resource-typed-grammar-plan.md)。

## 总目标

按 spec rev-3 §1 的 4 条原则（P1 资源轴跟操作对象走、P2 list 返回自身资源、P3 attach 是 PTY 操作、P4 统一命令列表）重构 slash 命令面：

- `/agent:*` 系列处理 agent 实例（add/remove/set-primary/primary/rename）
- `/pty:*` 系列处理 PTY URL（list/attach）
- `/session:*` 系列处理 session 生命周期 + chat 绑定（list/switch/end/bind-chat/unbind-chat）
- `/cc:tui` 落 claude_code plugin（rev-3 D5），第二个 plugin-scoped command 真实消费者（前一个是 feishu）

## 分支前置条件（已满足）

`origin/dev` HEAD `cccb7a6`，已包含：

1. concepts.md rev-10（PR #271）
2. cleanup PR（PR #274）—— `Esr.Scope.* → Esr.Session.*` + ChatScope 拆分
3. multimedia PR（PR #273，与 grammar 无关但同基线）

## 6 phase 划分（每 phase 独立 commit）

| Phase | 范围 | LOC | task 数 |
|---|---|---|---|
| **A** | `actor_ids` 字段加到 `%Instance{}` struct + 持久化 + `pty_actor_id_for/2` + **PtyProcess pubsub topic 从 `pty:<session_id>` 迁到 `pty:<actor_id>`（修 M-2 多 agent attach latent bug）** + multi-agent 隔离回归测试 | ~80 实现 + ~80 测试 | 5 |
| **B** | `/session:list` chat-bound shape + slash-wire `/session:switch` `/session:end` + `/help` 加 Users 类目 | ~50 实现 + ~30 测试 | 5 |
| **C** | per-agent 改名（5 个 `/agent:*`）+ `/plugin:agent-types`（旧 `/agent:list` 类目搬过来）+ `/agent:list` 重写为 instance 列表 + 删 3 个 session/* + slash_handler 加 deprecation 提示 | ~250 实现 + ~150 测试 | 10 |
| **D** | `/session:bind-chat` + `/session:unbind-chat` 替代 attach/detach + slash_handler 提示 + 删旧文件 | ~100 实现 + ~50 测试 | 5 |
| **E** | `/pty:list` + `/pty:attach` + `/claude_code:tui`（claude_code plugin manifest 加 `slash_routes:` 块；slash + kind 用 plugin name canonical prefix）+ 删 orphan `Esr.Commands.Attach` + e2e scenario 22（含 multi-agent attach 隔离断言） | ~150 实现 + ~80 测试 + 130 LOC e2e | 7 |
| **F** | docs sweep（cookbook/dev-guide/CLAUDE.md/futures/todo）+ manual-check audit rev-5 close-out（#2-#7 closed）+ e2e 14/15/18 header 注释更新 + 双语镜像同步 | ~80 LOC docs | 5 |
| **总计** | | ~640 实现 + ~390 测试 + 130 e2e + 80 docs ≈ 1240 LOC | ~37 |

## 关键决策（沿用 spec rev-3）

- **D1** 改名命令硬切换、零后向兼容；slash_handler 的 `@deprecated_slashes` map 给提示。
- **D3** PtySocket 签名 token auth 移出本 PR（rev-2 决议），追踪在 `docs/futures/todo.md`。
- **D4** `actor_ids` 字段持久化到 `%Instance{}` struct（不放 ActorQuery 索引）。
- **D5** `/claude_code:tui`（rev-4 § 0.1：原 rev-3 写的 `/cc:tui`，code-review 后改为 plugin canonical prefix）落 claude_code plugin（不落核心），第二个 plugin slash_routes 消费者。
- **D7** `Esr.Scope.* → Esr.Session.*` 已在 PR #274 合 dev，本 plan 假设这个前置已落。

## spec 不变量（e2e scenario 22 验证）

- **I1** 所有操作 agent 实例的 slash 都在 `/agent:*` 下。
- **I2** 所有 emit TUI URL 的 slash 都在 `/pty:*` 或 plugin shortcut。
- **I3** `/agent:list` 返回实例（不是类型）；`/plugin:agent-types` 返回类型目录。
- **I4** 5 个改名 slash 都在旧形态下返回 rename hint。
- **I5** `/cc:tui` 通过 claude_code plugin manifest 的 `slash_routes:` 块注册（rev-3 机制）。

## 执行说明

英文版每个 task 都按 TDD 节奏：写失败测试 → 跑确认失败 → 写实现 → 跑确认通过 → 提交。每个 phase 末尾 `(cd runtime && mix test)` 全跑一次确认无回归。

执行方式两选一：
- **subagent-driven（推荐）** — 每个 task 派一个新 subagent，两阶段 review（spec 合规 → 代码质量），快速迭代
- **executing-plans（同 session）** — 批量执行，断点 review

## PR 落地后

按 CLAUDE.md 的"每个 feature PR 合 dev 后立即 promote 到 main"规则：

```bash
bash scripts/promote-dev-to-main.sh
git fetch origin && git push origin origin/dev:main
gh pr close $N -c "Fast-forwarded via direct push (preserves SHAs across dev/main)."
```

## 进入实施

回 "go" 选择执行方式（subagent-driven / inline / 由 user 手动 dispatch）；其它回复继续讨论。
