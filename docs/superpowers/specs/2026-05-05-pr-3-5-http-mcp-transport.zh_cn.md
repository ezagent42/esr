# PR-3.5 — cc_mcp HTTP MCP Transport（esrd 自托管）

**日期：** 2026-05-05
**状态：** 草稿（subagent review 待做；用户 review 待做）
**关闭：** Phase 3 PR-3.5；cc_mcp 生命周期与 claude 解耦。

## 目标

把 cc_mcp 的 stdio-bridge 子进程换成 esrd 内部托管的 MCP server。
今天 claude 每个 session 起一个 `python -m esr_cc_mcp.channel` 作
为 MCP stdio 子进程，把 channel 生命周期绑死在 claude 进程上。本
PR 之后：

- claude 的 `.mcp.json` 用 `type: http, url: http://...`，不再
  `command: ...`。没有子进程；HTTP/SSE transport。
- esrd 在现有 Bandit 监听器上直接 serve `/mcp/<session_id>` MCP
  endpoint。
- Channel 状态住在 BEAM（现有的 `Esr.Entity.CCProcess` +
  `EsrWeb.ChannelChannel` per-session 状态）。claude 重启不再
  杀 channel。
- `adapters/cc_mcp/` Python 包整个删除。

## 为什么现在做

Phase 3/4 status 文档明确点出这是活的债务：cc_mcp 每次 claude 重
启都死；重启过程中飞行的 notification 静默丢；今天的 ws_client ↔
stdio ↔ claude 链是三层 transport，一层就够。PR-22/PR-24 修了 PTY
attach 生命周期但**没动 cc_mcp 生命周期** —— 本 PR 修。

## 非目标

- 把 MCP server 通用化超出 cc_mcp 的表面。今天 cc_mcp 暴露 ~10
  个工具（`reply`、`react`、`un_react`、`send_file`、`update_title`、
  `send_summary`、`kill_session`、`spawn_session`、`list_sessions`、
  `forward`）；Elixir 移植暴露同一组。未来想加自己 MCP 工具的插件
  走同一套基础设施，但 ship 自己的工具实现。
- 完整 MCP authorization 规范合规。`localhost` 绑定 + per-session
  URL 对 v1 够了；如果远程 claude（claude.ai web client）要连，
  再加 OAuth。
- HTTP/2 或 QUIC transport。Bandit 说 HTTP/1.1；Claude Code 的
  HTTP MCP client 也只要这个。

## 架构

### MCP HTTP transport 概要

按 Anthropic MCP 规范的 HTTP transport，MCP server 暴露**一个
URL**处理：

1. **POST `/`** —— JSON-RPC 请求/响应（tools/list、tools/call 等）。
   body 是 JSON-RPC 信封；响应是 JSON-RPC 信封（或 202 + SSE
   stream 给长跑工具）。
2. **GET `/`**（带 `Accept: text/event-stream`）—— server-sent
   events 流推 server→client 通知（今天走 stdio 的
   `notifications/claude/channel`）。

POST 和 GET 在同一 URL。Claude Code 的 MCP client 在 session 期间
保持 SSE 流开启，并行 POST 工具调用。

### URL 形式

```
http://127.0.0.1:<esrd_port>/mcp/<session_id>
```

Per-session URL 让路由琐碎：path 自带目标 session，localhost 绑定
不需要 auth header。

`esr-cc.sh` 写 `.mcp.json`：

```json
{
  "mcpServers": {
    "esr-channel": {
      "type": "http",
      "url": "http://127.0.0.1:4001/mcp/<session_id>"
    }
  }
}
```

（替换今天的 `command:`/`args:`/`env:` 块。）

### Phoenix 路由

```elixir
# router.ex
scope "/mcp/:session_id" do
  pipe_through :mcp

  post "/", EsrWeb.McpController, :handle_request
  get "/", EsrWeb.McpController, :handle_sse
end
```

`EsrWeb.McpController` 是薄的 HTTP/JSON-RPC 适配器：

- `handle_request/2`：decode JSON-RPC，路由到
  `Esr.Plugin.McpRegistry.dispatch/3`（session_id, method, params），
  encode 响应。
- `handle_sse/2`：开 SSE 流，把连接 PID 订阅到现有 per-session
  PubSub topic（`cli:channel/<session_id>`），把 broadcast 转成
  `event: notification\ndata: <json>\n\n` 帧。SSE 连接前已 buffer
  的通知立刻 flush —— 复用 `docs/notes/cc-mcp-pubsub-race.md` 的
  buffer-and-flush 模式。

