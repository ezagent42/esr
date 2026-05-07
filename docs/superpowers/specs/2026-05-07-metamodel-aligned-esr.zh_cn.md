# Spec：元模型对齐的 ESR — Session-First、Multi-Agent、Colon-Namespace、Plugin-Config-3-Layer

**日期：** 2026-05-07
**状态：** rev-2（DRAFT — 等待用户 review）
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
- **Q4=multi-scope per chat with attach**：1 个 chat = N 个并发 scope（session）；`/session:attach <uuid>` 加入；跨用户 attach 需 capability 门控。
- **Q5=一气呵成**：所有变更一次连贯迁移。

### 第二轮（Q6-Q10，2026-05-06）

- **Q6=D**：运营者通过 `/session:set-primary <name>` 设置 primary agent；默认 = 第一个加入 session 的 agent。
- **Q7=B**：纯文本 `@<name>` 用简单字符串匹配。单独一个 `@` 后不跟字母数字字符视为普通文本。**Agent 名在同一 session 内全局唯一，与类型无关。**
- **Q8=A**：每个 chat 维护一个"当前 attached session"指针；没有显式 `@` 的纯文本路由到 attached session 的 primary agent。
- **Q9=C**：既支持命令式（`/session:share`）也支持声明式（capability yaml）；命令式是声明式的语法糖。
- **Q10=C**：Session 是一等公民；`$ESRD_HOME/<inst>/sessions/<session_uuid>/` 本身即是一个 workspace（该 session 的自动临时 workspace）。

### 第三轮（Q11 + 修正 + Round-3 用户决策，2026-05-07）

- **Q11=B**：Plugin config 三层：**global → user-default-workspace → current-workspace**（优先级：workspace > user > global，per-key merge）。
- **用户关键洞察**：每个用户有个人 workspace。目录路径使用 **user UUID**（见 D1）。
- **删除 `/session:add-folder`**：folder 由 workspace 管理。
- **`/key` → `/pty:key`**：PTY 是 resource group，不是 session。
- **删除 `/workspace:sessions`**：workspace 不能依赖 session。
- **删除 `@deprecated_slashes` map**：硬切换；无 fallback。
- **feishu manifest 必须在 `config_schema:` 中包含 `app_id` + `app_secret`**。
- **`depends_on:` 字段在 `Loader.start_plugin/2` 时强制校验**。
- **Per-key merge** config 层：global → user → workspace。
- **删除 `sensitive:` 标志**。
- **launchd plist 只放 esrd 自身 env var**（`ESRD_HOME`、`ESRD_INSTANCE`、`ANTHROPIC_API_KEY`）。

### Round-3 用户决策（D1-D8，2026-05-07）— 已锁定

**D1 — User UUID 身份：纳入本次重设计。**
今天用户以 `username`（字符串）为 key。本次引入 user UUID 身份，与 PR-230 workspace UUID 模型并行：
- 每个用户在 `user.json.id` 中获得 UUID v4。
- `username` 变为可变 display alias（允许改名；UUID 稳定不变）。
- 新增 `Esr.Entity.User.NameIndex`：username ↔ UUID 双向查找。
- 用户目录路径：**`$ESRD_HOME/<inst>/users/<user_uuid>/`**（不是 `<username>/`）。
- 目录包含：`user.json`（身份 + alias + metadata）+ `.esr/workspace.json`（user-default workspace）+ `.esr/plugins.yaml`（user 层 plugin config）。
- 启动时解析 `users.yaml`；无 UUID 的条目分配 UUID；原子写回。

**D2 — Session 命名：human-friendly name + UUID 双轨；caps input 只接受 UUID。**
Session 同时有 `id`（UUID，不可变）和 `name`（可变 display alias）。关键合约：
- Workspace caps input：接受 name（转 UUID）和 UUID 两者（PR-230 模式）。
- **Session caps input：只接受 UUID。**name 输入在任何 surface 一律拒绝：CLI、slash dispatcher、yaml 校验。原因：session name 的唯一性范围是 `(owner_user, name)` per D6 — 非全局唯一，UUID-only input 消除歧义。
- 输出端（如 `/cap:show` 渲染）仍进行 UUID → name 翻译（人类可读，output-only）。

**D3 — `/session:new` 自动 attach 到创建该 session 的 chat：确认 YES（锁定行为）。**
创建 session 时自动 attach 到创建 chat 并设为 attached-current。这是锁定行为，不再是提案。

**D4 — `/session:share` 默认权限：`perm=attach`（锁定）。**
`/session:share <session_uuid> <user>` 默认 `perm=attach`。更安全的默认值：attach 允许使用但不允许管理。

**D5 — `esr cap grant` escript：拒绝 `session:<name>/...` — input UUID-only（锁定）。**
`esr cap grant` CLI escript 和 `/cap:grant` slash 命令均拒绝 `session:<name>/...` 形式的 cap 字符串。只接受 `session:<uuid>/...`。

**D6 — Session name 唯一性范围：`(owner_user, name)` tuple（锁定）。**
Session name 在 `(owner_user, name)` 命名空间内唯一，非全局唯一。两个不同用户可各自拥有名为 `esr-dev` 的 session。Registry name-index ETS table 使用复合 key：`{owner_user_uuid, name}`。

**D7 — User 层 config 路径：`users/<user_uuid>/.esr/plugins.yaml`（锁定）。**
重要后果：
1. 不从任何先前草案 `users/<username>/plugins.config.yaml` 路径迁移 — 该路径为假设性，从未实际发布。
2. **post-deploy `.esrd/` + `.esrd-dev/` 需手动清除**：本次重设计发布后，运营者必须清空现有 `$ESRD_HOME/<inst>/` 目录，新 Bootstrap 从零重建。见 §11。

**D8 — Plugin manifest `depends_on.core` 版本检查：纳入本次（Phase 7）。**
`Esr.Plugin.Manifest` 将 `depends_on.core` 解析为 SemVer 约束字符串（如 `">= 0.1.0"`）。Plugin load 时与 ESR 自身版本（读自 `runtime/mix.exs`）比对。约束不满足则拒绝加载，返回结构化错误。新增小模块 `Esr.Plugin.Version`（封装 Elixir stdlib `Version`）。约 ~80 LOC。Phase 7 LOC 估算更新。

### Post-Round-3 锁定汇总（供参考）

- User UUID 身份纳入本次（Round-3 决策，2026-05-07）。
- Session 维度的 cap：input UUID-only；name 仅在 output 端翻译。
- Post-deploy ESRD_HOME 需手动清除（无 in-place 迁移）。
- `depends_on.core` SemVer 检查纳入 Phase 7。
- `/session:new` 自动 attach 确认（D3）。
- `/session:share` 默认 `perm=attach` 确认（D4）。
- `esr cap grant` 拒绝 `session:<name>`（D5）。
- Session name 唯一性范围 `(owner_user, name)`（D6）。

---

## §1 — 动机

### 元模型与实现之间的偏差

`docs/notes/concepts.md`（rev 9，2026-05-03）定义了 ESR 的四元元模型：所有运行时活动由四个原语描述 — **Scope**、**Entity**、**Resource**、**Interface** — 加上声明式的 **Session**（描述如何实例化 Scope）。元模型的典型例子（§九）展示了一个群聊 Scope，其中包含多个人类 entity、多个 agent entity（`agent-cc-α`、`agent-codex-β`）和共享 resource，都通过 `MemberInterface` 协作。

实现在四个关键点上偏离了：

**偏差 1：Workspace-first，而非 session-first。**
今天必须先注册 workspace 才能创建 session。运营者的心智模型正好相反：先 `/session:new`，再 `/workspace:add`，再 `/agent:add`。PR #230 修复了 workspace 存储。本 spec 修复 session 主导权。

