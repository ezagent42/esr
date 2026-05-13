# CC Channel stdio Bridge — 设计 (rev-7)

**状态：** rev-7 草稿，经过 6 轮 subagent code-reviewer。**通过，可实施。**
**作者：** 2026-05-12 → 2026-05-13 飞书 live debugging
**取代：** PR-3.5（2026-05-05 "HTTP MCP transport"）

**rev 路径**：rev-1 想删一堆 → rev-2~5 被 review 反向劝住保留 → rev-6 按 operator 提醒"review 意见不必全采纳，过时测试和 dead code 该删就删"重新激进删 → rev-7 补完 rev-6 漏掉的连锁删除。

## 1. 背景

PR-3.5（2026-05-05）把 ESR 的 per-session Python stdio MCP bridge 换成 Phoenix HTTP route `/mcp/:session_id`。2026-05-13 live test 发现回归：**CC 的 `--channels` / `--dangerously-load-development-channels` flag 只识别 stdio transport 的 MCP server，不识别 HTTP**（CC 官方 docs：https://code.claude.com/docs/en/channels-reference 明确写"Connect over stdio transport"）。

后果：HTTP MCP 作为 **tool** server 注册成功（`/mcp` 显示 connected + 3 tools），但**作为 channel 没注册成功**。CC 没打开 SSE 流，`CCProcess.cc_mcp_ready` 永远 false，飞书 inbound 走 fallback 直接写 PTY stdin —— 功能能跑但 meta（chat_id / sender / message_id / ts）丢光，CC 没法用 `reply` tool 回到正确的 chat。

## 2. 目标

1. 恢复 channel notification 路径：飞书消息进 CC 是 `<channel source="feishu" chat_id="…" user="…" ts="…">` tag 带完整 meta
2. 删 HTTP MCP route + 所有相关 dead code（包括过时的 regression test）—— 不让后续 debug 被误导
3. 新增 `/pty:input slash command`：operator 显式写 PTY stdin（与 `/pty:key` 配对，一个管特殊键一个管文本）

## 3. 不做

- 改 tool dispatch transport（`reply` / `send_file` / `submit_slash` 还是同一个 stdio MCP server）
- 复活 pre-PR-3.5 的 `adapters/cc_mcp/`（自带 uv wrapper + pidfile 复杂度）
- 协议扩展（按 MCP channel 标准）
- **保留 cc_mcp_ready / PR-24 PTY-stdin fallback / cc_process_inbound_regression_test.exs:94 那个测试** —— stdio bridge 上线后这三样都是 dead code。"测试存在所以代码要保留"是循环论证；测试本身已过时，跟代码一起删

## 4. 架构

```
BEAM (Elixir OTP)
  ↓ erlexec port（BEAM 死时杀子进程）
PtyProcess (每 session 一个，erlexec :pty wrapper)
  ↓ claude 在 PTY 里跑
claude (CC 二进制)
  ↓ subprocess via mcp.json command + args（CC docs 要求）
Python stdio bridge (py/src/cc_channel_runner/__main__.py)
  ↓ Phoenix Channel WebSocket
EsrWeb.ChannelChannel @ "cli:channel/<session_id>"
  ↓
BEAM Phoenix endpoint
```

**Lifecycle 靠 stdio EOF**：bridge 用 `mcp.server.stdio.stdio_server()`，CC 一死 stdio pipe close，stdin EOF，asyncio loop 终止，Python 自然退。**不需要 ppid watchdog**。cc-openclaw 的 channel.py 同样模式在生产用，无孤儿。

bridge **不**继承 PTY 作 controlling terminal（CC 给 MCP 子进程是 pipe），所以 PTY SIGHUP 不是 secondary safety net。**只有 stdio EOF，但够用**。

## 5. 删除清单

### 5.1 主删除目标

