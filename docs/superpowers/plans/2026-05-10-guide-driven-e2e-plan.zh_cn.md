# Guide-driven e2e（防 drift）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `docs/guides/flow-*.md` 成为操作员 journey 的 source of truth，并能通过 bash 驱动器机器回放，走真正的产品聊天路径（`mock_feishu push_inbound` + 回包捕获）做断言。

**Architecture:** 进程外 bash 驱动器（`scripts/replay-guide.sh`，~100 LOC）解析 guide markdown 里的 `chat-input` / `chat-output` fence，启全新的 esrd + mock_feishu，按 HTTP 重放每一步，对回包做逐行 diff（带 placeholder 替换）。CI 在每个 PR 上对所有有 fence 的 guide 跑驱动器；Claude Code hook 在编辑 command handler 时提醒先跑相关 guide。配套 ADR-0001 记录"bash vs mix task"的决策。

**Tech Stack:** Bash（按 `tests/e2e/scenarios/common.sh` 的 set -Eeuo pipefail 约定），`jq` 做 JSON 解析，`uv run --project py python` heredoc 解析 markdown fence，`curl` 做 HTTP 调用，GitHub Actions 做 CI。

**分支策略：**
- 计划与 spec rev-4 一起落在 `spec/guide-driven-e2e`（PR #335）→ 合并
- 每个 Phase 从 **origin/dev 派生新分支**：
  - Phase 0 → `feat/guide-driven-e2e-phase-0-audit`
  - Phase 1 → `feat/guide-driven-e2e-phase-1-foundation`
  - Phase 2 → `feat/guide-driven-e2e-phase-2-canary`
  - Phase 3 → 不立分支，随特性走

---

## 文件结构

### 新文件

| 路径 | Phase | LOC | 职责 |
|---|---|---|---|
| `scripts/replay-guide.sh` | 1 | ~100 | 解析 fence、启 fixture、重放、diff |
| `scripts/check-scenario-headers.sh` | 1 | ~30 | 校验 scenario 的 `# Replays:` 头 |
| `scripts/hooks/replay-guide-reminder.sh` | 1 | ~20 | PostToolUse hook：编辑 command handler 时提示 |
| `docs/guides/_replay_smoke.md` | 1 | ~15 | CI 烟测用的合成 guide；1 对 input/output |
| `docs/guides/full-user-journey.md` | 0 | ~30 | 金标准 journey 索引 |
| `docs/guides/flow-bootstrap.md` | 0（改名）+ 2（加 fence）| ~60 | 由 `operator-bootstrap-journey.md` 改名 |
| `docs/guides/flow-bootstrap.zh_cn.md` | 0 + 2 | ~60 | zh_cn 镜像 |
| `docs/guides/flow-sessiontemplate-feishu-test.md` | 0（改名） | n/a | 由 `2026-05-10-sessiontemplate-feishu-test.md` 改名 |
| `docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md` | 0（改名） | n/a | zh_cn 镜像 |

### 修改文件

| 路径 | Phase | 改动 |
|---|---|---|
| `.claude/settings.json` | 1 | 加 PostToolUse hook（Edit\|Write\|MultiEdit matcher）|
| `CLAUDE.md` | 1 | 加 3 行 anti-drift 节，链到 spec |
| `.github/workflows/ci.yml` | 1 | 加 replay 步骤 + header-lint 步骤 |
| `tests/e2e/scenarios/19_session_first_default.sh` | 2 | 加 `# Replays:` 头 + 改为 replay 驱动 |
| `docs/guides/full-user-journey.md` | 1, 2 | fence 落地时填行 |
| `docs/guides/writing-an-agent-topology.md` | 0 | 审核；若引用已解散的 `agents.yaml` 则删除 |

---

## Phase 0：Guide 审计 + 改名（1 PR，~50 LOC）

纯文档清理，无新行为。必须在 Phase 1 之前落，给 Phase 1 一个稳定的文件名表。

### Task 0.1：开 Phase 0 分支

**文件：** 仅 git

