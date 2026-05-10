# Guide-driven e2e（防 drift）

**Status：** Draft —— 待用户批准
**日期：** 2026-05-10
**Author：** Claude (与 linyilun)
**配套文件：** [`.md`](2026-05-10-guide-driven-e2e.md) —— 英文原版

---

## 1. 为什么现在做

Phase 5（SessionTemplate + Channel migration）发布的 regression：
`Esr.Commands.Session.New.execute/2` 的 bare `/session:new name=test-cc`
形态（不带 `agent=` / `dir=` / `workspace=`）撞上 Phase 5 之前留下的
stale `validate_args` gate。**Scenario 25**（Phase 5 显式 invariant
测试，名 `25_session_template_instantiation.sh`）CI 跑绿。生产飞书
里第一次试就 `error: invalid_args`。

调研出三个根因：

1. **路径不一致**。所有现有 e2e scenario 通过 `esr_cli admin submit
   session_new --arg dir=... --arg ...` 触发 `session_new`。这绕开
   `Esr.Entity.SlashHandler.merge_chat_context/3` —— 注入
   `chat_id`/`app_id`/`caller_principal_id` 的 chat envelope 层。生产
   操作员在飞书 chat 里输入 `/session:new ...`，走 SlashHandler 路径。
   两条路径喂给 `execute/2` 的 args 形状不同。

2. **参数覆盖空洞**。24 个 scenario 全都传 `--arg dir=`，多数还传
   `--arg agent=` 或 `--arg workspace=`。bare `name=`-only 形态 ——
   操作员实际敲的形态 —— 从未被测过。bug 只在 `agent` + `dir`
   都 absent 时触发。

3. **指南 drift**。`docs/guides/operator-bootstrap-journey.md` 等指南
   描述操作员 journey、含 copy-paste 块，但没有机器可读的 readback
   把指南跟 e2e 套绑定。实现一变（Phase 5），指南静静跟现实拉开
   距离。跟着指南走的用户撞墙，撞的还是 e2e 套从未碰过的位置。

本 spec 提结构性修复：**指南成为 source of truth；e2e scenario 是
对指南步骤的机械回放**。实现 vs 指南的 drift 在 CI 表面化为指南
回放失败，而不是只有生产用户看见的失败。

---

## 2. 目标 & 非目标

### 目标

- **锁定指南为操作员 journey 的 source of truth。** 每个 chat-callable
  + 每个 CLI-callable 命令在至少一个指南步骤里出现。
- **机械回放。** 新 `mix esr.replay_guide` mix 任务解析每个
  `docs/guides/*.md`，提取机器可读的 input/output 对，通过生产代码
  路径（chat 走 mock_feishu；CLI-only 走 `esr_cli admin submit`）驱动，
  断言输出匹配。
- **覆盖 gate。** `mix esr.check_guide_coverage` 列举所有注册的命令
  kind，断言每个至少在一个指南步骤出现。新命令缺指南覆盖时构建挂掉。
- **失败方式 actionable。** 回放看到 mismatch 时，输出 unified diff
  指出指南路径 + 步骤号 + expected vs actual。开发者要么修实现，
  要么改指南。
- **三层分离。** **Infra**（mock_feishu / mock_claude_code）稳定，
  跟着外部产品。**指南**（markdown narrative）操作员可见的 source
  of truth。**回放引擎**桥接两者。每层一个目的，互不波及。

### 非目标

- **不替换 `Esr.Commands.Meta` 驱动的 `docs/grammar/*` 生成。** 单命令
  字典（`command_meta()` callback → `commands.md` + `errors.md`）保留。
  这是另一种 artifact（单命令字典 vs 多命令 journey）。
- **不自动生成指南。** 指南是人写的 narrative。从 `Esr.Commands.Meta`
  自动派生作 follow-up 写在 `docs/futures/todo.md`；本 spec 只在
  人写散文里嵌机器可读 fence。
- **不测 Feishu 协议。** mock_feishu 跟真 Feishu 的契约属 infra 层
  关切（独立 spec / 出范围）。
- **不替单测。** 回放测试在金字塔里位于单测之上 —— operator-journey
  集成测。函数级单测保留。
- **不全保真 Lark 集成。** 真 Feishu sidecar 对 Lark API 是发布期
  smoke（手工或定时），出范围。回放用 mock_feishu。