| 目标 | 操作 |
|---|---|
| `runtime/lib/esr_web/mcp_controller.ex` | **先**提取 `build_notification_params/1` 到 §6.1 新模块，**再删**整文件 |
| `runtime/lib/esr_web/router.ex:33-42` (`scope "/mcp/:session_id"` block) | 删 scope + 注释 |
| `runtime/test/esr_web/controllers/mcp_controller_test.exs` | 8 个 `build_notification_params/1` 测试迁到新文件 `channel_notification_test.exs`，原文件删 |
| `Esr.Plugins.ClaudeCode.Channels.McpHttp` 模块 | **重命名**为 `Esr.Plugins.ClaudeCode.Channels.Mcp`；`mcp_http.ex` → `mcp.ex`；behaviour 不变；SSE-prose 注释更新 |
| `CCProcess.cc_mcp_ready` field（含 init default + handler + dispatch 两分支） | **删**。stdio bridge 让 `cc_mcp_ready` 在 session boot 时近乎瞬时 fire（`channel_channel.ex:70-74` broadcast），not-ready 分支在生产中不可达 |
| `cc_process.ex` 的 `handle_info({:cc_mcp_ready, sid}, state)` clause | **删**。state 不再有 gate 要 flip |
| `cc_process.ex:309-340` `dispatch_action(send_input)` 两分支 | **替换**为单分支：永远 `broadcast_notification(current_session_id_or_primary(state), build_channel_notification(state, text))` |
| `cc_process.ex:322-336` PR-24 设计 rationale 注释块 | 跟着 fallback 一起删 |
| `cc_process_inbound_regression_test.exs:94` "send_input writes keystrokes to PtyProcess (no broadcast)" 测试 | **删**这一个 test。文件其它 broadcast-path 测试保留 —— 但要剥它们的 `send(pid, {:cc_mcp_ready, sid})` 测试-setup 行（见下行） |
| `cc_process_inbound_regression_test.exs:56, 169` + `cc_process_multi_session_test.exs:51` 的 `send(pid, {:cc_mcp_ready, sid})` 测试-setup boilerplate | **剥掉**这 3 行。handler 删了之后它们变成 no-op；broadcast-path 断言不依赖它们所以 test 还过；剥掉让 setup 不误导 |
| `cc_process.ex` `state.pty_actor_id` field | **删**。审计过：`commands/key.ex`、`feishu_chat_proxy.ex`、`commands/tui.ex`、`commands/pty/{list,attach,input}.ex`、`uri/compat.ex`、`instance_registry.ex` 都通过 `Esr.Uri.Compat.pty_actor_id_for/2` 独立解析 PTY actor_id，**从来不读 CCProcess 的 state**。唯一 reader 是被删的 fallback 分支 |
| `cc_process.ex` `state.pending_notifications` field | **删**（init 在 :127，reader+writer 在 `handle_info({:cc_mcp_ready, …})` clause :200-209，本 PR 一起删）。Pre-PR-24 它 buffer not-ready 期间的 notification；PR-24 换成 PTY-stdin 写；rev-7 把两套都删了 |

### 5.2 cross-reference 完整清单

`grep -rln -E "McpHttp|claude_code\.mcp_http"` 实际 **~22 个 src/test/scenario + 8 个 docs**：

**Source files (4):** `runtime/lib/esr/plugins/stub_agent/channels/noop.ex`, `runtime/lib/esr/plugins/feishu/channels/chat_proxy.ex`, `runtime/lib/esr/plugins/claude_code/manifest.yaml` (`kind: claude_code.mcp_http`), `runtime/lib/esr/bundles/feishu-cc/template.yaml`

**Test files (13):** `mcp_http_test.exs`, `new_session_smoke_test.exs`, `feishu_slash_new_session_test.exs`, `parser_test.exs`, `registry_test.exs`, `agent_def_builder_test.exs`, `bundle/loader_test.exs`, `bundles/feishu_cc_test.exs`, `commands/plugin/enable_test.exs`, `commands/plugin/install_test.exs`, `commands/session/new_test.exs`, `resource/capability_phase6_snapshot_test.exs`, `mix/tasks/esr_gen_bundle_docs_test.exs`

**E2E (2):** `tests/e2e/scenarios/26_operator_template_override.sh` + `29_external_bundle_install.sh`

**Docs (8):** `docs/grammar/templates.md`, `docs/futures/todo.md`, 几个老 spec + plan + manual-check（低优先级，rename pass 一起扫）

### 5.3 `McpController` cross-reference

