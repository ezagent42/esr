# Spec：元模型对齐的 ESR — Session-First、Multi-Agent、Colon-Namespace、Plugin-Config-3-Layer

**日期：** 2026-05-07
**状态：** rev-1（DRAFT — 等待用户 review）
**分支：** `spec/metamodel-aligned-esr`
**英文版：** [`2026-05-07-metamodel-aligned-esr.md`](2026-05-07-metamodel-aligned-esr.md)

**取代（内容已吸收，原分支保留作参考）：**
- `spec/colon-namespace-grammar` 分支 — `docs/superpowers/specs/2026-05-07-colon-namespace-grammar.md` → 吸收进 §4
- `spec/plugin-set-config` 分支 — `docs/superpowers/specs/2026-05-07-plugin-set-config.md` → 吸收进 §6（含修正）

---

## §0 — 锁定决策

以下所有决策均由用户在 **2026-05-06 至 2026-05-07 Feishu 对话**中锁定，原文引用，本 spec 不再重新辩论。

### 第一轮（Q1-Q5，2026-05-06）

- **Q1=A**：同类型 agent 允许多实例；实例通过 `@<name>` 区分。
- **Q2=A**（后改为 **Q7=B**）：`@<agent_name>` mention 解析 — 纯文本简单字符串匹配（见 Q7）。
- **Q3=C with twist**：per-session workspace 为主；chat-default workspace 为可选 fallback。
- **Q4=multi-scope per chat with attach**：1 个 chat = N 个并发 scope（session）；`/session:attach <name_or_uuid>` 加入；跨用户 attach 需 capability 门控。
- **Q5=一气呵成**：所有变更一次连贯迁移，不拆分成独立阶段。

### 第二轮（Q6-Q10，2026-05-06）

- **Q6=D**：运营者通过 `/session:set-primary <name>` 设置 primary agent；默认 = 第一个加入 session 的 agent。
- **Q7=B**：纯文本 `@<name>` 用简单字符串匹配（不使用平台 mention API）。单独一个 `@` 后不跟名字视为普通文本。**Agent 名在同一 session 内全局唯一，与类型无关**（不允许 `cc:esr-dev` 和 `codex:esr-dev` 同时存在）。
- **Q8=A**：每个 chat 维护一个"当前 attached session"指针；没有显式 `@` 的纯文本路由到 attached session 的 primary agent。
- **Q9=C**：既支持命令式（`/session:share`）也支持声明式（capability yaml）；命令式是声明式的语法糖。
- **Q10=C**：Session 是一等公民；`$ESRD_HOME/<inst>/sessions/<session_uuid>/` 本身即是一个 workspace（该 session 的自动临时 workspace）。

### 第三轮（Q11 + 修正，2026-05-07）

- **Q11=B**：Plugin config 三层：**global → user-default-workspace → current-workspace**（优先级：workspace > user > global，per-key merge）。
- **用户关键洞察**：每个用户在 `$ESRD_HOME/<inst>/users/<username>/` 有个人 workspace（"user-default workspace"）。
- **删除 `/session:add-folder`**：folder 由 workspace 管理，不由 session 管理。
- **`/key` → `/pty:key`**（不是 `/session:key` — key 是 PTY 命令，不是 session 命令）。
- **删除 `/workspace:sessions`**：workspace 不能依赖 session；只允许 session → workspace 方向。
- **删除 `@deprecated_slashes` map**：硬切换；不提供旧名 fallback 错误提示。
- **feishu manifest 必须在 `config_schema:` 中包含 `app_id` + `app_secret`**。
- **`depends_on:` 字段在 plugin load 时强制校验**（字段已存在于 manifest struct；需在 `Loader.start_plugin/2` 时 enforce）。
- **Per-key merge** config 层：global → user → workspace；每个 key 以最后一层 set 的为准；key 缺失则 fallback 到上层。
- **删除 `sensitive:` 标志**：如果运营者能配置某个 key，就能读它，无需 masking。
- **launchd plist 只放 esrd 自身 env var**（`ESRD_HOME`、`ESRD_INSTANCE`、`ANTHROPIC_API_KEY`）；其余（代理、per-plugin API key 等）放 plugin config yaml。

---

## §1 — 动机

### 元模型与实现之间的偏差

`docs/notes/concepts.md`（rev 9，2026-05-03）定义了 ESR 的四元元模型：所有运行时活动由四个原语描述 — **Scope**、**Entity**、**Resource**、**Interface** — 加上声明式的 **Session**（描述如何实例化 Scope）。元模型的典型例子（§九）展示了一个群聊 Scope，其中包含多个人类 entity、多个 agent entity（`agent-cc-α`、`agent-codex-β`）和共享 resource，都通过 `MemberInterface` 协作。

实现在两个关键点上偏离了：

1. **Workspace-first，而非 session-first。** 今天必须先注册 workspace 才能创建 session。运营者的心智模型（来自启动流程审计 `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md`）正好相反：先创建 session，再 attach workspace 和 agent。元模型与运营者一致——Session 实例化 Scope，Scope 引用 Resource（包括 workspace）。Workspace 是 Resource；它应该是 session 的结果，而不是前提。

2. **1 个 session 1 个 agent，而非 N 个。** 今天 `ChatScope.Registry` 将 `(chat_id, app_id)` 映射到唯一一个 `session_id`，每个 session 最多一个 CC 进程。元模型明确描述 `agent-cc-α` 和 `agent-codex-β` 是同一群聊 Scope 内的对等 Entity。

