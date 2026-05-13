# 运维 bootstrap 流程

**适用对象：** 第一次部署 esr daemon (`esrd`) 的运维。前提：你熟悉
基本的 Linux + Feishu 应用配置，已经在 Feishu 开放平台建好 app，
手里有 `app_id`、`app_secret`，以及你自己的 Feishu `open_id`。

跑完本指南后，你会得到：

- 一个跑着的 `esrd` 实例
- 你自己（已注册为规范 esr user，自动获 admin 权限）
- 一个连上 Feishu 的 adapter，事件流贯通
- 你的 Feishu 账号已绑到 esr user
- 一个 `/claude_code:tui` URL，在 Feishu chat 里点开即可进入浏览器
  终端，连上一个 Claude Code agent

**全程不需要改环境变量，不需要手编 yaml。**

> **姊妹文档：** [`feishu-adapter-setup.md`](feishu-adapter-setup.md)
> 深入讲 Feishu 一侧的配置（多 app、热更新配置、排查）。

## 快速开始

如果你已经有 daemon 在跑，只想要 copy-paste recipe：

```bash
# 在仓库根目录
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ./runtime/esr'

# 1. 启动 daemon（如果 launchctl 已经在跑可以跳过）
bash scripts/esrd.sh start --instance=default

# 2. 把自己注册为 user — 第一个 user 自动晋升为 admin
esr-dev exec user_add --name=linyilun

# 3. 注册一个 Feishu adapter (app_id + app_secret 来自 Feishu 控制台)
esr-dev exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx

# 4. 把你的 Feishu open_id 绑定到 esr user
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_xxx

# 5. 在 Feishu 群里和 bot 对话：
#    /session:new name=test-cc
#    /agent:add type=cc name=esr-developer
#    /claude_code:tui name=esr-developer
#    → 点 URL → 浏览器里的 xterm 打开你的 CC session
```

**这个命令做了什么（原子的）**：写 `~/.esrd-dev/default/adapters/<name>/config.yaml`，
spawn Python sidecar，**并且** spawn Elixir 端的 `FeishuAppAdapter` peer（处理 Feishu 入站事件）。
三件事在一次 call 里完成 —— 不再需要 `esr exec adapter_refresh` 收尾。

正是这条流程。下面的章节解释每一步、底层身份模型，以及出错时
怎么排查。

## 前置条件

