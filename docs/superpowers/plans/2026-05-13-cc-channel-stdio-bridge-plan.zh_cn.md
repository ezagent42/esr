# CC Channel stdio Bridge — 实施计划

> **For agentic workers:** 必需子技能 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`。

**目标：** 恢复飞书 → CC 的 `<channel>` notification 路径，把 HTTP MCP route 换成 stdio MCP bridge（按 CC docs 强制约束：channel server 必须 stdio）。

**架构：**
```
BEAM → erlexec → claude → (per mcp.json) spawn Python stdio bridge
                                ↓ Phoenix Channel WS
                          EsrWeb.ChannelChannel @ "cli:channel/<sid>"
```
Lifecycle 靠 stdio EOF —— claude 一死，pipe close，MCP Python SDK 的 `stdio_server()` read 到 EOF，Python 自然退。**无需 ppid watchdog**。

**Tech Stack：** Elixir 1.18 / OTP 27 / Phoenix；Python `mcp.server.stdio` + `websockets`；沿用现有 erlexec subprocess 模式。

**Spec：** `docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md` rev-7（6 轮 subagent review 通过）

**分支：** `feat/cc-channel-stdio-bridge`（单 PR；下面 phases 是 commit 边界，不是 PR 边界）

---

## Phase 1：提取 `ChannelNotification` helper

`mcp_controller.ex:268-329` 的纯 data transform 需在 controller 删除后留存。

### Task 1.1：创建 `Esr.Plugins.ClaudeCode.ChannelNotification`

- [ ] **Step 1**：从 **`runtime/lib/esr_web/mcp_controller.ex:268-329`** 提取 `build_notification_params/1` + `build_text_params/1` + `build_attachment_params/3` + `take_meta/1` + `reason_str/1`（两 clauses，arity 1 — 一个 `is_atom(reason)` head，一个 fallthrough）到 `runtime/lib/esr/plugins/claude_code/channel_notification.ex`
- [ ] **Step 2**：`mix compile` 验证无新 warning
- [ ] **Step 3**：commit `feat(cc-channel): extract ChannelNotification helper from McpController`

### Task 1.2：迁移 8 个既有测试

- [ ] **Step 1**：从 `runtime/test/esr_web/controllers/mcp_controller_test.exs` 复制 8 个 `build_notification_params/1` 测试到新文件 `runtime/test/esr/plugins/claude_code/channel_notification_test.exs`
- [ ] **Step 2**：更新 alias `EsrWeb.McpController` → `Esr.Plugins.ClaudeCode.ChannelNotification`
- [ ] **Step 3**：`mix test test/esr/plugins/claude_code/channel_notification_test.exs` 应过 8 个
- [ ] **Step 4**：commit `test(cc-channel): migrate build_notification_params tests to ChannelNotification`

---

## Phase 2：Python stdio bridge

### Task 2.1：`cc_channel_runner` package skeleton

- [ ] **Step 1**：验证 `py/pyproject.toml` 有 `websockets`；缺 `mcp` 就加 `mcp >= 1.0`，`uv sync`
- [ ] **Step 2**：写 `py/src/cc_channel_runner/__main__.py` 骨架（argparse `--session-id` + `--esrd-url`，log 到 stderr）
- [ ] **Step 3**：smoke test `uv run python3 -m cc_channel_runner --session-id test --esrd-url ws://localhost:4001`
- [ ] **Step 4**：commit `feat(cc-channel): cc_channel_runner skeleton`

### Task 2.2：Phoenix Channel WS client

- [ ] **Step 1**：写 `py/src/cc_channel_runner/phx_client.py`：connect + `phx_join` topic `cli:channel/<sid>` + 3 次 backoff 重连。参考 `cc-openclaw/channel_server/adapters/cc/channel.py:65-180`
- [ ] **Step 2**：写 `py/tests/test_cc_channel_runner_phx_client.py` 用 `websockets.serve` mock server 验证 join 流程
- [ ] **Step 3**：`uv run pytest` 应过
- [ ] **Step 4**：commit `feat(cc-channel): phx_client.py + WS join unit test`

