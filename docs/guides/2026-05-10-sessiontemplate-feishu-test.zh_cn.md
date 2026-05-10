# SessionTemplate + Channel —— 飞书侧测试指南

> **配套文件:** [`.md`](2026-05-10-sessiontemplate-feishu-test.md)
> **Spec:** [`docs/superpowers/specs/2026-05-10-session-template-and-channel.md`](../superpowers/specs/2026-05-10-session-template-and-channel.md)
> **Plan:** [`docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`](../superpowers/plans/2026-05-10-session-template-and-channel-plan.md)
> **PR 序列:** #324 → #325 → #326 → #327 → #328 → #329 → #330 → #331

本文带操作员通过飞书 chat 端到端测试 SessionTemplate + Channel 迁移。
CLI 侧配置已就绪；本文记录复现步骤 + 验证点。

## 前置（CLI 侧已完成）

`~/.esrd-dev/default/` 实例已就绪（operator: `linyilun`, principal `f813b071-…`）：

- `operator.json` —— `caller_principal_id` 字段（#321 后 schema）
- `adapters/esr_helper_dev/config.yaml` —— yaml-v2 一物一目录（#322 后）
- `plugins/{claude_code,feishu}/config.yaml` —— yaml-v2 plugin config
- `plugins.yaml` —— `enabled: [claude_code, feishu]`
- esrd-dev 运行中，feishu sidecar attach

从 fresh install 开始的话，老 [`operator-bootstrap-checklist.md`](operator-bootstrap-checklist.md)
覆盖步骤 1–7；新增 SessionTemplate 验证从步骤 8 起。

## 操作员可见的变化

相对 rev-5 checklist 的**唯一**新增/变化：

| 接口 | 之前 | 现在 |
|---|---|---|
| `/session:new` 参数 | `name=foo agent=cc` | `name=foo template=feishu-cc`（新参数；单 template 时缺省 auto-elect）|
| 新 slash | — | `/agent:add-session session=<sid> name=<n>`（multi-session-per-instance）|
| 新 mix 任务 | — | `mix esr.gen_bundle_docs`，`mix esr.check_bundles`（CI 门）|
| Agent 持久化 | 嵌在 `session.json::agents[]` | 一物一文件 `sessions/<sid>/agents/<uuid>.json`（boot 时自动迁移）|

其它（workspace 流程 / /agent:add / 纯文本 → CC 回复）不变。

## 测试步骤

### 8a. 校验 bundle + template 已注册

在装了 bot 的飞书 chat：

```
/plugin:list
```

预期：列出 `claude_code` (enabled)、`feishu` (enabled)、`stub_agent` (disabled
—— Phase 8 抽象验证 e2e 用的 stub bundle)。

(没有 `/bundle:list` slash；通过 `/session:new template=` 能解析名字间接验证。)

### 8b. workspace + 通过 template 起 session

```
/workspace:new name=test-ws
/workspace:add-folder path=/Users/h2oslabs/Workspace/esr
/session:new name=test-cc template=feishu-cc
```

预期：
- `/workspace:new` 返 `ok: true`
- `/workspace:add-folder` 返 `ok: true`（路径必须是真 git repo）
- `/session:new` 返 `ok: true`，新 template-driven 路径起的会话

省略 `template=` 也行 —— Phase 5 的 `Esr.Session.DefaultTemplate.auto_elect_if_single/0`
boot 时把 `feishu-cc`（唯一注册的 template）选为默认，所以 `/session:new name=test-cc`
也通。

### 9. 加 CC agent

```
/agent:add type=cc name=alice
```

预期：`ok: true` + `actor_ids.cc` + `actor_ids.pty` 都填好。

### 10. 纯文本 → CC 回复

同一个 chat：

```
hello, what's the cwd?
```

预期：Claude Code 回真实 cwd。

### 11. Multi-session-per-instance（Phase 7 新增）

在第二个装了同一 bot 的飞书 chat：

```
/workspace:use name=test-ws
/session:new name=test-cc-junior
/agent:add-session session=<test-cc-junior 的 sid> name=alice
```