`runtime/lib/esr/plugins/claude_code/{manifest.yaml, channels/mcp_http.ex, cc_process.ex:489}` + `runtime/test/esr/{worker_supervisor_test.exs, resource/sidecar/registry_test.exs}` —— 全是 `@moduledoc` / 注释 references。rename + delete pass 一起改。**注意**：rev-3 错说 launcher.ex / launcher_test.exs 也有 controller ref，实际 grep 0 hits。launcher_test.exs 要改是因为它对生成的 URL shape 有断言（§8.1），不是因为它 cite 了 controller 模块。

### 5.4 不删（保留）

- `feishu_chat_proxy.ex` 对 `pty:<actor_id>` + `cc_mcp_ready/<sid>` + `pty_attach/<sid>` 的 PubSub 订阅 —— 都还有其它合法用途（browser /attach rewire 等）
- `Channels.Mcp`（rename 后的 McpHttp）保留对 `cc_mcp_ready` 的订阅 + 转发 :ready event 给 AgentDefBuilder。Producer 在 `channel_channel.ex:70-74`，没变，所以这条链不受 CCProcess 删除影响（独立）

### 5.5 延后删除候选（cutover 后验证再删）

`feishu_chat_proxy.ex` 的 `boot_mode` / `pty_buffer` / `pty_flush_timer` / `dev_channels_confirmed` + `maybe_confirm_dev_channels/1` 自动按 "1\r" + PTY-stdout mirror loop。

**触发验证**：rev-7 cutover 上线后第一个 Feishu /session:new 时 smoke test：
1. CC 还会 render `--dangerously-load-development-channels` confirmation banner 吗？被注册成 stdio channel 后可能 CC 直接 exempt 了 → `maybe_confirm_dev_channels/1` 没东西匹配 → 可删
2. FCP 还需要把 PTY-stdout mirror 到 chat 吗？channel notification 路径如果把 CC 的所有输出都通过 `<channel>` tag reply 传过来，mirror 就 redundant 了

按 smoke test 结果决定是否在 follow-up PR `feat/feishu-chat-proxy-postchannel-cleanup` 里删。**不盲删**。

## 6. 新增清单

### 6.1 `Esr.Plugins.ClaudeCode.ChannelNotification` 提取

新文件 `runtime/lib/esr/plugins/claude_code/channel_notification.ex`，把 `mcp_controller.ex:268-329` 的 `build_notification_params/1` + helpers (`build_text_params/1`, `build_attachment_params/3`, `take_meta/1`, `reason_str/1`) 整段搬来。纯 data transform，无 state，无 controller 依赖。8 个测试迁到 `channel_notification_test.exs`。

Python bridge **自己用 Python 重写一份**（保持 bridge 是纯粹 stdio↔WS proxy）—— 简化：**跳过 `PhaserRegistry.transform/2` 的 attachment 路径解析**，把 `media_uri` + `msg_type` 当 meta 属性 pass-through。CC-side 自行解析。理由：PhaserRegistry 是 Elixir-only resource registry，bridge 跨语言调它不值得。

### 6.2 Python stdio bridge

位置 `py/src/cc_channel_runner/`（跟 `feishu_adapter_runner` 平级）。入口 `python -m cc_channel_runner`。Argv `--session-id <uuid>` + `--esrd-url <ws-url>`。依赖 `mcp` + `websockets`。

职责：
1. 连 Phoenix Channel WS `<esrd-url>/channel/socket/websocket?vsn=2.0.0`
2. `phx_join` topic `cli:channel/<sid>`（匹配 `channel_channel.ex:17` 的 `def join("cli:channel/" <> session_id, …)`）
3. 起 MCP stdio server，capabilities 声明 `claude/channel: {}` + `tools: {}`，instructions 抄 `mcp_controller.ex:148-153`
4. **Tool dispatch**：注册 `reply` / `send_file` / `submit_slash` handlers。每个：
   - 生成 `req_id` (ULID)
   - 推 Phoenix frame `event: "envelope"` + `payload: %{kind: "tool_invoke", req_id, tool, args}`（匹配 `channel_channel.ex:115` `handle_in("envelope", %{"kind" => "tool_invoke"} = payload, socket)`）
   - 等服务器推 `envelope` WS frame 且 `payload.kind == "tool_result"` + 匹配 `req_id`（服务端通过 `channel_channel.ex:168-176` `push(socket, "envelope", Map.merge(result, %{"kind" => "tool_result", "req_id" => req_id}))` 推回）
   - 翻译 `ok: true | false` 成 MCP tool result