启动流程审计具体揭示了运营者的痛点：步骤 10（`/agent:add cc name=esr-developer`）完全没有对应 surface；步骤 8（`/session:new`）Grammar 不符合因为 colon-namespace 未发布；步骤 6（`/plugin claude-code set config`）没有任何机制。

PR #230（workspace UUID 重设计）修复了 workspace 存储模型，引入了 UUID、混合存储（ESR-bound 在 `$ESRD_HOME/<inst>/workspaces/<name>/`，repo-bound 在 `<repo>/.esr/workspace.json`）以及 14 个 `/workspace:*` slash 命令。本 spec 直接在此基础上构建，对齐剩余部分。

### 目标

1. 将实现与元模型对齐：session-first、multi-agent、Scope 作为群聊实例。
2. 简化运营者 UX：统一 `/<group>:<verb>` 语法，取消混用的 dash/space/bare 形式。
3. 启用多 agent 协作：每个 session N 个 agent，全局唯一 `@<name>` 寻址，primary-agent 路由。
4. 启用运营者设置 plugin config：3 层解析，替代 shell-script 临时方案。
5. 一次连贯迁移（Q5=一气呵成），不拆分单独阶段。

### 非目标（延后）

- **Plugin config 热重载** — Phase 1 需重启；热重载是 Phase 2。
- **User UUID 身份** — 当前用户以 username（字符串）为 key。Spec 默认使用 username 路径；UUID 身份作为开放问题列在 §10。
- **远程 plugin 安装** — `/plugin:install` 继续仅支持本地路径；Hex/git-remote 安装是 Phase 2。
- **Session 声明式 YAML** — spec 定义 `session.json` 运行时状态文件；声明式 `SessionSpec` YAML（类比元模型的 `use SomeSession`）是未来阶段。

---

## §2 — 新模型

### 元模型原语到具体实现的映射

| 元模型原语 | 具体实现 | 备注 |
|---|---|---|
| **Scope** | Chat attached 的 session 实例，UUID 标识 | `Esr.Resource.Session.*`（新）；每个 session 即一个 Scope；一个 chat 可 attach N 个 session |
| **Entity（人类）** | `Esr.Entity.User` | username-keyed；暂无 UUID（见 §10） |
| **Entity（agent）** | Session 内的 agent 实例：`{type, name}` 对 | 如 `{cc, "esr-dev"}`、`{codex, "reviewer"}`；`Esr.Entity.Agent.Instance`（新） |
| **Resource（workspace）** | `Esr.Resource.Workspace.*`（PR-230）+ session 自动临时 workspace | per-session workspace 在 `sessions/<uuid>/`；命名 workspace 在 `workspaces/<name>/` |
| **Resource（channel）** | Feishu chat（`chat_id` + `app_id` 对） | `Esr.Entity.FeishuChatProxy`；chat 是 channel Resource |
| **Resource（capability）** | `Esr.Resource.Capability.*` | 符号 + grant binding；CLI edge 处做 UUID 翻译 |
| **Interface** | Role traits：`MemberInterface`、`ChannelInterface` 等 | 定义在 `docs/notes/actor-role-vocabulary.md` |
| **Session（声明式）** | `session.json` schema（新）；完整声明式 YAML 延后 | `session.json` 捕获实例状态：agents、attached chats、primary、workspace binding |

### 变化对比

**之前**（现状）：
- 1 个 chat → 1 个 workspace → 1 个 session → 1 个 CC agent
- Session 以 workspace 为 scope；`ChatScope.Registry` 将 `(chat_id, app_id)` 映射到唯一 `session_id`

**之后**（本 spec）：
- 1 个 chat → N 个 session（attached-set）；每个 session 引用一个 workspace
- Session 是一等 Scope；workspace 是 session 引用的 Resource
- 每个 session 可有 N 个 agent 实例，名字在 session 内全局唯一
- 每个 chat 的"当前 attached session"指针（Q8=A）将普通文本路由到 primary agent

### 示意图：一个 chat 有 2 个 session

```
chat: oc_xxx（Feishu DM，app_id=cli_yyy）
├── attached sessions（attached-set）：
│   ├── session "esr-dev"（uuid=aaa-111）   ← 当前 attached
│   │   ├── workspace: sessions/aaa-111/   （自动临时）
│   │   ├── agents：
│   │   │   ├── {cc, "esr-dev"}            ← primary agent
│   │   │   └── {codex, "reviewer"}
│   │   └── owner: linyilun
│   └── session "docs"（uuid=bbb-222）      （已 attach，非当前）
│       ├── workspace: workspaces/docs-ws/  （命名，共享）
│       ├── agents：
│       │   └── {cc, "docs-writer"}        ← primary agent
│       └── owner: linyilun
└── attached-current 指针 → session "esr-dev"
```

linyilun 发普通文本 → session "esr-dev" → primary agent "esr-dev"（type cc）
`@reviewer hello` → session "esr-dev" → agent "reviewer"（type codex）
`/session:attach docs` → 切换 attached-current 指针到 session "docs"

---

## §3 — 存储布局

### 完整目录树

```
$ESRD_HOME/<inst>/
├── plugins.yaml                              # global：enabled list + global plugin config
├── workspaces/                               # ESR-bound 命名 workspace（PR-230）
│   └── <name>/
│       ├── workspace.json                    # workspace 身份、folders、chats、transient
│       └── .esr/
│           └── plugins.yaml                  # workspace 层 plugin config（新）
├── users/                                    # user-default workspace（新）
│   └── <username>/
│       ├── workspace.json                    # 此目录本身即 workspace，为用户自动管理
│       └── .esr/
│           └── plugins.yaml                  # user 层 plugin config（新）
└── sessions/                                 # session-default workspace（新，per Q10=C）
    └── <session_uuid>/
        ├── workspace.json                    # 自动临时，除非通过 /session:bind-workspace 重绑
        ├── session.json                      # session 状态：agents、attached chats、primary
        └── .esr/
            └── plugins.yaml                  # 少用；通常 session 继承 workspace 层 config
```