- [ ] **Step 1：从最新 dev 派生分支**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-0-audit origin/dev
```

- [ ] **Step 2：确认干净状态**

Run: `git status`
预期：`On branch feat/guide-driven-e2e-phase-0-audit ... nothing to commit, working tree clean`

### Task 0.2：审计已陈旧的 guide 引用

**文件：** 检查 `docs/guides/*.md`

- [ ] **Step 1：grep 已解散的引用**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
echo "=== agents.yaml 引用 ===" ; rg -l "agents\.yaml" docs/guides/ || true
echo "=== /new-session 旧 slash ===" ; rg -l "/new-session\b" docs/guides/ || true
echo "=== rev-3 前的 grammar 标记 ===" ; rg -l "Esr\.Commands\.Plugin\.Install" docs/guides/ || true
```

预期：列出要重写或删除的少量文件。把输出捕获用于 Step 2。

- [ ] **Step 2：把审计决策写进 PR 描述**

在最终 PR body 里列出：
- `writing-an-agent-topology.md` —— 引用 `agents.yaml`：**删除**（SessionTemplate 迁移 Phase 6 已解散 agents.yaml；拓扑现在从插件 manifest 的 `agent_kinds:` 派生，不再由用户手写）
- `operator-bootstrap-checklist.md` —— 保留（是核验清单不是 flow）
- `feishu-adapter-setup.md` —— 保留；fence 在 Phase 3 organic 期间补

本步骤不 commit —— 删除动作在 Task 0.5 落地。

### Task 0.3：把 `operator-bootstrap-journey.md` 改名为 `flow-bootstrap.md`

**文件：**
- 改名：`docs/guides/operator-bootstrap-journey.md` → `docs/guides/flow-bootstrap.md`
- 改名：`docs/guides/operator-bootstrap-journey.zh_cn.md` → `docs/guides/flow-bootstrap.zh_cn.md`（若存在）

- [ ] **Step 1：查 zh_cn 镜像是否存在**

Run: `ls docs/guides/operator-bootstrap-journey*`
预期：1 或 2 个文件。记录是哪种。

- [ ] **Step 2：用 git mv 改名**

```bash
git mv docs/guides/operator-bootstrap-journey.md docs/guides/flow-bootstrap.md
# 若 zh_cn 镜像存在：
# git mv docs/guides/operator-bootstrap-journey.zh_cn.md docs/guides/flow-bootstrap.zh_cn.md
```

- [ ] **Step 3：找入向链接并更新**

```bash
rg -l "operator-bootstrap-journey" --type md
```

预期：引用旧名的 markdown 文件列表。逐个编辑指向 `flow-bootstrap.md`（zh_cn 链则指向 `.zh_cn.md`）。

- [ ] **Step 4：Commit**

```bash
git commit -m "docs: rename operator-bootstrap-journey → flow-bootstrap (spec/§4 Phase 0)"
```

### Task 0.4：把 `2026-05-10-sessiontemplate-feishu-test.md` 改名为 `flow-sessiontemplate-feishu-test.md`

**文件：**
- 改名：`docs/guides/2026-05-10-sessiontemplate-feishu-test.md` → `docs/guides/flow-sessiontemplate-feishu-test.md`
- 改名：`docs/guides/2026-05-10-sessiontemplate-feishu-test.zh_cn.md` → `docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md`

- [ ] **Step 1：git mv 两个文件**

```bash
git mv docs/guides/2026-05-10-sessiontemplate-feishu-test.md \
       docs/guides/flow-sessiontemplate-feishu-test.md
git mv docs/guides/2026-05-10-sessiontemplate-feishu-test.zh_cn.md \
       docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md
```

- [ ] **Step 2：找入向链接并更新**

```bash
rg -l "2026-05-10-sessiontemplate-feishu-test" --type md
```

逐个 match 更新到新文件名。

- [ ] **Step 3：Commit**

```bash
git commit -m "docs: rename sessiontemplate-feishu-test guide to flow- convention"
```

### Task 0.5：删除 `writing-an-agent-topology.md`（已陈旧）

**文件：**
- 删：`docs/guides/writing-an-agent-topology.md`
- 删：`docs/guides/writing-an-agent-topology.zh_cn.md`（若存在）

- [ ] **Step 1：确认 guide 真的陈旧**

```bash
rg -n "agents\.yaml" docs/guides/writing-an-agent-topology.md | head -5
```

预期：出现引用已解散的 `agents.yaml` 的命中行。若输出为空（说明审计后已更新），STOP 并重评估 —— 跳过本任务，在 PR body 备注。

- [ ] **Step 2：找入向链接**

```bash
rg -l "writing-an-agent-topology" --type md
```

预期：零个或少量 match。每个 match：要么把链接换成对应插件 manifest spec 中 `agent_kinds:` 的文档指针，要么直接删链接。

- [ ] **Step 3：删除 + Commit**

```bash
git rm docs/guides/writing-an-agent-topology.md
# 若 zh_cn 存在：
# git rm docs/guides/writing-an-agent-topology.zh_cn.md
git commit -m "docs: drop writing-an-agent-topology — agents.yaml dissolved PR-328"
```

### Task 0.6：建立 `docs/guides/full-user-journey.md` 索引骨架

**文件：**
- 新建：`docs/guides/full-user-journey.md`
- 新建：`docs/guides/full-user-journey.zh_cn.md`

- [ ] **Step 1：写英文索引**

新建 `docs/guides/full-user-journey.md`，内容：

```markdown
# ESR full user journey

The complete operator-facing journey, broken into sub-flows. Each
sub-flow has its own fenced guide that doubles as the e2e replay
source. CI runs `scripts/replay-guide.sh` against every fenced
guide on every PR.

**Vocabulary:** see [`CONTEXT.md`](../../CONTEXT.md) for the
journey/flow/guide/scenario terms.

| Sub-flow | What it covers | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd → first user → register adapter → bind feishu → workspace + session + agent → first CC reply | [flow-bootstrap.md](flow-bootstrap.md) | [19_session_first_default.sh](../../tests/e2e/scenarios/19_session_first_default.sh) |
| SessionTemplate (Feishu test) | Operator end-to-end test of SessionTemplate + Channel migration | [flow-sessiontemplate-feishu-test.md](flow-sessiontemplate-feishu-test.md) | (none yet — Phase 3 organic) |

Rows for further sub-flows (multi-session, PTY attach, plugin lifecycle,
bundle install, ...) are added by feature PRs as they ship — see the
anti-drift rule in [spec §3.3](../superpowers/specs/2026-05-10-guide-driven-e2e.md#33-docsguidesfull-user-journeymd--the-gold-standard-index).
```

- [ ] **Step 2：写 zh_cn 镜像**

新建 `docs/guides/full-user-journey.zh_cn.md`，内容：

```markdown
# ESR 全部用户 journey

完整的操作员可见 journey，按 sub-flow 切分。每个 sub-flow 自己的
fenced 指南同时充当 e2e 回放源。CI 在每个 PR 上对所有有 fence 的
指南跑 `scripts/replay-guide.sh`。

**术语：** 见 [`CONTEXT.md`](../../CONTEXT.md) 中的
journey/flow/guide/scenario 定义。

| Sub-flow | 覆盖什么 | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd → 第一个 user → 注册 adapter → 绑 feishu → workspace + session + agent → 第一次 CC 回复 | [flow-bootstrap.zh_cn.md](flow-bootstrap.zh_cn.md) | [19_session_first_default.sh](../../tests/e2e/scenarios/19_session_first_default.sh) |
| SessionTemplate（Feishu 测试） | 操作员端到端测 SessionTemplate + Channel migration | [flow-sessiontemplate-feishu-test.zh_cn.md](flow-sessiontemplate-feishu-test.zh_cn.md) | （暂无 —— Phase 3 organic） |

更多 sub-flow（multi-session、PTY attach、plugin lifecycle、bundle
install 等）随功能 PR 上线时补充 —— 见 [spec §3.3](../superpowers/specs/2026-05-10-guide-driven-e2e.zh_cn.md#33-docsguidesfull-user-journeymd--金标准索引) 防腐烂规则。
```

- [ ] **Step 3：Commit**

```bash
git add docs/guides/full-user-journey.md docs/guides/full-user-journey.zh_cn.md
git commit -m "docs(guides): add full-user-journey index (spec §3.3)"
```

### Task 0.7：开 Phase 0 PR + admin-merge

**文件：** 仅 git/gh

- [ ] **Step 1：push 分支**

```bash
git push -u origin feat/guide-driven-e2e-phase-0-audit
```

- [ ] **Step 2：开 PR，审计摘要写进 body**

```bash
gh pr create --base dev --title "docs(guides): Phase 0 audit + rename for guide-driven e2e" \
  --body "$(cat <<'EOF'
## Summary
Phase 0 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). 纯文档清理 —— 无行为变更。

- 改名 `operator-bootstrap-journey.md` → `flow-bootstrap.md`（+ zh_cn）
- 改名 `2026-05-10-sessiontemplate-feishu-test.md` → `flow-sessiontemplate-feishu-test.md`（+ zh_cn）
- 删除 `writing-an-agent-topology.md`（引用已解散的 `agents.yaml`，PR-328 起被插件 manifest 的 `agent_kinds:` 块取代）
- 新建 `docs/guides/full-user-journey.md`（+ zh_cn）作为 journey 官方索引

## Test plan
- [ ] `rg "operator-bootstrap-journey" --type md` 无 match
- [ ] `rg "2026-05-10-sessiontemplate-feishu-test" --type md` 无 match
- [ ] `rg "writing-an-agent-topology" --type md` 无 match
- [ ] `docs/guides/full-user-journey.md` 存在且有两条种子行

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3：等 CI 然后 admin-merge**

```bash
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

预期：PR 合入 dev。分支删除。

---

## Phase 1：基础（1 PR，~250 LOC）

建 replay 机器、hook、CI 步、烟测。本阶段完成后，CI 对合成烟测 guide 跑 replay 绿（PASS）；尚无生产 guide 加 fence。

### Task 1.1：开 Phase 1 分支

**文件：** 仅 git

- [ ] **Step 1：从最新 dev 派生分支（已含 Phase 0）**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-1-foundation origin/dev
```

### Task 1.2：写合成烟测 guide

**文件：**
- 新建：`docs/guides/_replay_smoke.md`

- [ ] **Step 1：写烟测 guide**

新建 `docs/guides/_replay_smoke.md`，内容：

````markdown
# _replay_smoke (CI synthetic)

合成 guide，CI 每跑一次都用来运行 `scripts/replay-guide.sh`。一对
input/output fence。非面向用户 —— 前缀下划线把它从 full-user-journey.md
排除。

### Step 1：注册 adapter，bot 回包给出注册的 id

```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/adapter:register name=esr_helper_dev app_id=cli_a9563cc03d399cc9 app_secret=dummy_for_smoke
```

```chat-output
ok: true
adapter: esr_helper_dev
```
````

`_` 前缀是"replay harness 私用"的约定 —— `scripts/replay-guide.sh` 与
CI 循环对 `_*.md` 默认跳过，除非显式作为参数传入。

- [ ] **Step 2：Commit**

```bash
git add docs/guides/_replay_smoke.md
git commit -m "docs(guides): add _replay_smoke.md synthetic CI guide"
```

### Task 1.3：写 `scripts/replay-guide.sh` 骨架 + 烟测

**文件：**
- 新建：`scripts/replay-guide.sh`

- [ ] **Step 1：写骨架**

新建 `scripts/replay-guide.sh`，内容如下。~100 LOC；用 `tests/e2e/scenarios/common.sh` 的 helper（`start_mock_feishu`、`start_esrd`、`seed_capabilities`、`_e2e_teardown`）。

（脚本主体见英文版 plan 同名 task 的 Step 1，逐字相同。完整 bash 源代码不在 zh_cn 镜像中重复 —— 维护单一源避免双向 drift。）

- [ ] **Step 2：在 `source common.sh` 行之后插入 `_replay_diff` helper**

（同样见英文版 plan 同名 task 的 Step 2，bash 源逐字相同。）

- [ ] **Step 3：chmod + shellcheck**

```bash
chmod +x scripts/replay-guide.sh
shellcheck scripts/replay-guide.sh || true   # 警告 OK，错误失败
```

预期：shellcheck 报零错误。SC2034/SC2155 这类风格警告 OK，可就地用 `# shellcheck disable=` 抑制。

- [ ] **Step 4：烟测**

```bash
bash scripts/replay-guide.sh docs/guides/_replay_smoke.md
echo "exit=$?"
```

预期：`_replay_smoke.md: 1 step(s) replayed, PASS` 且 `exit=0`。若 adapter register 步因合成 `app_id`/`app_secret` 被拒，调整烟测 guide 的 fence 内容（例如换成实际 seeded 的 `app_id`）。

- [ ] **Step 5：Commit**

```bash
git add scripts/replay-guide.sh
git commit -m "feat(replay): scripts/replay-guide.sh — parse fences + replay via mock_feishu (spec §3.1)"
```

### Task 1.4：写 `scripts/check-scenario-headers.sh`

**文件：**
- 新建：`scripts/check-scenario-headers.sh`

- [ ] **Step 1：写 linter**

（脚本源同英文版 plan Task 1.4 Step 1。）

- [ ] **Step 2：chmod + 用当前（未迁移的）scenario 跑一次 —— 预期会失败并列出**

```bash
chmod +x scripts/check-scenario-headers.sh
bash scripts/check-scenario-headers.sh || true
```

预期：打印缺少头的 scenario 列表 —— 这是迁移 backlog。Phase 1 不修这些；Phase 2 迁移 scenario 19；Phase 3 organic。

- [ ] **Step 3：加 Phase 1 用的 exempt list 机制（让 CI 现在就通过）**

编辑 `scripts/check-scenario-headers.sh`，把 `EXEMPT_REGEX` 行改成：

```bash
# Exempt list：共享 helper + 待 Phase 3 迁移的 scenario。
# 每个条目对应的 scenario 拿到 `# Replays:` 头时从这里删掉。
EXEMPT_REGEX='^(_common_selftest|common|_wait_url|01_|02_|04_|05_|06_|07_|08_|11_|12_|13_|14_|15_|16_|17_|18_|20_|21_|22_|23_|24_|25_|26_|27_|28_|29_|30_)\.'
```

按当前 `tests/e2e/scenarios/` 的实际前缀调整（用 `ls tests/e2e/scenarios/ | awk -F_ '{print $1"_"}' | sort -u` 枚举）。Phase 2 会把 `19_` 从 exempt list 中删除。

- [ ] **Step 4：再跑一遍 + Commit**

```bash
bash scripts/check-scenario-headers.sh
git add scripts/check-scenario-headers.sh
git commit -m "feat(replay): scripts/check-scenario-headers.sh — Replays-header linter (spec §3.4)"
```

预期：linter 退 0（所有现存 scenario 都在 exempt list 内）。

### Task 1.5：写 `scripts/hooks/replay-guide-reminder.sh`

**文件：**
- 新建：`scripts/hooks/replay-guide-reminder.sh`

- [ ] **Step 1：写 hook 脚本**

（脚本源同英文版 plan Task 1.5 Step 1。）

- [ ] **Step 2：chmod + 烟测**

```bash
chmod +x scripts/hooks/replay-guide-reminder.sh
# 模拟一次 PostToolUse 载荷：
echo '{"tool_input":{"file_path":"runtime/lib/esr/commands/session/new.ex"}}' \
  | bash scripts/hooks/replay-guide-reminder.sh
```

预期：把告警写到 stderr；退 0。

- [ ] **Step 3：确认非 command 文件不出声**

```bash
echo '{"tool_input":{"file_path":"runtime/lib/esr/foo.ex"}}' \
  | bash scripts/hooks/replay-guide-reminder.sh
echo "exit=$?"
```

预期：零输出，`exit=0`。

- [ ] **Step 4：Commit**

```bash
git add scripts/hooks/replay-guide-reminder.sh
git commit -m "feat(hooks): replay-guide-reminder.sh — nudge on command-handler edits (spec §3.5)"
```

### Task 1.6：在 `.claude/settings.json` 注册 hook

**文件：**
- 修改：`.claude/settings.json`

- [ ] **Step 1：读现有 settings**

```bash
cat .claude/settings.json
```

预期：JSON 对象，`hooks.PostToolUse` 数组已含 `openclaw-channel-postcheck.sh` 条目。

- [ ] **Step 2：往 `hooks.PostToolUse` 加第二条**

（最终形态见英文版 plan Task 1.6 Step 2 —— 逐字相同的 JSON。）

- [ ] **Step 3：用 jq 校验**

```bash
jq . .claude/settings.json >/dev/null
```

预期：零输出，退 0（确认 JSON 形态合法）。

- [ ] **Step 4：Commit**

```bash
git add .claude/settings.json
git commit -m "chore(claude): register replay-guide-reminder PostToolUse hook (spec §3.5)"
```

### Task 1.7：CLAUDE.md 加 anti-drift 节

**文件：**
- 修改：`CLAUDE.md`（根目录）

- [ ] **Step 1：确认 CLAUDE.md 存在**

```bash
ls CLAUDE.md
```

不存在则新建一个有顶层标题；存在则原地编辑。

- [ ] **Step 2：追加节（保留原有内容）**

用 Edit 加（保留现有内容）：

```markdown
## Guide-driven e2e（防 drift）

- 改 command handler？提交前跑 `scripts/replay-guide.sh` 对相关 guide 验证。
- 检测到 guide drift？提示用户 —— 改实现 OR 更新 guide。别静默忽略。
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md)
```

- [ ] **Step 3：Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude-md): add Guide-driven e2e anti-drift section (spec §3.6)"
```

### Task 1.8：加 CI workflow 步骤 —— 报告制 gate

> **Spec rev-5 改动（2026-05-11）：** CI 不再直接跑 replay（ubuntu-latest
> 起不了 FAA Python sidecar，见 `.github/workflows/ci.yml` 末尾的
> `mix test on Linux CI` TODO）。改为：开发者本地跑
> `scripts/generate-e2e-report.sh` 后提交 `docs/e2e-reports/<short-sha>.md`；
> CI 验证报告存在、新鲜、所有 guide PASS。详见 spec §3.7。

**文件：**
- 修改：`.github/workflows/ci.yml`
- 新建：`scripts/verify-e2e-report.sh`
- 新建：`scripts/generate-e2e-report.sh`

- [ ] **Step 1：读现有 ci.yml**

```bash
cat .github/workflows/ci.yml
```

确认有 `build-and-test`（或同等）job 可以扩展。

- [ ] **Step 2：写两个脚本**

`scripts/verify-e2e-report.sh`（~50 LOC）：用
`git log --reverse "${GITHUB_BASE_REF:-dev}"..HEAD -- <paths>` 找 PR diff 中
最新一个触及 `runtime/lib/esr/commands/` 或 `docs/guides/flow-*.md` 的 commit，
要求 `docs/e2e-reports/<short-sha>.md` 存在、引用该 commit 的 full sha、
没有 `| FAIL ` 行。

`scripts/generate-e2e-report.sh`（~80 LOC）：遍历 fenced guide
（`_replay_smoke.md` + 所有有 `^```chat-input` 的 `flow-*.md`），对每个跑
`replay-guide.sh`，累积 PASS/FAIL + 步骤数 + wall time，按 spec §3.7
schema 写出 `docs/e2e-reports/<HEAD-short-sha>.md`。

- [ ] **Step 3：往 build-and-test job 追加两步**

在现有 e2e 步骤之后（或 job 的 `steps:` 末尾），加：

```yaml
      - name: Lint scenario headers
        run: bash scripts/check-scenario-headers.sh

      - name: Verify e2e report
        # Anti-drift gate 按 spec §3.7。报告制而不是 CI 跑 replay，
        # 因为 Ubuntu CI 起不了 FAA Python sidecar；ESR 生产目标
        # 只有 macOS。开发者本地跑 scripts/generate-e2e-report.sh
        # 然后提交 docs/e2e-reports/<short-sha>.md。
        run: bash scripts/verify-e2e-report.sh
```

- [ ] **Step 3：如有 actionlint 则用它校验**

```bash
which actionlint && actionlint .github/workflows/ci.yml || true
```

预期：零错误。隐式 shell 的警告 OK。

- [ ] **Step 4：Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add replay-guide + scenario-header lint steps (spec §3.7)"
```

### Task 1.9：开 Phase 1 PR + admin-merge

**文件：** 仅 git/gh

- [ ] **Step 1：push 分支**

```bash
git push -u origin feat/guide-driven-e2e-phase-1-foundation
```

- [ ] **Step 2：开 PR**

```bash
gh pr create --base dev --title "feat(replay): Phase 1 — replay-guide.sh + hook + CI (guide-driven e2e)" \
  --body "$(cat <<'EOF'
## Summary
Phase 1 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). Ships replay 机器：

- `scripts/replay-guide.sh`（~100 LOC）—— fence parser + fixture 启动 + diff
- `scripts/check-scenario-headers.sh`（~30 LOC）—— Replays-header linter（当前 scenario 在 exempt list）
- `scripts/hooks/replay-guide-reminder.sh`（~20 LOC）—— PostToolUse 在 command-handler 编辑时提醒
- `.claude/settings.json` —— 注册 hook
- `CLAUDE.md` —— 3 行 anti-drift 节
- `.github/workflows/ci.yml` —— replay + header-lint 步
- `docs/guides/_replay_smoke.md` —— CI 烟测合成 guide

## Test plan
- [ ] `bash scripts/replay-guide.sh docs/guides/_replay_smoke.md` → 退 0，`1 step(s) replayed, PASS`
- [ ] `bash scripts/check-scenario-headers.sh` → 退 0
- [ ] `echo '{"tool_input":{"file_path":"runtime/lib/esr/commands/session/new.ex"}}' | bash scripts/hooks/replay-guide-reminder.sh` → 打告警
- [ ] CI 绿

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3：等 CI；任何失败都查（不要跳 replay 步）**

```bash
gh pr checks --watch
```

预期：绿。若 replay 烟测失败，先本地 debug —— 最可能是 mock_feishu 启动时序或 user_add/feishu_bind admin-submit 形态。

- [ ] **Step 4：admin-merge**

```bash
gh pr merge --admin --squash --delete-branch
```

---

## Phase 2：Canary —— flow-bootstrap + regression bisect（1 PR，~150 LOC）

落第一条真实 fence 序列，并用它证明 2026-05-10 `/session:new name=test-cc` regression 会被抓出来。

### Task 2.1：开 Phase 2 分支

- [ ] **Step 1：从最新 dev 派分支**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-2-canary origin/dev
```

### Task 2.2：给 `docs/guides/flow-bootstrap.md` 加 fence

**文件：**
- 修改：`docs/guides/flow-bootstrap.md`

- [ ] **Step 1：读现有内容**

```bash
cat docs/guides/flow-bootstrap.md
```

记 5 个主步骤：注册 adapter、绑 feishu、建 workspace、建 session、发普通文本 → CC 回包。

- [ ] **Step 2：在第 1 步散文之后插入第一对 fence（adapter register）**

用 Edit 在 step-1 散文之后插入：

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/adapter:register name=esr_helper_dev app_id=cli_a9563cc03d399cc9 app_secret=changeme_secret
```

```chat-output
ok: true
adapter: esr_helper_dev
```
````

- [ ] **Step 3：第 2 对 —— feishu_bind**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/feishu:bind
```

```chat-output
ok: true
bound_open_id: ou_test_linyilun
```
````

- [ ] **Step 4：第 3 对 —— workspace create**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/workspace:new name=demo path=/tmp/replay-demo-ws
```

```chat-output
ok: true
workspace: demo
```
````

- [ ] **Step 5：第 4 对 —— session create（REGRESSION GATE）**

这是 2026-05-10 `/session:new name=test-cc` bug 的捕获 fence。pre-PR-#334 命中 `validate_args`；post-PR-#334 通过默认 workspace 解析成功。

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/session:new name=test-cc
```

```chat-output capture=session_id
ok: true
session_id: <UUID>
template: feishu-cc
agent: cc
```
````

- [ ] **Step 6：第 5 对 —— plain text → CC 回包**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
hello, what is the current working directory?
```

```chat-output
<...>
/tmp/replay-demo-ws
<...>
```
````

- [ ] **Step 7：Commit**

```bash
git add docs/guides/flow-bootstrap.md
git commit -m "docs(guides): add fences to flow-bootstrap (Phase 2 canary, 5 pairs)"
```

### Task 2.3：把 fence 镜像到 `flow-bootstrap.zh_cn.md`

**文件：**
- 修改：`docs/guides/flow-bootstrap.zh_cn.md`

- [ ] **Step 1：往 zh_cn 镜像补同样的 fence 块**

fence 本身不翻（slash 命令、字段名都是英文）。只有周边散文是中文。在对应位置插入相同的 5 对 fence。

- [ ] **Step 2：Commit**

```bash
git add docs/guides/flow-bootstrap.zh_cn.md
git commit -m "docs(guides): mirror flow-bootstrap fences into zh_cn"
```

### Task 2.4：本地 replay → PASS

- [ ] **Step 1：跑 replay**

```bash
bash scripts/replay-guide.sh docs/guides/flow-bootstrap.md
```

预期：`flow-bootstrap.md: 5 step(s) replayed, PASS`。任一步失败说明 bug 真实存在 —— 修生产代码而不是弱化 fence。

### Task 2.5：Bisect 验证 —— 证明 regression 真的会被抓到

**文件：** 仅 git

- [ ] **Step 1：把新 fence 暂存，切到 pre-#334 dev 上**

```bash
# 保存新 flow-bootstrap.md
cp docs/guides/flow-bootstrap.md /tmp/flow-bootstrap-with-fences.md
# detach 到 pre-#334 历史（commit 8777357 是 PR #321 合入 dev 后、#334 之前）
git checkout 8777357 --detach
# 把 fenced guide + replay 脚本拷到旧 tree
cp /tmp/flow-bootstrap-with-fences.md docs/guides/flow-bootstrap.md
cp scripts/replay-guide.sh /tmp/replay-guide-from-phase-1.sh
chmod +x /tmp/replay-guide-from-phase-1.sh
```

- [ ] **Step 2：对 pre-#334 dev 跑 replay → 预期在第 4 对 FAIL**

```bash
bash /tmp/replay-guide-from-phase-1.sh docs/guides/flow-bootstrap.md
echo "exit=$?"
```

预期：打印 `... FAIL at step 4: ...`（`/session:new name=test-cc` 撞 `invalid_args`）；`exit=1`。

如果此步 PASS，说明 spec "Phase 5 应该抓到 regression" 不成立 —— STOP，重读 regression。整个 anti-drift 前提依赖本步骤失败。

- [ ] **Step 3：恢复 Phase 2 分支状态**

```bash
git checkout feat/guide-driven-e2e-phase-2-canary
rm -f /tmp/flow-bootstrap-with-fences.md /tmp/replay-guide-from-phase-1.sh
```

- [ ] **Step 4：用一行空 commit 落档 bisect**

```bash
git commit --allow-empty -m "verify: regression bisect — pre-#334 replay FAILs at step 4, post-#334 PASSes (spec §4 Phase 2 acceptance #6)"
```

### Task 2.6：把 `scenarios/19_session_first_default.sh` 改成 thin-wrapper

**文件：**
- 修改：`tests/e2e/scenarios/19_session_first_default.sh`

- [ ] **Step 1：把脚本体替换成 thin-wrapper**

重写文件为：

```bash
#!/usr/bin/env bash
# scenario 19 — session-first default workspace resolution.
#
# Replays: docs/guides/flow-bootstrap.md
#
# This script is a thin wrapper around scripts/replay-guide.sh. The
# real test lives in the guide's fences. Edit the guide, not this file.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

exec bash "${SCRIPT_DIR}/../../../scripts/replay-guide.sh" \
  "${SCRIPT_DIR}/../../../docs/guides/flow-bootstrap.md"
```

- [ ] **Step 2：从 check-scenario-headers.sh 的 EXEMPT_REGEX 里删 `19_`**

编辑 `scripts/check-scenario-headers.sh`，把 `EXEMPT_REGEX` 里的 `19_|` 删掉。

- [ ] **Step 3：跑 header linter → 预期 PASS**

```bash
bash scripts/check-scenario-headers.sh
```

预期：`check-scenario-headers: all scenarios have valid headers`，退 0。

- [ ] **Step 4：本地跑迁移后的 scenario**

```bash
bash tests/e2e/scenarios/19_session_first_default.sh
```

预期：通过 replay PASS（5 steps）。

- [ ] **Step 5：Commit**

```bash
git add tests/e2e/scenarios/19_session_first_default.sh scripts/check-scenario-headers.sh
git commit -m "test(e2e): scenario 19 → thin-wrapper around flow-bootstrap.md replay (spec §3.4)"
```

### Task 2.7：更新 `full-user-journey.md` 的 Bootstrap 行

**文件：**
- 修改：`docs/guides/full-user-journey.md`
- 修改：`docs/guides/full-user-journey.zh_cn.md`

- [ ] **Step 1：标记 Bootstrap 行的 scenario 字段为已上线**

两个文件中 Bootstrap 行的 "E2E scenario" 列已经指向 `19_session_first_default.sh` —— 确认 Phase 0 + Phase 2 改动后链接仍能解析；已经指向正确文件就不用编辑。

- [ ] **Step 2：Commit（no-op-friendly）**

```bash
git diff docs/guides/full-user-journey.md docs/guides/full-user-journey.zh_cn.md
# 如有 diff：
git commit -am "docs(guides): finalize Bootstrap row in full-user-journey index"
```

### Task 2.8：开 Phase 2 PR + admin-merge

- [ ] **Step 1：push**

```bash
git push -u origin feat/guide-driven-e2e-phase-2-canary
```

- [ ] **Step 2：开 PR**

```bash
gh pr create --base dev --title "test(e2e): Phase 2 canary — flow-bootstrap fences + scenario 19 thin-wrapper" \
  --body "$(cat <<'EOF'
## Summary
Phase 2 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). 第一条真实 fence 序列 + regression bisect 证明。

- `docs/guides/flow-bootstrap.md` 加 5 对 fence（adapter / feishu_bind / workspace / session / chat → CC reply）
- `docs/guides/flow-bootstrap.zh_cn.md` 镜像
- `tests/e2e/scenarios/19_session_first_default.sh` 变成 guide replay 的 thin wrapper
- Bisect 已验证：pre-#334 replay 在第 4 对 FAIL（`/session:new name=test-cc`）；post-#334 PASS —— 见 commit `verify: regression bisect`

## Test plan
- [ ] `bash scripts/replay-guide.sh docs/guides/flow-bootstrap.md` → 5 steps PASS
- [ ] `bash tests/e2e/scenarios/19_session_first_default.sh` → PASS（通过 replay）
- [ ] `bash scripts/check-scenario-headers.sh` → PASS
- [ ] CI 绿

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3：等 CI + admin-merge**

```bash
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## Phase 3：Organic 扩散（无独立 PR）

Phase 2 落地后，anti-drift 机制就在线。无批量迁移 —— 覆盖随特性 PR 增长。

### 约定（无 checklist；是仓库纪律）

当特性 PR 触及 `runtime/lib/esr/commands/*.ex`：

1. PostToolUse hook 触发提醒作者
2. 作者：
   - 给现有 guide 加 fence（并更新对应 scenario 脚本里的 `# Replays:` 头），或
   - 新建 `docs/guides/flow-<topic>.md`（+ zh_cn），往 `full-user-journey.md` 加行，再写一个 thin-wrapper scenario 指过去
3. PR review 拒绝改 command handler 但二者都没做的特性 PR

### 重新评估的触发条件

如果一年过去（或在没 fence 的命令上发生 3 次 drift bug），开 follow-up brainstorm 加 `mix esr.check_guide_coverage` 作硬 CI gate。记 `docs/futures/todo.md`。

---

## Self-Review

### Spec 覆盖核对

| Spec 节 | Plan task |
|---|---|
| §1 Why now（regression 上下文）| Task 2.5 bisect |
| §1.5 Vocabulary | （CONTEXT.md 已在 spec rev-4 落，不重落）|
| §2 Goals | 所有 Phase 合起来 |
| §3.1 `scripts/replay-guide.sh` | Task 1.3 |
| §3.2 Fence 协议 + `user=` auto-bind | Task 1.3（USER_MAP_JSON + auto-bind 块）|
| §3.3 `full-user-journey.md` 索引 | Task 0.6（建）+ Task 2.7（终稿）|
| §3.4 Scenario 头标注 | Task 1.4（linter）+ Task 2.6（迁 scenario 19）|
| §3.5 Claude Code hook | Task 1.5（脚本）+ Task 1.6（settings.json）|
| §3.6 CLAUDE.md 新增 | Task 1.7 |
| §3.7 CI workflow 步 | Task 1.8 |
| §3.8 all-inline fixture state | Task 2.2（flow-bootstrap fence 从绝对零起）|
| §4 Phase 0 audit | Task 0.1–0.7 |
| §4 Phase 1 foundation | Task 1.1–1.9 |
| §4 Phase 2 canary | Task 2.1–2.8 |
| §4 Phase 3 organic | Plan §"Phase 3" |
| §5 验收 | 所有验收点已分布于各 Phase；#6（bisect 证明）= Task 2.5 |
| §7 approval gate → writing-plans | 本计划即交付物 |

无 gap。

### Placeholder 扫描

搜了 TBD/TODO/FIXME/XXX/???。干净。

### 类型/命名一致性

- `replay-guide.sh` 入参：到处都是 `<guide-path>`
- `_replay_diff` helper 签名一致（`expected, actual, capture-var-name`）
- `USER_MAP_JSON` env 名在 bash 和 python parser 一致
- `CAPTURES` 关联数组名在 `_replay_diff` 和主循环一致
- Fence frontmatter 键：`app_id`、`chat_id`、`user`、`capture` —— spec §3.2 和 Task 1.3 一致
- `# Replays:` 头格式 —— spec §3.4 和 Tasks 1.4 + 2.6 一致

---

## Open risk（非阻塞）

- **mock_feishu 回包捕获 polling 形态。** Task 1.3 假设 `GET /open-apis/im/v1/messages?chat_id=...` 返回最新消息在 `.data.items[0].body.content`。若实际响应 shape 不同（如包成 `data.list`），Task 1.3 Step 4 烟测会失败 —— 推进前先修 jq path。
- **Bash 5 依赖（`<<<` here-string + `[[ =~ ${rx}$ ]]`）。** macOS 默认 `/bin/bash` 是 3.2。shebang `#!/usr/bin/env bash` 会拾 Homebrew bash（e2e 约定如此）。CI 跑 Ubuntu —— bash 5 是默认。
- **Adapter `app_secret=changeme_secret` 字面值。** Task 2.2 第 1 对 fence 用占位 secret。烟测 fixture 的 mock_feishu 不校验 secret（短路掉 TLS），所以 replay 不影响。真实 Feishu 测试用用户自己的 secret，永不写进任何 guide。