---

## 3. 架构 —— 三层

```
┌─────────────────────────────────────────────────────────────────────┐
│ 第三层 —— 回放引擎  （随 spec 变；之后基本不动）                       │
│   mix esr.replay_guide     —— 解析 + 驱动 + 断言                     │
│   mix esr.check_guide_coverage —— 注册表 vs 指南步骤                 │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ 驱动
┌──────────────────────────────────▼──────────────────────────────────┐
│ 第二层 —— 指南  （随功能变；这就是 source of truth）                  │
│   docs/guides/*.md   —— 操作员 journey，narrative + 带 fence 的步骤  │
│   docs/guides/*.zh_cn.md  （镜像；narrative 翻译，fence 共享）        │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ 通过它回放
┌──────────────────────────────────▼──────────────────────────────────┐
│ 第一层 —— infra  （罕变；只跟着外部产品）                             │
│   mock_feishu.py            —— Lark 协议 mock（push_inbound /        │
│                               reply 抓取 / reaction 生命周期）       │
│   mock_claude_code  （未来需要时再加）                               │
│   esrd 测试实例             —— 每次回放隔离的 $ESRD_HOME             │
└─────────────────────────────────────────────────────────────────────┘
```

**为什么三层不是两层：** infra 层的稳定性跟 scenario 层的正确性是
两个独立关切。混在一起（今天的 `tests/e2e/scenarios/common.sh` 把
infra setup + scenario 步骤同一个 shell 文件）导致 infra 改一下
所有 scenario 都波及；scenario 改一下不小心动了 infra。回放引擎
位于中间，自己拥有回放逻辑，让指南 + infra 各自只关心一件事。

**什么放哪里：**

- `mock_feishu.py`（已存在 `py/src/feishu_adapter_runner/mock_feishu.py`）：
  行为不变。继续暴露 `push_inbound` / `reply_capture` / `react_capture`。
  回放引擎驱动它。
- `tests/e2e/scenarios/common.sh`：缩小。esrd 测试实例 + mock_feishu
  的 boot/teardown 留下；per-scenario 逻辑迁到指南。
- `docs/guides/*.md`：加 fence 块（§4 详述）。
- `tests/e2e/scenarios/<topic>.sh`：每个变 5 行 wrapper：

```bash
#!/usr/bin/env bash
# scenario 25 —— 回放 docs/guides/operator-bootstrap-journey.md
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
exec mix esr.replay_guide --guide=docs/guides/operator-bootstrap-journey.md
```

---

## 4. Guide-fence 协议

约定：markdown fenced code block 用特定 language tag。回放引擎按
文档顺序提取。

### 4.1 Fence 语言

| Language | 方向 | 通道 | 断言？ |
|---|---|---|---|
| `chat-input` | 操作员 → bot | mock_feishu push_inbound | 否（输入）|
| `chat-output` | bot → 操作员 | mock_feishu reply_capture | 是 |
| `cli-input` | 操作员 → CLI | `esr_cli admin submit` | 否（输入）|
| `cli-output` | CLI → 操作员 | stdout | 是 |
| `cli-stderr` | CLI → 操作员 | stderr | 是 |
| `setup-bash` | scenario fixture | shell 执行 | 是（exit 0）|

`setup-bash` 覆盖那些不算操作员动作但 scenario 跑起来要做的事
（如建一个干净的 `~/.esrd-test/` 状态、export env）。少用；多数
setup 留给 `common.sh`。

### 4.2 Fence frontmatter（language 之后的 info string）

