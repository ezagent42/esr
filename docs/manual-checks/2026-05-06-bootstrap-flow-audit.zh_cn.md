# Bootstrap-flow audit — 2026-05-06

**操作员设想的 12 步流程** vs **`origin/dev` `854f1f2` 实际承载的能力**。

> **配套文件：** 英文原版位于
> [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md)。

> **更正说明（2026-05-06，rev 2）：** 本审计的第一版基于 `main` 分支
> 状态写就，但 `dev` 比 `main` **领先 99 个 commit**——其中包含整个
> plugin 机制（spec [`2026-05-04-plugin-mechanism-design.md`](../superpowers/specs/2026-05-04-plugin-mechanism-design.md)
> 加上 `Esr.Plugin.{Loader, Manifest, EnabledList}` 模块、5 个 admin
> 命令、5 条 slash route、2 个内置 plugin）。下文以 `dev` 实状为准；
> 第一版"plugin 概念不存在"的判断完全错误，已修正。

## 方法论

每一步从三个维度打分：

| 维度 | 符号 | 含义 |
|---|---|---|
| Interface | I | 存在某个入口点*可能*服务这一步 |
| Function | F | 入口点端到端确实交付预期行为 |
| Grammar | G | 操作员所打字面与 shipped 形态完全一致 |

符号：✅ 是 · ⚠️ 部分 · ❌ 否 · `[unverified]` 未通过代码确认。

证据为 `file_path:line` 或直接代码引用。审视范围：
`runtime/priv/slash-routes.default.yaml`、`runtime/lib/esr/cli/main.ex`、
`runtime/lib/esr/commands/**`、`runtime/lib/esr/plugin/**`、
`runtime/lib/esr/plugins/**`、`runtime/lib/esr/resource/capability/supervisor.ex`、
`runtime/lib/esr/users/**`、`scripts/esr*.sh`、近期 spec
（`docs/superpowers/specs/2026-05-0[4,5]*.md`）。

## 总览表

| # | 操作员所打 | I | F | G | 结论 |
|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | 可工作（前提是 launchd plist 已安装） |
| 2 | `esr add user linyilun`（自动 admin） | ✅ | ⚠️ | ❌ | 命令存在；自动 admin 由 env 驱动而非"序号第一" |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | install 动词在；语义是 local-path，不是按名拉取 |
| 4 | `esr plugin feishu bind linyilun ou_xxx` | ✅ | ✅ | ❌ | 绑定动词在 user 域：`esr user bind-feishu` |
| 5 | `esr plugin install claude-code` | ✅ | ⚠️ | ⚠️ | 同 #3；默认已内置 |
| 6 | `esr plugin claude-code set config {http_proxy=…}` | ❌ | ❌ | ❌ | 无 `set config` 动词；`required_env` 仅 manifest 声明 |
| 7 | （飞书）`/help` `/doctor` | ✅ | ✅ | ✅ | 按设计工作 |
| 8 | （飞书）`/session:new` | ✅ | ✅ | ❌ | 实际为 `/new-session` 或 `/session new`（空格不冒号） |
| 9 | （飞书）`/workspace:add <path> worktree=test-esr` | ⚠️ | ⚠️ | ❌ | 心智模型不同；最近的是 `/new-workspace` + `/new-session worktree=…` |
| 10 | （飞书）`/agent:add cc name=esr-developer` | ⚠️ | ⚠️ | ❌ | agent 由 plugin 声明；最近的等价是 `/plugin enable claude_code` |
| 11 | （飞书）普通文本 → 回复含 cwd | ✅ | ✅ | ✅ | 当下能工作 |
| 12 | （飞书）`/agent:inspect esr-developer` → URL | ⚠️ | ✅ | ❌ | `/attach` 返回 URL 但是按 chat-current 解析，不是按 agent 名字 |

**总体：12 步里 9 步内容上能工作**（7 全通、2 部分通）。剩下 3 步
（#6 set-config、#9 workspace-add、#10 agent-add）卡在缺动词
（`set config`）或心智模型不一致（操作员设想 session→add-workspace→
add-agent；ESR 走 workspace+chat→spawn-session+plugin-declared-agent）。
单格 ❌ 大多落在 **grammar** 维度——操作员设想的冒号命名 + 动词序
和实际的 dash/space 不匹配。

---

## 逐步详解