Repo-bound workspace（PR-230 模式，不变）：

```
<repo>/
└── .esr/
    ├── workspace.json                        # workspace 身份（PR-230）
    └── plugins.yaml                          # workspace 层 plugin config（新）
```

### 路径 helpers（扩展 `Esr.Paths`）

| Helper | 路径 |
|---|---|
| `Esr.Paths.sessions_dir/0` | `$ESRD_HOME/<inst>/sessions/` |
| `Esr.Paths.session_dir/1` | `$ESRD_HOME/<inst>/sessions/<session_uuid>/` |
| `Esr.Paths.session_json/1` | `$ESRD_HOME/<inst>/sessions/<session_uuid>/session.json` |
| `Esr.Paths.user_workspace_dir/1` | `$ESRD_HOME/<inst>/users/<username>/` |
| `Esr.Paths.user_workspace_json/1` | `$ESRD_HOME/<inst>/users/<username>/workspace.json` |
| `Esr.Paths.user_plugins_yaml/1` | `$ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml` |
| `Esr.Paths.workspace_plugins_yaml/1` | `<workspace_root>/.esr/plugins.yaml` |

### `session.json` schema（版本 1）

```json
{
  "schema_version": 1,
  "id": "<session_uuid>",
  "name": "<human-friendly name>",
  "owner_user": "<username>",
  "workspace_id": "<workspace_uuid>",
  "agents": [
    {
      "type": "cc",
      "name": "esr-dev",
      "config": {}
    },
    {
      "type": "codex",
      "name": "reviewer",
      "config": {}
    }
  ],
  "primary_agent": "esr-dev",
  "attached_chats": [
    {
      "chat_id": "oc_xxx",
      "app_id": "cli_xxx",
      "attached_by": "<username>",
      "attached_at": "2026-05-07T12:00:00Z"
    }
  ],
  "created_at": "2026-05-07T12:00:00Z",
  "transient": true
}
```

Schema 说明：

- `id`：UUID v4，session 创建时生成。
- `name`：运营者提供（或自动生成为 `session-<timestamp>`）。
- `workspace_id`：指向 workspace UUID。默认为 `sessions/<session_uuid>/` 的自动临时 workspace。`/session:bind-workspace` 后指向命名 workspace。
- `agents` 列表：每项有 `type`（plugin 名，如 `cc`、`codex`）、`name`（session 内全局唯一）、可选 `config` 覆盖（agent 启动时 merge 到 workspace 层 config 之上）。
- `primary_agent`：接收未 @ 纯文本的 agent 名。默认为 `agents` 第一项。`/session:set-primary` 可更改。
- `attached_chats`：将此 session 加入 attached-set 的 chat 集合。
- `transient`：`true` = session 结束且 workspace 干净时自动清理 `sessions/<uuid>/`；`false` = 结束后保留。

### 用户默认 workspace 的 `workspace.json`

`users/<username>/` 下的 user-default workspace 遵循 PR-230 的 `workspace.json` schema，固定值如下：

```json
{
  "schema_version": 1,
  "id": "<uuid>",
  "name": "<username>",
  "owner": "<username>",
  "kind": "user-default",
  "folders": [],
  "chats": [],
  "transient": false,
  "created_at": "..."
}
```

User-default workspace 在 `esr user add <name>` 时自动创建。不出现在 `/workspace:list`（按 `kind != "user-default"` 过滤），但可通过 `/workspace:info name=<username>` 查看。

### 迁移说明：`ChatScope.Registry` 数据格式

当前 `(chat_id, app_id)` → `session_id` 单槽格式需迁移为 `(chat_id, app_id)` → `{current: session_id, attached_set: [session_id]}`。启动迁移：读取旧单槽格式 → 包装为 `{current: id, attached_set: [id]}` → 持久化新格式。

---

## §4 — Slash 命令面（Colon-Namespace，硬切换）

### 语法规则（锁定，2026-05-06）

1. **完整切换，无 alias，无 fallback helper。** 旧语法输入返回 `unknown command: /old-form`。不设 `@deprecated_slashes` map（用户修正，2026-05-07）。
2. **多词动词保留 dash。** `/workspace:add-folder`，而非 `/workspace:addfolder`。
3. **无过渡期。** 一次发布，硬切换。
4. **`/help` 和 `/doctor` 保持 bare 形式** — 元系统发现命令；不加冒号。
5. **`/key` → `/pty:key`**（用户修正，2026-05-07 — key 向 PTY 发键盘输入；PTY 是 resource group）。
6. **删除 `/workspace:sessions`**（用户修正，2026-05-07 — workspace 不能依赖 session）。

### 完整 slash 清单（迁移后）

#### 现有 slash 改名为 colon 形式