| 需要的东西 | 在哪里拿 |
|---|---|
| Feishu 开放平台 app | <https://open.feishu.cn> — 新建 app，复制 `app_id`（以 `cli_` 开头）和 `app_secret` |
| Feishu bot 进了你的群 | 在 app 的"加入群聊"配置里加 bot；想用 session 的群都要有 bot |
| 你的 Feishu `open_id` | 每个 app 一个值（`ou_xxx`）。可以给 bot 发任意消息看 inbound payload，或者查 Feishu 的 user-info API |
| `claude` CLI | [Claude Code 安装](https://docs.claude.com/claude-code) — 起 `cc` agent 需要它 |
| `esrd` 安装好了 | 本地 build (`cd runtime && mix escript.build`) 或者 `mix escript.install` |

`runtime/esr` escript 是运维操作的 CLI 入口。它通过 admin queue
（文件队列，在 `<ESRD_HOME>/<instance>/admin_queue/`）和 `esrd`
通信，所以 daemon 必须先跑起来，`esr exec ...` 才能推进。

## 一步步走（共 12 步）

### 1. 启动 daemon

```bash
# launchctl 托管（开发推荐）
ESRD_HOME=$HOME/.esrd-dev launchctl load -w \
    scripts/launchd/com.ezagent.esrd-dev.plist

# 或者手动前台启动
ESRD_HOME=$HOME/.esrd-dev bash scripts/esrd.sh start --instance=default
```

实例状态文件都在 `$ESRD_HOME/default/`：`esrd.pid`、`esrd.port`、
`users.yaml`、`capabilities.yaml`、`adapters/<name>/config.yaml`
（每实例一目录，参考 yaml-layout-v2 spec
`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`），
`operator.json`（第 2 步写入），以及
`admin_queue/{pending,completed,failed}/` 提交队列。

设个 alias 让每次 CLI 调用都指到这个实例：

```bash
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ./runtime/esr'
```

### 2. 第一次 `user_add` — bootstrap sentinel 生效

```bash
esr-dev exec user_add --name=linyilun
```

第一次执行时同时发生三件事：

1. **Sentinel.** CLI 还没有 `operator.json`，所以以
   `submitted_by: "system:bootstrap"` 提交。slash dispatcher
   （`Esr.Entity.SlashHandler`）看到没有 admin 就给 `user_add` 一次
   cap-check bypass。(PR #282；spec
   `docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md`。)
2. **自动 admin.** `Esr.Commands.User.Add` 往 `capabilities.yaml`
   写一个新 principal entry，caps 为 `["*"]`。(PR #281；audit
   step #2 在 `docs/manual-checks/2026-05-08-post-multi-instance-audit.md`。)
3. **`operator.json`** 写入你的 UUID + name。之后的 CLI 调用就靠
   `Esr.Cli.Main.resolve_submitter/0` 读它，以你的身份提交 — 不
   需要任何 env var。

返回示例：

```
added esr user linyilun (auto-admin: bootstrap)
  id: <uuid-v4>
  default_workspace: linyilun-default
  auto_admin: true
```

此后 sentinel 永久休眠（只要 `capabilities.yaml` 里有
admin，`Grants.any_admin?/0` 永远是 `true`）。

### 3. 确认 cap 落地

```bash
esr-dev exec cap_list
cat $HOME/.esrd-dev/default/operator.json
```

应该看到你的 principal 持 `capabilities: ["*"]`，operator 指针写好了：

```json
{ "schema_version": 1, "caller_principal_id": "<your-uuid>",
  "name": "linyilun", "set_at": "...", "set_by": "user_add" }
```

### 4. 注册 Feishu adapter

```bash
esr-dev exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx
```

这会在
`adapters/esr_helper/config.yaml` 写新的每实例目录（yaml-layout-v2 — 见
`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`），
`app_id` + `app_secret` 都进 `config:` 块。然后启动 Python sidecar
(`feishu_adapter_runner`)，挂在 `Esr.WorkerSupervisor` 下。
sidecar 通过 Lark 的 `lark_oapi.ws.Client` 开一条到 `open.feishu.cn`
的长连接 WebSocket — **不需要任何 inbound HTTP callback URL**。

返回：`{"adapter_id": "esr_helper", "running": true}`。

`esr-dev exec actor_list` 应该能看到 sidecar peer。看不到的话见
[`feishu-adapter-setup.md`](feishu-adapter-setup.md) § 排查。

在 Feishu chat 里和 bot 对话，`/adapter:list` 能确认接线：

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/adapter:list
```

```chat-output
feishu_app_e2e-mock  type=feishu  app_id=e2e-mock  base_url=http://127.0.0.1:<int>  app_secret=***
```

fence 里的 `base_url` 占位符是 e2e 测试 mock Feishu 的运行时端口；
真实部署不会有 `base_url=` 字段（默认就是 `open.feishu.cn`）。其他
字段按 `Esr.Commands.Adapter.List.format_row/1` 原样渲染。

### 5. 绑定你的 Feishu 身份

```bash
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_xxx
```

把 `ou_xxx` 追加到 `users.yaml` 里你那一行的 `feishu_ids:` 列表。
从 `ou_xxx` 进来的 Feishu 消息现在会被识别成 `linyilun`，
dispatcher 自动取你的 admin caps。

> **`open_id` 是 per-app 的.** 同一个人在每个 Feishu app 里有不同的
> `ou_xxx` — Feishu 用 `(app_id, user)` 推导。如果以后注册了第二个
> Feishu adapter，要用新 app 的 `ou_xxx` 再 `feishu_bind` 一次。

运维也可以直接在 chat 里用 `/feishu:bind` 自助绑定 — dispatcher 从
inbound envelope 读调用方的 Feishu `open_id` 然后绑到指定的
esr user。重复执行是安全的 no-op：

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/feishu:bind name=linyilun
```

```chat-output
ou_test_linyilun already bound to linyilun
```

注意回复里带的是调用方的 `open_id`（这里的 `ou_test_linyilun` 是
e2e fixture 的合成 id；真实部署里看到的是你的真实 `ou_xxx`）。
渲染文案见 `runtime/lib/esr/plugins/feishu/commands/bind_user.ex`。

### 6. （Feishu 控制台）确认事件订阅

在你 app 的 Feishu 开放平台控制台：

- 找到事件订阅配置（标签随 Feishu 版本变 — 较新版用 "事件与回调"）。
  确保 `im.message.receive_v1` 事件开了。
- 长连接传输方式 **不需要任何公网 callback URL** — sidecar 主动 dial
  out 到 Feishu。
- bot 权限（典型最小集）：
  - `im:message` — 读消息
  - `im:message:send_as_bot` — 以 bot 身份回复
  - `im:resource` — 取图片 / 文件（多媒体协议）
- 把 app 发布到企业内部使用，让它能加入群；把 bot 加到目标群里。

如果你的租户必须用 HTTP push 而不是长连接，见
[`feishu-adapter-setup.md`](feishu-adapter-setup.md) § HTTP-callback transport。

### 7-8. （Feishu chat）`/help` 和 `/doctor`

```
/help
/doctor
```

`/help` 按类别列 slash（Users / Workspace / Sessions / Agents /
PTY / Plugins / Capabilities）。`/doctor` 跑元系统自检（dispatcher
活着、plugin 加载好、capabilities 可读）。bot 不回的话见下面的
[常见坑](#常见坑)。

### 8a. `/workspace:new`（可选 — 只在你想要命名 workspace 时）

第 2 步自动建的 `<username>-default` workspace 对大多数运维已经够用，
但你可能想给具体项目建命名 workspace。在 chat 里用 `/workspace:new`：

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/workspace:new name=demo
```

```chat-output
ok: %{"action" => "created", "chats" => [%{"app_id" => "feishu_app_e2e-mock", "chat_id" => "oc_mock_single", "kind" => "dm"}], "folders" => [], "id" => "<UUID>", "location" => "esr:<...>/workspaces/demo", "name" => "demo", "owner" => "linyilun"}
```

当前 chat 会自动 bind 到新 workspace（见回复里的 `chats`）— 后续
`/session:new` 调用就通过 M-5 fallback chain 的 chat-bound 这层
resolve 到 `demo`。

### 9. `/session:new`

```
/session:new name=test-cc
```

起一个绑到当前 chat 的 session。workspace + agent 自动 resolve：
workspace 走 M-5 fallback chain（chat-current → user-default），
agent 来自 session template 的 `agent_def`。什么都不配的话，
默认 elect 的 `feishu-cc` template 把两边都填好 — 完成第 1-5
步之后，`/session:new name=<任意>` 就是最小的运维操作了。

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/session:new name=test-cc
```

```chat-output capture=session_id
session started: <UUID>
```

这条 bare-name `/session:new` 形式是 2026-05-10 的回归门：在
PR #334 之前，这个命令会在历史遗留的 `validate_args(agent, dir)`
检查处失败，错码 `invalid_args: dir required`。上面这个 fence
会让任何重新引入此门的 build FAIL —
`tests/e2e/scenarios/19_session_first_default.sh` 是这个 replay 的
CI 包装。

### 10. `/agent:add`

```
/agent:add type=cc name=esr-developer
```

在 chat-current session 里起一个 Claude Code agent，挂在
`Esr.Scope.AgentSupervisor` 下，supervision 是 `(CC, PTY) :one_for_all`。
返回：

```
{ "actor_ids": { "cc": "<uuid>", "pty": "<uuid>" } }
```

`name=` 是运维面的 tag，`/claude_code:tui` 等 agent-reference 系列
slash 用它定位。

### 11. `/claude_code:tui`

```
/claude_code:tui name=esr-developer
```

解析 agent name → PTY actor id，发一个签名的 PtySocket URL。
点它 — 浏览器打开 xterm.js 终端，挂到 agent 的 PTY。
`/claude_code:tui` 是 `/pty:attach` 的薄 shortcut；如果第 10 步已经
拿到了 PTY id，直接 `/pty:attach pty=<uuid>` 也可以。

### 12. 纯文本 → CC 回复

```
hello — what's the cwd?
```

session 的 CC agent 通过 `<channel>` tag 前缀拿到消息，回复走
`mcp__esr-channel__reply` 工具。回复出现在同一个 chat。完事 —
书签 TUI URL 留一个浏览器终端开着，方便边在 Feishu 操作边看。

## 身份模型

四个互相区分的身份概念，别搞混：

| 概念 | 是什么 | 在哪 | 谁创建 |
|---|---|---|---|
| **esr user** | CLI 上的规范身份（如 `linyilun`）；UUID v4 | `users.yaml`（一行）；`users/<uuid>/user.json` | `esr exec user_add --name=<n>` |
| **Feishu `open_id`** | Feishu 一侧的身份，per-app（`ou_xxx`） | 绑到 esr user 的 `feishu_ids:` 列表里 | `esr exec feishu_bind --name=<n> --feishu_user_id=<ou_xxx>` |
| **当前 CLI operator** | 本地 `esr` escript 当前作为哪个 esr user 提交 | `<ESRD_HOME>/<instance>/operator.json` | `user_add`（首次）或 `user_switch` 写入 |
| **Sentinel `"system:bootstrap"`** | 保留字符串，作为 fallback `submitted_by` | 嵌在 queue envelope 里 | CLI 的 `resolve_submitter/0`，当 `operator.json` 缺失时 |

**`operator.json` schema：**

```json
{
  "schema_version": 1,
  "caller_principal_id": "<user_uuid>",
  "name": "<username>",
  "set_at": "<iso8601>",
  "set_by": "user_add" | "user_switch" | "manual"
}
```

每次 `esr exec ...` 都被 `Esr.Cli.Main.resolve_submitter/0` 读。
写入由 `Esr.Commands.User.Add.maybe_grant_admin/1`（首次
user_add）和 `Esr.Commands.User.Switch.execute/1` 负责。

**Sentinel safety:** 字符串 `"system:bootstrap"` 被
`Esr.Resource.Capability.FileLoader.validate_entry/1` 拒绝（不能
在 yaml 里 grant），也被 `Esr.Commands.Cap.Grant.execute/1` 拒绝
（不能在 submit 时传）。bypass 逻辑只在 slash-handler dispatch
那一处生效，门控三条件全部满足才放过：

1. `submitted_by == "system:bootstrap"`
2. `kind == "user_add"`（唯一允许的 kind）
3. `Esr.Resource.Capability.Grants.any_admin?/0 == false`

任何一个为 false → 走正常 cap-check。admin 一旦存在，条件 3
永远是 false，sentinel 永久休眠。

完整设计见
`docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md`。

## Cap 模型 概览

- capabilities 在 `<ESRD_HOME>/<instance>/capabilities.yaml`。每行
  principal 有 `id`、`kind`（`esr_user` 或 `feishu_user`）、
  `capabilities: [...]`、可选 `note`。
- `*` 是通配符 — admin。第一个 `user_add` 自动 grant。
- 其它 cap 是具体权限串，如
  `user.manage`、`workspace.create`、`cap.manage`、
  `session:<uuid>/spawn`、`pty:<actor_id>/attach`、`feishu/user-bind`。
- 通过 `esr exec cap_grant principal_id=<uuid> permission=<cap>`
  分配 cap。反向操作是 `cap_revoke`。

典型的第二个用户配法：

```bash
esr-dev exec user_add --name=alice
# alice 拿到 UUID 但没有 admin（你已经持 *）
esr-dev exec cap_grant --principal_id=<alice-uuid> --permission=workspace.create
esr-dev exec cap_grant --principal_id=<alice-uuid> --permission=session:default/create
```

## 切换用户

当前 CLI operator 一个实例只有一个 `operator.json`。切换：

```bash
esr-dev exec user_switch --name=alice
```

这会：

1. 验证 alice 存在。
2. 验证调用方有 `user.manage`（sentinel **不** bypass 这步 — 切
   active user 要求 admin）。
3. 覆盖 `operator.json`，`set_by: "user_switch"`。

切完之后，这个 shell 后续每次 `esr exec ...` 都以 alice 身份提交。
切回去就 `user_switch --name=linyilun`（或你的 admin 用户）。

> 也支持手动覆盖 — 真要绕过 CLI 可以 `echo '{...}' > operator.json`。
> 只有 `caller_principal_id` 和 `name` 是 load-bearing；`set_by` 只是
> 信息字段。

## 常见坑

### 所有 CLI 命令都报 `unauthorized`

dispatcher 拒了你 envelope 里的 principal：

- `operator.json` 缺失 → 跑 `esr exec user_switch --name=<你>`
  （没有任何 user 的话就 `user_add`）。
- `operator.json` 指向一个没 caps 的 UUID → 检查 `cap_list` 看缺什么。
- `operator.json` 是损坏的 JSON → CLI 打印
  `operator.json malformed at <path>; using bootstrap sentinel` 到
  stderr。修 JSON 或删掉文件。

### 第一次 `user_add` 还是返回 `unauthorized`

三个 sentinel bypass 条件必须同时满足（见上面 § 身份模型）。如果
条件 3 不满足，说明 admin 已经存在 — 看 `cap_list`，可能之前某次
boot 或 env 变量种了 `capabilities.yaml`。

### Plugin install 只支持本地路径

`/plugin:install <name>` 语法在，但只能装本地 plugin 路径 — 没有
远程 registry。内置 plugin（`feishu`、`claude_code` 等）默认就启
着，多数运维不需要手动装。

### Feishu `open_id` 是 per-app 的

第二个 Feishu adapter 意味着同一个人有另一个 `ou_xxx`。每个都要
单独绑：

```bash
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_app1_xxx
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_app2_xxx
```

`users.yaml` 会同时列两个。

### dev plist / shell rc 里有老 env 变量

- **`ESR_BOOTSTRAP_PRINCIPAL_ID`** —
  `scripts/launchd/com.ezagent.esrd-dev.plist` 里还有，向后兼容用。
  有了 sentinel 之后这个是 **可选** 的（spec D5 保留为补充性的 boot
  seed；之后某个 PR 可能会废）。新自动化不要依赖它。
- **`ESR_OPERATOR_PRINCIPAL_ID`** — PR #282 之前用来挑 submitter 的
  环境变量。**不再读取**（spec D3 硬切）。从 shell rc 删掉它，靠
  `operator.json` + `esr exec user_switch`。

### `register_adapter` 之后 sidecar 反复重启

`actor_list` 看到 sidecar 不断重启的话，最常见原因是 fix 之前的
`register_adapter` bug，spawn config 漏了 `app_secret`。`fix/register-adapter-app-secret`
之后，`adapters/<name>/config.yaml` 带 `config.app_secret`，sidecar
每次 restore 都读它。如果是在 buggy build 上注册过 adapter，跑
`/adapter:remove name=<n>` 然后重新 `register_adapter`，或者手编
`adapters/<name>/config.yaml` 然后重启 daemon。按 yaml-layout-v2
（spec § 4.7）daemon 会对任何缺 `app_secret` 的 feishu 行
fail-loud（Logger.error）+ **跳过 spawn** — 不再静默 fallback 到
`plugins.yaml`。

## 引用

- Specs：
  - `docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md` —
    sentinel + `operator.json` + `user_switch` 设计。
  - `docs/superpowers/specs/2026-05-08-resource-typed-grammar.md` —
    `/agent:*`、`/pty:*`、`/session:*`、`/claude_code:tui` 语法。
- 审核：
  - `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` —
    12-step journey baseline 重打分。
- 姊妹文档：
  - `docs/guides/feishu-adapter-setup.md` — Feishu 控制台配置、
    多 app 部署、热更新、排查。
- 背景：
  - `docs/cookbook.md` — recipe 风格的代码片段。
  - `docs/dev-guide.md` — handler / adapter / pattern 编写。
