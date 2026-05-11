# Guide-driven e2e（防 drift）

**Status：** Draft —— 待用户批准
**日期：** 2026-05-10
**Author：** Claude (与 linyilun)
**配套文件：** [`.md`](2026-05-10-guide-driven-e2e.md) —— 英文原版

---

## 1. 为什么现在做

Phase 5 的 SessionTemplate + Channel 迁移发布的 regression：
`Esr.Commands.Session.New.execute/2` 的 bare `/session:new name=test-cc`
形态（不带 `agent=` / `dir=` / `workspace=`）撞上 stale `validate_args`
gate。**Scenario 25**（Phase 5 显式 invariant 测试）跑绿。生产飞书
里第一次试就 `error: invalid_args`。

三个原因：

1. **路径不一致。** 所有 e2e scenario 中**触发 slash 命令**那条路径都
   通过 `esr_cli admin submit ...`，绕开
   `Esr.Entity.SlashHandler.merge_chat_context/3`（chat envelope
   注入器）。纯文本入向（如 "what's the cwd?"）和多媒体入向**确实**
   走的是生产 `mock_feishu push_inbound` 路径（scenario 01/02/04/05/20
   验证）。绕开是 slash 专属的约定 —— mock_feishu 本身不阻挡推 slash
   文本入向，只是 harness 从来没这么做过。
2. **参数覆盖空洞。** 24 个 scenario 全都显式传 `--arg dir=`。操作员
   实际敲的 bare `name=`-only 形态从未被测过。
3. **指南 drift。** `docs/guides/*.md` 描述操作员 journey。没有机器
   readback 把指南绑到 e2e。实现一变就静静跟指南偏。

**修复：** 指南成为操作员 journey 的 source of truth；一个小脚本
通过生产代码路径回放指南步骤。

---

## 1.5 词典

本 spec 通篇用这四个词。ESR 现有词典（`docs/notes/concepts.md` rev-11）
没定义它们，所以这里锁定并同步到项目级 `CONTEXT.md`。

| 术语 | 定义 |
|---|---|
| **journey** | operator 端到端的完整路径（fresh install → 第一次 CC 回复）。每个项目一个。索引在 `docs/guides/full-user-journey.md`。|
| **flow** | journey 的一个 sub-segment（bootstrap / workspace+session / pty-attach 等）。一个 flow ↔ 一个 guide ↔ 一或多个 scenario。|
| **guide** | flow 的人类可读文档 `docs/guides/flow-<topic>.md`。同时是 replay 的 fence 源。|
| **scenario** | flow 的机器执行壳 `tests/e2e/scenarios/<n>.sh`，通过 `# Replays:` 头链回 guide。|

基数：

```
journey ──含──▶ N 个 flow
flow    ──由 1 个 guide 描述
flow    ──由 ≥1 个 scenario 执行（通常 1；高级 flow 可能有排列组合多个）
```

## 2. 目标 & 非目标

### 目标

- 锁定指南为操作员 journey 的 source of truth。
- `scripts/replay-guide.sh` shell 脚本解析指南 markdown 里的
  `chat-input` / `chat-output` fence，通过 `mock_feishu` push_inbound
  + reply_capture 回放，断言输出匹配。
- Claude Code hook 在 `runtime/lib/esr/commands/*.ex` 被改时触发，
  提醒 agent 提交前跑相关指南的回放。
- CLAUDE.md 规则给人和 agent 看，描述这个约定。
- CI 对每个有 fence 的指南跑 `replay-guide.sh`；mismatch 阻 merge。

### 非目标

- 不替换 `Esr.Commands.Meta` 驱动的 `docs/grammar/*` 生成。那是单命令
  reference（字典），跟本 spec 互补。
- 不自动生成指南。指南是人写的；只在里面嵌机器可读 fence。
- 不测 Feishu 协议本身。mock_feishu 跟真 Feishu 的契约是另一个
  （推后）关切。
- 不写 Elixir mix 任务做回放/覆盖。`scripts/replay-guide.sh` 是**进程外
  黑盒驱动器**——启 esrd 子进程、HTTP 跟它说话——本质上跟 `mix
  esr.gen_slash_routes` 这种解析 ESR 自身 AST 的**内部工具**不同。
  完整理由见 [ADR-0001](../../adr/0001-bash-replay-script.md)。