### Task 2.3：MCP stdio server + capabilities

- [ ] **Step 1**：在 `__main__.py` wire `mcp.server.stdio.stdio_server()`。capabilities `experimental={"claude/channel": {}}` + `tools={}`。instructions 抄自 `mcp_controller.ex:148-153`
- [ ] **Step 2**：smoke test handshake：`echo` 一个 initialize 进 stdin，stdout 应回 JSON-RPC initialize response 含 `experimental.claude/channel`
- [ ] **Step 3**：commit `feat(cc-channel): MCP stdio server + claude/channel capability`

### Task 2.4：Notification dispatch（WS → MCP stdout）

- [ ] **Step 1**：WS consumer loop 收 `envelope` frame，按 `payload.kind` 分发：
  - `tool_result` → 走 Task 2.5
  - `notification` | `cleanup_check_requested` → `build_notification_params` 转 MCP stdout
  - `session_killed` → `SystemExit(0)` 退
  - 其它 → log warning + drop（whitelist 纪律）
- [ ] **Step 2**：在 `cc_channel_runner/notification.py` 用 Python 重写 `build_notification_params`，**跳过 PhaserRegistry**，`media_uri`/`msg_type` pass-through 作 meta
- [ ] **Step 3**：单元测试
- [ ] **Step 4**：commit `feat(cc-channel): notification path`

### Task 2.5：Tool dispatch（MCP request → WS push → await tool_result）

- [ ] **Step 1**：注册 MCP tool handlers (`reply` / `send_file` / `submit_slash`)，每个：
  - 生成 `req_id = uuid.uuid4().hex`
  - push Phoenix frame `event="envelope"` + `payload={kind:"tool_invoke", req_id, tool, args}`（匹配 `channel_channel.ex:115` `handle_in("envelope", %{"kind" => "tool_invoke"} = payload, …)`）
  - 等服务器推回 `envelope` frame 且 `payload.kind == "tool_result"` + 匹配 `req_id`
  - 翻译 `ok: true | false` 成 MCP `CallToolResult`
- [ ] **Step 2**：tool schemas 暂硬编码（参考 `Esr.Plugins.ClaudeCode.Mcp.Tools` 现有 3 个 schema），后续 PR 可改成动态 fetch
- [ ] **Step 3**：mock WS 单元测试 round-trip
- [ ] **Step 4**：commit `feat(cc-channel): tool dispatch`

---

## Phase 3：Launcher 改写

### Task 3.1：`write_mcp_json/1` → `write_channel_mcp_config/1`

**重要**：现有 `write_mcp_json/1` 在 `launcher.ex:86` 接 **keyword list** `[session_id:, esrd_url:]`，caller 在 `:175` 也传 kw list。rev-7 保留 kw-list 签名，只改函数体。

- [ ] **Step 1**：保留 kw-list 入参，只改输出 shape：
```elixir
def write_channel_mcp_config(opts) do
  session_id = Keyword.fetch!(opts, :session_id)
  esrd_url = Keyword.fetch!(opts, :esrd_url)

  config = %{
    "mcpServers" => %{
      "esr-channel" => %{
        "command" => python_bin_path(),
        "args" => ["-m", "cc_channel_runner",
                   "--session-id", session_id,
                   "--esrd-url", esrd_url]
      }
    }
  }
  # ...File.write...
end
```
`python_bin_path/0` 抄 `Esr.Workers.AdapterProcess.python_bin/0`（`adapter_process.ex:99`）的路径解析模式
- [ ] **Step 2**：`git grep -n "write_mcp_json"` 找所有 caller：`launcher.ex:175` + `launcher_test.exs`。改名。**注意**：`cc_process.ex` 没调用过它（subagent review 验证过）
- [ ] **Step 3**：`launcher_test.exs:152-174` 既有 url 断言改为 `command =~ "python"` + `"cc_channel_runner" in args`
- [ ] **Step 4**：`mix test test/esr/plugins/claude_code/launcher_test.exs` 应过
- [ ] **Step 5**：commit `refactor(cc-channel): write_channel_mcp_config emits stdio command shape`