| 之前 | 之后 | 规则 |
|---|---|---|
| `/help` | `/help` | bare meta — 保留 |
| `/doctor` | `/doctor` | bare meta — 保留 |
| `/whoami` | `/user:whoami` | bare → colon，group=user |
| `/key` | `/pty:key` | bare → colon，group=pty（用户修正） |
| `/new-workspace` | `/workspace:new` | dash → colon |
| `/workspace list` | `/workspace:list` | space → colon |
| `/workspace edit` | `/workspace:edit` | space → colon |
| `/workspace add-folder` | `/workspace:add-folder` | space → colon，dash 保留 |
| `/workspace remove-folder` | `/workspace:remove-folder` | space → colon，dash 保留 |
| `/workspace bind-chat` | `/workspace:bind-chat` | space → colon，dash 保留 |
| `/workspace unbind-chat` | `/workspace:unbind-chat` | space → colon，dash 保留 |
| `/workspace remove` | `/workspace:remove` | space → colon |
| `/workspace rename` | `/workspace:rename` | space → colon |
| `/workspace use` | `/workspace:use` | space → colon |
| `/workspace import-repo` | `/workspace:import-repo` | space → colon，dash 保留 |
| `/workspace forget-repo` | `/workspace:forget-repo` | space → colon，dash 保留 |
| `/workspace info` | `/workspace:info` | space → colon |
| `/workspace describe` | `/workspace:describe` | space → colon |
| `/workspace sessions` | **已删除** | workspace 不能依赖 session（用户修正） |
| `/sessions` | `/session:list` | bare → colon，group=session |
| `/list-sessions`（alias） | 删除 | 由 `/session:list` 覆盖 |
| `/new-session` | `/session:new` | dash → colon |
| `/session new`（alias） | 删除 | 由 `/session:new` 覆盖 |
| `/end-session` | `/session:end` | dash → colon |
| `/session end`（alias） | 删除 | 由 `/session:end` 覆盖 |
| `/list-agents` | `/agent:list` | dash → colon，group=agent |
| `/actors` | `/actor:list` | bare → colon，group=actor |
| `/list-actors`（alias） | 删除 | 由 `/actor:list` 覆盖 |
| `/attach` | `/session:attach` | bare → colon，group=session |
| `/plugin list` | `/plugin:list` | space → colon |
| `/plugin info` | `/plugin:info` | space → colon |
| `/plugin install` | `/plugin:install` | space → colon |
| `/plugin enable` | `/plugin:enable` | space → colon |
| `/plugin disable` | `/plugin:disable` | space → colon |

#### 新增 `/session:*` 系列（全部为新）

| Slash | Permission | 说明 |
|---|---|---|
| `/session:new [name=X] [worktree=Y]` | `session:default/create` | 创建 session + 自动临时 workspace。自动 attach 到创建该 session 的 chat，primary agent = 第一个加入的 agent。 |
| `/session:attach <name\|uuid>` | `session:<uuid>/attach` | 在当前 chat 加入已有 session；设置 attached-current 指针。跨用户 attach 需 cap 门控。 |
| `/session:detach` | none | 当前 chat 离开 attached session；不结束 session。 |
| `/session:end [session=X]` | `session:<uuid>/end` | 终止 session。若 transient workspace 干净则自动清理。 |
| `/session:list` | `session.list` | 列出当前 chat 的 session（attached-set + 调用者可见的）。 |
| `/session:add-agent <type> name=X [config_overrides]` | `session:<uuid>/add-agent` | 向当前 session 添加 agent 实例。名字在 session 内必须全局唯一。 |
| `/session:remove-agent <name>` | `session:<uuid>/add-agent` | 从 session 移除 agent 实例。不能移除 primary agent（除非先 set-primary 到其他 agent）。 |
| `/session:set-primary <name>` | `session:<uuid>/add-agent` | 设置 primary agent（接收未 @ 的纯文本）。 |
| `/session:bind-workspace <name>` | `session:<uuid>/end` | 将 session 从自动临时 workspace 切换到命名 workspace。 |
| `/session:share <session> <user> [perm=attach\|admin]` | `session:<uuid>/share` | 将 attach（或 admin）capability 授权给其他用户。默认 `perm=attach`。是 `/cap:grant` 的语法糖。 |
| `/session:info [session=X]` | `session.list` | 显示 session 详情：agents、primary、attached chats、workspace、创建时间。 |

#### 新增 `/pty:*` 系列（替代 bare `/key`）

| Slash | Permission | 说明 |
|---|---|---|
| `/pty:key keys=<spec>` | none | 向当前 chat 的 session PTY 发送特殊键盘输入（up/down/enter/esc/tab/c-X 等）。 |

#### 新增 `/plugin:*` config 管理命令

| Slash | Permission | 说明 |
|---|---|---|
| `/plugin:set <plugin> key=value [layer=global\|user\|workspace]` | `plugin/manage` | 设置 config key；校验 manifest `config_schema:`；需重启。默认 layer=global。 |
| `/plugin:unset <plugin> key [layer=global\|user\|workspace]` | `plugin/manage` | 从指定层删除 config key；幂等。 |
| `/plugin:show <plugin> [layer=effective\|global\|user\|workspace]` | `plugin/manage` | 显示 plugin config。`layer=effective` = merge 结果。 |
| `/plugin:list-config` | `plugin/manage` | 显示所有已启用 plugin 的有效 config。 |

#### 新增 `/cap:*` 系列（capability 管理，slash 形式）

| Slash | Permission | 说明 |
|---|---|---|
| `/cap:grant <cap> <user>` | `cap.manage` | 向用户授权 capability（`esr cap grant` escript 的 slash 形式）。 |
| `/cap:revoke <cap> <user>` | `cap.manage` | 撤销用户的 capability。 |

### Mention 解析器

纯文本中的 `@<name>` 路由（Q7=B，锁定）：

- 输入文本在 dispatch 前扫描 `@([a-zA-Z0-9_-]+)` 模式。
- 若匹配且 `<name>` 是 attached session 的 agent 名 → 路由到该 agent。
- 若无匹配，或 session 中无该名 agent → 路由到 primary agent（Q8=A）。
- 单独一个 `@` 后不跟字母数字字符 → 视为纯文本。
- Agent 名匹配大小写敏感。
- 模块：`Esr.Entity.MentionParser`（新）。