- v1 不强制绝对覆盖（每个命令 kind 必须在指南里出现）。v1 抓**有
  fence 的命令**的 drift；没 fence 的命令保持没 fence。覆盖 gate 是
  follow-up，等真出现 drift 在没 fence 的命令上时再加。

---

## 3. 组件

四个轻量部件：

### 3.1 `scripts/replay-guide.sh`

bash 脚本（~100 LOC，bash 处理不灵的地方用 `python3 -c` heredoc 帮忙）。
公开界面：

```
scripts/replay-guide.sh <guide-path>
scripts/replay-guide.sh docs/guides/flow-bootstrap.md
```

全部 match exit 0；有 mismatch 时给 diff，non-zero。

内部流程（具体不空话）：

1. 通过 `awk` / `python3 -c` 解析 markdown，提取 language tag 是
   `chat-input` 或 `chat-output` 的 fenced 块
2. 文档顺序配对 input → output → input → output。错位（连两 output 等）
   报结构错并指出指南行号
3. boot fresh 测试 fixture：
   - 新 `$ESRD_HOME=/tmp/esr-replay-<run-id>/`
   - 自由端口起 `mock_feishu.py`（复用 `tests/e2e/scenarios/common.sh`
     里的 helper）
   - 通过 `scripts/esrd.sh start --instance=replay-<run-id>` 起 esrd
   - 等 ready（端口文件出现）
4. 走步骤列表：
   - **chat-input** → `curl http://127.0.0.1:$MOCK_FEISHU_PORT/push_inbound`
     带 fence body 当消息文本
   - **chat-output** → poll mock_feishu 的 reply_capture 接口直到
     有 reply（30s 超时）→ 跟 fence body 逐行 diff（带 placeholder
     替换）
5. teardown：停 esrd / 停 mock_feishu / `rm -rf` fixture 目录
6. 打印汇总：`<guide>: N steps replayed, <PASS|FAIL>`

### 3.2 Fence 协议 —— v1 最小集

只两个 language：

| Language | 方向 | 通道 |
|---|---|---|
| `chat-input` | 操作员 → bot | mock_feishu push_inbound |
| `chat-output` | bot → 操作员 | mock_feishu reply_capture |

`chat-input` fence 行的 frontmatter：`app_id`、`chat_id`、可选 `user`。
缺省遵循 ESR bootstrap 约定（操作员 `linyilun`、adapter
`esr_helper_dev`、合成测试 chat）。

**`user=` 解析（v1 自动绑定）。** `user=` 取逻辑名（`linyilun`，
不是 `ou_xxx` open_id），让 guide 保持可读。首次遇到某个名字时，
`replay-guide.sh` 查内置映射表（如 `linyilun → ou_test_linyilun`），并：

1. 如 ESR 用户记录不存在，自动创建。
2. 创建 `feishu_bind` 把该用户绑到合成 open_id。

后续步骤复用已建立的绑定。映射表在 `scripts/replay-guide.sh` 中维护，
guide 里出现新操作员名时扩展。`ou_xxx` 值永远不写进 guide frontmatter，
只用操作员可读名。

Placeholder（逐行替换）：`<UUID>` 匹配 UUID v4，`<int>` 匹配数字串，
`<...>` 通配。v1 出这三个；其它按真实需要扩展。

`chat-output` 上的 `capture=<varname>`：把匹配到的 placeholder 绑给
后续步骤用 `{{varname}}`。

工作示例：

````markdown
### Step 8：bare /session:new 通过默认 template 解析

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

`cli-input` / `cli-output` 等 **推到 v1.1**（或更晚），等真有
admin-CLI-only 流的 drift bug 出现再加。recurring bug class 是
chat-flow drift；admin CLI 测试通过 `esr_cli admin submit` 已经能用。

### 3.3 `docs/guides/full-user-journey.md` —— 金标准索引

新文件 `docs/guides/full-user-journey.md` 是 ESR 支持的**所有操作员
journey 的官方索引**。人类可读：操作员落到这里看到完整 journey 地图，
点入任何 sub-flow。机器可读：每行链到一个 per-flow 指南（带 fence），
CI 的 replay 循环走每个被链接的 guide。

形态（草图）：