---

## Phase 4：Rename `Channels.McpHttp` → `Channels.Mcp`

### Task 4.1：sed pass

- [ ] **Step 1**：（macOS BSD sed）：
```bash
git grep -l "Channels\.McpHttp" | xargs sed -i '' 's/Channels\.McpHttp/Channels.Mcp/g'
git grep -l "claude_code\.mcp_http" | xargs sed -i '' 's/claude_code\.mcp_http/claude_code.mcp_stdio/g'
git mv runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex \
       runtime/lib/esr/plugins/claude_code/channels/mcp.ex
git mv runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs \
       runtime/test/esr/plugins/claude_code/channels/mcp_test.exs
```
- [ ] **Step 2**：`git grep -E "McpHttp|claude_code\.mcp_http"` 应零 hit（docs 里若残留就手动改）
- [ ] **Step 3**：更新 renamed `mcp.ex` 的 `@moduledoc` —— 删 SSE prose，描述 stdio bridge 机制（注意 Phase 4 时 controller 还没删，prose 别说"已删"）
- [ ] **Step 4**：全套 `mix test`
- [ ] **Step 5**：commit `refactor(cc-channel): rename Channels.McpHttp → Channels.Mcp`

---

## Phase 5：删 CCProcess dead code（大连锁删除）

### Task 5.1A：删 state fields + handler + dispatch 分支

- [ ] **Step 1**：`cc_process.ex` init（约 :122-127）strip `cc_mcp_ready: false` / `pending_notifications: []` / `pty_actor_id: ...`
- [ ] **Step 2**：删 `handle_info({:cc_mcp_ready, sid}, state)` clause（约 :200-209）
- [ ] **Step 3**：简化 `dispatch_action(send_input)`（:309-340）成单分支 always-broadcast，同时删 `:322-336` PR-24 注释块
- [ ] **Step 4**：commit `refactor(cc-channel): delete CCProcess boot-bridge fallback + dead state fields`

### Task 5.1B：测试 setup 修剪

- [ ] **Step 1**：`cc_process_inbound_regression_test.exs:94` 那个 "send_input writes keystrokes to PtyProcess (no broadcast)" 测试整个删
- [ ] **Step 2**：同文件 :56 :169 + `cc_process_multi_session_test.exs:51` 三处 `send(pid, {:cc_mcp_ready, sid})` 测试-setup boilerplate 剥掉（handler 删了之后这些 send 变 no-op；broadcast 路径断言不依赖它们，测试还过）
- [ ] **Step 3**：`mix test test/esr/plugins/claude_code/` 应除被删 test 外全过
- [ ] **Step 4**：commit `test(cc-channel): strip dead cc_mcp_ready setup from CCProcess tests`

---

## Phase 6：删 HTTP MCP route

### Task 6.1：删 controller + scope

- [ ] **Step 1**：`runtime/lib/esr_web/router.ex:33-42` 的 `scope "/mcp/:session_id"` block + 注释 删
- [ ] **Step 2**：`git rm runtime/lib/esr_web/mcp_controller.ex runtime/test/esr_web/controllers/mcp_controller_test.exs`
- [ ] **Step 3**：`git grep -rE "McpController|mcp_controller" runtime/` 应零（注释也清干净）
- [ ] **Step 4**：`mix test` 应过
- [ ] **Step 5**：commit `chore(cc-channel): delete HTTP MCP route + controller + tests`

---

## Phase 7：`/pty:input` slash command

### Task 7.1：`Esr.Commands.Pty.Input`

- [ ] **Step 1**：写 `runtime/lib/esr/commands/pty/input.ex` 按 spec §6.5（DSL；name + text 必传；不自动加 `\r`）
- [ ] **Step 2**：`mix esr.gen_slash_routes` 重生 yaml
- [ ] **Step 3**：写 `runtime/test/esr/commands/pty/input_test.exs`
- [ ] **Step 4**：commit `feat(cc-channel): /pty:input slash command`

---

## Phase 8：Integration + lifecycle tests

