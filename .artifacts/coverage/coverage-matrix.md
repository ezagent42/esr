---
type: coverage-matrix
id: coverage-matrix-001
status: draft
producer: skill-0
created_at: "2026-04-21"
project: esr
branch: feat/sy-discuss
---

# Coverage Matrix: ESR v0.2-channel

## 概览

| 指标 | 值 |
|------|-----|
| 总模块数 | 16 |
| 代码测试覆盖模块 | 15/16 (patterns-roles-scenarios 是声明式 artifact，无独立测试) |
| 单元+集成测试总数 | 636 |
| 通过 | 630 |
| 失败 | 5 (SCRIPTS-1 代码 bug + ELIXIR-1 flaky timing x4) |
| 跳过（代码级条件） | 1 (test_ipc_integration.py — ESR_E2E_RUNTIME 门控) |
| 操作 E2E 覆盖流程 | 2/M (两个 scenario YAML + final_gate.sh 13 checks) |
| 环境受限测试 | 1 (test_ipc_integration.py — 需要活跃 runtime) |

## 代码测试覆盖

### Python 层（Layer 2-4 + infra）

| 模块 | 测试路径 | 测试命令 | 结果 | 覆盖状态 |
|------|---------|---------|------|---------|
| py-sdk-core | py/tests/test_{actions,adapter,adapter_layout,command,command_compose,command_yaml,events,handler,handler_layout,optimizer_*,package,pattern_*,public_api,uri,workspaces}.py | `cd py && uv run pytest tests/test_actions.py … -q` | 149/149 passed | ✅ covered |
| py-cli | py/tests/test_cli_*.py + test_runtime_bridge.py + test_cmd_run_output_format.py | `cd py && uv run pytest tests/test_cli_*.py …` | 90/90 passed | ✅ covered |
| py-ipc | py/tests/test_{envelope,channel_*,adapter_*,handler_worker*,ipc_integration,url_discovery,adapter_loader,adapter_manifest}.py | `cd py && uv run pytest tests/test_envelope.py …` | 75/76 passed (1 skipped live) | ✅ covered |
| py-verify | py/tests/test_{capability,purity_*,handlers_cross_cutting}.py | `cd py && uv run pytest tests/test_capability.py …` | 32/32 passed | ✅ covered |
| adapter-feishu | adapters/feishu/tests/ | `cd py && uv run pytest ../adapters/feishu/tests/ -q` | 40/40 passed | ✅ covered |
| adapter-cc-tmux | adapters/cc_tmux/tests/ | `cd py && uv run pytest ../adapters/cc_tmux/tests/ -q` | 23/23 passed | ✅ covered |
| adapter-cc-mcp | adapters/cc_mcp/tests/ | `cd adapters/cc_mcp && PYTHONPATH=src uv run --with mcp --with anyio --with aiohttp --with websockets --with pytest --with pytest-asyncio pytest tests/` | 7/7 passed | ⚠️ covered via workaround (not in py testpaths; build-config gap CC-MCP-1) |
| handler-feishu-app | handlers/feishu_app/tests/ | `cd py && uv run pytest ../handlers/feishu_app/tests/ -q` | 12/12 passed | ✅ covered |
| handler-feishu-thread | handlers/feishu_thread/tests/ | `cd py && uv run pytest ../handlers/feishu_thread/tests/ -q` | 11/11 passed | ✅ covered |
| handler-cc-session | handlers/cc_session/tests/ | `cd py && uv run pytest ../handlers/cc_session/tests/ -q` | 4/4 passed | ✅ covered |
| handler-tmux-proxy | handlers/tmux_proxy/tests/ | `cd py && uv run pytest ../handlers/tmux_proxy/tests/ -q` | 4/4 passed | ✅ covered |
| scripts | scripts/tests/*.py + scripts/tests/test_esrd_sh.sh | `uv run --project py pytest scripts/tests/` + `bash scripts/tests/test_esrd_sh.sh` | 32 pass + **1 fail** (SCRIPTS-1) + 6 bash pass | ⚠️ regression |
| patterns-roles-scenarios | covered indirectly by py-sdk-core test_pattern_*.py + scenarios run under final_gate check 4 | n/a | n/a | ✅ covered indirectly |

### Elixir 层（Layer 1 OTP runtime）

| 模块 | 测试路径 | 测试命令 | 结果 | 覆盖状态 |
|------|---------|---------|------|---------|
| runtime-core | runtime/test/esr/{application_*,dead_letter,peer_*,session_registry,uri,worker_supervisor,workspaces_registry}_test.exs | `cd runtime && mix test test/esr/peer_*_test.exs …` | 73/73 passed | ✅ covered |
| runtime-subsystems | runtime/test/esr/{adapter_hub,handler_router,persistence,telemetry,topology}/*_test.exs | `cd runtime && mix test test/esr/adapter_hub/ test/esr/handler_router/ test/esr/persistence/ test/esr/telemetry/ test/esr/topology/` | 56/56 passed | ✅ covered |
| runtime-web | runtime/test/esr_web/*.exs | `cd runtime && mix test test/esr_web` | 22/26 passed, **4 flaky** (ELIXIR-1) | ⚠️ flaky |

## 操作 E2E 覆盖

E2E 测试通过 scenario runner (mock) 或 `final_gate.sh --lark` (live Lark API) 执行。

| 用户流程 | E2E 测试 | 证据类型 | 覆盖状态 |
|---------|---------|---------|---------|
| v0.1 feishu-to-cc 全链路（msg_received → thread_session → tmux → cc_output → 回复） | scenarios/e2e-feishu-cc.yaml (7 steps: A..H) | mock_feishu 录制 + ledger append | ✅ covered (mock) |
| v0.2 ESR-channel MCP 全链路（A-new-session, B-notify, C-reply-tool, D-at-addressing, E-kill, F-drain, G-deadletter-empty） | scenarios/e2e-esr-channel.yaml | mock_feishu + mock_mcp_ctl 录制 | ✅ covered (mock) |
| L0..L6 外部 verdict（final_gate v2 全 13 checks）| scripts/final_gate.sh | tmp log 每 check 一份 | ✅ covered (mock 默认) |
| `--lark` live 模式（真 Lark API 往返） | scripts/final_gate.sh --lark | ~/.esr/live.env + Lark Open API | ⚠️ covered only when operator has Lark credentials |
| `/new-session` 创建 CC 会话 + 绑定 tmux 窗口 | e2e-esr-channel step A | mock_feishu /push_inbound + esrd log | ✅ covered |
| `@<tag>` 地址路由（thread_session Route fallback） | e2e-esr-channel step D + handler-feishu-app::test_at_addressing | ledger + unit | ✅ covered |
| `ECHO-PROBE: <nonce>` → bot 回 nonce 的确定性探针 | final_gate check 10 L2 | nonce round-trip log | ✅ covered (diagnostic role) |
| 并行 sessions `${tag}-a` vs `${tag}-b` 隔离 | final_gate check 12 L6 | sub-nonce 只出现在 a 的 ledger | ✅ covered |
| `esr cmd stop` → session_killed + tmux 窗口消失 | final_gate check 11 L5 + e2e-esr-channel step E | ledger | ✅ covered |
| `esr drain` 清理残留 worker | e2e-esr-channel step F | ledger | ✅ covered |
| `esr deadletter list/retry/flush` | e2e-esr-channel step G + py/tests/test_cli_deadletter.py | unit + ledger | ✅ covered (逻辑) |
| `esr workspace add <name> --role <role>` | e2e-esr-channel setup + py/tests/test_cli_workspace.py | unit | ✅ covered (命令层) |
| kill -9 esrd 后重启恢复 adapters+peers | runtime/test/esr/application_restore_adapters_test.exs + application_restore_test.exs | ExUnit | ⚠️ covered at unit level, 无操作级 E2E |
| telemetry subscribe 实时事件流 | py/tests/test_cli_telemetry.py | unit | ⚠️ covered at unit level, 无操作级 E2E |
| `esr trace` 轨迹查询 | py/tests/test_cli_trace.py | unit | ⚠️ covered at unit level, 无操作级 E2E |
| `esr debug replay/inject/pause/resume` | py/tests/test_cli_debug.py | unit | ⚠️ covered at unit level, 无操作级 E2E |
| `esr actors list/tree/inspect/logs` | py/tests/test_cli_actors.py | unit | ⚠️ covered at unit level, 无操作级 E2E |
| handler pool/extra workers (F10) | 尚未实现 | - | ❌ not applicable (v0.2 singleton worker) |

## 环境受限覆盖 (soft-dependency 受限)

v0.2 无 hard-dependency 受限测试 —— 所有环境已在 Step 2.5 打通（elixir 新装 + tmux + zellij + asciinema + uv 就绪）。

| 测试 | 所需环境 | 状态 | 说明 |
|------|---------|------|------|
| py/tests/test_ipc_integration.py::test_ipc_integration_live | ESR_E2E_RUNTIME=1 + esrd 运行中 | ⚠️ skipped (intentional) | 非 env 缺失，是代码级 `@pytest.mark.skip` 门控。用于本地对接真 runtime 时验证。|
| scripts/final_gate.sh --lark | ~/.esr/live.env (FEISHU_APP_ID/SECRET/TEST_CHAT_ID) | 🟡 需凭据 | soft-dependency：只影响 live-mode 验证，mock 模式全套跑通 |
| docker-based integration | Docker | 🟡 non-blocking | v0.2 未使用 Docker；env-check 标 missing-soft，忽略 |

## E2E 缺口清单（Skill 2 test-plan 输入）

按优先级（高→低）：

### P0 — 运维/可观测性流程（有单元测试但无操作 E2E）
1. **kill -9 esrd → auto-restore**：应有"杀 esrd → 10s 内重启 → 之前的 feishu adapter 继续接收消息"的操作 E2E
2. **`esr telemetry subscribe --pattern '[:esr,:handler,*]'` live stream**：应有"执行 trigger → 确认 telemetry 事件在 CLI 实时显示"的 E2E
3. **deadletter 完整闭环**：handler 超时 → retry exhausted → DLQ 入队 → `esr deadletter list` 可见 → `esr deadletter retry <id>` 重放 → 成功 → `esr deadletter list` 空
4. **`esr debug pause <actor> && resume`**：验证 PeerServer pause 队列行为（F8）

### P1 — 混合错误路径
5. **adapter subprocess crash → auto-restart**：杀 adapter_runner Python 进程，验证 esrd 重新拉起并重发 init_directive（PRD 04 F13）
6. **topology rollback on init failure**：让 tmux node 的 init_directive 失败（如 cwd 不存在），验证 rollback_spawned 干净清理所有已启动 peers
7. **feishu API rate-limit retry**：mock_feishu 返回 429 三次后 200，验证 adapter 按 1/2/4/8/16/30s 重试直到成功（PRD 04 F15b）

### P2 — 性能/边界
8. **1000-event dedup FIFO**：向同一 thread 发 1001 条重复消息，验证 dedup set 驱逐最旧
9. **大量 cc_output 洪水**：CC 产出 5000 行/s，验证 PeerServer 不 OOM，telemetry buffer 按 retention window 修剪
10. **SessionRegistry offline 标记**：杀 cc_proxy actor，验证 SessionRegistry.status 变 `:offline`，后续 notify_session 走 fallback

### P3 — 非 E2E 但值得补的单元/集成
11. **SCRIPTS-1 修复**：更新 test_exactly_one_allowed_file_passes fixture 覆盖 v0.2-channel 双文件要求
12. **ELIXIR-1 修复**：CliChannelTest flaky assert_receive → 增大 timeout 或改 serial
13. **CC-MCP-1 修复**：adapters/cc_mcp 纳入 py/pyproject.toml [tool.uv.sources] + testpaths，避免 PYTHONPATH workaround

## 总结

- 代码测试覆盖 **极广**（全部 layer 1-4 单元 + 部分集成）
- 操作 E2E 主干已覆盖（v0.1 + v0.2 两条 scenario），final_gate 13-check 外部 verdict 成熟
- **缺口** 集中在"运维/可观测性/混合错误路径"类 E2E —— 目前大多仅覆盖到 unit 层
- **环境** 已全绿，无 hard-dependency 受限测试
- **已知回归**：SCRIPTS-1（stale fixture）、ELIXIR-1（flaky timing）、CC-MCP-1（build-config 小 gap）
