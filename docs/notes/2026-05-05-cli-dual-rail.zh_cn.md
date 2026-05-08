# e2e CLI 双轨化（Phase A — 2026-05-05）

**状态：** 基础设施落地。escript 轨道**预期今天会红**——这正是
迁移进度的 gate。

## 为什么要做

Phase A 之前每个 e2e 场景都直接调 Python CLI：

```bash
uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit ...
```

—— 8 个 scenario 脚本里 27 处。Phase 2 发的"escript 替代 Python
CLI"声称（PR-2.5/2.6 escript build）**e2e 上零覆盖**。"Phase 2
完成"可以合并，而 escript 实际上一个 operator 真在用的命令都没
覆盖。

双轨模式修这个：同一组 e2e 断言在两个轨道上跑；escript 轨道
失败的地方精确告诉我们 PR-4.6 / PR-4.7（删 Python CLI）落地前
还有哪些命令要迁。

## 怎么工作

`tests/e2e/scenarios/common.sh` 导出一个 helper：

```bash
esr_cli() {
  if [[ "${RUN_VIA:-python}" == "escript" ]]; then
    # 读 ${ESRD_HOME}/${ESR_INSTANCE}/esrd.port；设置 ESR_HOST。
    # 端口文件不存在则回落 127.0.0.1:4001。
    ESR_HOST="..." "${_E2E_REPO_ROOT}/runtime/esr" "$@"
  else
    uv run --project "${_E2E_REPO_ROOT}/py" esr "$@"
  fi
}
```

Scenario 调 `esr_cli admin submit foo --arg bar=baz`，不再写显式
`uv run`。同样的断言（`assert_contains "$OUT" "ok: true"`）今天
比对 Python 轨道，迁移后比对 escript 轨道。

Make 目标：

| 目标 | 跑什么 |
|---|---|
| `make e2e` | 所有 scenario 走 Python 轨（默认——保 Phase-A 之前的基线）。|
| `make e2e-cli` | CLI 触接 scenario（08 + 11）走 `RUN_VIA` 选的轨。|
| `make e2e-escript` | `RUN_VIA=escript make e2e-cli` 简写。|

## 双阶段迁移纪律

按用户 2026-05-05 的要求：每个代码构成迁移必须在**两端**都展示
e2e 绿：

1. **Phase A — gate 存在。** 同样的 e2e，`RUN_VIA` 切换暴露新
   轨跑不通哪些命令。今天：大部分红。
2. **Phase B — 填空。** 每个 PR 加一族 slash route（`/actors`、
   `/cap`、`/users`、`/reload`……）直到 escript 轨道断言一一
   匹配 Python 轨。
3. **Phase C — 删旧轨。** 当 `RUN_VIA=escript make e2e` 全绿，
   把 e2e 默认切到 escript-only 并删除 `py/src/esr/cli/`。在那
   之前，Python 轨保留——它是证明"用户可见行为没退化"的基线。

每个迁移 PR 描述里必须答：

- **Surface 变？** Y/N。Y 则列新增 e2e 断言。
- **同一 e2e 下代码路径变？** A → B 路径写明。
- **双轨证据：** 改前 Python 轨绿，改后 escript 轨绿。**断言
  不变 + 轨道变 = 迁移证明。**

## 今天预期 escript 轨红的地方

不实跑（实际 sweep 在 PR 的 CI 段做），预测红集：

1. **`esr actors list`** —— scenario 01、02、04、05 都用。escript
   没有 `actors` 命令、也没 `/actors` slash route。Phase B-1 关。
2. **`admin submit X` 输出格式不一致** —— escript 渲染
   `"ok: " <> Jason.encode!(result)`，Python 输出多行 YAML
   （`ok: true\nsession_id: ...`）。`assert_contains "$OUT" "ok: true"`
   这种断言根据精确子串可能过、可能不过。Phase B-1 统一。
3. **`admin submit help`**（e2e 08）—— escript exec 路径走 HTTP
   schema dump 处理 `help`，但 `admin submit help` 走 queue-file
   dispatch 可能不出预期的 `ok: true` 信封。CI 见。Phase B-1 审计。

这个 PR 不是来修这些的。这个 PR 是把它们变得**可测量**。
Phase B PR 每个把一个断言转绿。

## 这个 PR 不做的事

- **不让 escript 自动从 port 文件发现**端口——helper 做了，但
  `esr` 二进制本身仍只读 `ESR_HOST`。Phase B 跟进。
- **不对齐 Python / escript 输出格式。** Phase B-1。
- **不加新 slash route。** Phase B-1 到 B-4 做。
- **不删任何 Python CLI 代码。** Phase C 做。

## 改动文件

- `tests/e2e/scenarios/common.sh`：加 `esr_cli()` helper，
  切换 `assert_actors_list_*` + `register_feishu_adapter`。
- `tests/e2e/scenarios/{01,02,04,05,08,11}*.sh`：27 个内嵌调用
  切到 `esr_cli`。
- `Makefile`：加 `e2e-08`、`e2e-11`、`e2e-cli`、`e2e-escript`。
- 本笔记。

## 引用

- 记忆规则（2026-05-05）："Completion claim requires invariant
  test." 多 PR 阶段不是"PR 都合了就完成"，是"目标不达成时有测试
  会失败"。双轨化就是"Python CLI 替换完成"的那个测试。
- North Star：插件隔离。escript 只通过 slash route 调度（不硬
  编码插件名），直接服务"未来开发者无需协调就能在不同插件上
  工作"的目标。