预期：
- alice 的 `session_ids` 数组现在含两个 session UUID
- 看磁盘：
  ```bash
  cat ~/.esrd-dev/default/sessions/<sid_A>/agents/<alice_uuid>.json | jq .session_ids
  ```
  显示 `[<sid_A>, <sid_B>]`。
- 第二个 chat 发 `hello from junior`；回复**只**落第二个 chat（不串到 boss chat）。
  Reply routing 跟着 inbound 的 `current_session_id` 走。

### 12. PTY attach（不变）

```
/claude_code:tui name=alice
```

返带签名 `?token=` 的 URL；浏览器点开 xterm.js 接进 alice 的 PTY。

## 验证点

Phase 1-8 承诺的**架构 invariant**：

- [ ] `/session:new template=feishu-cc name=foo` 不带 `agent=` 也成功
      （template 自带 agent_kind）
- [ ] `/session:new name=foo`（不带 `template=`）也成功 —— 单 template
      auto-elect 为默认
- [ ] 两 session + 一 agent via `/agent:add-session` —— 回复正确分流（无串扰）
- [ ] 磁盘：`sessions/<sid>/agents/<uuid>.json` 一物一文件（Phase 7 hardcut，
      告别 `agents:[]` 数组）
- [ ] `mix esr.check_bundles` CI 门绿（在 `runtime/` 下跑）

## 常见问题

### 报 `operator.json malformed`

`principal_id` 字段在 #321 (2026-05-09) 被改名 `caller_principal_id`。
迁老 `~/.esrd-dev/` 的话改一下字段就行。CLI 每次调用都重读，无须重启。

### `no template registered`

`Esr.SessionTemplate.Registry.list_all/0` 为空。检查：
1. `bundles_dir` 解析 —— `Esr.Paths.bundles_dir/0` 应返
   `runtime/lib/esr/bundles/`（Phase 8 修了原 bug）。Phase 7 及之前的
   build 路径有错；用 #331 后的 build 重启。
2. bundle 的 `dependencies.plugins[]` 全部启用（feishu-cc 需 `feishu` +
   `claude_code` 两个）。
3. 日志：`tail -50 ~/.esrd-dev/default/logs/launchd-stderr.log` 不应出现
   `Logger.warning` 因依赖未启用而 skip template。

### `unknown_kind: plugin:list`

`:` 是 slash 形式（chat 侧）。CLI 用 kind 名（snake_case）：`esr-dev exec
plugin_list`，不是 `exec /plugin:list`。

### Agent 回复落错 chat（multi-session）

Phase 7 invariant 测试
(`runtime/test/esr/plugins/claude_code/cc_process_multi_session_test.exs`)
钉了这一点。生产观察到的话，bug 八成在 `CCProcess` 从 inbound envelope
读 `current_session_id` 那一步。检查 inbound `notification` 是否携带
`current_session_id` 字段（Phase 7 task 7.6 给 cc_mcp 工具目录加上的）。

## 验收清单

跑完上面步骤，8-phase 迁移操作员侧验证完毕：

- ✅ Phase 1-3：Channel behaviour + 2 个 impl 注册（`/plugin:list` 显示
      claude_code + feishu enabled）
- ✅ Phase 4：Bundle + SessionTemplate registry；首个 bundle `feishu-cc`
      自动加载
- ✅ Phase 5：`/session:new template=` 切换 + 默认 auto-elect
- ✅ Phase 6：agents.yaml 注销；`agent_kinds:` source-of-truth 落 plugin
      manifest
- ✅ Phase 7：一物一文件；多 session 共享 instance via `/agent:add-session`
- ✅ Phase 8：`mix esr.check_bundles` CI 门；stub plugin 证明抽象不绑死 CC

任何步骤挂了，抓 `~/.esrd-dev/default/logs/launchd-stderr.log` + 失败的
slash + `cat ~/.esrd-dev/default/sessions/<sid>/session.json` 输出反馈。
