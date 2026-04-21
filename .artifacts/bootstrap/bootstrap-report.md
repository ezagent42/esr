---
type: bootstrap-report
id: bootstrap-report-001
status: executed
producer: skill-0
created_at: "2026-04-21"
project: esr
branch: feat/sy-discuss
duration_minutes: ~120
---

# Bootstrap Report: ESR v0.2-channel

## 环境问题与解决

### Step 2 发现的状态

| 工具 | 结果 | 严重度 |
|------|------|--------|
| python3 | ✅ 3.14.3 (brew python@3.14) | ready |
| uv | ✅ 0.7.15 | ready |
| node | ✅ v22.17.0 | ready |
| pytest | ⚠️ env-check 误报 ready，实际需 `uv sync` | resolved (Step 2.5) |
| git | ✅ 2.43.0 | ready |
| tmux | ✅ 3.6a | ready (cc_tmux 必需) |
| zellij | ✅ 0.44.1 | ready |
| asciinema | ✅ 2.4.0 | ready |
| docker | ❌ missing | soft (v0.2 不需) |
| **elixir/mix/erl** | **❌ 完全缺失** | **HARD（runtime/ 39 个 ExUnit 测试需要）** |

### Step 2.5 自动修复

1. **`brew install elixir`** —— 安装 Erlang/OTP 28.4.2 + Elixir 1.19.5。耗时约 7 分钟（X11/wxwidgets/llvm 依赖链很长，但 bottle 已预下载）。
2. **`cd py && uv sync --dev`** —— 拉齐 49 个 Python dev dependencies（pytest 9.0.3、pytest-asyncio、pytest-cov、ruff、mypy 等）。
3. **`cd runtime && mix deps.get && mix compile`** —— 拉取 20+ Hex 包（phoenix 1.8、bandit、jason、yaml_elixir、credo、dialyxir、phoenix_pubsub、telemetry_metrics、telemetry_poller、dns_cluster），然后 `mix compile` 干净通过（仅 1 条样式 warning，见 ELIXIR-2）。

### 无法自动修复 / 跳过

- **Docker** — 软依赖，v0.2 未使用，标 missing-soft 跳过。
- **Lark live credentials (`~/.esr/live.env`)** — 软依赖，仅影响 `final_gate.sh --lark` 真 API 模式；mock 模式全套绿，不阻塞。
- **`gh` CLI** — 仅 `close-issue.sh` 在 Step 6 triage rejection 时使用；后续按需安装。

## 测试执行结果

### 总结

| 维度 | 数 |
|------|----|
| **总测试** | 636 |
| **通过** | 630 (99.21%) |
| **失败** | 5 (0.79%) |
| **跳过** | 1 (代码级条件门控) |
| **环境性 error/skip** | 0 ✅ |

### 各 suite 明细

| Suite | 命令 | 通过 | 失败 | 跳过 | 备注 |
|-------|------|------|------|------|------|
| python (py + adapters[2] + handlers[4]) | `cd py && uv run pytest` | 440 | 0 | 1 | 1 skip = `test_ipc_integration_live` (ESR_E2E_RUNTIME 门控) |
| adapter-cc-mcp | `PYTHONPATH=src uv run --with mcp …` | 7 | 0 | 0 | 不在 py testpaths（CC-MCP-1） |
| scripts (pytest) | `uv run --project py pytest scripts/tests/` | 32 | 1 | 0 | SCRIPTS-1 fixture 过期 |
| scripts (bash) | `bash scripts/tests/test_esrd_sh.sh` | 6 | 0 | 0 | esrd 生命周期 |
| elixir | `cd runtime && mix test` | 151 | 4 | 0 | ELIXIR-1 timing flaky |

### Failed 测试根因分类

#### SCRIPTS-1（代码 bug） — 1 failure
- **测试**：`scripts/tests/test_loopguard_scenarios_allowlist.py::test_exactly_one_allowed_file_passes`
- **根因**：v0.2-channel 在 `scripts/loopguard_scenarios_allowlist.py:8` 把 allowlist 从 `{e2e-feishu-cc.yaml}` 扩展到 `{e2e-feishu-cc.yaml, e2e-esr-channel.yaml}`，但测试 fixture 仍只写其中一个文件。属于"产品代码改了，测试 fixture 没跟上"的典型 stale-fixture bug。
- **修复**：在 `tmp_path` 设置中追加创建 `e2e-esr-channel.yaml`，使 fixture 与 v0.2 allowlist 一致。