**偏差 2：1 个 session 1 个 agent，而非 N 个。**
今天 `ChatScope.Registry` 将 `(chat_id, app_id)` 映射到唯一 `session_id`，每个 session 最多一个 CC 进程。元模型明确描述 `agent-cc-α` 和 `agent-codex-β` 是同一群聊 Scope 内的对等 Entity。

**偏差 3：slash 语法不一致。**
ESR 的 slash 语法今天混用 dash（`/new-session`、`/list-agents`）、space（`/workspace info`、`/plugin install`）和无分隔符形式。统一的 `<group>:<verb>` 形式能降低运营者心智负担。

**偏差 4：没有运营者可设置的 plugin config。**
Per-plugin 调优需要编辑 `scripts/esr-cc.local.sh`，一个只适用于单台机器、单个运营者的 shell 脚本，没有多用户、多 workspace 的解决方案。

### PR #230 修复了什么（本 spec 的先例）

PR #230（workspace UUID 重设计）引入了：
- UUID 标识的 workspace，带 name → UUID 索引（`Esr.Resource.Workspace.NameIndex`）
- 混合存储：ESR-bound + repo-bound
- 14 个 `/workspace:*` slash 命令
- `Esr.Resource.Capability.UuidTranslator`：workspace 支持 name 和 UUID 两种输入
- 双 ETS 表模式：legacy name-keyed + new UUID-keyed

本 spec 将 UUID 模式扩展至 session 和 user，新增 3 层 plugin config，并对齐完整的 slash surface。

### 目标

1. **Session-first**：session 创建自动生成 workspace（自动临时于 `sessions/<uuid>/`）。
2. **Multi-agent**：每个 session N 个 agent，全局唯一 `@<name>` 寻址，primary-agent 路由。
3. **User UUID 身份**：用户获得 UUID 稳定身份；username 是可变 alias（D1）。
4. **统一 slash 语法**：一种规范的 `/<group>:<verb>` 形式；硬切换。
5. **运营者 plugin config**：3 层 YAML-backed config，manifest `config_schema:` 声明允许的 key。
6. **一次连贯迁移**：所有变更作为一次有序的 PR 序列发布。

### 非目标（延后）

- **Plugin config 热重载** — Phase 1 需重启；热重载是 Phase 2。
- **远程 plugin 安装** — `/plugin:install` 继续仅支持本地路径。
- **声明式 SessionSpec YAML** — spec 定义 `session.json` 运行时状态文件；完整声明式 YAML 是未来阶段。
- **Session branching / worktree fork** — 现有 worktree-fork 逻辑不变。

---

## §2 — 新模型

### 元模型原语到具体实现的映射

| 元模型原语 | 具体实现 | 状态 |
|---|---|---|
| **Scope** | Chat attached 的 session 实例，UUID 标识；`Esr.Resource.Session.*` | 新（Phase 1） |
| **Entity（人类）** | `Esr.Entity.User`（UUID-keyed，`user.json` + `users.yaml` NameIndex） | Phase 1b 扩展 |
| **Entity（agent）** | Session 内的 agent 实例：`{type, name}` 对；`Esr.Entity.Agent.Instance` | 新（Phase 3） |
| **Resource（workspace）** | `Esr.Resource.Workspace.*`（PR-230）+ session 自动临时 workspace | 现有；自动临时模式为新 |
| **Resource（channel）** | Feishu chat（`chat_id` + `app_id` 对）；`Esr.Entity.FeishuChatProxy` | 现有 |
| **Resource（capability）** | `Esr.Resource.Capability.*`；符号 + grant binding | 现有；Phase 5 新增 scope |
| **Interface** | Role traits：`MemberInterface`、`ChannelInterface` 等 | 定义在 `docs/notes/actor-role-vocabulary.md` |
| **Session（声明式）** | `session.json` schema（新）；完整声明式 YAML 延后 | 新（Phase 1） |

### 变化对比

**之前**（现状）：

```
1 个 chat
└── 1 个 workspace（先注册）
    └── 1 个 session（后创建）
        └── 1 个 CC agent（唯一）
```

**之后**（本 spec）：

```
1 个 chat
└── attached-set: [session_A（当前）, session_B, ...]
    session_A
    ├── workspace: sessions/<uuid>/ (自动临时) 或 workspaces/<name>/ (命名)
    ├── agents: [{cc, "esr-dev"}（primary）, {codex, "reviewer"}, ...]
    └── attached_chats: [{chat_id, app_id, attached_by, attached_at}, ...]
```

消息路由：
```
chat_id + app_id
→ ChatScope.Registry（attached-set 查找）
→ current session_id
→ MentionParser（扫描 @<name>）
→ 有 mention：路由到指定 agent
→ 无 mention：路由到 primary agent
→ agent PID
```

### 示意图：一个 chat 有 2 个 session

```
chat: oc_xxx（Feishu DM，app_id=cli_yyy）
│
├── attached sessions（attached-set）：
│   ├── session "esr-dev"（uuid=aaa-111）   <- 当前 attached
│   │   ├── workspace: sessions/aaa-111/   （自动临时）
│   │   ├── agents：
│   │   │   ├── {cc, "esr-dev"}            <- primary agent
│   │   │   └── {codex, "reviewer"}
│   │   ├── owner_user: <linyilun 的 user_uuid>
│   │   └── transient: true
│   └── session "docs"（uuid=bbb-222）      （已 attach，非当前）
│       ├── workspace: workspaces/docs-ws/  （命名，共享）
│       ├── agents：
│       │   └── {cc, "docs-writer"}        <- primary agent
│       └── transient: false
└── attached-current 指针 → "aaa-111"

路由示例：
  普通文本 "fix the test"         → session aaa-111 → agent "esr-dev"（primary）
  "@reviewer look at this"        → session aaa-111 → agent "reviewer"
  "/session:attach bbb-222"       → 切换 attached-current 到 bbb-222（UUID only）
  （切换后）普通文本 "edit"         → session bbb-222 → agent "docs-writer"（primary）
```

### 用户默认 workspace

Per D1（锁定，2026-05-07）：每个用户在 `$ESRD_HOME/<inst>/users/<user_uuid>/` 有个人 workspace：

- `esr user add <name>` 时自动创建。
- `.esr/workspace.json` 中 `kind: "user-default"`（不出现在 `/workspace:list`，可通过 `/workspace:info name=<username>` 查看）。
- 持有 user 层 plugin config 于 `.esr/plugins.yaml`。
- 目录同时包含 `user.json`（UUID + username alias + metadata）。

各层对应路径：

```
global 层    → $ESRD_HOME/<inst>/plugins.yaml
user 层      → $ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml
workspace 层 → <current_workspace_root>/.esr/plugins.yaml
```

---

## §3 — 存储布局

### 完整目录树（迁移后）

```
$ESRD_HOME/<inst>/
├── plugins.yaml                              # global：enabled list + global plugin config
├── workspaces/                               # ESR-bound 命名 workspace（PR-230）
│   └── <name>/
│       ├── workspace.json                    # workspace 身份、folders、chats
│       └── .esr/
│           └── plugins.yaml                  # workspace 层 plugin config（新）
├── users/                                    # user-default workspace（新，D1）
│   └── <user_uuid>/                          # 以 UUID 为 key，不是 username（D1）
│       ├── user.json                         # 用户身份：id、username alias、metadata
│       └── .esr/
│           ├── workspace.json                # 此目录本身即 workspace，kind="user-default"
│           └── plugins.yaml                  # user 层 plugin config（新）
└── sessions/                                 # session-default workspace（新，per Q10=C）
    └── <session_uuid>/
        ├── workspace.json                    # 自动临时 workspace
        ├── session.json                      # session 状态：agents、attached chats、primary
        └── .esr/
            └── plugins.yaml                  # 少用；session 级 config 覆盖
```