### 第 1 步 — `esr daemon start`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/cli/main.ex:42-101` 的 `cmd_daemon` 处理 `start`/`stop`/`restart`/`status`，分发到 `launchctl load -w <plist>`。 |
| **F** | ✅ 前提是 `~/Library/LaunchAgents/com.ezagent.esrd-<instance>.plist` 存在。Plist 由 `scripts/esrd-launchd.sh` 安装。 |
| **G** | ✅ 完全一致。 |

**揭示的前置条件：** `esr daemon start` 假设 plist 已存在；首次操作员
得先跑 `bash scripts/esrd-launchd.sh install`（或等价命令）。escript
本身也需要 build——`runtime/esr` 在新检出后并不存在，要先
`(cd runtime && mix escript.build)`。CLAUDE.md 提到了这层关系；
可考虑加一个一键 `make bootstrap` 脚本。

### 第 2 步 — `esr add user linyilun`（自动 admin）

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/user/add.ex` 存在。CLI 经 `cli/main.ex:88-93` 的 catch-all 路由到 admin queue，写为 `esr user add`。 |
| **F** | ⚠️ 添加用户能成；但"首个用户自动 admin"不是按序号实现的，而是由环境变量驱动：`runtime/lib/esr/resource/capability/supervisor.ex:maybe_bootstrap_file/1` 检查 `ESR_BOOTSTRAP_PRINCIPAL_ID`，若 `capabilities.yaml` 缺失就 seed 一份给该 principal admin 权。所以"首个 admin 鸡生蛋"问题**已经解决**，只是形态跟操作员所想不同。 |
| **G** | ❌ 实际词序是 `esr user add <name>`（group-then-verb，与现有 `esr cap *` / `esr daemon *` / `esr plugin *` 一致）。操作员打的 `esr add user` 会路由到 slash kind `add_user`（未注册），失败。 |

**修补方向：** 操作员想要的"自动 admin"机制存在，只是绑在 env 上。
一个 spec："若无 `ESR_BOOTSTRAP_PRINCIPAL_ID` 且启动时 zero users，
则下一个 `user add` 自动 grant admin"——在现有 seeding 上加几行就行。

### 第 3 步 — `esr plugin install feishu`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/plugin/install.ex` 注册为 slash `/plugin install`，CLI 形态 `esr plugin install`。 |
| **F** | ⚠️ Phase-1 的 `install` 接收 `<local_path>`，**不是** `<plugin_name>`——它把本地源目录复制到 `runtime/lib/esr/plugins/<name>/` 并校验 manifest。Spec [`2026-05-04-plugin-mechanism-design.md` §2 非目标](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#二) 明确把 Hex / git remote install 推到 Phase 2。而且：feishu **已经内置**（`runtime/lib/esr/plugins/feishu/manifest.yaml`）且**默认开启**（`Esr.Plugin.EnabledList.legacy_default/0`）——操作员的意图（"让 feishu 可用"）冷启动后已被满足。最贴近意图的现有命令是 `esr plugin list`（确认 feishu 已加载）或 `esr plugin enable feishu`（如果之前被禁用）。 |
| **G** | ⚠️ 动词 `install` 在；参数形态（name vs path）不一致。 |

### 第 4 步 — `esr plugin feishu bind linyilun ou_xxxx`

| | |
|---|---|
| **I** | ✅ `runtime/lib/esr/commands/user/bind_feishu.ex`（标准形：`esr user bind-feishu <username> <ou_id>`）。 |
| **F** | ✅ 绑定写入 `Esr.Users.Registry` 的 `:esr_users_by_feishu_id` ETS 表；支持一个用户多个 feishu id。 |
| **G** | ❌ Plugin-scoped 的 `esr plugin feishu bind ...` 与 user-scoped 的 `esr user bind-feishu` 形态不同。代码中绑定的心智模型是"这个用户在 feishu 平台上还有 `<ou_id>` 这个名字"——以用户为中心，不是以 plugin 为中心。 |

**值得注意：** plugin manifest spec
（[§3 注入点 #19](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#三)）
确实定义了 plugin 侧的 `identity_hook`（`Esr.Plugins.Feishu.Identity.resolve_external_id/2`），
core 的 `whoami`/`doctor` 调用它做 `ou_<id>` → 标准 username 的解析。
所以**解析路径**已 plugin 化；只有**绑定动词**留在 user 域。如果操作员
偏好强烈，可以加一个 plugin 命名空间的 alias `esr plugin feishu bind ...`。

### 第 5 步 — `esr plugin install claude-code`

同第 3 步。值得提的小点：plugin 名是 `claude_code`（snake_case，
见 `runtime/lib/esr/plugins/claude_code/manifest.yaml:11`）；操作员
打的是 `claude-code`（kebab）。Manifest spec
[§4.1](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#41-validation-rules)
说名字 kebab-case，但内置 plugin 实际用 snake——值得加一行 spec 一致性。

PR-3.5（2026-05-05）**删除**了 `adapters/cc_mcp/`——claude 通话的 MCP
server 现在由 esrd 自己 host（`EsrWeb.McpController`）。cc plugin 不
再需要 Python sidecar（见 `runtime/lib/esr/plugins/claude_code/manifest.yaml:14-23`）。

### 第 6 步 — `esr plugin claude-code set config {http_proxy=…}`

| | |
|---|---|
| **I** | ❌ `set config` 动词不存在。Plugin spec 只定义 `list/info/install/enable/disable`。 |
| **F** | ❌ — |
| **G** | ❌ — |

最接近的现有机制是 manifest 的 `required_env:` 字段（注入点 #13）——
plugin 声明依赖的 env 变量，启动时验证缺失则 fail。但这是
**编译期 manifest 声明**，不是**运行时操作员设置**。

操作员设想的 `set config` 需要：
1. 新 admin 命令（`Esr.Commands.Plugin.SetConfig`）
2. 新 yaml 文件（`plugins.config.yaml` 之类）存放每 plugin 的操作员可改 env
3. 重载机制（或像 `/plugin install` 那样发"restart required"提示）

跟进 spec 候选。TODO 里"agent (cc) startup config first-class"正是
这件事——本审计确认了操作员想要的形态。

### 第 7 步 — `/help` `/doctor`

| | |
|---|---|
| **I** | ✅ 都注册在 `runtime/priv/slash-routes.default.yaml:25-65`。 |
| **F** | ✅ `/help` 按 `category:` 分组渲染 schema。`/doctor`（`runtime/lib/esr/commands/doctor.ex`——dev 上从 `admin/commands/` 移到了 `commands/`）检查用户绑定 + chat→workspace 绑定，输出"下一步"建议。 |
| **G** | ✅ 完全一致。 |

**陈旧引用小坑** 在 `doctor.ex:67-73`：提示文里写 `./esr.sh user add`。
实际 entry 是 `esr` escript（`mix escript.build` 生成）；**`esr.sh`
这个文件不存在**。一行修复：要么 ship `scripts/esr.sh`（exec 转给
escript），要么把提示文改成 `esr user add`。

### 第 8 步 — `/session:new`

| | |
|---|---|
| **I** | ✅ Session 创建在。 |
| **F** | ✅ `Esr.Commands.Session.New` 经 `slash-routes.default.yaml` 接通；按 workspace `root:` 字段从 `origin/main` fork 一个 git worktree。 |
| **G** | ❌ 实际：`/new-session`（dash）+ alias `/session new`（空格）。冒号命名 `/session:new` 不被解析。 |

**横切关注：** ESR 的 slash 语法今天混用 dash、space、无分隔
（`/new-session`、`/session new`、`/workspace info`、`/list-agents`）。
若 spec 把 `/<group>:<verb>` 定为标准形，操作员设想的若干 slash
就能直接工作，并能让项目废弃临时 alias。

### 第 9 步 — `/workspace:add /Users/.../esr worktree=test-esr`

| | |
|---|---|
| **I** | ⚠️ 现有最近的是 `/new-workspace name=… root=… start_cmd=… owner=…`。dev 上还新增了 `/workspace describe`（操作员侧的 `describe_topology` MCP tool 的孪生命令）——只看不改。**两者都不"把 workspace 路径加到当前 session"。** |
| **F** | ⚠️ 现行模型是 workspace-first：注册 workspace（`/new-workspace`），自动绑当前 chat，然后 `/new-session workspace=<n> name=<s> worktree=<branch>`。操作员设想的 `/workspace:add` 像是 2 步流程的第二步（先 `/session:new` 再 `/workspace:add`）。两个模型结构不同。 |
| **G** | ❌ — |

**底层心智模型差异**（与 rev 1 一致）：操作员想 `session → add
workspace → add agent`；项目走 `workspace + chat → spawn session`。
拍板前值得 brainstorm——要么给操作员的顺序搭壳，要么 ship 一份
operator guide 带新人走当前的顺序。

另：路径里 `/User/h2oslabs/...` 应是 `/Users/...`（大写 S 复数，是
typo）。

### 第 10 步 — `/agent:add cc name=esr-developer`

| | |
|---|---|
| **I** | ⚠️ 没有 `/agent:add` slash。`/list-agents`（`runtime/lib/esr/commands/agent/list.ex`）枚举 agent 列表。**但** agent 是 *plugin 声明的*——`claude_code` plugin 的 manifest 声明了 `cc` agent（[`2026-05-04-plugin-mechanism-design.md` §4 注入点 #3](../superpowers/specs/2026-05-04-plugin-mechanism-design.md#四-plugin-manifest-schema)）。所以"加 cc agent"语义上等价于"确保 claude_code plugin 启用"——`esr plugin enable claude_code`（默认就启用了，相当于 no-op）。 |
| **F** | ⚠️ 功能意图（"有个可用的 CC agent"）默认满足；操作员的祈使语气 `add` 没有。 |
| **G** | ❌ — |

**Spec ask：** 决定 agent 走声明式（config-only，plugin 自带）还是长出
祈使式 `add` slash。前者简单；后者更贴近操作员心智，但带来 reload
race + 唯一性检查工作。

`name=esr-developer` 参数也值得标注——操作员设想 agent **实例命名**
（一个 chat 内可以有 `cc:esr-developer` + `cc:reviewer`）。今天 agent
名字就是 plugin 声明的 `cc`，每个 session 至多一个 cc-agent。
chat 内多实例 agent 会是 agent 模型的一项重大扩展。

### 第 11 步 — 普通文本 → 回复含 cwd

| | |
|---|---|
| **I** | ✅ 入站文本 → cc plugin 的 CCProcess → cc 回复路径，是生产主路径。 |
| **F** | ✅ 由 [`docs/notes/manual-e2e-verification.md`](../notes/manual-e2e-verification.md) "Single-app DM scenario"（PR-A 已合）和 `tests/e2e/scenarios/06_pty_attach.sh` + `07_pty_bidir.sh` 端到端验证。 |
| **G** | ✅ — |

具体到操作员希望回复里看到 `/Users/h2oslabs/Workspace/esr/.worktrees/test-esr`，
需要：
- 第 8/9 步把 `cwd=` 设到那个 worktree 路径（`/new-session
  worktree=test-esr` 就是干这个，参 CLAUDE.md "Session URI shape"
  ："`cwd` is a git worktree path (always)"）；
- CC 被问到时跑 `pwd` 报告。

两个条件对一个能工作的系统都是合理预期。

### 第 12 步 — `/agent:inspect esr-developer` → 浏览器 URL 看 TUI

| | |
|---|---|
| **I** | ⚠️ `/attach`（`runtime/lib/esr/commands/attach.ex`）返回可点击的 HTTP URL，背靠 xterm.js。PR-23（Phoenix.Channel + xterm.js）+ PR-24（binary WS PTY transport）已经把这条路打通。 |
| **F** | ✅ 端到端可用。 |
| **G** | ❌ 两处 grammar 偏差：(a) `/attach` 解析的是 *chat-current* session，不是 *agent name*；(b) 操作员设想的 `/agent:inspect <name>` 暗示参数驱动查找，不是 chat-context 查找。 |

**邻近开放问题：** 同一个 chat 里如果有多个 session（重复跑
`/new-session` 起不同 `name=`），`/attach` 只解析到 chat-current 那个
slot——按名字 attach 旧 session 没路径。新增的 `/workspace describe`
（dev 上加的）是个先例：操作员侧检查命令，**接受显式名字**。
attach-by-name（`/attach name=<s>` 或 `/agent inspect <s>`）可以照
这个先例补上。

---

## 横切性差距

### 1. 冒号命名语法（步骤 8/9/10/12）

grammar 错配的最大单一来源。ESR 当前 slash 语法混用 dash
（`/new-session`、`/list-agents`）、空格（`/workspace info`、
`/plugin install`）、无分隔。一份采用 `<group>:<verb>` 为标准形的
spec 可以让心智负担降低，并让若干操作员所打 slash 无需改功能就能用。

### 2. 操作员可设的 per-plugin 配置（步骤 6）

[`docs/futures/todo.md`](../futures/todo.md) 里已有"Spec: agent (cc)
startup config first-class"。Plugin manifest 的 `required_env:` 声明
*需要什么*，但没暴露 *操作员怎么设*。与 plugin/agent 边界紧耦合。

### 3. `add` 周边的心智对齐（步骤 9/10）

项目走**声明式**（workspace / agent / adapter 实例都是 yaml；plugin
集合靠 `/plugin enable` + restart）；操作员设想**祈使式**
（`/session:new` + `/workspace:add` + `/agent:add`）。两条路：要么把
声明式模型显式教给操作员（清晰的 bootstrap 文档 + 具体顺序），要么
落地祈使式 slash 包住声明式的状态变化。

### 4. 首个用户自动 admin（步骤 2）

机制存在（`ESR_BOOTSTRAP_PRINCIPAL_ID` env），但需要操作员先知道
要设这个 env。更友好的默认——"`user add` 跑时若 capabilities.yaml 没
任何 admin grant，自动给该用户 admin"——是小改动（约 30 LOC，落在
`Esr.Resource.Capability.Supervisor`），可以让操作员省掉 env 一步。

### 5. `esr.sh` 引用（步骤 1/7）

`doctor.ex:67-73` 等 hint 文广告 `./esr.sh user add`。dev 上实际入口
是 `esr` escript（`runtime/esr`，`mix escript.build` 产物）；磁盘上
**没有** `esr.sh`。要么 ship 一个 `scripts/esr.sh` 薄壳（`exec ./esr
"$@"`），要么把 hint 改成直接用 `esr`。

---

## 推荐 spec（按杠杆排序）

按 影响 ÷ 工作量 大致从高到低：

1. **修陈旧的 `esr.sh` 引用** — 1 行改：`doctor.ex` 提示文里把
   `./esr.sh` 换成 `esr`。或在 escript 构建后顺手 ship 一个
   `scripts/esr.sh` 薄壳。
2. **首用户自动 admin 扩展** — 在 `user add` 调用时，若 capabilities.yaml
   还没有任何 admin grants，默认 grant 给被加的用户。常见情形下能
   subsume `ESR_BOOTSTRAP_PRINCIPAL_ID`。
3. **Spec：冒号命名 slash 语法** — 拍板标准形（操作员提的
   `<group>:<verb>`）；更新 `slash-routes.default.yaml` 把
   `/session:new` 等设为主形态；dash 形保留一个 release 作 deprecated
   alias。
4. **Spec：操作员可设 per-plugin 配置** — `/plugin <name> set config
   <key>=<value>` 写到 `plugins.config.yaml`（`plugins.yaml` 旁边）；
   像 `/plugin install` 一样发 "restart required" 提示。subsume TODO
   里那条"agent (cc) startup config first-class"。
5. **Spec：祈使式 `add` 动词（或文档化声明式流程）** — 要么 ship
   `/session:new` → `/workspace:add` → `/agent:add` 作为声明式状态
   变化的薄壳，要么 ship 一份 `docs/guides/first-time-operator.md`
   带新人走当前的 workspace-first 顺序。文档化便宜得多；改造代价大。

---

## 相关文档

- [`docs/notes/manual-e2e-verification.md`](../notes/manual-e2e-verification.md)
  — 已运行系统的*发布后*手工验证。互补 `make e2e`。
- [`docs/dev-flow.md`](../dev-flow.md) — 本审计依循的 `feature → dev →
  main` 流程。
- [`runtime/priv/slash-routes.default.yaml`](../../runtime/priv/slash-routes.default.yaml)
  — slash command 标准源。
- [`docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md`](../superpowers/specs/2026-05-04-plugin-mechanism-design.md)
  — plugin 机制 spec rev 5（本审计的 plugin 相关结论全部引用）。
- [`docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`](../superpowers/specs/2026-05-05-plugin-physical-migration.md)
  — plugin 物理迁移（第三阶段）。
- [`docs/futures/todo.md`](../futures/todo.md) — 长生命周期 TODO 列表；
  本审计若干条目映射到那里现有的 entry。