#### ELIXIR-1（test-harness flaky）— 4 failures
- **测试**：`EsrWeb.CliChannelTest` 中的 4 个 `cli:*` topic 测试（run/stop/deadletter/unknown）
- **现象**：`assert_receive` 100ms 默认超时在 `max_cases=16` 并行下超时；`--max-cases 1 --seed 0` 串行减到 2 个；`mix test test/esr_web/cli_channel_test.exs` 单独跑 19/19 全过。
- **根因**：测试本身的 timing 假设过紧 + 并行 case 之间 PubSub 消息排队延迟。不是 runtime bug。
- **修复方向**：增大 `assert_receive` timeout 到 500ms，或给 CliChannel 的 cli:* sub-tests 加 `:async false`，或用 ExUnit `describe` 块 + `:serial` 标签隔离。

#### ELIXIR-2（style warning，非 failure）
- **位置**：`runtime/lib/esr/topology/instantiator.ex:332`
- **现象**：`defp issue_init_directive/2` 在 261 行已定义，332 行又定义，中间被其他 helper 隔开。Elixir 编译器要求 same name/arity 的 defp 子句相邻。
- **修复**：把两个子句移到一起。

#### CC-MCP-1（build-config gap）
- **现象**：`adapters/cc_mcp` 的 editable install 没在 `py/pyproject.toml` 的 `[tool.uv.sources]` 和 `[dependency-groups].dev` 中，`adapters/cc_mcp/tests` 也没在 `[tool.pytest.ini_options].testpaths`。
- **影响**：`make test-py` 不会跑 cc_mcp 测试；CI / final_gate 对 cc_mcp 的覆盖间接来自 e2e-esr-channel scenario。
- **修复**：补 sources + dependency-group + testpaths 三处。

### Step 4 环境性 error/skip 循环

**无环境性 error/skip。** Step 2.5 一次性修复了 elixir 缺失这唯一的 hard dependency。Step 4 第一次执行就所有 suite 全部正常运行（passed/failed 即真实测试结果）。

## 覆盖分析

详见 `.artifacts/coverage/coverage-matrix.md`。摘要：

### 代码测试覆盖
- **15/16 模块** 有直接的代码测试覆盖（patterns-roles-scenarios 是声明式 artifact，覆盖来自 py-sdk-core 的 test_pattern_*.py + final_gate scenario 4）
- **636 测试 / 630 通过** —— 99.21% pass rate
- 三层（py-sdk-core / adapter-* / handler-*）的单元测试**密度最高**（149 + 70 + 31）
- 运行时（runtime-core / runtime-subsystems / runtime-web）共 **155** 个 ExUnit 测试，覆盖 OTP supervision、Phoenix Channel、Topology lifecycle、Persistence restore

### 操作 E2E 覆盖
- 主干已覆盖：v0.1 feishu-to-cc + v0.2 ESR-channel MCP 两条 scenario YAML，外加 `final_gate.sh` v2 的 13-check 外部 verdict。
- **缺口**（详 coverage-matrix "E2E 缺口清单"）：
  - **P0 运维/可观测性**：kill -9 esrd 重启、telemetry subscribe live stream、deadletter 完整闭环、debug pause/resume —— 都仅 unit 级覆盖，无操作 E2E
  - **P1 错误路径**：adapter subprocess crash auto-restart、topology rollback on init failure、feishu 429 retry —— unit 覆盖，无操作 E2E
  - **P2 性能/边界**：1000-event dedup FIFO、cc_output flood、SessionRegistry offline 标记
  - **P3 修复回归**：SCRIPTS-1、ELIXIR-1、CC-MCP-1