启动时，`users.yaml`（现有文件）是 username → UUID 索引的数据来源。`Esr.Entity.User.NameIndex` GenServer 从中构建 ETS 表。

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
| `Esr.Paths.users_dir/0` | `$ESRD_HOME/<inst>/users/` |
| `Esr.Paths.user_dir/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/` |
| `Esr.Paths.user_json/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/user.json` |
| `Esr.Paths.user_workspace_json/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/workspace.json` |
| `Esr.Paths.user_plugins_yaml/1` | `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml` |
| `Esr.Paths.workspace_plugins_yaml/1` | `<workspace_root>/.esr/plugins.yaml` |

所有用户相关 helper 接受 `user_uuid`（UUID 字符串），不是 `username`。

### `user.json` schema（version 1，D1 新增）

```json
{
  "schema_version": 1,
  "id": "<user_uuid>",
  "username": "linyilun",
  "display_name": "林懿伦",
  "created_at": "2026-05-07T12:00:00Z"
}
```

字段说明：
- `id`：UUID v4，用户创建时生成，username 改名后不变。
- `username`：可变 display alias。在同一 instance 内全局唯一。`Esr.Entity.User.NameIndex` 负责唯一性保证。
- `display_name`：可选，允许为空字符串。

### `session.json` schema（version 1）

```json
{
  "schema_version": 1,
  "id": "<session_uuid>",
  "name": "<human-friendly name>",
  "owner_user": "<user_uuid>",
  "workspace_id": "<workspace_uuid>",
  "agents": [
    { "type": "cc",    "name": "esr-dev",  "config": {} },
    { "type": "codex", "name": "reviewer", "config": {} }
  ],
  "primary_agent": "esr-dev",
  "attached_chats": [
    {
      "chat_id": "oc_xxx",
      "app_id": "cli_xxx",
      "attached_by": "<user_uuid>",
      "attached_at": "2026-05-07T12:00:00Z"
    }
  ],
  "created_at": "2026-05-07T12:00:00Z",
  "transient": true
}
```

Schema 说明：
- `id`：UUID v4，session 创建时生成，终身稳定。
- `name`：运营者提供（或自动生成为 `session-<timestamp>`）。在 `(owner_user, name)` 范围内唯一（D6），非全局唯一。
- `owner_user`：创建该 session 的用户的 **user UUID**。
- `workspace_id`：session 绑定 workspace 的 UUID。
- `agents`：有序 agent 实例列表。
- `agents[].type`：plugin 名（如 `cc`、`codex`）。
- `agents[].name`：运营者分配，session 内全局唯一（与类型无关）。
- `primary_agent`：接收未 @ 纯文本的 agent 名（Q8=A）。
- `attached_chats`：`attached_by` 为执行 `/session:attach` 的**用户 UUID**。
- `transient`：`true` = session 结束且 workspace 干净时自动清理。

### Session name 唯一性范围：`(owner_user, name)` tuple（D6）

Registry name-index ETS table 使用复合 key：`{owner_user_uuid, session_name}`。两个不同用户可各自拥有名为 `esr-dev` 的 session。`UuidTranslator` 在 output 端翻译时需限定 session owner 范围。

Session cap 字符串在 input 端始终使用 UUID（D2、D5）。输出渲染可展示 `<name>` 以提升可读性。

### 启动迁移：`users.yaml` → UUID 分配（D1）

启动时，`Esr.Entity.User.NameIndex` 读取 `users.yaml`。对每个用户条目：
- 已有 `user_uuid` 字段：加载并建立索引。
- 无 `user_uuid` 字段：生成 UUID v4，原子写回 `users.yaml`，创建 `users/<user_uuid>/user.json` 和 `users/<user_uuid>/.esr/workspace.json`（若不存在）。

此迁移非破坏性且幂等。任何先前草案布局的 `users/<username>/` 目录（从未实际发布）均忽略。

### 启动迁移：`ChatScope.Registry` 数据格式

当前格式（单槽）：
```elixir
{{chat_id, app_id}, session_id}
```

迁移为 attached-set 格式：
```elixir
{{chat_id, app_id}, %{current: session_id, attached_set: [session_id]}}
```

迁移位置：`Esr.Resource.ChatScope.FileLoader.load/1`。非破坏性：旧 `session_id` 成为 `current` 并作为 `attached_set` 的唯一元素。

---

## §4 — Slash 命令面（Colon-Namespace，硬切换）

### 语法规则（锁定，2026-05-06，含 2026-05-07 修正）

**规则 1 — 完整切换，无 alias，无 fallback。**
所有 slash 命令使用 colon 形式。旧形式输入返回 `unknown command: /old-form`。不设 `@deprecated_slashes` map。

**规则 2 — 多词动词保留 dash。**
`/workspace:add-folder`、`/workspace:bind-chat`、`/workspace:import-repo`。

**规则 3 — 无过渡期。**
一次发布，硬切换。

**规则 4 — `/help` 和 `/doctor` 保持 bare 形式。**
元系统发现命令，不加冒号。

**规则 5 — `/key` → `/pty:key`。**
Key 向 PTY 发键盘输入；PTY 是 resource group，不是 session。

**规则 6 — 删除 `/workspace:sessions`。**
Workspace 不能依赖 session。

**规则 7 — Session slash 命令的 input 只接受 UUID（D2、D5）。**
`/session:attach`、`/session:end`、`/session:add-agent`、`/session:share` 以及所有 session-scoped `/cap:grant` 调用：只接受 UUID 标识 session。name 输入被拒绝。与 workspace 命令不同（workspace 同时接受 name 和 UUID）。

### 完整 slash 清单

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

#### 新增 `/session:*` 系列（Phase 6 全部为新）

注意：所有 session 识别参数只接受 **UUID**（D2、D5），name 输入返回结构化错误。

| Slash | Permission | 说明 |
|---|---|---|
| `/session:new [name=X] [worktree=Y] [workspace=W]` | `session:default/create` | 创建 session + 自动临时 workspace。**自动 attach 到创建该 session 的 chat**（D3，锁定行为），设为 attached-current，primary = 第一个加入的 agent。 |
| `/session:attach <uuid>`（name 被拒绝） | `session:<uuid>/attach` | 在当前 chat 通过 UUID 加入已有 session；设置 attached-current 指针。跨用户 attach 需 cap 门控。 |
| `/session:detach` | none | 当前 chat 离开 attached session；不结束 session。 |
| `/session:end [session=<uuid>]` | `session:<uuid>/end` | 终止 session。若 transient workspace 干净则自动清理。 |
| `/session:list` | `session.list` | 列出当前 chat 的 session：名称、UUID、agent 数量、当前 attached 状态、workspace 名。 |
| `/session:add-agent <type> name=X [config_key=val ...]` | `session:<uuid>/add-agent` | 向当前 session 添加 agent 实例。名字在 session 内必须全局唯一。 |
| `/session:remove-agent <name>` | `session:<uuid>/add-agent` | 从 session 移除 agent 实例。不能移除 primary agent（除非先 set-primary 到其他 agent）。 |
| `/session:set-primary <name>` | `session:<uuid>/add-agent` | 设置 primary agent（接收未 @ 的纯文本）。 |
| `/session:bind-workspace <name>` | `session:<uuid>/end` | 将 session 从自动临时 workspace 切换到命名 workspace。 |
| `/session:share <session_uuid> <user> [perm=attach\|admin]` | `session:<uuid>/share` | 向用户授权 `session:<uuid>/attach`（或 admin）capability。默认 `perm=attach`（D4，锁定）。Session 以 UUID 标识（D2、D5）。是 `/cap:grant` 的语法糖。 |
| `/session:info [session=<uuid>]` | `session.list` | 显示 session 详情：id、name、owner username（翻译后）、workspace 绑定、agents、primary、attached chats、创建时间、transient 标志。 |