MCP "session" 概念由 URL 段 `session_id` 标识；不引入 MCP-level
session token。

### 工具实现

`Esr.Plugins.ClaudeCode.Mcp.Tools.*` 模块 —— 每个 cc 插件暴露的
MCP 工具一个模块。每个模块实现：

```elixir
@callback schema() :: map()           # JSON schema for tools/list
@callback call(session_id, params) :: {:ok, result} | {:error, reason}
```

工具实现是 idiomatic Elixir —— 调现有 per-session 状态（CCProcess、
FeishuChatProxy 等），用今天 Python cc_mcp 通过 WS 调的同一组 API。

### `cc_mcp` Python 删除

本 PR 之后：

- `adapters/cc_mcp/` 整个目录删除。
- `py/pyproject.toml` 的 `[tool.uv.sources] esr-cc-mcp = ...` 删除。
- `scripts/esr-cc.sh` 写 HTTP 形式的 `.mcp.json`。
- `--dangerously-load-development-channels server:esr-channel` 标志
  保留 —— `esr-channel` 现在是 HTTP MCP server 在 `.mcp.json` 里的
  注册名。

feishu manifest 的 `python_sidecars:` 不变（feishu 还有 sidecar）；
claude_code 的 `python_sidecars:` 里 `cc_adapter_runner` 留下因为
那是另一个 Python 进程（handler runner，不是 MCP bridge）。**仅
cc_mcp** —— MCP bridge —— 消失。

### claude_code 插件 manifest 更新

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml
declares:
  entities: [...]
  python_sidecars:
    # cc_adapter_runner 留下；cc_mcp 删除（MCP server 现在 esrd 自托管，
    # 没 Python sidecar）。
    - adapter_type: cc_session
      python_module: cc_adapter_runner
  startup:
    module: Esr.Plugins.ClaudeCode.McpServer
    function: register_endpoint