---

## §5 — Capabilities

### 新增 capability scope

在 PR-230 的 `workspace:<uuid>/<verb>` 模式基础上，引入以下新 cap scope：

| Cap 字符串 | 含义 |
|---|---|
| `session:<uuid>/attach` | 加入已有 session（跨用户） |
| `session:<uuid>/add-agent` | 在 session 中 add/remove/set-primary agent |
| `session:<uuid>/end` | 终止该 session |
| `session:<uuid>/share` | 向其他用户授权该 session 的 attach 权限 |
| `plugin:<name>/configure` | 设置指定 plugin 的 config key |

`session:default/create` cap（`/new-session` 已有）保留作为创建权。

### Session 的 UUID 翻译

`Esr.Resource.Capability.UuidTranslator`（PR-230 引入，处理 workspace UUID）扩展以支持 `session:<name>` ↔ `session:<uuid>` 翻译（CLI edge 处）。

模式：运营者输入 `/session:share esr-dev linyilun` 时，handler 将 `esr-dev`（当前 chat 上下文中的 session 名）解析为 `aaa-111`（其 UUID），构造 cap `session:aaa-111/share`。同样的解析适用于所有 session-scoped cap 的 slash dispatch。

### Session 共享安全模型（Q9=C，Risk 3）

跨用户 attach 需 capability 门控。攻击模型：

1. UserA 创建 session。Session workspace root 为 `sessions/aaa-111/`，包含 UserA 的代码和状态。
2. 若 UserB 可以无授权 attach，则 UserB 可以向 UserA 的 CC agent 发送任意命令，可能导致代码外泄或破坏性操作。
3. 缓解：必须显式 grant `session:<uuid>/attach` cap。`/session:share` 是运营者发起 grant 的命令。Admin 用户持有 `session:*/attach` 通配符。
4. Session 创建者自动持有该 session 的所有 `session:<uuid>/*` cap。

---

## §6 — Plugin Config（3 层）

### 层定义（Q11=B，锁定）

| 层 | 存储位置 | 运营者命令 |
|---|---|---|
| **Global** | `$ESRD_HOME/<inst>/plugins.yaml` → `config:` 节 | `/plugin:set <plugin> key=value layer=global` |
| **User** | `$ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml` → `config:` 节 | `/plugin:set <plugin> key=value layer=user` |
| **Workspace** | `<workspace_root>/.esr/plugins.yaml` → `config:` 节 | `/plugin:set <plugin> key=value layer=workspace` |

`<workspace_root>` 是 session 当前绑定 workspace 的根目录（`sessions/<uuid>/` 自动临时，或 `workspaces/<name>/` ESR-bound，或 `<repo>/` repo-bound）。

### 解析算法

```
effective_config(plugin, session_context) =
  per-key merge：
    1. 从 schema defaults 开始（所有层均无的 key 用 manifest default）
    2. 应用 global 层   （key 存在则覆盖 default）
    3. 应用 user 层     （key 存在则覆盖 global）
    4. 应用 workspace 层（key 存在则覆盖 user）

  "存在" = 该层 config map 中包含该 key
  （即使值为空字符串 ""；空字符串也赢过 absent）
  "absent" = 该层 config map 中根本没有该 key
```

在 session 创建时解析；存入 ETS，key 为 `{session_id, plugin_name}`。之后任意时刻可通过 `Esr.Plugin.Config.get/2` 读取。

### Manifest `config_schema:`（新字段）

每个 plugin 的 `manifest.yaml` 新增 `config_schema:` 块：

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml（新增）
config_schema:
  http_proxy:
    type: string
    description: "HTTP 代理 URL。空字符串 = 不用代理。"
    default: ""

  https_proxy:
    type: string
    description: "HTTPS 代理 URL，通常与 http_proxy 相同。"
    default: ""

  no_proxy:
    type: string
    description: "逗号分隔的绕过代理的主机/后缀。"
    default: ""

  anthropic_api_key_ref:
    type: string
    description: |
      Anthropic API key 的 env var 引用，如 "${ANTHROPIC_API_KEY}"。
      Plugin 在 session 启动时通过 System.get_env/1 解析实际值。
      请勿将 key 明文写在此字段。
    default: "${ANTHROPIC_API_KEY}"

  esrd_url:
    type: string
    description: "esrd 的 WebSocket URL，控制 HTTP MCP endpoint。"
    default: "ws://127.0.0.1:4001"
```

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml（新增）
config_schema:
  app_id:
    type: string
    description: "Feishu app ID（cli_xxx）。API 调用必需。"
    default: ""

  app_secret:
    type: string
    description: "Feishu app secret。API 调用必需。"
    default: ""

  log_level:
    type: string
    description: "日志级别（debug|info|warning|error）。"
    default: "info"
```

`config_schema:` 设计说明：

- **无 `sensitive:` 标志**（用户修正，2026-05-07）。能配置 key 的运营者就能读它；无需 masking。
- `type:` 必填。Phase 1 支持 `string` 和 `boolean`；integer 和 list 延后到 Phase 2。
- `description:` 必填 — 强制 plugin 作者为每个 key 写文档。
- `default:` 必填；可为空字符串。Schema default 是最后的 fallback。
- 运营者提供的 key 若不在 `config_schema:` 中，写入时报错并列出所有有效 key。

### `depends_on:` 强制执行

`depends_on:` 字段已存在于 `Esr.Plugin.Manifest` struct，由 `Manifest.parse/1` 解析。`Esr.Plugin.Loader.topo_sort_enabled/2` 已读取 `manifest.depends_on.plugins` 做排序。但 Loader 目前不会在依赖缺失时 fail-fast。