#### 新增 `/pty:*` 系列（替代 bare `/key`）

| Slash | Permission | 说明 |
|---|---|---|
| `/pty:key keys=<spec>` | none | 向当前 chat 的 session PTY 发送特殊键盘输入（up/down/enter/esc/tab/c-X 等）。 |

#### 新增 `/plugin:*` config 管理命令（Phase 7 全部为新）

| Slash | Permission | 说明 |
|---|---|---|
| `/plugin:set <plugin> key=value [layer=global\|user\|workspace]` | `plugin/manage` | 设置 config key；校验 manifest `config_schema:`；原子写入；打印重启提示。默认 layer=global。 |
| `/plugin:unset <plugin> key [layer=global\|user\|workspace]` | `plugin/manage` | 从指定层删除 config key；幂等。 |
| `/plugin:show <plugin> [layer=effective\|global\|user\|workspace]` | `plugin/manage` | 显示 plugin config。`layer=effective` = merge 结果。 |
| `/plugin:list-config` | `plugin/manage` | 显示所有已启用 plugin 的有效 config。 |

#### 新增 `/cap:*` 系列（capability 管理，slash 形式）

| Slash | Permission | 说明 |
|---|---|---|
| `/cap:grant <cap> <user>` | `cap.manage` | 向用户授权 capability。对于 session cap，`<cap>` 必须使用 UUID（如 `session:<uuid>/attach`），name 形式 `session:<name>/...` 被拒绝（D5）。 |
| `/cap:revoke <cap> <user>` | `cap.manage` | 撤销用户的 capability。session cap 同样只接受 UUID。 |

### Mention 解析器

纯文本中的 `@<name>` 路由（Q7=B，锁定）：

- 扫描 `@([a-zA-Z0-9_-]+)` 模式。
- 若匹配且 `<name>` 是 attached session 的 agent 名 → 路由到该 agent。
- 若无匹配，或 session 中无该名 agent → 路由到 primary agent（Q8=A）。
- 单独一个 `@` 后不跟字母数字字符 → 视为纯文本。
- Agent 名匹配大小写敏感。

---

## §5 — Capabilities

### 新增 capability scope

在 PR-230 的 `workspace:<uuid>/<verb>` 模式基础上，引入以下新 cap scope：

| Cap 字符串 | 含义 | Input 合约 |
|---|---|---|
| `session:<uuid>/attach` | 加入已有 session（跨用户） | **只接受 UUID**（D2、D5） |
| `session:<uuid>/add-agent` | 在 session 中 add/remove/set-primary agent | 只接受 UUID |
| `session:<uuid>/end` | 终止该 session | 只接受 UUID |
| `session:<uuid>/share` | 向其他用户授权该 session 的 attach 权限 | 只接受 UUID |
| `plugin:<name>/configure` | 设置指定 plugin 的 config key | n/a |

**Session cap vs. workspace cap — input 合约对比：**

| Resource 类型 | 接受 name input？ | 接受 UUID input？ | 输出展示 |
|---|---|---|---|
| Workspace cap（`workspace:<x>/...`） | YES — CLI edge 翻译（PR-230） | YES | UUID → name 翻译（可读） |
| Session cap（`session:<x>/...`） | **NO — 拒绝**（D2、D5） | YES | UUID → name 翻译（可读） |

`esr cap grant` escript 和 `/cap:grant` slash 命令均强制执行：若 cap 字符串形如 `session:<value>/...` 且 `<value>` 不符合 UUID v4 格式，返回 `error: session caps require UUID; name input is not accepted (got "<value>")`。

Session 创建者在 session 创建时自动持有所有 `session:<uuid>/*` cap（在 `Esr.Commands.Session.New.execute/1` 中 seed）。

### Session 的 UUID 翻译（仅 output 端）

`Esr.Resource.Capability.UuidTranslator` 扩展 `session_uuid_to_name/2` 函数，**仅用于 output 端**翻译（如 `/cap:show`、`/session:list` 渲染中 UUID → name 的人类可读显示）。

Input 端翻译（`session_name_to_uuid`）**刻意不实现**（D2）。若运营者在需要 UUID 的地方传入 name，command module 在调用任何翻译函数之前先返回结构化错误。

### Session 共享安全模型（Q9=C，Risk 3）

跨用户 attach 需 capability 门控：

1. UserA 的 session workspace root 包含 UserA 的代码和状态。
2. 若 UserB 可以无授权 attach，则 UserB 可以向 UserA 的 CC agent 发送任意命令。
3. 防御：`Esr.Commands.Session.Attach.execute/1` 处 cap 检查。UUID-only 输入（D2）还意味着攻击者即使知道 session name，也无法构造有效的 cap 字符串。
4. `/session:share <session_uuid> <user> perm=attach`（D4 默认）是非 admin 用户授权 attach cap 的唯一方式。
5. `session.json` 中 `attached_chats` 记录审计追踪。

---

## §6 — Plugin Config（3 层）

### 层定义（Q11=B + D7，锁定 2026-05-07）

**层 1 — Global**（最低优先级）：

```
$ESRD_HOME/<inst>/plugins.yaml
```

现有文件，新增可选 `config:` 顶层 key。

```yaml
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

**层 2 — User**（中间优先级）：

```
$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml
```

新文件，以 user UUID 为 key（D7），不是 username。只有 `config:` key（无 `enabled:`）。

```yaml
config:
  claude_code:
    anthropic_api_key_ref: "${MY_ANTHROPIC_KEY}"
    http_proxy: "http://user-proxy:8080"
```

**层 3 — Workspace**（最高优先级）：

```
<workspace_root>/.esr/plugins.yaml
```

新文件。`<workspace_root>` 是 session 当前绑定 workspace 的根目录。

```yaml
config:
  claude_code:
    http_proxy: ""    # 覆盖为直连（清除 global proxy）
```

### 解析算法

```
effective_config(plugin, session_context) =
  per-key merge：
    1. 从 schema defaults 开始
    2. 应用 global 层
    3. 应用 user 层     （key 存在则覆盖 global）
    4. 应用 workspace 层（key 存在则覆盖 user）

  "存在" = 该层 config map 中包含该 key（即使值为空字符串""）
  "absent" = 该层 config map 中根本没有该 key
```

算法接受 `user_uuid`（不是 username），per D1/D7。

### Manifest `config_schema:` field（Phase 7 新增）

**claude_code manifest 新增：**

```yaml
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
    description: "Anthropic API key 的 env var 引用，如 \"${ANTHROPIC_API_KEY}\"。Plugin 在 session 启动时通过 System.get_env/1 解析实际值。"
    default: "${ANTHROPIC_API_KEY}"
  esrd_url:
    type: string
    description: "esrd 的 WebSocket URL。"
    default: "ws://127.0.0.1:4001"
```

**feishu manifest 新增：**

```yaml
config_schema:
  app_id:
    type: string
    description: "Feishu app ID（cli_xxx）。API 调用必需。"
    default: ""
  app_secret:
    type: string
    description: "Feishu app secret。API 调用必需。请勿 commit 到 repo。"
    default: ""
  log_level:
    type: string
    description: "日志级别（debug|info|warning|error）。"
    default: "info"
