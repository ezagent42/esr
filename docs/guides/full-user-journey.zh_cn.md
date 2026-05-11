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