本 spec 要求：在 `Loader.start_plugin/2` 时，若 `depends_on.plugins` 中有 plugin 不在已加载集合，返回 `{:error, {:missing_dependency, dep_name}}` 并中止该 plugin 启动。Let-it-crash（用户原则）。

### 存储格式

```yaml
# $ESRD_HOME/<inst>/plugins.yaml
enabled:
  - feishu
  - claude_code
config:
  claude_code:
    http_proxy: "http://proxy.local:8080"
    esrd_url: "ws://127.0.0.1:4001"
  feishu:
    app_id: "cli_a9563cc03d399cc9"
    app_secret: "${FEISHU_APP_SECRET}"
```

```yaml
# $ESRD_HOME/<inst>/users/<username>/.esr/plugins.yaml
config:
  claude_code:
    anthropic_api_key_ref: "${MY_ANTHROPIC_KEY}"
```

```yaml
# <workspace_root>/.esr/plugins.yaml
config:
  claude_code:
    http_proxy: ""    # 覆盖为直连（清除 global proxy）
```

### Shell 脚本删除

`scripts/esr-cc.sh` 和 `scripts/esr-cc.local.sh` 在 Phase 8 合并后删除。env-export 职责迁移：

| `esr-cc.sh`/`esr-cc.local.sh` 职责 | 迁移目标 |
|---|---|
| `http_proxy`、`https_proxy`、`no_proxy`、`HTTP_PROXY`、`HTTPS_PROXY` | `claude_code` plugin config |
| `ANTHROPIC_API_KEY` / `.mcp.env` source | 保留在 launchd plist 作为系统 env var；在 plugin config 用 `anthropic_api_key_ref` 引用 |
| `ESR_ESRD_URL` | `claude_code.config.esrd_url` |
| `exec claude` + `CLAUDE_FLAGS` 构建 | `Esr.Entity.PtyProcess` / `Esr.Plugins.ClaudeCode.Launcher`（Elixir 原生） |
| `session-ids.yaml` resume 查找 | PTY spawn 前在 Elixir 处理 |
| `.mcp.json` 写入 | PTY spawn 前在 Elixir 处理 |
| workspace trust 预写入 `~/.claude.json` | PTY spawn 前在 Elixir 处理 |
| `ESR_WORKSPACE`、`ESR_SESSION_ID` env var | PtyProcess spawn args（BEAM 已设置） |
| `ESRD_HOME`、`ESRD_INSTANCE` | 仅在 launchd plist（esrd 自身 env var） |

### 重载语义

Phase 1：需重启。`/plugin:set` 后打印：`config written: <plugin>.<key> = "..." [<layer> layer]\nesrd 需重启生效（esr daemon restart）`。

Phase 2（超出本 spec 范围）：`Esr.Plugin.Config.reload/1` 热重载。

---

## §7 — 迁移计划（10 个 phase，硬切换）

每个 phase 对应一个 PR。顺序强制（依赖列在 table 中）。LOC 为新增/删除/修改估算。

| Phase | PR 标题 | 主要文件 | LOC 估算 | 依赖 |
|---|---|---|---|---|
| 0 | `spec: metamodel-aligned ESR`（本 spec） | `docs/superpowers/specs/` | — | — |
| 1 | `feat: session UUID identity + storage layout` | `runtime/lib/esr/resource/session/*`（新），`Esr.Paths` helpers，JSON schema | ~800 | Phase 0 |
| 2 | `feat: chat→[sessions] attach/detach state` | `runtime/lib/esr/resource/chat_scope/registry.ex`、`chat_scope/file_loader.ex` | ~600 | Phase 1 |
| 3 | `feat: multi-agent per session` | `runtime/lib/esr/entity/agent/instance.ex`（新），`agent/registry.ex` 扩展 | ~700 | Phase 1 |
| 4 | `feat: mention parser + primary-agent routing` | `runtime/lib/esr/entity/mention_parser.ex`（新），`entity/slash_handler.ex` | ~400 | Phase 3 |
| 5 | `feat: session cap UUID translation` | `runtime/lib/esr/resource/capability/uuid_translator.ex` | ~300 | Phase 1 |
| 6 | `feat: colon-namespace slash cutover` | `runtime/priv/slash-routes.default.yaml`、`slash_handler.ex`、所有 command 模块 | ~1200 | Phase 1+3 |
| 7 | `feat: plugin-config 3-layer + manifest config_schema` | `runtime/lib/esr/plugin/*`、`runtime/lib/esr/plugins/*/manifest.yaml` | ~600 | Phase 6 |
| 8 | `chore: delete esr-cc.sh + esr-cc.local.sh` | `scripts/`、`runtime/lib/esr/entity/pty_process.ex`、`tests/e2e/scenarios/` | ~300 已删 | Phase 7 |
| 9 | `docs+test: e2e scenarios 14-16 + docs sweep` | `docs/`、`tests/e2e/scenarios/` | ~400 | Phase 8 |

**依赖 DAG：**
```
0 → 1 → 2
        ↘ 3 → 4
          ↘ 5
    1+3 → 6 → 7 → 8 → 9
```

无环。所有边单向，无依赖循环。

**总估算：** ~5300 LOC，10 个 PR，~1-2 周。

---

## §8 — 风险登记