```

`config_schema:` 设计说明：

- **无 `sensitive:` 标志**（用户修正，2026-05-07）。
- `type:`、`description:`、`default:` 均必填；缺失则 `Manifest.parse/1` 返回结构化错误。
- Phase 1 支持 `string` 和 `boolean`；integer 和 list 延后到 Phase 2。
- 运营者提供的 key 若不在 `config_schema:` 中，写入时报错并列出所有有效 key。

### `depends_on:` 强制执行（2026-05-07 修正）

在 `Loader.start_plugin/2` 中，`Manifest.validate/1` 之前先调用 `check_dependencies/2`。依赖缺失则返回 `{:error, {:missing_dependency, dep_name}}`，plugin 不启动。Let-it-crash。

### `depends_on.core` SemVer 检查（D8，Phase 7 新增）

新增 `Esr.Plugin.Version` 模块（封装 Elixir stdlib `Version`）：

```elixir
defmodule Esr.Plugin.Version do
  @spec satisfies?(constraint :: String.t(), version :: String.t()) :: boolean()
  def satisfies?(constraint, version), do: Version.match?(version, constraint)

  @spec esrd_version() :: String.t()
  def esrd_version(), do: Application.spec(:esr, :vsn) |> to_string()
end
```

在 `Loader.start_plugin/2` 中，`check_dependencies/2` 之后调用 `check_core_version/1`：

```elixir
defp check_core_version(manifest) do
  constraint = manifest.depends_on[:core]
  if constraint do
    esrd_vsn = Esr.Plugin.Version.esrd_version()
    if Esr.Plugin.Version.satisfies?(constraint, esrd_vsn),
      do: :ok,
      else: {:error, {:core_version_mismatch, constraint, esrd_vsn}}
  else
    :ok
  end
end
```

约 ~80 LOC（`Esr.Plugin.Version` + tests）。Phase 7 LOC 估算更新为 ~700（原 ~600）。

### Shell 脚本删除

`scripts/esr-cc.sh` 和 `scripts/esr-cc.local.sh` 在 Phase 8 删除。env-export 职责迁移：

| `esr-cc.sh`/`esr-cc.local.sh` 职责 | 迁移目标 |
|---|---|
| `http_proxy`、`https_proxy`、`no_proxy` | `claude_code` plugin config |
| `ANTHROPIC_API_KEY` / `.mcp.env` source | 保留在 launchd plist；plugin config 用 `anthropic_api_key_ref` 引用 |
| `ESR_ESRD_URL` | `claude_code.config.esrd_url` |
| `exec claude` + `CLAUDE_FLAGS` 构建 | `Esr.Plugins.ClaudeCode.Launcher`（Elixir 原生） |
| `session-ids.yaml` resume 查找 | PTY spawn 前在 Elixir 处理 |
| `.mcp.json` 写入 | `Launcher.write_mcp_json/1` before spawn |
| workspace trust 预写入 `~/.claude.json` | Elixir `File.write/2` before spawn |
| `ESRD_HOME`、`ESRD_INSTANCE` | 仅在 launchd plist |
| `ESR_WORKSPACE`、`ESR_SESSION_ID` | PtyProcess spawn args |

### 重载语义

Phase 1：需重启。`/plugin:set` 后打印：`config written: <plugin>.<key> = "..." [<layer> layer]\nesrd 需重启生效（esr daemon restart）`。

---

## §7 — 迁移计划（11 个 phase，硬切换）

每个 phase 对应一个 PR。D1 引入新 Phase 1b（user UUID 迁移），插入原 Phase 1 和 Phase 2 之间。

| Phase | PR 标题 | 主要文件 | LOC 估算 | 依赖 |
|---|---|---|---|---|
| 0 | `spec: metamodel-aligned ESR`（本 spec） | `docs/superpowers/specs/` | — | — |
| 1 | `feat: session UUID identity + storage layout` | `runtime/lib/esr/resource/session/*`（新），`Esr.Paths` helpers，JSON schema | ~800 | Phase 0 |
| 1b | `feat: user UUID identity + NameIndex + user.json migration` | `runtime/lib/esr/entity/user/*`，`Esr.Paths` user helpers，`users.yaml` boot migration | ~600 | Phase 1 |
| 2 | `feat: chat→[sessions] attach/detach state` | `runtime/lib/esr/resource/chat_scope/registry.ex`、`chat_scope/file_loader.ex` | ~600 | Phase 1b |
| 3 | `feat: multi-agent per session` | `runtime/lib/esr/entity/agent/instance.ex`（新），`agent/registry.ex` 扩展 | ~700 | Phase 1 |
| 4 | `feat: mention parser + primary-agent routing` | `runtime/lib/esr/entity/mention_parser.ex`（新），`entity/slash_handler.ex` | ~400 | Phase 3 |
| 5 | `feat: session cap UUID translation + UUID-only enforcement` | `runtime/lib/esr/resource/capability/uuid_translator.ex`，cap seeding in `Session.New` | ~350 | Phase 1 |
| 6 | `feat: colon-namespace slash cutover + new session/pty/cap slashes` | `runtime/priv/slash-routes.default.yaml`、`slash_handler.ex`、所有 command 模块 | ~1200 | Phase 1b + Phase 3 |
| 7 | `feat: plugin-config 3-layer + manifest config_schema + depends_on + core SemVer` | `runtime/lib/esr/plugin/*`、`runtime/lib/esr/plugins/*/manifest.yaml`、`Esr.Plugin.Version`（新） | ~700 | Phase 6 |
| 8 | `chore: delete esr-cc.sh + esr-cc.local.sh + elixir-native PTY launcher` | `git rm scripts/esr-cc.sh scripts/esr-cc.local.sh`，`runtime/lib/esr/entity/pty_process.ex`，`Launcher`（新） | ~300 已删 + ~400 新增 | Phase 7 |
| 9 | `docs+test: e2e scenarios 14-16 + docs sweep` | `docs/`、`tests/e2e/scenarios/` | ~400 | Phase 8 |

**依赖 DAG（严格无环）：**

```
0 → 1 → 1b → 2
               ↗
          3 → 4
          ↗
     1  → 5
     1b + 3 → 6 → 7 → 8 → 9