```

插件的 `startup:` 钩子在 boot 时把 MCP endpoint 注册进
`EsrWeb.Endpoint` 的 router。（今天 router 的 `scope "/mcp"` 是硬
编码的；plugin-startup 钩子让它变成插件拥有，未来 agent 插件 ——
codex、gemini-cli —— 可以注册自己的 MCP path。）

实际上：路由在 Phoenix 是编译期。插件不能运行时**加**路由。两个
选项：

- **(A)** core 的 router 无条件保留 `/mcp/:session_id`，但让
  controller 派发到插件的工具注册表（**这个**是运行时可变的）。
  路由通用；工具表面插件拥有。
- **(B)** 每个插件用读 enabled plugins 的 Phoenix router 宏在
  编译期注册自己的 scope。重。

**spec 选 (A)。** MCP HTTP 路由是通用插件扩展点，跟 `/plugin/list`
对所有插件通用一样。Per-session 工具注册表插件拥有。

这意味 `runtime/lib/esr_web/router.ex` 无条件加 `/mcp/:session_id`
scope。`EsrWeb.McpController` 派发到 `Esr.Plugin.McpRegistry`（新
—— 小 ETS 表），cc 插件在 startup 时把 cc 工具实现填进去。

未来 agent 插件用同一个 `Esr.Plugin.McpRegistry` 注册自己的工具。
注册表按工具名 key；冲突 raise（let it crash）。

## 失败模式

| 时机 | 行为 |
|---|---|
| claude 重启，esrd 在 | 同一 URL 上新 HTTP session。esrd 的 per-session PubSub topic 还有 buffer 的通知等着。SSE flush 重放。|
| esrd 重启，claude 在 | claude 的 MCP HTTP client 拿到 connection-refused → 退避重连。Per-session 状态丢（按当前 esrd 行为；本 PR 范围外）。|
| 工具调用到不存在的 session_id | 404 + JSON-RPC error 信封。claude 在 channel 里显示错误；用户用 `/new-session` 重试。|
| Session pid 注册前的工具调用 | 跟今天一样：PubSub buffer 留住直到订阅者 attach（按 `docs/notes/cc-mcp-pubsub-race.md`）。|
| JSON-RPC 损坏 | 400 + 简单错。controller body 没 try/rescue。|
| SSE 连接断 | claude 重连（MCP client 行为）。esrd 的 pubsub 订阅在连接 PID 死时自动清理。|

边界没 try/rescue。Bandit 的 per-request 崩溃隔离够。

## 测试策略

| 层 | 测试 | 断言什么 |
|---|---|---|
| Unit | `EsrWeb.McpControllerTest` | POST `/mcp/<sid>/` + `tools/list` 返回注册的工具名。POST + `tools/call reply text=ack` 调到 `Esr.Plugins.ClaudeCode.Mcp.Tools.Reply.call/2`。|
| Unit | `Esr.Plugin.McpRegistryTest` | register/3 + 按工具名 lookup。冲突 raise。|
| Integration | `EsrWeb.McpSseTest` | GET `/mcp/<sid>/` + `Accept: text/event-stream` 开 SSE；在 `cli:channel/<sid>` 上 broadcast 通知 → 发出 `event: notification\ndata: …` 帧。|
| **e2e（关键）** | `tests/e2e/scenarios/06_pty_attach.sh` | 已经跑真实 claude+cc_mcp 轮回。本 PR 之后同一 scenario 用 HTTP 形式的 `.mcp.json` 跑 —— e2e 通过证明 "operator 工作流不变"。|
| **不变量** | `Esr.Plugins.IsolationTest` 扩展 | 加新断言：`runtime/lib/esr_web/` 的 controller / router 不引用 `Esr.Plugins.ClaudeCode.*`（具体：`EsrWeb.McpController` 不能按名引用 cc 插件模块；通过 registry 派发）。|

## diff 大小预估

- `runtime/lib/esr_web/router.ex`：**+5 LOC**（`/mcp/:session_id` scope）
- `runtime/lib/esr_web/mcp_controller.ex`（新）：**+150 LOC**（POST + SSE handlers）
- `runtime/lib/esr/plugin/mcp_registry.ex`（新）：**+50 LOC**（ETS-backed 工具注册表）
- `runtime/lib/esr/plugins/claude_code/mcp.ex`（新）：**+30 LOC**（`register_endpoint/0` startup 钩子 + 工具列表）
- `runtime/lib/esr/plugins/claude_code/mcp/tools/*.ex`（新，~10 模块）：**+400 LOC**（每工具 ~40 LOC；body 把现有 cc_mcp 工具逻辑移植到 Elixir）
- `runtime/lib/esr/plugins/claude_code/manifest.yaml`：**+5 LOC**（`startup:` 块；cc_mcp sidecar 条目删除）
- `scripts/esr-cc.sh`：**−10 LOC**（删 `command:` 块，写 `url:` 形式）
- `adapters/cc_mcp/`：**−~1500 LOC**（整目录删）
- `py/pyproject.toml`：**−1 LOC**（`esr-cc-mcp` 源删除）
- 测试：**+250 LOC**（新）**−~800 LOC**（cc_mcp 测试删）

**净：~+900 LOC 加，~−2310 LOC 删 = ~−1400 LOC。** 净**减**因为
Python ws_client + stdio bridge + per-tool 适配器都没了。

## 回滚

Revert 干净：cc_mcp/ 回来；`.mcp.json` 模板回 `command:`；controller +
registry + tools 删除；router scope 删除。Phase D-1 + D-2 的成果不
受影响（本 PR 严格做 cc_mcp 生命周期）。

## 解决了的设计问题（let-it-crash 立场）

- **Per-session URL 还是 query param？** URL path（`/mcp/<session_id>`）。
  路由更干净，不用解析 header。
- **Auth？** localhost 绑定 + URL 保密。v1 不带 auth header。等
  远程 claude.ai client 要连再加 token 形式（Phase E-2）。
- **工具注册表冲突？** raise。let it crash（memory rule）。
- **SSE 还是 long-poll 给通知？** SSE。MCP HTTP transport 规范要求
  server→client 用 SSE。
- **工具 body raise 怎么办？** 传到 Bandit；per-request 500 +
  JSON-RPC error 信封由 McpController 单一 catch-all clause 格式
  化。500 是 let-it-crash 信号；同一 SSE stream 上后续调用照常工作。

## 用户（林懿伦）开放问题

1. **MCP 路由放在 `runtime/lib/esr_web/router.ex`（选 A）** 还是
   通过 Phoenix router 宏由插件注册（选 B —— 重）？spec 默认 A，
   理由"编译期路由更简单"。
2. **插件工具住源码树哪里？**
   `runtime/lib/esr/plugins/claude_code/mcp/tools/`（每工具一模块）
   是 spec 假设。vs 备选 `runtime/lib/esr/plugins/claude_code/mcp.ex`
   一个 ~400-LOC 大模块，请确认。
3. **向后兼容窗口？** spec 假设硬切换 —— 同一 PR 删 `cc_mcp/`、
   翻 `.mcp.json`，不留过渡双栈。`git pull` 之后 operator 直接拿
   到 HTTP transport。