| # | 风险 | 可能性 | 缓解措施 |
|---|---|---|---|
| R1 | `ChatScope.Registry` 数据格式变更破坏运行中实例 | 中 | Phase 2 `file_loader.ex` 启动迁移：读取旧单槽 → 转为 attached-set → 持久化新格式。启动时校验，非懒加载。 |
| R2 | `/session:add-agent` 时 agent 名冲突 | 低（设计面控制） | 插入前强制名字唯一性检查。返回 `{:error, {:duplicate_agent_name, name}}`，并附上结构化消息："agent name 'esr-dev' 已存在于 session（type: cc）；请选择不同名字。" |
| R3 | 跨用户 attach 安全绕过 | 低（正确执行时） | `/session:attach` dispatch 时 cap 检查：调用者必须持有 `session:<uuid>/attach`。Session 创建者自动持有。跨用户需通过 `/session:share` 或 admin 通配符授权。攻击模型见 §5。 |
| R4 | Plugin config schema 严格性 — 运营者 typo 被拒绝 | 低 | 结构化错误提示："unknown config key 'http-proxy' for plugin claude_code；valid keys：http_proxy, https_proxy, no_proxy, anthropic_api_key_ref, esrd_url"。 |
| R5 | 硬切换 slash 名 — 现有 docs、tests、scripts 失效 | 中 | Phase 9（docs sweep）对每个旧命令名 `git grep`；Phase 6 PR 描述列出所有受影响文件。E2E scenarios 使用内部 kind 名（非 slash 文本）— 不受重命名影响。 |
| R6 | 删除 shell 脚本 — 生产运营者丢失 env var | 中 | Phase 8 PR 描述包含迁移清单：（1）deploy 前用 `/plugin:set` 设置所需 config；（2）`/plugin:show` 验证；（3）重启 esrd；（4）`make e2e`。Phase 8 合并前发 Feishu 公告。 |
| R7 | `esr user add` 时 user-default workspace 自动创建失败（`users/` 目录缺失） | 低 | `Esr.Commands.User.Add` 用 `File.mkdir_p/1` 创建 `users/<username>/` 后再写 `workspace.json`。与 Phase 1 session 启动同一模式。 |
| R8 | `depends_on:` 强制执行破坏现有 plugin | 低 | `feishu` 和 `claude_code` 均声明 `depends_on: {core: ">= 0.1.0", plugins: []}`。空 plugins 列表表示无 plugin 间依赖；只有声明了 plugin 依赖但该依赖未启用时才触发报错。 |

---

## §9 — 测试计划

### 单元测试（per phase）

**Phase 1（session 身份）：**
- `Esr.Resource.Session.Registry` — UUID 往返：创建 → 持久化 → 重载 → 断言字段一致。
- `Esr.Resource.Session.Registry` — name → UUID 索引：按名查找返回正确 UUID。
- `Esr.Resource.Session.FileLoader` — 原子性：部分写入不可见（temp-rename 模式）。
- `Esr.Paths` — 新 helper 返回路径匹配 `$ESRD_HOME/<inst>/sessions/<uuid>/`。

**Phase 2（chat→[sessions]）：**
- `ChatScope.Registry` — attach：chat 初始为空；attach 后 `current` = session_id，`attached_set` = [session_id]。
- `ChatScope.Registry` — detach：detach 后 session 从 `attached_set` 移除；`current` 更新为下一个或 nil。
- `ChatScope.Registry` — 启动迁移：旧单槽 ETS row 转为 attached-set 格式。
- `ChatScope.Registry` — 多 attach：两个 session 已 attach；`current` 指针随 `/session:attach` 切换。

**Phase 3（multi-agent）：**
- `Agent.Instance` — 名字唯一：加 `{cc, "esr-dev"}` 再加 `{codex, "esr-dev"}` → `{:error, {:duplicate_agent_name, "esr-dev"}}`。
- `Agent.Instance` — 不同名不同类型：`{cc, "dev"}` + `{codex, "reviewer"}` → 均成功。
- Primary agent fallback：移除 primary → 报错，需先 set-primary 到其他 agent。

**Phase 4（mention 解析）：**
- `MentionParser` — `@esr-dev hello`（session 中有 agent `esr-dev`）→ 路由到 `esr-dev`。
- `MentionParser` — `@ hello`（单独 `@`）→ 路由到 primary（普通文本处理）。
- `MentionParser` — `@unknown hello`（名字不在 session 中）→ 路由到 primary，无报错。
- Primary 路由：无 `@` 文本 → primary agent。

**Phase 5（cap UUID 翻译）：**
- `UuidTranslator` — `session:esr-dev`（名字）→ `session:aaa-111`（UUID，当前 chat 上下文）。
- `UuidTranslator` — 未知 session 名 → `{:error, :not_found}`。

**Phase 6（colon-namespace）：**
- 所有 colon 形式 slash 从 yaml 加载并通过 `Registry.lookup/1` 解析。
- `/help` 和 `/doctor` 仍能解析（bare 形式保留）。
- 旧形式 key（`/new-session`、`/workspace info`）返回 `unknown command`。
- 新增 `/session:new`、`/session:attach`、`/pty:key`、`/plugin:set` 解析正确。

**Phase 7（plugin config）：**
- Manifest 解析接受有效 `config_schema:`（string 和 boolean 类型）。
- Manifest 解析拒绝缺少 `type:` 的 `config_schema:` 条目。
- `Esr.Plugin.Config.resolve/2` — 仅 global：schema default 用于 absent key；global 值覆盖 default。
- `Esr.Plugin.Config.resolve/2` — user 层在某 key 上覆盖 global；其他 key 用 global。
- `Esr.Plugin.Config.resolve/2` — workspace 层覆盖 user 和 global。
- `Esr.Plugin.Config.resolve/2` — workspace 空字符串（`""`）覆盖 global 非空。
- `Esr.Plugin.Config.resolve/2` — workspace 层 absent 不覆盖 global。
- `/plugin:set` 校验 key 是否在 schema 中；未知 key → 报错，文件不变。
- `/plugin:set` 有效 key 写入正确文件。
- `depends_on:` 强制：依赖缺失的 plugin → `{:error, {:missing_dependency, dep}}`。