```markdown
# ESR 全部用户 journey

完整的操作员 journey，按 sub-flow 切。每个 sub-flow 自己的 fenced
指南同时充当 e2e scenario。

| Sub-flow | 覆盖什么 | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd / 第一个 user / 注册 adapter / 绑 feishu | [flow-bootstrap.md](flow-bootstrap.md) | tests/e2e/scenarios/01_*.sh |
| Workspace + session | workspace 创建 / session 起 + agent 起 / 纯文本 → CC reply | [flow-workspace-session.md](flow-workspace-session.md) | tests/e2e/scenarios/19_*.sh |
| Multi-session | 一个 CC 实例两 chat via /agent:add-session | [flow-multi-session.md](flow-multi-session.md) | tests/e2e/scenarios/28_*.sh |
| PTY attach | /claude_code:tui → xterm.js | [flow-pty-attach.md](flow-pty-attach.md) | tests/e2e/scenarios/22_*.sh |
| Plugin lifecycle | install / enable / disable / hot-reload | [flow-plugin-lifecycle.md](flow-plugin-lifecycle.md) | tests/e2e/scenarios/16_*.sh |
| Bundle install | 外部路径 bundle 安装 + 依赖检查 | [flow-bundle.md](flow-bundle.md) | tests/e2e/scenarios/29_*.sh |
| ... | ... | ... | ... |
```

为什么单立索引文件（而不是把 fence 直接放 `full-user-journey.md`）：
- journey 太长一次 fence-replay 跑不完；想要 sub-flow 级隔离 fixture
  （每个 sub-flow 都从全新 esrd 起，按 §3.8 all-inline 约定）。
  per-flow 文件 = per-flow fixture。
- 操作员看索引要先看地图，再 drill-down。fence 把地图弄乱。
- CI 并行：`for flow in flow-*.md; do replay-guide.sh & done`。

防腐烂规则：发布新的操作员可见 flow 时，PR 加一行到
`full-user-journey.md` + 一个对应的 `flow-<name>.md`。reviewer 拒
触及 `runtime/lib/esr/commands/` 但没加 guide 行的 PR。

### 3.4 `tests/e2e/scenarios/*.sh` 头部标注

每个 scenario 脚本必须在头部声明它来自哪个指南：

```bash
#!/usr/bin/env bash
# scenario 19 — session-first default workspace resolution.
#
# Replays: docs/guides/flow-workspace-session.md
#
# 本脚本是薄壳。改 guide，别改本文件。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
exec bash "${SCRIPT_DIR}/../../../scripts/replay-guide.sh" "${SCRIPT_DIR}/../../../docs/guides/flow-workspace-session.md"
```

linter（`scripts/check-scenario-headers.sh`，~30 LOC bash）：
- 走 `tests/e2e/scenarios/*.sh`
- 断言每个文件前 20 行有 `# Replays: docs/guides/<file>.md`
- 断言被引用的 guide 存在
- 断言 scenario 文件短（≤ 30 LOC）—— 长自定义逻辑要么放 guide
  要么放一次性 `*-custom.sh` 豁免列表

跟 `replay-guide.sh` 一起当 CI 一步跑。没加标注的 scenario 偷溜进
来时挂掉。

### 3.5 Claude Code hook

Claude Code hook 配置在 `.claude/settings.json` 的 `hooks` 键下。
matcher 只能 match tool 名（regex 字符串）——matcher 层**没有**
`args.file_path` 过滤字段。文件路径过滤要在脚本里做，脚本从 stdin
读 `tool_input` JSON（仓库里 `scripts/hooks/openclaw-channel-postcheck.sh`
就是这个约定）。