5. **Notification dispatch**：服务端在 `channel_channel.ex:163-166` 通过 `push(socket, "envelope", payload)` 推 notification。bridge 收 `envelope` WS frame 后按 `payload.kind` 分发：

| `payload.kind` | 行为 |
|---|---|
| `tool_result` | 走 step 4 的 correlate-by-req_id |
| `notification` | 转 MCP `notifications/claude/channel`（producer 在 `cc_process.ex:457` + `entity/server.ex:610`） |
| `cleanup_check_requested` | 转 MCP notification。Producer：`runtime/lib/esr/commands/session/branch_end.ex:252` |
| `session_killed` | bridge 退出（关 stdio_server context，CC 看到 EOF）。**仓库今天没 producer**，flag 给将来 `Esr.Session.LifecycleObserver` (`runtime/lib/esr/session/lifecycle_observer.ex`)。defensive 处理 |
| 其它任何 kind | log warning + drop。whitelist 纪律，避免误转 malformed payload 给 MCP |

每条转发的 bridge 调 Python 端的 `build_notification_params(payload)`（§6.1 重实现），写 MCP frame `{"method": "notifications/claude/channel", "params": {...}}` 到 stdout。

6. WS disconnect：3 次 backoff (1s/2s/4s) 重连，全失败退出
7. 直接 venv python，bypass uv run（匹配 `AdapterProcess` PR-21β 教训）

### 6.3 Launcher.write_mcp_json/1 改写

`launcher.ex:69-116` 当前生成 `type: http, url: http://…`，改成生成 `command + args`：
```json
{"mcpServers":{"esr-channel":{"command":"/abs/path/to/py/.venv/bin/python","args":["-m","cc_channel_runner","--session-id","<sid>","--esrd-url","ws://<host>:<port>"]}}}
```

- `default_esrd_url/0` (launcher.ex:192) 从 `defp` promote 到 `def`，方便 bridge-config helper 调
- 函数名 `write_mcp_json/1` → `write_channel_mcp_config/1`
- launcher_test.exs:152-174 既有 url 断言更新为 `command + args` 断言

### 6.4 `cc_mcp_ready` broadcast —— 已就位，不用改

`EsrWeb.ChannelChannel.join/3` 在 `channel_channel.ex:70-74` 已经 broadcast `cc_mcp_ready/<sid>`（PR-9 T12-comms-3c 加的）。删了 `mcp_controller.ex:handle_sse` 之后，这条 WS-join 路径成为**唯一** producer，spec **不需要**新加 code。`Channels.Mcp` GenServer 跟 AgentDefBuilder 的 `:ready` 订阅链路完全不动。

### 6.5 /pty:input slash command

`runtime/lib/esr/commands/pty/input.ex`，用 `Esr.Commands.Meta` DSL（task #466 之后 yaml 是 derived）：

```elixir
arg :name, required: true, doc: "agent name"
arg :text, required: true, doc: "free-form text"
```

实现：解析 chat-current session sid → `Esr.Uri.Compat.pty_actor_id_for(sid, name)` → `Esr.Entity.PtyProcess.write(actor_id, text)`。**不**自动加 `\r`；要回车操作员紧跟 `/pty:key enter`。

与 `/pty:key` 区分：

| | `/pty:key` | `/pty:input` |
|---|---|---|
| 用途 | 特殊不可打印键 | 任意打印文本 |
| 末尾 `\r` | 对应键自带 | **永不** |

`name=` 模式跟 `/claude_code:tui` 一致（tui.ex:53 同样用 `Esr.Uri.Compat.pty_actor_id_for(sid, name)`）。实现完跑 `mix esr.gen_slash_routes` 重生 yaml。

## 7. Lifecycle 不变量