`chat-input` 必带 `app_id` + `chat_id` + （可选）`user`。例：

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/session:new name=test-cc
```
````

回放引擎把 `app_id` 映射到 mock_feishu 配置好的某 adapter 实例，
`chat_id` 映射到合成测试 chat，`user` 映到 Feishu `open_id`（通过
测试 fixture 的 user 表解析）。`user` 缺省时引擎用默认测试操作员
（按 ESR bootstrap 约定 `linyilun`）。

`chat-output` / `cli-output` 接受可选 `capture=<varname>` 把匹配的
placeholder 绑给后续步骤：

````markdown
```chat-output capture=session_id
ok: true
session_id: <UUID>
```

```chat-input app_id=esr_helper_dev chat_id=oc_test_chat
/session:end session={{session_id}}
```
````

### 4.3 Placeholder 语法

| Token | 匹配 |
|---|---|
| `<UUID>` | UUID v4 |
| `<UUIDv7>` | UUID v7（如/未来切到）|
| `<int>` | 一个或多个十进制数字 |
| `<word>` | `[A-Za-z0-9_-]+` |
| `<string>` | 一个或多个非换行字符 |
| `<…>` | 通配，忽略此处（不捕获）|
| `<...>` | 同上，ASCII 变体 |

Placeholder 逐行匹配。fence body 一行匹配实际输出一行 当 每个
placeholder 给其 token 分配了合法匹配。非 placeholder 文字字面匹配。

### 4.4 多行 + 顺序语义

默认 fence body 按行顺序匹配输出。如果实际输出多余行，匹配失败 ——
除非 fence 结尾用 `<…>` 表示「多余行可以」。输出顺序严格：
`chat-output` fence 必须是紧前 `chat-input` 的下一个回复。要断言
「N 秒内无回复」用 `chat-silent` fence（推到 v1.1；v1 要求每个
input 必带 output）。

---

## 5. 回放引擎 —— `mix esr.replay_guide`

### 5.1 公开界面

```
mix esr.replay_guide [--guide=<path>] [--all] [--strict] [--verbose]
```

- `--guide=<path>` —— 回放一个指南。无 flag 默认。
- `--all` —— 回放所有 `docs/guides/*.md`。
- `--strict` —— warning（多余行、未识别 fence language）也挂。
  默认 warn。
- `--verbose` —— 每步运行时打印。

全成功 exit 0；任何 mismatch / setup 失败 non-zero。

### 5.2 内部流程

```
1. 读 docs/guides/<topic>.md
2. markdown 解析器 → token stream
3. 提取 language ∈ {chat-input, chat-output, cli-input, cli-output,
   cli-stderr, setup-bash} 的 fenced 块
4. 文档顺序配对 input/output；对错位（连两 output、input 没 output 等）
   报结构错，指出指南行号
5. boot 测试 fixture：
   - 新 $ESRD_HOME 在 /tmp/esr-replay-<run-id>/
   - 起 mock_feishu.py 在自由端口
   - 通过 scripts/esrd.sh start --instance=replay-<run-id> 起 esrd
   - 等待 ready
6. 走步骤列表：
   - chat-input  → mock_feishu push_inbound；抓下一回复（30s 超时）
   - chat-output → 断言抓到的回复匹配 fence body（逐行 + placeholder）
   - cli-input   → spawn `esr_cli admin submit ...`；抓 stdout/stderr
   - cli-output  → 断言 stdout 匹配
   - cli-stderr  → 断言 stderr 匹配
   - setup-bash  → bash -c body；断言 exit 0
7. teardown：停 esrd；停 mock_feishu；rm -rf fixture 目录
8. 打印汇总："<guide>: N steps replayed, <PASS|FAIL>"
```

### 5.3 错误报告

mismatch 时：

```
✗ docs/guides/operator-bootstrap-journey.md (step 8 of 14, line 142)

  chat-input  app_id=esr_helper_dev chat_id=oc_test_chat
  ┃ /session:new name=test-cc

  expected (chat-output):
  ┃ ok: true
  ┃ session_id: <UUID>

  actual:
  ┃ ok: false
  ┃ type: invalid_args
  ┃ message: "session_new agent required"

  → step failed at line 142；要么实现跟指南偏（跑
    `git log --since='2 weeks ago' runtime/lib/esr/commands/session/new.ex`
    查近期改动）要么指南过期（按新行为更新 fence body）。
```

提示行算出来的：expected != actual 时扫近期触及怀疑源文件的提交
（从 input slash kind → command_module 通过 SlashRoute Registry
解析）。

---

## 6. 覆盖 gate —— `mix esr.check_guide_coverage`

### 6.1 断言什么

每个在 `Esr.Resource.SlashRoute.Registry` 注册的命令 kind 至少在
`docs/guides/*.md` 的某 fenced 步骤里出现。

kind 从 fence body 提取：

- `chat-input`：解析 slash 文本 → `/session:new ...` → 通过注册表
  解析为 kind `session_new`。
- `cli-input`：从 `esr-dev exec <kind> ...` 或 `esr_cli admin submit
  <kind> ...` 解析 kind 名。

不能明确解析到 kind 的步骤（如纯文本 "hello, what's the cwd?" 通过
chat-input 走当 `/help` 测）不计数。回放引擎 log 每一 kind-coverage
hit；覆盖 gate 聚合。

### 6.2 输出

```
$ mix esr.check_guide_coverage

✓ 73 / 73 chat-callable kinds covered
✓ 12 / 12 internal kinds covered

Per-kind coverage:
  session_new: docs/guides/operator-bootstrap-journey.md (step 7),
               docs/guides/sessiontemplate-feishu-test.md (step 3)
  workspace_new: docs/guides/operator-bootstrap-journey.md (step 5)
  ...
```

有缺口时：

```
✗ 71 / 73 chat-callable kinds covered (2 gaps)

Uncovered kinds:
  agent_remove
  pty_attach

加指南覆盖：在某指南里加一个 chat-input 或 cli-input fence，其
slash/kind 解析到每个未覆盖 kind。覆盖 gate 在 CI 强制
（.github/workflows/ci.yml）。
```

### 6.3 CI 接入

`.github/workflows/ci.yml` 在现有 `mix esr.check_command_docs` 之后
加两步：

```yaml
- name: Replay guides
  run: cd runtime && mix esr.replay_guide --all --strict

- name: Check guide coverage
  run: cd runtime && mix esr.check_guide_coverage
```

两个失败都 block merge。

---

## 7. 迁移计划

五阶段；~1500 LOC + 双语指南升级。

### Phase A —— 基础（回放引擎 + 覆盖 gate，不迁移）

- 新：`runtime/lib/mix/tasks/esr/replay_guide.ex`
- 新：`runtime/lib/mix/tasks/esr/check_guide_coverage.ex`
- 新：`runtime/lib/esr/guide/parser.ex`（markdown fence 提取器）
- 新：`runtime/lib/esr/guide/replay_runner.ex`（驱动 + 断言）
- 新：`runtime/lib/esr/guide/kind_resolver.ex`（slash 文本 → kind 名）
- 测试：每模块 70%+ 单测覆盖
- 一个小合成指南 `docs/guides/_replay_smoke.md` 端到端覆盖每种 fence；
  CI 跑它

### Phase B —— Canary（operator-bootstrap-journey）

- 升级 `docs/guides/operator-bootstrap-journey.md`（连同 `.zh_cn.md`
  镜像；fence 共享）用新 fence 约定
- 把 `tests/e2e/scenarios/19_session_first_default.sh` 内容换成 5 行
  调 `mix esr.replay_guide --guide=...` 的 wrapper
- 验证 CI 绿
- 验收：2026-05-10 `/session:new name=test-cc` regression 可以表达
  成单一 fence pair，并能逮到这次 bug

### Phase C —— 批量迁移（其余指南 + scenario）

`docs/guides/` 现有指南：
- `operator-bootstrap-journey.md`（Phase B）
- `feishu-adapter-setup.md`
- `2026-05-10-sessiontemplate-feishu-test.md`
- `operator-bootstrap-checklist.md`（这是 checklist 不是 journey；
  评估是否采用 fence 或保持原状）

加 fence。把每个现有 scenario 映到指南回放 wrapper。

per-scenario 决策：
- 有对应指南 → 替为回放 wrapper
- 没指南但代表操作员 journey → 先写指南再回放
- 测 admin-CLI-only 流（如 scenario 04 multi-app routing、scenario 27
  dependency-unmet 结构化错误）→ 指南做「高级 / admin journey」或
  legacy bash 保留。明确标注

每个 scenario 迁一次提交。

### Phase D —— CI gate

- 把 `mix esr.replay_guide --all` + `mix esr.check_guide_coverage`
  接入 `.github/workflows/ci.yml`
- block 掉 PR 让覆盖率 drop（covered → uncovered 转移用对 `dev` HEAD
  的 diff 检测）

### Phase E —— 清理 + linter

- 审 `tests/e2e/scenarios/common.sh`。删 chat-callable 命令绕开
  SlashHandler 的 helpers（Phase 5 regression 的诱因）
- 加 linter（mix 或 shell）：`tests/e2e/scenarios/` 下任何对
  slash-callable kind 用 `esr_cli admin submit` 的文件被 reject，
  除非显式 allowlist（admin-CLI-only 流）
- 更新 `CLAUDE.md` 加一行链接：`- [Guide-driven e2e](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md) — drift prevention via guide replay.`

---

## 8. 验收标准

| # | 验收 | 验证 |
|---|---|---|
| 1 | `Esr.Resource.SlashRoute.Registry` 所有 chat-callable kind 至少 1 个指南步骤覆盖 | `mix esr.check_guide_coverage` exit 0 |
| 2 | 所有 admin-CLI kind 至少 1 个指南步骤覆盖 | 同上 |
| 3 | `mix esr.replay_guide --all --strict` 通过 | CI |
| 4 | 2026-05-10 `/session:new name=test-cc` regression 在 `operator-bootstrap-journey.md` 编为 fence；对 pre-fix `dev@8777357` 回放在那里 FAIL；对 post-fix `dev@<post-#334>` PASS | bisect smoke（手工一次性）|
| 5 | Guide-replay 报告 drift 时给文件:行 + diff | 检查失败输出 |
| 6 | `mock_feishu.py` 跟 `common.sh` infra 层在本 PR 系列零变化（无 infra 跟 guide 格式耦合）| review diff |
| 7 | `docs/grammar/{commands,errors}.md` 继续从 `Esr.Commands.Meta` 生成（不变）| `mix esr.gen_command_docs` 跑干净 |

---

## 9. 开放问题 / 未来工作

推后 —— 不阻塞基础发布：

1. **从 `Esr.Commands.Meta` 自动 baseline 指南。** 未来
   `mix esr.gen_baseline_guide --command=<kind>` 从
   `command_meta()` 的 examples 输出 starter fence 序列。开发者
   再人化。`docs/futures/todo.md` 跟踪。

2. **并行。** 30+ 指南串行回放可能几分钟。每指南 fixture-dir
   隔离已经设计好；通过 `mix run` worker 横跨指南并行作 follow-up。

3. **Fixture 新鲜度。** 有些指南（如 plugin-config-hot-reload）
   要干净 fresh-install；有些在同一状态上增量。回放引擎默认
   per-guide 新鲜；显式 fixture-share 标注让 chain 共享状态。
   有真用例才上。

4. **mock_feishu 协议版本。** 真 Feishu 加新事件形状时，mock_feishu
   契约 drift。出范围；由 infra 层自己的 gating 覆盖（钉 Lark API
   版本 + 对录制的真事件语料的 contract-test）。

5. **PTY/web 流的浏览器驱动 scenario。** `/claude_code:tui` 返一个
   操作员点的 URL。今天 scenario 22 / phase E 测通过 http GET 断言
   URL 形状，不是真浏览器会话。无头浏览器层（playwright?）严格
   超 v1 范围；推后。

6. **国际化指南输出。** mock_feishu 回放操作员文本；如果命令渲染
   中文（一些 `/doctor` / `/help` 输出是中文），fence body 字面
   含那些中文。OK。如果输出变 locale-aware（per-user 语言切换），
   fence 需要 locale 标注。推后。

---

## 10. 批准 gate

用户（linyilun）通过飞书回复批准本 spec。批准后：

1. spec 提交到 `docs/superpowers/specs/2026-05-10-guide-driven-e2e.md`
   （英文原版）+ `.zh_cn.md`（本镜像）
2. 通过 `superpowers:writing-plans` 写 plan 到
   `docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md`
3. 实施从 Phase A 开始

---

## 附录 A —— 工作示例：2026-05-10 regression 表达成 fence

scenario 25 在新世界里应该长这样：

````markdown
### Step 8：bare `/session:new name=` 解析为默认 template

Phase 5 之后 `feishu-cc` 是 auto-elect 默认 template（fresh-install
后唯一注册的）。操作员只敲 `/session:new name=test-cc` 应该成功 ——
不需要 `agent=`、`dir=`、`template=`、`workspace=` —— 其它每个 arg
从 chat-current 状态 + 默认 template 自动解析。

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

对 `dev@8777357`（pre-#334）回放：实际是
`{ok: false, type: invalid_args, ...}` mismatch → CI block Phase 5 PR。

对 post-#334 回放：两行都 match → CI 绿。

这就是 Phase 5 当时应该带的 **invariant gate**。