### Task 8.1：Integration e2e

- [ ] **Step 1**：写 `runtime/test/esr/integration/cc_channel_stdio_e2e_test.exs`。参考 `new_session_smoke_test.exs` 的 app-boot pattern。真实子进程 spawn 用 `Port.open({:spawn_executable, …}, [...])` —— rev-1 plan 错说 `real_claude_boot_test.exs` 有 `Port.open` 示例，实际它走 `:erlexec`/`OSProcess`，用 `Port.open` 重新写
- [ ] **Step 2**：scenario 严格按 spec §8.3：app boot → 起 session → 读 mcp.json 验证 shape → `Port.open` bridge → mock 注入 broadcast → 读 MCP stdout 验证
- [ ] **Step 3**：`@tag :slow`，`mix test --include slow`
- [ ] **Step 4**：commit

### Task 8.2：Lifecycle invariant tests

- [ ] **Step 1**：写 `runtime/test/esr/lifecycle/cc_channel_orphan_test.exs` 验证 I-1..I-4
- [ ] **Step 2**：`@tag :slow`
- [ ] **Step 3**：commit

### Task 8.3：Shell e2e

- [ ] **Step 1**：写 `tests/e2e/scenarios/33_cc_channel_stdio.sh`（30/31/32 都占了；33 是下一个 free number）。**注意**：scenarios 27/29 不是真正的 channel-protocol 测试，是 template/bundle 测试碰到 `kind:` 字符串而已；33 要自己设计 mock-feishu inbound → bridge → mock-CC 验证流程
- [ ] **Step 2**：commit

---

## Phase 9：手动验证

不是代码任务，是 merge 前 smoke test checklist：

- [ ] **9.1** launchd `kickstart -k` 重启 ESRD
- [ ] **9.2** 飞书绑定的 dev bot 群里发 `/session:new name=verify-1`
- [ ] **9.3** `/pty:attach pty=<sid>` 拿到 URL，浏览器打开
- [ ] **9.4** TUI 里 `/mcp`，确认 `esr-channel` 显示 `connected + 3 tools + channel capability`
- [ ] **9.5** 飞书 chat 发 `hello?`
- [ ] **9.6** TUI 里验证 message 作 `<channel source="feishu" chat_id="…" user="…" ts="…">` tag 进 CC context
- [ ] **9.7** CC 用 reply tool 回，验证消息回到飞书 chat
- [ ] **9.8** 发 `/pty:input name=cc text=hello-from-input` —— 验证 TUI 输入框看到文本（未提交）
- [ ] **9.9** 发 `/pty:key enter` —— 验证 CC 收到 prompt
- [ ] **9.10** spec §5.5 验证：CC TUI 输出是否在 chat 里**重复**出现（一份来自 channel reply，一份来自旧的 PTY-stdout mirror）。如果重复 → 开 follow-up PR `feat/feishu-chat-proxy-postchannel-cleanup` 删 mirror。**dev-channels auto-confirm 不删**（2026-05-13 确认是 CC 固有 boot 机制）

9.1 — 9.10 全过：就是 2026-05-12 一整天没复现到的核心症状。merge。

---

## Self-review

- ✅ Spec §5/§6/§7/§8 全部映射到 phase（1→6.1; 2→6.2; 3→6.3; 4→5; 5→5.1/5.4/5.5; 6→5.1/5.2/5.3; 7→6.5; 8→8.1-8.5）
- ✅ 无 placeholder（每 step 都有实际内容 + 命令）
- ✅ 类型/名字一致：`ChannelNotification` / `cc_channel_runner` / `write_channel_mcp_config/1` / `Channels.Mcp` / `Esr.Commands.Pty.Input`
- ✅ Subagent review rev-2 patch 已应用（P0 三处 + P1 几处）

## 执行衔接

**1. Subagent-Driven**（推荐）—— fresh subagent per task；spec compliance + code quality 两阶段 review；in-session 连续推进
**2. Inline Execution** —— `superpowers:executing-plans`，batch + checkpoint

默认 subagent-driven，单 PR，commit 边界 = phase 边界。