### 环境受限
- **0 hard-dependency 受限测试**（elixir 装上之后全部能跑）
- 1 个软门控 skip：`test_ipc_integration_live`（需要 ESR_E2E_RUNTIME=1 + esrd 在跑），属于代码级条件，不是环境问题。

## 决策记录

### 关于 Skill 1 安装位置
**决策**：装到 `/.claude/skills/project-discussion-esr/`（项目本地），而非用户全局或 `~/.claude/skills/`。
**理由**：Skill 1 与项目 1:1 绑定，项目知识不应该污染全局 skill 空间；放项目内还能跟代码一起进 git，团队共享。

### 关于模块切分
**决策**：16 模块（4 Elixir runtime + 4 Python infra + 3 adapter + 4 handler + 1 declarative），每个模块一个 subagent。
**理由**：模块边界 = 包边界（adapters/feishu = 一个 uv editable 包；runtime/lib/esr/topology = 一个 OTP supervision 子树），切分天然，subagent 上下文不会跨太多概念。Python SDK 内部又按 layer 切分（sdk-core / cli / ipc / verify），方便 Skill 3 知道把测试加到哪。

### 关于 verify-bootstrap.sh
**决策**：写一个 ESR 特化的 `verify-bootstrap-esr.sh` 替代 plugin 自带脚本。
**理由**：plugin 自带版硬编码了 zchat 项目的模块名（`agent_manager, irc_manager, auth, project, app, zellij`）和 `zchat-channel-server, zchat-protocol` submodules，对 ESR 全部 false positive。我写的版本检查 ESR 的 16 真实模块，全绿（32 通过 / 0 阻塞 / 1 警告 = bootstrap-report 此时尚未写）。

### 关于 cc_mcp 测试 workaround
**决策**：暂用 `PYTHONPATH=src uv run --with mcp ...` workaround 跑测试，不在 bootstrap 阶段修复 py/pyproject.toml。
**理由**：bootstrap 应"如实记录"现状，修复属于后续开发任务。Workaround 已显示 7/7 通过证明代码本身 OK，缺口是 build-config，不是代码 bug。已记录为 CC-MCP-1。

### 关于 ELIXIR-1 flaky 是否阻塞
**决策**：不阻塞 bootstrap。记录为 known-issue，建议后续修复。
**理由**：失败的是 test-harness 自身的 timing 假设（assert_receive 100ms 超时），不是 runtime 行为 bug。关键的 `channel_integration_test.exs`（true e2e）稳定通过。Skill 1 的 test-runner 把这个限制写在脚本注释里，避免下次有人误以为是新 regression。

### 关于 baseline 中"Total tests"算 636 还是 441
**决策**：算 636（5 个 suite 总和），不是单一 `make test-py` 的 441。
**理由**：完整基线必须覆盖所有可执行的测试；441 仅是 `cd py && uv run pytest`（受 testpaths 限制），漏了 cc_mcp、scripts、elixir 三类。Skill 1 也按 16 模块各自的 test-runner 来跑，与 636 这个口径一致。

### 关于 bootstrap-report.md 算 BLOCK 还是 WARN
**决策**：维持 plugin 默认 WARN 级别。
**理由**：本报告就是 Step 7.5 的产出；如果设 BLOCK，第一次 bootstrap 会陷入循环。WARN 提醒后续 session 注意此文件存在已足够。

## 已知边界

- **Python 版本**：env-check 报 3.14.3，但 `py/.venv` 实际是 3.13。两者都满足 `requires-python = ">=3.11"`，无影响。
- **Elixir 1.19 vs Phoenix 1.8**：本项目 mix.exs 锁 `phoenix ~> 1.8.0`，与 Elixir 1.19 兼容性已在 `runtime/AGENTS.md` 记录的 Phoenix 1.8 风格指南中体现。
- **`mix test test/esr_web/`**（带尾斜杠）会发现 0 测试，需写 `test/esr_web` 或枚举具体文件。已在 `test-runtime-web.sh` 注释。
- **runtime-subsystems 跑全 `mix test test/esr/{adapter_hub,handler_router,…}/` 在 cold cache 下偶发 build-lock race**，分组串跑稳定。已在 `test-runtime-subsystems.sh` 注释。