| ID | 不变量 | 测试 |
|---|---|---|
| I-1 | BEAM SIGKILL → 所有 session 的 bridge 5s 内退 | `cc_channel_orphan_test.exs` |
| I-2 | `/session:end` → 该 session 的 bridge 5s 内退 | 同上 |
| I-3 | claude SIGKILL → bridge 5s 内通过 stdio EOF 退 | 同上 |
| I-4 | BEAM 长期不可用 → bridge 3 次 backoff 失败后退 | Python unit test (`py/tests/test_cc_channel_runner_ws.py`) |

## 8. 测试

- **§8.1 Elixir unit**：`launcher_test.exs:152-174` 更新；新建 `channel_notification_test.exs`（迁 8 测试）
- **§8.2 Python unit**：`py/tests/test_cc_channel_runner_ws.py`（mock WS + stdio EOF + tool call envelope shape）
- **§8.3 Integration**：`runtime/test/esr/integration/cc_channel_stdio_e2e_test.exs`（按 `new_session_smoke_test.exs` + `real_claude_boot_test.exs` 模式）
- **§8.4 Shell e2e**：`tests/e2e/scenarios/33_cc_channel_stdio.sh`（编号 33+ 因为 30/31/32 都占了）
- **§8.5 Lifecycle**：`runtime/test/esr/lifecycle/cc_channel_orphan_test.exs`（`@tag :slow`）

## 9. 迁移

- **9.1** 不需要数据迁移（旧 session 的 mcp.json 是 `type:http`，重建 session 后自动重写）
- **9.2** cc-openclaw `channel_server/adapters/cc/channel.py` 是参考实现
- **9.3** 不要 feature flag —— 硬切换
- **9.4** `--dangerously-load-development-channels server:esr-channel` flag 保留（CC docs 研究预览阶段要求）
- **9.5** rename sed pass（macOS BSD sed）：
```bash
git grep -l "Channels.McpHttp" | xargs sed -i '' 's/Channels\.McpHttp/Channels.Mcp/g'
git grep -l "claude_code\.mcp_http" | xargs sed -i '' 's/claude_code\.mcp_http/claude_code.mcp_stdio/g'
git mv .../channels/mcp_http.ex .../channels/mcp.ex
git mv .../channels/mcp_http_test.exs .../channels/mcp_test.exs
```

## 10. 待解决问题

- **Q1** WS auth：`EsrWeb.ChannelSocket.connect/3` 是否要 session-scoped token，实施时验证
- **Q2** `instructions` 字符串照抄 `mcp_controller.ex:148-153` 还是改？倾向**照抄**，后续 PR 再改

## 11. 实施 phasing

单 PR。顺序：

1. 提取 `build_notification_params/1` → `ChannelNotification` 模块 + 迁测试。`mix test` 绿
2. 实现 Python bridge `py/src/cc_channel_runner/` + Python unit test
3. 改 `Launcher.write_mcp_json/1` → `write_channel_mcp_config/1`，`default_esrd_url/0` promote 到 def，更新 launcher tests
4. sed pass 重命名 `Channels.McpHttp` → `Channels.Mcp`，更新 SSE prose
5. **删 CCProcess**：`cc_mcp_ready` field + `handle_info({:cc_mcp_ready, …})` + `pending_notifications` field + `pty_actor_id` field + `dispatch_action(:send_input)` 两分支 → 单分支永远 broadcast + PR-24 注释块 (`:322-336`)。**同时**改 `cc_process_inbound_regression_test.exs` + `cc_process_multi_session_test.exs`：删 :94 那个 fallback 测试，剥 :56 :169 :51 的 `send(pid, {:cc_mcp_ready, sid})` setup 行
6. 删 `mcp_controller.ex` + router scope + 原 mcp_controller_test.exs
7. 加 `/pty:input` 命令 + `mix esr.gen_slash_routes`
8. 加 integration test + shell scenario + lifecycle test
9. 手测：`/session:new` → CC 起 → `/mcp` 显示 `esr-channel connected + 3 tools + channel capability` → 飞书消息进 CC 是 `<channel>` tag 带 meta —— **就是 2026-05-12 没复现到的核心症状**
10. 验证 §5.5 delayed deletion：dev-channels banner 还出现吗？PTY mirror 还需要吗？如果都不需要，开 follow-up PR 删

预估 ~30 文件修改 / ~5 新增 / ~3 删除。净 LoC 约略持平。