### E2E 测试（新 scenario）

**Scenario 14：Multi-agent session**

```bash
# 运营者创建 session，添加 2 个 CC agent，发送 @ 寻址消息
esr admin submit session_new name=multi-test ...
esr admin submit session_add_agent session=multi-test type=cc name=alice ...
esr admin submit session_add_agent session=multi-test type=cc name=bob ...
# 发送 "@alice ping"
# 断言：alice 收到消息
# 发送 "@bob hello"
# 断言：bob 收到消息
# 发送普通文本 "hi"
# 断言：primary agent（alice，第一个加入）收到消息
```

**Scenario 15：Cross-user attach**

```bash
# UserA 创建 session，向 userB 授权 attach cap
esr admin submit session_new name=shared-session user=userA ...
esr admin submit session_share session=shared-session user=userB perm=attach ...
# UserB 在不同 chat attach
esr admin submit session_attach session=shared-session chat=oc_yyy user=userB ...
# UserB 发消息
# 断言：消息路由到 shared-session 的 primary agent
# UserC（无 cap）尝试 attach → 应失败
esr admin submit session_attach session=shared-session chat=oc_zzz user=userC ...
# 断言：cap 检查拒绝
```

**Scenario 16：Plugin config layering**

```bash
# 在 global 层设置 http_proxy
/plugin:set claude_code http_proxy=http://global.proxy:8080 layer=global
/plugin:show claude_code layer=effective   # → http_proxy = "http://global.proxy:8080"
# user 层覆盖
/plugin:set claude_code http_proxy=http://user.proxy:8080 layer=user
/plugin:show claude_code layer=effective   # → http_proxy = "http://user.proxy:8080"
# workspace 层清除代理
/plugin:set claude_code http_proxy="" layer=workspace
/plugin:show claude_code layer=effective   # → http_proxy = ""
# 取消 workspace 层 — user 层重现
/plugin:unset claude_code http_proxy layer=workspace
/plugin:show claude_code layer=effective   # → http_proxy = "http://user.proxy:8080"
```

---

## §10 — 开放问题（等待用户 Round-3+）

1. **User UUID 身份化**：当前用户以 username（字符串）为 key，路径为 `users/<username>/`。是否在后续 phase 引入 user UUID + username 索引（参考 PR-230 的 workspace UUID 重设计）？允许 username 改名而不破坏 capability 引用。本 spec 不阻塞于此，作为 future-work 标注。

2. **Session 命名**：human-friendly name + UUID 双轨（参考 PR-230 workspace 模式）？Spec 提案两者兼有；`/session:new name=X` 提供 human name。Session-scoped cap 字符串是否也支持 name-keyed 输入（如 `session:esr-dev/attach`，通过 `UuidTranslator` 解析为 UUID）？

3. **`/session:new` 默认 attach 行为**：创建 session 时，是否自动 attach 到创建该 session 的 chat 并设为 attached-current？Spec 提案为 yes（符合运营者预期）。请确认。

4. **`/session:share` 默认权限**：`/session:share <session> <user>` 默认 `perm=attach`。这是否正确？还是应默认 `perm=admin`？Spec 提案 `perm=attach` 作为更安全的默认值。

5. **`/cap:grant` 接受 session name**：现有 `esr cap grant` escript 命令是否接受 `session:<name>`（通过 `UuidTranslator` 解析为 UUID），还是要求 `session:<uuid>`（仅 UUID）？Spec 提案 name-keyed 输入，参考 workspace 模式。

---

## §11 — 交叉引用

- `docs/notes/concepts.md`（rev 9，2026-05-03）— 四元元模型；本 spec 所有原语定义的规范来源。
- `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`（rev 3）— workspace UUID 先例；本 spec 将 UUID 模式扩展至 session，并新增 3 层 plugin config。
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` — 启动流程审计，揭示本次重设计的运营者痛点；§7 的 10 个 phase 覆盖所有 12 步骤和 cross-cutting 缺口。
- `runtime/priv/slash-routes.default.yaml` — 当前 slash 清单基准；Phase 6 将所有 primary key 改写为 colon 形式。
- `runtime/lib/esr/resource/workspace/registry.ex` — workspace UUID 模型（PR-230）；session registry 遵循相同的 ETS 双表模式。
- `runtime/lib/esr/resource/chat_scope/registry.ex` — 当前 chat-current-slot；Phase 2 迁移为 attached-set。
- `runtime/lib/esr/entity/user/registry.ex` + `file_loader.ex` — 当前用户模型（username-keyed，无 UUID）；user-default workspace 创建扩展 `Esr.Commands.User.Add`。
- `runtime/lib/esr/plugin/manifest.ex` + `runtime/lib/esr/plugins/*/manifest.yaml` — plugin manifest；Phase 7 新增 `config_schema:` 字段并 enforce `depends_on:`。
- `scripts/esr-cc.sh` + `scripts/esr-cc.local.sh` — Phase 8 删除；env-export 职责迁移至 plugin config 和 Elixir 原生 PTY launcher。
- （参考）`spec/colon-namespace-grammar` 分支 — 内容已吸收入 §4。
- （参考）`spec/plugin-set-config` 分支 — 内容已吸收入 §6（含用户修正：删除 `sensitive:` flag，将 `project` 层重命名为 `workspace`，feishu manifest 新增 `app_id` + `app_secret`）。
