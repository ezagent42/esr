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

1. **路径不一致。** 所有 e2e scenario 都通过 `esr_cli admin submit ...`
   触发命令，绕开 `Esr.Entity.SlashHandler.merge_chat_context/3`
   （chat envelope 注入器）。生产走 SlashHandler；测试不走。
2. **参数覆盖空洞。** 24 个 scenario 全都显式传 `--arg dir=`。操作员
   实际敲的 bare `name=`-only 形态从未被测过。
3. **指南 drift。** `docs/guides/*.md` 描述操作员 journey。没有机器
   readback 把指南绑到 e2e。实现一变就静静跟指南偏。

**修复：** 指南成为操作员 journey 的 source of truth；一个小脚本
通过生产代码路径回放指南步骤。

---

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
- 不写 Elixir mix 任务做回放/覆盖。100 行 bash 脚本 + hook + CLAUDE.md
  规则覆盖 recurring drift class，不需要新增 4 模块的 Elixir 子系统。
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
scripts/replay-guide.sh docs/guides/operator-bootstrap-journey.md
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

### 3.3 Claude Code hook

`.claude/hooks/replay-guide-reminder.json`：

```json
{
  "event": "PostToolUse",
  "matcher": {
    "tool_name": ["Edit", "Write", "MultiEdit"],
    "args.file_path": "runtime/lib/esr/commands/.*\\.ex$"
  },
  "command": "echo '⚠️  改了 command handler。提交前跑 scripts/replay-guide.sh 对相关 guide 验证。找相关 guide：rg \"$(basename $(echo \"<file_path>\" | sed -e \"s|.*/||\" -e \"s|\\.ex$||\" | tr A-Z a-z))\" docs/guides/'"
}
```

具体 hook DSL 跟项目现有 hook 约定（看 `docs/futures/todo.md` 或
`hookify:` skill）。目标：改 command 文件时 agent / 开发者收到
一行提醒。

### 3.4 CLAUDE.md 新增

3 短行，详细见 spec：

```
## Guide-driven e2e（防 drift）

- 改 command handler？提交前跑 `scripts/replay-guide.sh` 对相关 guide
- guide drift？提示用户 —— 修实现 OR 更新 guide。别静静忽略
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md)
```

按用户 CLAUDE.md 纪律（2026-05-10 设）：CLAUDE.md 保持紧凑，
长内容外链。

### 3.5 CI workflow step

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
`operator-bootstrap-journey.md` 加上 fence，下个 PR 起 CI 就开始
抓 drift。

---

## 4. 迁移计划

3 阶段，~300 LOC 总。

### Phase 1：基础（~150 LOC，1 个 PR）

- 写 `scripts/replay-guide.sh`（~100 LOC bash）
- 加 `.claude/hooks/replay-guide-reminder.json`（按 hook DSL 等价）
- CLAUDE.md 加一节（3 行 + 链接）
- `.github/workflows/ci.yml` 加一步
- 烟测：合成最小指南 `docs/guides/_replay_smoke.md`，1 对 input/output；
  CI 跑绿

### Phase 2：Canary（~50 LOC + 指南升级）

- 升级 `docs/guides/operator-bootstrap-journey.md`（连同 `.zh_cn.md`
  镜像、fence 共享），给 5 个主步骤加 fence（workspace、session、
  agent、纯文本 → CC reply、TUI URL）
- 本地 replay → CI 绿
- 验证 2026-05-10 `/session:new name=test-cc` regression：对
  `dev@8777357`（pre-#334）回放 step 8 FAIL；对 post-#334 PASS。
  这就是 Phase 5 当时该带的 invariant

### Phase 3：随特性扩散

- 新特性发布时它的指南顺手加 fence
- 现有指南被改时如果没 fence 就加上
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
| 5 | `operator-bootstrap-journey.md` 5 主步骤都有 fence | 看指南 |
| 6 | 2026-05-10 regression 可表达成 fence；pre-#334 FAIL，post-#334 PASS | bisect 烟测（手工一次性）|

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