**加到 `.claude/settings.json`：**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PROJECT_DIR}/scripts/hooks/replay-guide-reminder.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**新文件 `scripts/hooks/replay-guide-reminder.sh`**（~20 LOC bash）。
从 stdin 读 `tool_input` JSON，取 `file_path` 字段，只在文件匹配
`runtime/lib/esr/commands/.*\.ex$` 时打提醒：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
case "$fp" in
  runtime/lib/esr/commands/*.ex|*/runtime/lib/esr/commands/*.ex)
    base="$(basename "$fp" .ex | tr A-Z a-z)"
    cat >&2 <<EOF
⚠️  你改了 $fp。
提交前跑 scripts/replay-guide.sh 对引用此命令的 guide 验证。
找候选 guide：rg "$base" docs/guides/
EOF
    ;;
esac
```

目标：改 command 文件时 agent / 开发者收到一行提醒。hook 跟现有
`pre-merge-dev-gate.sh`、`openclaw-channel-postcheck.sh` 装一起——
同一种约定、同一个 `scripts/hooks/` 目录。

### 3.6 CLAUDE.md 新增

3 短行，详细见 spec：

```
## Guide-driven e2e（防 drift）

- 改 command handler？提交前跑 `scripts/replay-guide.sh` 对相关 guide
- guide drift？提示用户 —— 修实现 OR 更新 guide。别静静忽略
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md)
```

按用户 CLAUDE.md 纪律（2026-05-10 设）：CLAUDE.md 保持紧凑，
长内容外链。

### 3.7 CI workflow step

`.github/workflows/ci.yml` 的 `build-and-test` job 追加：

```yaml
- name: Replay guides with fences
  run: |
    for guide in docs/guides/*.md; do
      if grep -q '^```chat-input' "$guide"; then
        bash scripts/replay-guide.sh "$guide"
      fi
    done
```

没 fence 的指南跳过（不挂）。等 Phase 2 给
`flow-bootstrap.md` 加上 fence，下个 PR 起 CI 就开始
抓 drift。

### 3.8 Fixture state 约定 —— all-inline

每个 guide **自包含**。每个 guide 的 fence 序列都从全新 fixture
（无 user、无 adapter、无 chat、无 workspace）起步，**所有 setup 步
都内联**作为 fence，然后才到本 guide 真正测试的流程：

- `flow-bootstrap.md` 从绝对零起 —— 它的 fence **就是** bootstrap 步骤。
- `flow-workspace-session.md` 先跑跟 bootstrap 一样的 fence，再做
  workspace + session 步。
- `flow-pty-attach.md` 先跑 bootstrap + workspace + session 的 fence，
  然后 PTY attach 步。

理由：spec 的核心原则是"1:1 复刻真实操作员路径"。操作员手工跑 guide
时每一步都做——bootstrap 包括在内；replay 工具也一样。这一约定
**排除了跨 guide 链接**（`# Requires: flow-bootstrap.md` 头部在 v1
**不支持**）——因为链接会把操作员可读的 fence 步骤替换成 replay 工具
的隐式魔法。

**缓解重复。** 重复的 bootstrap fence 不长（注册 adapter，然后
`user=linyilun` 通过 §3.2 自动绑定）。一个 guide **可以**用 markdown
散文（"下面 4 个 fence 跟 `flow-bootstrap.md` 步骤 1-4 相同"）给人类
读者建立上下文，但**fence 本身必须存在**——replay 工具只读 fence，
不读散文。

**与 §3.2 `user=` auto-bind 协同。** §3.2 的 `user=` auto-resolution
廉价地覆盖了 user 创建。adapter 注册、synthetic chat 创建、任何
workspace 状态都**必须**作为显式 fence 出现。

交叉引用：§3.3 的 `full-user-journey.md` 索引按深度排序 sub-flow。
更深的 guide 有更长的 setup fence 前缀；这是预期、不是 smell。

---

## 4. 迁移计划

4 阶段，~400 LOC 总。

### Phase 0：审计 + 清理 `docs/guides/`（~50 LOC，1 个 PR）

`docs/guides/` 现状（2026-05-10 审计）：

| 文件 | 状态 | 动作 |
|---|---|---|
| `flow-sessiontemplate-feishu-test.md`（Phase 0 由日期前缀名改名）| 当前（刚发）| 加 fence |
| `feishu-adapter-setup.md` | 当前 | 留；加 fence |
| `flow-bootstrap.md`（Phase 0 改名）| 当前 | 加 fence（可后续拆 `flow-bootstrap.md` + `flow-workspace-session.md`）|
| `operator-bootstrap-checklist.md` (+ `.zh_cn.md`) | 是 checklist 不是 journey | 留；从 `full-user-journey.md` 链作「验证 checklist」|
| （旧 agent-topology 指南）| 已过期（agents.yaml 在 Phase 6 注销）| **Phase 0 删除**；canonical 来源现在是插件 manifest 的 `agent_kinds:` 块 |

动作：
1. grep 每个 guide 找过期引用：`agents.yaml`、删除的 slash、rev-3
   之前 grammar 等。删真过期的；重写半过期的
2. 命名标准化：每个 per-flow guide 是 `flow-<topic>.md`
3. 建 `docs/guides/full-user-journey.md` 当索引（一开始空行 ——
   Phase 1+ 随 fence 落地填）
4. 退役 `2026-05-10-` 日期前缀名（一次性测试 guide；并入
   `flow-sessiontemplate-feishu-test.md`）

### Phase 1：基础（~150 LOC，1 个 PR）

- 写 `scripts/replay-guide.sh`（~100 LOC bash）
- 写 `scripts/check-scenario-headers.sh`（~30 LOC bash）—— 头部
  标注 linter
- 写 `scripts/hooks/replay-guide-reminder.sh`（~20 LOC bash），把对应的
  `PostToolUse` 条目加到 `.claude/settings.json`（具体格式见 §3.5）
- CLAUDE.md 加一节（3 行 + 链接）
- `.github/workflows/ci.yml` 加一步（replay + header-check）
- 烟测：合成最小指南 `docs/guides/_replay_smoke.md`，1 对 input/output；
  CI 跑绿

### Phase 2：Canary（~50 LOC + 指南升级）

- 升级 `docs/guides/flow-bootstrap.md`（Phase 0 改名，连同
  `.zh_cn.md` 镜像），给 5 个主步骤加 fence（workspace、session、
  agent、纯文本 → CC reply、TUI URL）
- `tests/e2e/scenarios/19_session_first_default.sh` 加
  `# Replays: docs/guides/flow-bootstrap.md` 头（或按 §3.4 替成
  thin-wrapper 形态）
- `docs/guides/full-user-journey.md` 加 bootstrap 一行
- 本地 replay → CI 绿
- 验证 2026-05-10 `/session:new name=test-cc` regression：对
  `dev@8777357`（pre-#334）回放 step 8 FAIL；对 post-#334 PASS。
  这就是 Phase 5 当时该带的 invariant

### Phase 3：随特性扩散

- 新特性发布 → `full-user-journey.md` 加一行 + 一个 per-flow
  指南带 fence。PR review 拒绝触 `runtime/lib/esr/commands/` 但
  没加 guide 行的 PR
- 现有指南被改时如果没 fence 就加上
- 每个迁移的 scenario 加 `# Replays: <guide>` 头
- 不强求一次到位；覆盖跟着正常特性工作扩散

如果一年下来还是有 drift 漏过 → 再考虑加
`mix esr.check_guide_coverage` 做绝对覆盖。`docs/futures/todo.md`
跟踪。

---

## 5. 验收标准

| # | 验收 | 验证 |
|---|---|---|
| 1 | `scripts/replay-guide.sh` 解析 + 回放 + 断言 fence pair | 对 `_replay_smoke.md` 单测烟测 |
| 2 | 改 `runtime/lib/esr/commands/*.ex` 时 hook 触发 | 手工触发 |
| 3 | CLAUDE.md 更新；spec 链接到位 | 看文件 |
| 4 | CI 对有 fence 指南跑 replay | 绿 PR |
| 5 | `docs/guides/flow-bootstrap.md` 5 主步骤都有 fence | 看指南 |
| 6 | 2026-05-10 regression 可表达成 fence；pre-#334 FAIL，post-#334 PASS | bisect 烟测（手工一次性）|
| 7 | `docs/guides/full-user-journey.md` 存在做金标准索引，列出每个 fenced sub-flow | 看文件 |
| 8 | 每个 `tests/e2e/scenarios/*.sh` 在头部声明 `# Replays: docs/guides/<file>.md` | `scripts/check-scenario-headers.sh` exit 0 |
| 9 | 过期 guide 已删 / 改名（Phase 0 审计后）| `git diff` Phase 0 PR |

---

## 6. 开放问题 / 未来工作

`docs/futures/todo.md` 跟踪：

1. **覆盖 gate**（`mix esr.check_guide_coverage`）。等真有 drift
   出现在没 fence 的命令上再做
2. **CLI fence language**（`cli-input` / `cli-output`）。等真有
   admin-CLI-only drift 浮现再加
3. **从 `Esr.Commands.Meta` 自动 baseline 指南**。`docs/grammar/*`
   per-command 生成已就位；journey 自动派生重，不阻塞
4. **mock_feishu 协议版本**（独立 spec，infra 层）
5. **PTY / web 流** —— `/claude_code:tui` 返 URL 操作员点击。
   replay v1 通过 http 断言 URL 形状；全浏览器回放推后

---

## 7. 批准 gate

用户（linyilun）通过飞书批准。批准后：

1. 本 spec commit（PR #335 已开）
2. 通过 `superpowers:writing-plans` 写 plan 到
   `docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md`
3. 实施从 Phase 1 开始