```

无环。所有边单向，无依赖循环。

**总估算：** ~6350 LOC，11 个 PR，约 1.5-2 周。

---

## §8 — 风险登记

| # | 风险 | 可能性 | 缓解措施 |
|---|---|---|---|
| R1 | `ChatScope.Registry` 数据格式变更破坏运行中实例 | 中 | Phase 2 `file_loader.ex` 启动迁移。回归测试：旧格式 fixture 启动 → 断言新格式。 |
| R2 | `/session:add-agent` 时 agent 名冲突 | 低 | 插入前强制名字唯一性检查；结构化错误 + 可用名列表（`/session:info`）。 |
| R3 | 跨用户 attach 安全绕过 | 低 | UUID v4 有 2^122 比特熵。UUID-only input（D2）意味着攻击者知道 session name 也无法构造有效 cap 字符串。 |
| R4 | Plugin config schema 严格性 — 运营者 typo 被拒绝 | 低 | 结构化错误提示 + 有效 key 列表。 |
| R5 | 硬切换 slash 名 — 现有 docs、tests、scripts 失效 | 中 | Phase 9 docs sweep。Phase 6 合并前发 Feishu 公告。 |
| R6 | 删除 shell 脚本 — 生产运营者丢失 env var | 中 | Phase 8 `make e2e` 门控：所有 scenario 01-13 需通过。Phase 8 合并前发 Feishu 公告。 |
| R7 | `esr user add` 时 user-default workspace 自动创建失败 | 低 | `Esr.Commands.User.Add` 用 `File.mkdir_p!/1` 创建 `users/<user_uuid>/` 后再写入文件。 |
| R8 | `depends_on:` 或 `depends_on.core` 强制执行破坏现有 plugin | 低 | `feishu` 和 `claude_code` 均声明 `depends_on: {core: ">= 0.1.0", plugins: []}`。仅在声明了但未满足的约束时触发。 |
| R9 | User UUID boot migration 破坏 `users.yaml` | 低 | 原子写（temp-rename）。幂等：若 `users/<uuid>/user.json` 已存在则跳过。 |
| R10 | Session cap UUID-only 拒绝令运营者困惑（习惯了 workspace 接受 name） | 中 | 清晰结构化错误：`"session caps require UUID; name input is not accepted (got \"esr-dev\")"。/session:list` 输出同时展示 UUID 和 name 以便复制。 |

---

## §9 — 测试计划

### 单元测试（per phase）

**Phase 1（session 身份）：**
- `Session.Registry` — UUID 往返：创建 → 持久化 → 重载 → 断言字段一致。
- `Session.Registry` — name → UUID 索引（复合 key）：`lookup_by_name({owner_uuid, "esr-dev"})` 返回正确 UUID。
- `Session.FileLoader` — 原子性：部分写入不可见。
- `Esr.Paths` — 新 helper 返回路径匹配 `$ESRD_HOME/<inst>/sessions/<uuid>/`。

**Phase 1b（user UUID 身份）：**
- Boot migration：无 UUID 的 `users.yaml` 条目获得 UUID；文件写回。
- `User.NameIndex` — `username_to_uuid("linyilun")` 返回 `{:ok, uuid}`。
- `User.NameIndex` — `uuid_to_username(uuid)` 返回 `{:ok, "linyilun"}`。
- `Commands.User.Add` — `esr user add alice` 创建 `users/<uuid>/user.json` + `users/<uuid>/.esr/workspace.json`（kind: "user-default"）。
- `Commands.Workspace.List` — 不包含 `kind: "user-default"` 条目。
- `Commands.Workspace.Info` — `/workspace:info name=alice` 返回 user-default workspace。
- 幂等：添加同一用户两次，第二次为 no-op。

**Phase 2（chat→[sessions]）：**
- `ChatScope.Registry` — attach：attach 后 `current` = session_id，`attached_set` = [session_id]。
- `ChatScope.Registry` — detach：session 从 `attached_set` 移除；`current` 更新。
- `ChatScope.FileLoader` — 启动迁移：旧单槽 ETS row 转为 attached-set 格式并写回。
- `ChatScope.Registry` — 多 attach：Attach A，Attach B，Detach A → B 成为 current。

**Phase 3（multi-agent）：**
- `Commands.Session.AddAgent` — 名字冲突（同名不同类型）→ `{:error, {:duplicate_agent_name, "esr-dev"}}`。
- `Commands.Session.AddAgent` — 名字冲突（同名同类型）→ 相同错误。
- `Commands.Session.AddAgent` — 不同名不同类型：`{cc, "dev"}` + `{codex, "reviewer"}` → 均成功。
- `Commands.Session.RemoveAgent` — 不能移除 primary → 需先 set-primary 到其他 agent。

**Phase 4（mention 解析）：**
- `MentionParser` — `@esr-dev hello`（session 中有 agent `esr-dev`）→ `{:mention, "esr-dev", "hello"}`。
- `MentionParser` — `@ hello`（单独 `@`）→ `{:plain, "@ hello"}`。
- `MentionParser` — `@unknown hello`（名字不在 session 中）→ `{:plain, "@unknown hello"}`（路由到 primary）。

**Phase 5（cap UUID 翻译 + UUID-only 强制）：**
- `Capability.UuidTranslator` — name input 在 session cap 中被拒绝：`validate_session_cap_input("session:esr-dev/attach")` → `{:error, {:session_name_in_cap, _}}`。
- `Capability.UuidTranslator` — UUID input 接受：`validate_session_cap_input("session:aaa-111.../attach")` → `:ok`。
- `Capability.UuidTranslator` — workspace cap 不受影响：`validate_session_cap_input("workspace:my-ws/read")` → `:ok`（pass through）。
- Session 创建者自动持有所有 `session:<uuid>/*` cap。
- Output-side 翻译：`session_uuid_to_name(uuid, ctx)` 返回 `{:ok, "esr-dev"}`。

**Phase 6（colon-namespace）：**
- 所有 colon 形式 slash 通过 `Registry.lookup/1` 解析。
- `/help` 和 `/doctor` 仍能解析（bare 形式保留）。
- 旧形式 key（`/new-session`）返回 `unknown command`。
- `/session:attach esr-dev`（name，非 UUID）→ 结构化错误提示 UUID 要求。

**Phase 7（plugin config + SemVer）：**
- `Plugin.Manifest` — 接受有效 `config_schema:`。
- `Plugin.Manifest` — 拒绝缺少 `type:` 的 `config_schema:` 条目。
- `Plugin.Config.resolve/2` — 仅 global：schema default 用于 absent key；global 值覆盖 default。
- `Plugin.Config.resolve/2` — user 层覆盖 global 某个 key；其他 key 用 global。
- `Plugin.Config.resolve/2` — workspace 层覆盖 user 和 global。
- `Plugin.Config.resolve/2` — workspace 空字符串（`""`）覆盖 global 非空。
- `Plugin.Config.resolve/2` — 使用 `user_uuid`（不是 username）读取 user 层文件。
- `depends_on:` 强制：依赖缺失 → `{:error, {:missing_dependency, dep}}`。
- `Plugin.Version.satisfies?(">= 0.1.0", "0.2.0")` → `true`。
- `Plugin.Version.satisfies?(">= 1.0.0", "0.2.0")` → `false`。
- Core version mismatch at load → `{:error, {:core_version_mismatch, ...}}`。

### E2E 测试（新 scenario）

**Scenario 14：Multi-agent session**

```bash
esr admin submit session_new name=multi-test submitter=linyilun ...
esr admin submit session_add_agent session_id=$SID type=cc name=alice ...
esr admin submit session_add_agent session_id=$SID type=cc name=bob ...
assert_contains "$(session_info $SID)" '"primary_agent":"alice"'
assert_contains "$(session_info $SID)" '"name":"bob"'
# 断言：alice 收到 @alice 消息；bob 收到 @bob 消息；primary（alice）收到普通文本
```

**Scenario 15：Cross-user attach（UUID-only）**

```bash
# UserA 创建 session，向 userB 授权 attach cap（UUID 标识）
/session:share $SID userB perm=attach
# UserB 通过 UUID attach（name attach 被拒绝）
esr admin submit session_attach session=$SID chat=oc_yyy user=userB ...
assert_attached userB $SID oc_yyy
# UserC（无 cap）尝试 attach → 应失败
RESULT=$(esr admin submit session_attach session=$SID chat=oc_zzz user=userC ...)
assert_error "$RESULT" "cap_check_failed"
# name-based attach 被拒绝
RESULT=$(esr admin submit session_attach session=shared chat=oc_www user=userB ...)
assert_error "$RESULT" "session caps require UUID"
```

**Scenario 16：Plugin config 3-layer resolution**

```bash
/plugin:set claude_code http_proxy=http://global.proxy:8080 layer=global
assert_effective_contains 'http_proxy = "http://global.proxy:8080"'
/plugin:set claude_code http_proxy=http://user.proxy:8080 layer=user
assert_effective_contains 'http_proxy = "http://user.proxy:8080"'
/plugin:set claude_code http_proxy="" layer=workspace
assert_effective_contains 'http_proxy = ""'
/plugin:unset claude_code http_proxy layer=workspace
assert_effective_contains 'http_proxy = "http://user.proxy:8080"'
/plugin:unset claude_code http_proxy layer=user
assert_effective_contains 'http_proxy = "http://global.proxy:8080"'
```

---

## §10 — 开放问题（已全部关闭）

本节记录 rev-1 的 5 个开放问题及其最终决议（Round-3 用户决策，2026-05-07）。保留本节作为决策演进文档。

**Q-OQ1（已关闭）：User UUID 身份化**
决议：D1 — User UUID 身份纳入本次重设计。用户目录路径从一开始即使用 `<user_uuid>`，无需后续痛苦迁移。

**Q-OQ2（已关闭）：Session 命名 — human-friendly name + UUID 双轨**
决议：D2 — Session 有 `name` 和 `id`（UUID）两个字段。**Input** 端 session cap 只接受 UUID，不接受 name（与 workspace 不同）。**Output** 端进行 UUID → name 翻译以提升可读性。

**Q-OQ3（已关闭）：`/session:new` 默认 attach 行为**
决议：D3 — YES，确认。`/session:new` 自动 attach 到创建 chat 并设为 attached-current。锁定行为。

**Q-OQ4（已关闭）：`/session:share` 默认权限**
决议：D4 — 确认 `perm=attach` 为默认值。更安全的默认值。

**Q-OQ5（已关闭）：`/cap:grant` 是否接受 session name**
决议：D5 — 拒绝。Session cap 在 input 端只接受 UUID。与 workspace 模式相反 — session name 不是全局唯一的（D6），name-keyed input 会产生歧义。

---

## §11 — Post-Deploy 迁移步骤（新增）

Per D7（锁定，2026-05-07）：本次重设计发布后，不提供 in-place 迁移。运营者必须清空现有 `$ESRD_HOME/<inst>/` 目录，让新 Bootstrap 从零重建。

### 必须执行的清除步骤（per D7）

在新 build 第一次启动前：

```bash
# 警告：此操作将销毁所有现有 session、workspace 和 plugin config。
# 请提前记录所需的 workspace folder、plugin key 等信息。

# 开发实例：
rm -rf ~/.esrd-dev/

# 生产实例：
rm -rf ~/.esrd/
```

辅助脚本位于 `tools/wipe-esrd-home.sh`：

```bash
#!/usr/bin/env bash
# tools/wipe-esrd-home.sh
# 在 metamodel-aligned-esr 构建首次启动前清除 ESRD_HOME。
# 用法：./tools/wipe-esrd-home.sh [--dev | --prod]
set -euo pipefail

MODE=${1:-"--dev"}
if [[ "$MODE" == "--dev" ]]; then
  TARGET="${ESRD_HOME:-$HOME/.esrd-dev}"
elif [[ "$MODE" == "--prod" ]]; then
  TARGET="${ESRD_HOME:-$HOME/.esrd}"
else
  echo "用法: $0 [--dev | --prod]" >&2; exit 1
fi

echo "即将清除: $TARGET"
echo "此操作将销毁所有 session、workspace 和 plugin config。"
read -p "输入 'yes' 确认: " confirm
[[ "$confirm" == "yes" ]] || { echo "已取消。"; exit 1; }
rm -rf "$TARGET"
echo "已清除。启动 esrd 将从 Bootstrap 重建。"
```

### Bootstrap 重建（首次启动后）

`Esr.Bootstrap`（现有模块）在新 `$ESRD_HOME/<inst>/` 首次启动时运行，创建：

1. `plugins.yaml` — global config，`enabled: [feishu, claude_code]`，`config: {}`。
2. `admin` 用户 — `users.yaml` 含一个条目 `{username: "admin", uuid: <generated>}`。创建 `users/<admin_uuid>/user.json` 和 `users/<admin_uuid>/.esr/workspace.json`（kind: "user-default"）。
3. Admin caps — `admin` 用户获得 `cap.manage`、`plugin/manage`、`session:default/create`、`workspace:default/create`。
4. `default` workspace — `workspaces/default/workspace.json`。

不预创建 session。运营者通过 `/session:new name=my-session` 开始工作。

### 为什么不做 in-place 迁移（D7 理由）

- `users/<username>/` 路径来自先前草案，从未实际发布到生产。没有需要迁移的数据。
- `users/<user_uuid>/` 结构需要 UUID 分配，通过 Phase 1b 启动时的 `users.yaml` 迁移最为干净。
- 任何先前草案中的 `users/<username>/.esr/plugins.yaml` 均未被发布代码写入，不存在运营者数据。
- 干净的 Bootstrap 是达到一致状态的最安全且最简单的路径。

---

## §12 — 交叉引用

- `docs/notes/concepts.md`（rev 9，2026-05-03）— 四元元模型；本 spec 所有原语定义的规范来源。
- `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`（rev 3）— workspace UUID 先例；本 spec 将 UUID 模式扩展至 session 和 user，并新增 3 层 plugin config。
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` — 启动流程审计，揭示运营者痛点；§7 的 11 个 phase 覆盖所有步骤和 cross-cutting 缺口。
- `runtime/priv/slash-routes.default.yaml` — 当前 slash 清单基准；Phase 6 将所有 primary key 改写为 colon 形式。
- `runtime/lib/esr/resource/workspace/registry.ex` — workspace UUID 模型（PR-230）；session registry 遵循相同的 ETS 双表模式。
- `runtime/lib/esr/resource/chat_scope/registry.ex` — 当前 chat-current-slot；Phase 2 迁移为 attached-set。
- `runtime/lib/esr/entity/user/registry.ex` + `file_loader.ex` — 当前用户模型（username-keyed，无 UUID）；Phase 1b 引入 UUID 身份和 `NameIndex`。
- `runtime/lib/esr/plugin/manifest.ex` + `runtime/lib/esr/plugins/*/manifest.yaml` — plugin manifest；Phase 7 新增 `config_schema:` 字段 + `depends_on.core` SemVer 强制执行。
- `scripts/esr-cc.sh` + `scripts/esr-cc.local.sh` — Phase 8 删除。
- `tools/wipe-esrd-home.sh` — 新增脚本（Phase 9 或 Bootstrap PR）。运营者 wipe 辅助工具。
- （参考）`spec/colon-namespace-grammar` 分支 — 内容已吸收入 §4。
- （参考）`spec/plugin-set-config` 分支 — 内容已吸收入 §6（含用户修正）。

---

## §13 — Self-Review Checklist（rev-2）

### D1-D8 覆盖情况

| 决策 | 已反映？ | 章节 |
|---|---|---|
| D1：user UUID 纳入本次；`users/<user_uuid>/`；NameIndex；boot migration | 是 | §0 锁定，§3 存储布局，§7 Phase 1b |
| D2：session name+UUID 双轨；session cap input UUID-only；name 仅 output | 是 | §0 锁定，§4 规则 7，§4 新增 session slash，§5 cap table |
| D3：`/session:new` 自动 attach — 确认锁定行为 | 是 | §0 锁定，§4 `/session:new` 说明 |
| D4：`/session:share` 默认 `perm=attach` — 确认 | 是 | §0 锁定，§4 `/session:share` 说明 |
| D5：`esr cap grant` 拒绝 `session:<name>` — UUID-only | 是 | §0 锁定，§4 `/cap:grant` 说明，§5 cap table，§7 Phase 5 |
| D6：session name 唯一性范围 `(owner_user, name)` | 是 | §3 session.json schema，§3 session name 说明，§7 Phase 1 |
| D7：`users/<user_uuid>/.esr/plugins.yaml`；无迁移；wipe 必须执行 | 是 | §3 存储布局，§6 层 2，§11 post-deploy 步骤 |
| D8：`depends_on.core` SemVer 检查纳入 Phase 7；`Esr.Plugin.Version` | 是 | §6 `depends_on.core` 小节，§7 Phase 7 |

### 结构性检查

| 检查项 | 状态 |
|---|---|
| 存储布局使用 `<user_uuid>` 而非 `<username>` 作为用户目录 | 是 — §3 完整目录树 |
| §5 明确对比 workspace cap（name+UUID）vs session cap（UUID-only）的 input 合约 | 是 — §5 对比表格 |
| §10 标记为 CLOSED（5 个开放问题全部已决议） | 是 — §10 标题 + 每条决议 |
| §11 新增 post-deploy wipe 章节 | 是 — §11 新增 |
| Phase 数量从 10 → 11（新增 Phase 1b） | 是 — §7 表格 |
| 依赖 DAG 仍然无环 | 是 — §7 DAG 图 |
| 无 emoji | 是 |
| 所有文件路径使用 repo-relative 或 `$ESRD_HOME/<inst>/` 前缀 | 是 |
| EN + zh_cn 段落对齐（§0-§15 相同编号） | 是 |

---

## §14 — 不变量测试（完成门控）

**Phase 1 不变量 — Session 存储：**
通过 `Session.Registry.create/1` 创建的 session 在进程重启后必须可从磁盘读取。

**Phase 1b 不变量 — User UUID 分配：**
对一个新 instance 执行 `esr user add alice` 后，必须存在 `users/<some_uuid>/user.json`（`username: "alice"`）和 `users/<some_uuid>/.esr/workspace.json`（`kind: "user-default"`）。`User.NameIndex.username_to_uuid("alice")` 返回 `{:ok, uuid}`。

**Phase 2 不变量 — Attached-set 原子性：**
一个 chat 依次 attach A、attach B、detach A 后，必须有 `attached_set = [B]` 且 `current = B.id`。

**Phase 3 不变量 — Agent 名字唯一性：**
添加 `{cc, "esr-dev"}` 后再添加 `{codex, "esr-dev"}` 必须返回 `{:error, {:duplicate_agent_name, "esr-dev"}}`。

**Phase 4 不变量 — Mention 路由到未知 agent 时 fallthrough：**
`@nonexistent hello` 发送到 session（唯一 agent 为 "alice"）必须路由到 alice，而非返回错误。

**Phase 5 不变量 — Session cap UUID-only 强制：**
`esr cap grant session:esr-dev/attach alice`（`esr-dev` 是名字，非 UUID）必须返回结构化错误。cap **不得**被写入。

**Phase 6 不变量 — yaml 中无旧形式 slash：**
`runtime/priv/slash-routes.default.yaml` 中所有 primary slash key 必须使用 colon 形式（`/help`、`/doctor` 除外）。grep 断言。

**Phase 7 不变量 — Per-key merge 正确性：**
global `http_proxy="http://g"`，user `http_proxy="http://u"`，workspace absent：`Config.resolve("claude_code", user_uuid: uuid, workspace_id: w_id)["http_proxy"]` 必须等于 `"http://u"`。

**Phase 7 不变量 — SemVer 强制执行：**
声明 `depends_on.core: ">= 99.0.0"` 的 plugin 必须以 `{:error, {:core_version_mismatch, ...}}` 失败加载。

**Phase 8 不变量 — Shell 脚本删除：**
`scripts/esr-cc.sh` 和 `scripts/esr-cc.local.sh` 不得存在。`make e2e` 需通过（scenario 01-13）。

**Phase 9 不变量 — Multi-agent 和 cross-user attach：**
Scenario 14（multi-agent session）和 Scenario 15（cross-user attach + UUID-only 强制）均需通过。

---

## §15 — 实现说明与 Elixir 约定

### Session registry 启动顺序

`Esr.Entity.User.NameIndex` 必须在 `Esr.Resource.Session.Registry` 之前启动（session struct 中 `owner_user` 为 UUID；NameIndex 提供 boot 时 legacy username → UUID 解析）。

`Esr.Resource.Session.Registry` 必须在 `Esr.Resource.ChatScope.Registry` 之前启动。

在 `Esr.Application.start/2` 中添加顺序：

```elixir
{Esr.Entity.User.NameIndex, []},          # Phase 1b：最先
{Esr.Resource.Session.Supervisor, []},    # Phase 1：第二
{Esr.Resource.ChatScope.Registry, []},    # Phase 2：第三
```

### `session.json` 写入原子性

遵循 PR-230 的 `workspace.json` 模式：先写 `<session_dir>/session.json.tmp`，再通过 `File.rename/2` 原子替换为 `session.json`。

### Plugin config ETS cache 失效

`/plugin:set` 写入磁盘后调用 `Esr.Plugin.Config.invalidate/1`。运行中 session 保持其 session 创建时解析的 config。运营者需 `/session:end` + `/session:new` 才能在不重启 daemon 的情况下使用新 config。

### 错误处理约定（let-it-crash）

- `Session.Registry` 启动：`File.mkdir_p!/1` 创建 `sessions_dir/0`。
- `Session.FileLoader.load/1`：`session.json` 格式错误 → log error，跳过该 session（不阻止 daemon 启动）。
- `Plugin.Loader.start_plugin/2` 违反 `depends_on` 或 `depends_on.core` → 返回 `{:error, ...}`，log，跳过该 plugin。

### 新增模块汇总

| 模块 | Phase | 用途 |
|---|---|---|
| `Esr.Resource.Session.Struct` | 1 | Session struct（对应 `session.json` schema） |
| `Esr.Resource.Session.Registry` | 1 | GenServer；ETS 双表（uuid + `{owner_user_uuid, name}` index） |
| `Esr.Resource.Session.FileLoader` | 1 | 从磁盘加载 `session.json` |
| `Esr.Resource.Session.JsonWriter` | 1 | 原子写 `session.json` |
| `Esr.Resource.Session.Supervisor` | 1 | session registry 的 supervisor |
| `Esr.Entity.User.NameIndex` | 1b | GenServer；ETS: username → uuid + uuid → username；boot migration |
| `Esr.Entity.User.JsonWriter` | 1b | 原子写 `user.json` |
| `Esr.Entity.Agent.Instance` | 3 | Agent instance struct |
| `Esr.Entity.MentionParser` | 4 | 解析纯文本中的 `@<name>` |
| `Esr.Plugin.Config` | 7 | 3 层 resolution + ETS cache（接受 user_uuid） |
| `Esr.Plugin.Version` | 7 | SemVer 约束检查（`depends_on.core`） |
| `Esr.Commands.Session.New` | 6 | 从 `Esr.Commands.Scope.New` 重命名 |
| `Esr.Commands.Session.Attach` | 6 | 新：attach 已有 session（UUID-only input） |
| `Esr.Commands.Session.Detach` | 6 | 新：离开 session 不结束它 |
| `Esr.Commands.Session.End` | 6 | 从 `Esr.Commands.Scope.End` 重命名 |
| `Esr.Commands.Session.List` | 6 | 从 `Esr.Commands.Scope.List` 重命名 |
| `Esr.Commands.Session.AddAgent` | 6 | 新：添加 agent 实例 |
| `Esr.Commands.Session.RemoveAgent` | 6 | 新：移除 agent 实例 |
| `Esr.Commands.Session.SetPrimary` | 6 | 新：设置 primary agent |
| `Esr.Commands.Session.BindWorkspace` | 6 | 新：重绑到命名 workspace |
| `Esr.Commands.Session.Share` | 6 | 新：授权 attach cap（UUID-only input） |
| `Esr.Commands.Session.Info` | 6 | 新：session 详情 |
| `Esr.Commands.Plugin.SetConfig` | 7 | 新：向指定层写入 config key |
| `Esr.Commands.Plugin.UnsetConfig` | 7 | 新：从指定层删除 config key |
| `Esr.Commands.Plugin.ShowConfig` | 7 | 新：显示 config（有效值或单层） |
| `Esr.Commands.Plugin.ListConfig` | 7 | 新：显示所有 plugin 有效 config |
| `Esr.Plugins.ClaudeCode.Launcher` | 8 | Elixir 原生 CC launcher（替代 esr-cc.sh） |
