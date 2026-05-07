# 元模型对齐 ESR 实施计划（中文版）

> **给智能体执行者：** 必须使用子技能 superpowers:subagent-driven-development 逐任务执行本计划。步骤使用复选框（`- [ ]`）语法追踪进度。

**目标：** 将 ESR 从"工作区优先、单 Agent"迁移到"Session 优先、多 Agent"架构，与 concepts.md 元模型对齐。

**架构概要：**
- Session 是一等公民，有 UUID；chat→[sessions]（attach/detach）
- 多 Agent per session，用全局唯一 `@<name>` 寻址
- per-session 工作区位于 `$ESRD_HOME/<inst>/sessions/<uuid>/`
- 用户默认工作区位于 `users/<user_uuid>/`
- 三层插件配置（global/user/workspace）
- 冒号命名空间斜杠语法（硬切换，无兼容期）

**技术栈：** Elixir/OTP/Phoenix；ETS 注册表；YAML 配置；JSON Schema 验证；UUID v4；SemVer 插件依赖。

**规格文档：** `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md`（rev-2，2026-05-07 用户审批）。

**迁移顺序（规格 §7）：** 1 → 1b → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9。每个 Phase 对应一个 PR，目标分支：`dev`。

---

## 文件结构总览

按职责分组，所有 11 个 Phase 涉及的新建 / 修改 / 删除文件。

### 新增：`Esr.Resource.Session.*`（Phase 1）

| 文件 | 模块 | Phase |
|---|---|---|
| `runtime/lib/esr/resource/session/struct.ex` | `Esr.Resource.Session.Struct` | 1 |
| `runtime/lib/esr/resource/session/file_loader.ex` | `Esr.Resource.Session.FileLoader` | 1 |
| `runtime/lib/esr/resource/session/json_writer.ex` | `Esr.Resource.Session.JsonWriter` | 1 |
| `runtime/lib/esr/resource/session/registry.ex` | `Esr.Resource.Session.Registry` | 1 |
| `runtime/lib/esr/resource/session/supervisor.ex` | `Esr.Resource.Session.Supervisor` | 1 |
| `runtime/priv/schemas/session.v1.json` | JSON Schema | 1 |

### 新增：`Esr.Entity.User.NameIndex` + 迁移（Phase 1b）

| 文件 | 模块 | Phase |
|---|---|---|
| `runtime/lib/esr/entity/user/name_index.ex` | `Esr.Entity.User.NameIndex` | 1b |
| `runtime/lib/esr/entity/user/migration.ex` | `Esr.Entity.User.Migration` | 1b |
| `runtime/priv/schemas/user.v1.json` | JSON Schema | 1b |

### 修改（Phase 1b）

| 文件 | 变更 | Phase |
|---|---|---|
| `runtime/lib/esr/entity/user/file_loader.ex` | 在 boot 时调用 Migration.run/1 | 1b |
| `runtime/lib/esr/entity/user/registry.ex` | 新增 `:esr_users_by_uuid` 表；`get_by_id/1`、`list_all/0` | 1b |

### 修改（Phase 2）

| 文件 | 变更 | Phase |
|---|---|---|
| `runtime/lib/esr/resource/chat_scope/registry.ex` | chat→[sessions] 附加集合形态 | 2 |
| `runtime/lib/esr/resource/chat_scope/file_loader.ex` | 新增：持久化 + boot 加载 | 2 |

### 修改（Phase 1 + 1b）

| 文件 | 变更 |
|---|---|
| `runtime/lib/esr/paths.ex` | 新增 session_json/1、session_workspace_dir/1、users_dir/0、user_dir/1、user_json/1、user_workspace_json/1、user_plugins_yaml/1、workspace_plugins_yaml/1 |

### 删除（Phase 8）

| 文件 |
|---|
| `scripts/esr-cc.sh` |
| `scripts/esr-cc.local.sh` |

---

## Phase 1：Session UUID 身份 + 存储布局

**PR 标题：** `feat: session UUID identity + storage layout (Phase 1)`
**目标分支：** `dev`
**预估 LOC：** ~800
**依赖：** Phase 0（规格文档）

### 任务 1.1：`Esr.Resource.Session.Struct`

**文件：**
- 新建：`runtime/lib/esr/resource/session/struct.ex`
- 新建：`runtime/test/esr/resource/session/struct_test.exs`

**参考：** `runtime/lib/esr/resource/workspace/struct.ex`，读取后再写测试。

- [ ] **Step 1 — 写失败测试**（见英文版 Task 1.1 Step 1 代码块，内容一致）
- [ ] **Step 2 — 运行失败测试**：`cd runtime && mix test test/esr/resource/session/struct_test.exs`
- [ ] **Step 3 — 实现 struct**（见英文版 Task 1.1 Step 3 代码块）
- [ ] **Step 4 — 运行通过测试**
- [ ] **Step 5 — 提交**：`feat(session): add Session.Struct with typed fields (Phase 1.1)`

---

### 任务 1.2：`session.v1.json` JSON Schema

**文件：**
- 新建：`runtime/priv/schemas/session.v1.json`
- 新建：`runtime/test/esr/resource/session/json_schema_test.exs`

**参考：** `runtime/priv/schemas/workspace.v1.json`。

- [ ] **Step 1 — 写失败测试**（见英文版 Task 1.2 Step 1 代码块）
- [ ] **Step 2 — 运行失败测试**
- [ ] **Step 3 — 实现 schema**（见英文版 Task 1.2 Step 3 代码块）
- [ ] **Step 4 — 运行通过测试**
- [ ] **Step 5 — 提交**：`feat(session): add session.v1.json schema + validation tests (Phase 1.2)`

---

### 任务 1.3：`Esr.Resource.Session.FileLoader.load/2`

**文件：**
- 新建：`runtime/lib/esr/resource/session/file_loader.ex`
- 新建：`runtime/test/esr/resource/session/file_loader_test.exs`

验证：`schema_version`、UUID 格式、`owner_user` 非空。

- [ ] **Step 1–5**（见英文版 Task 1.3，代码块相同）
- [ ] **提交**：`feat(session): add Session.FileLoader load/2 with schema + UUID validation (Phase 1.3)`

---

### 任务 1.4：`Esr.Resource.Session.JsonWriter.write/2`

**文件：**
- 新建：`runtime/lib/esr/resource/session/json_writer.ex`
- 新建：`runtime/test/esr/resource/session/json_writer_test.exs`

原子写：tmp + rename；包含 write → load 往返测试。

- [ ] **Step 1–5**（见英文版 Task 1.4，代码块相同）
- [ ] **提交**：`feat(session): add Session.JsonWriter atomic write + round-trip test (Phase 1.4)`

---

### 任务 1.5：`Esr.Paths` 扩展

**文件：**
- 修改：`runtime/lib/esr/paths.ex`
- 修改：`runtime/test/esr/paths_test.exs`

新增辅助函数：
- `session_json/1` → `$ESRD_HOME/<inst>/sessions/<uuid>/session.json`
- `session_workspace_dir/1` → `$ESRD_HOME/<inst>/sessions/<uuid>/.esr`
- `session_schema_v1/0`

**注意：** `session_dir/1` 和 `sessions_dir/0` 已存在，勿重复添加。

- [ ] **Step 1–5**（见英文版 Task 1.5）
- [ ] **提交**：`feat(paths): add session_json/1, session_workspace_dir/1, session_schema_v1/0 (Phase 1.5)`

---

### 任务 1.6：`Esr.Resource.Session.Registry` boot + ETS 骨架

**文件：**
- 新建：`runtime/lib/esr/resource/session/registry.ex`
- 新建：`runtime/test/esr/resource/session/registry_test.exs`

两个 ETS 表：
- `:esr_sessions_by_uuid` — UUID 主键
- `:esr_session_name_index` — 复合键 `{owner_user_uuid, name}`（规格 D6）

Phase 1 公开 API：`start_link/1`、`reload/0`、`get_by_id/1`、`list_all/0`。

- [ ] **Step 1–5**（见英文版 Task 1.6，代码块相同）
- [ ] **提交**：`feat(session): add Session.Registry ETS skeleton + disk scan boot (Phase 1.6)`

---

### Phase 1 PR 检查清单

- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 无编译警告：`mix compile 2>&1 | grep -i warning`
- [ ] 将 `Esr.Resource.Session.Supervisor` 加入 `Esr.Application` 子进程列表（在 `ChatScope.Registry` 之前）

---

## Phase 1b：用户 UUID 身份 + NameIndex + user.json 迁移

**PR 标题：** `feat: user UUID identity + NameIndex + user.json migration (Phase 1b)`
**目标分支：** `dev`
**预估 LOC：** ~600
**依赖：** Phase 1（Paths 约定）

### 任务 1b.1：`Esr.Entity.User.NameIndex`

**文件：**
- 新建：`runtime/lib/esr/entity/user/name_index.ex`
- 新建：`runtime/test/esr/entity/user/name_index_test.exs`

双向 username↔UUID ETS 索引。完全镜像 `Esr.Resource.Workspace.NameIndex`，仅将命名空间改为 `user`。

两张表：`:esr_user_name_to_id`、`:esr_user_id_to_name`。

公开 API：`put/3`、`id_for_name/2`、`name_for_id/2`、`rename/3`、`delete_by_id/2`、`all/1`。

- [ ] **Step 1–5**（见英文版 Task 1b.1，代码块相同）
- [ ] **提交**：`feat(user): add User.NameIndex bidirectional ETS username/UUID index (Phase 1b.1)`

---

### 任务 1b.2：`user.v1.json` JSON Schema

**文件：**
- 新建：`runtime/priv/schemas/user.v1.json`
- 新建：`runtime/test/esr/entity/user/json_schema_test.exs`

必填字段：`schema_version`、`id`（UUID v4）、`username`（非空）。可选：`display_name`、`created_at`。

- [ ] **Step 1–5**（见英文版 Task 1b.2，代码块相同）
- [ ] **提交**：`feat(user): add user.v1.json schema + validation tests (Phase 1b.2)`

---

### 任务 1b.3：用户 boot 迁移（`users.yaml` → `users/<uuid>/user.json`）

**文件：**
- 修改：`runtime/lib/esr/entity/user/file_loader.ex`
- 新建：`runtime/lib/esr/entity/user/migration.ex`
- 新建：`runtime/test/esr/entity/user/migration_test.exs`

**迁移逻辑：**
1. 检测 `users.yaml` 是否存在；若不存在直接返回 `:ok`
2. 解析 YAML，对每个用户条目：生成 UUID v4，写 `users/<uuid>/user.json`，写 `users/<uuid>/.esr/workspace.json`（kind="user-default"）
3. 原子重命名 `users.yaml` → `users.yaml.migrated-<unix_ts>`（保留备份）

幂等：第二次运行时 `users.yaml` 已不存在，直接返回 `:ok`。

- [ ] **Step 1–5**（见英文版 Task 1b.3，代码块相同）
- [ ] **提交**：`feat(user): add User.Migration users.yaml → per-uuid dirs (Phase 1b.3)`

---

### 任务 1b.4：`Esr.Entity.User.Registry` UUID 键扩展

**文件：**
- 修改：`runtime/lib/esr/entity/user/registry.ex`
- 修改：`runtime/test/esr/entity/user/registry_test.exs`（扩展）

新增 `:esr_users_by_uuid` ETS 表。现有 `:esr_users_by_name` 保持不变（向后兼容）。

新增公开 API：`load_snapshot_with_uuids/2`、`get_by_id/1`、`list_all/0`。

- [ ] **Step 1–5**（见英文版 Task 1b.4）
- [ ] **提交**：`feat(user): extend User.Registry with UUID-keyed ETS table + get_by_id/1 (Phase 1b.4)`

---

### 任务 1b.5：`Esr.Paths` 用户辅助函数

**文件：**
- 修改：`runtime/lib/esr/paths.ex`
- 修改：`runtime/test/esr/paths_test.exs`

新增辅助函数：
- `users_dir/0` → `$ESRD_HOME/<inst>/users/`
- `user_dir/1` → `$ESRD_HOME/<inst>/users/<user_uuid>/`
- `user_json/1` → `$ESRD_HOME/<inst>/users/<user_uuid>/user.json`
- `user_workspace_json/1` → `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/workspace.json`
- `user_plugins_yaml/1` → `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml`
- `workspace_plugins_yaml/1` → `<workspace_root>/.esr/plugins.yaml`
- `user_schema_v1/0`

所有函数接受 `user_uuid`（UUID 字符串），不接受 `username`。

- [ ] **Step 1–5**（见英文版 Task 1b.5）
- [ ] **提交**：`feat(paths): add user_dir/1, user_json/1, user_workspace_json/1, user_plugins_yaml/1, workspace_plugins_yaml/1 (Phase 1b.5)`

---

### Phase 1b PR 检查清单

- [ ] 在 `Esr.Entity.User.FileLoader.load/1` 顶部调用 `Migration.run(Esr.Paths.runtime_home())`
- [ ] 将 `Esr.Entity.User.NameIndex` 加入 `Esr.Entity.User.Supervisor` 子进程列表
- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 无编译警告：`mix compile 2>&1 | grep -i warning`

---

## Phase 2：ChatScope.Registry — chat→[sessions] attach/detach 状态

**PR 标题：** `feat: chat→[sessions] attach/detach state (Phase 2)`
**目标分支：** `dev`
**预估 LOC：** ~600
**依赖：** Phase 1b

**状态形态变更：**

```elixir
# 旧格式（1:1 模型）
{{chat_id, app_id}, session_id, refs}

# 新格式（attached-set 模型）
{{chat_id, app_id}, %{current: session_uuid | nil, attached: MapSet<session_uuid>}}
```

### 任务 2.1：ChatScope 状态形态重写

**文件：**
- 修改：`runtime/lib/esr/resource/chat_scope/registry.ex`
- 修改：`runtime/test/esr/resource/chat_scope/registry_test.exs`（扩展）

**新增公开 API：**
- `attach_session/3`（chat_id, app_id, session_uuid） — 添加到 attached；若首次则设为 current
- `detach_session/3` — 从 attached 移除；若是 current，将 next remaining 设为 current（或 nil）
- `current_session/2` — 返回当前 session UUID
- `attached_sessions/2` — 返回 UUID 列表

**保留（向后兼容）：**
- `register_session/3` — 已弃用但不删除
- `lookup_by_chat/2` — 代理至新形态的 current 字段

- [ ] **Step 1–5**（见英文版 Task 2.1，代码块相同）
- [ ] **提交**：`feat(chat_scope): add attach_session/3, detach_session/3, current_session/2, attached_sessions/2 (Phase 2.1)`

---

### 任务 2.2：`lookup_by_chat/2` 迁移兼容层

- [ ] 更新 `lookup_by_chat/2`，从新形态的 `current` 字段返回 `{:ok, sid, %{}}` 格式（保持调用方兼容）
- [ ] **提交**：`feat(chat_scope): update lookup_by_chat/2 shim for new attached-set shape (Phase 2.2)`

---

### 任务 2.3：多 Session attach/detach 测试套件

**文件：** `runtime/test/esr/resource/chat_scope/multi_session_test.exs`（新建）

测试场景（见英文版 Task 2.3 完整代码块）：
1. 附加 2 个 session → 两者都在 attached，第一个为 current
2. detach current → 下一个变为 current
3. detach 非 current → current 不变
4. 重复附加 → 幂等（无重复）
5. 列出所有 sessions
6. detach 最后一个 → 空列表 + :not_found current

- [ ] **提交**：`test(chat_scope): multi-session attach/detach invariant suite (Phase 2.3)`

---

### 任务 2.4：跨重启持久化 attached-set

**文件：**
- 新建：`runtime/lib/esr/resource/chat_scope/file_loader.ex`
- 修改：`runtime/lib/esr/resource/chat_scope/registry.ex`（init + 写入钩子）

持久化文件：`$ESRD_HOME/<inst>/chat_attached.yaml`

```yaml
chat_attached:
  - chat_id: "oc_xxx"
    app_id: "cli_yyy"
    sessions: ["uuid1", "uuid2"]
    current: "uuid1"
```

boot 时读取并填充 ETS；每次 `attach_session/3` 或 `detach_session/3` 后原子写入磁盘。

- [ ] **Step 1–6**（见英文版 Task 2.4，代码块相同）
- [ ] **提交**：`feat(chat_scope): persist attached-set to chat_attached.yaml + boot reload (Phase 2.4)`

---

### Phase 2 PR 检查清单

- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 确认现有调用方编译正常：`mix compile 2>&1 | grep -i error`
- [ ] 扫描 `lookup_by_chat` 调用方：`grep -r "lookup_by_chat" runtime/lib/ | grep -v registry.ex`

---

## Phase 3：多 Agent per session — 实例模型 + 名称唯一性

**PR 标题：** `feat: multi-agent per session — instance model + name uniqueness (Phase 3)`
**目标分支：** `dev`
**预估 LOC：** ~700
**依赖：** Phase 2

**目标：** 每个 session 可托管多个具名 agent 实例。名称在 session 内跨所有 type 全局唯一。`Session.Registry` 将 agents 列表持久化到 `session.json`。三个 slash 命令（`/session:add-agent`、`/session:remove-agent`、`/session:set-primary`）实现为纯命令模块；slash-routes 条目在 Phase 6 添加。

---

### 任务 3.1：`Esr.Entity.Agent.Instance` struct + JSON schema

**文件：**
- 新建：`runtime/lib/esr/entity/agent/instance.ex`
- 新建：`runtime/priv/schemas/agent_instance.v1.json`
- 新建：`runtime/test/esr/entity/agent/instance_test.exs`
- 新建：`runtime/test/esr/entity/agent/instance_schema_test.exs`

字段：`id`（UUID v4）、`session_id`（UUID）、`type`（来自插件 manifest 的字符串，如 `"cc"`）、`name`（session 内全局唯一）、`config`（map，默认 `%{}`）、`created_at`（ISO 8601）。

- [ ] **Step 1–5**（见英文版 Task 3.1，代码块相同）
- [ ] **提交**：`feat(agent): add Agent.Instance struct + agent_instance.v1.json schema (Phase 3.1)`

---

### 任务 3.2：`Esr.Entity.Agent.InstanceRegistry`（per-session ETS）

**文件：**
- 新建：`runtime/lib/esr/entity/agent/instance_registry.ex`
- 新建：`runtime/test/esr/entity/agent/instance_registry_test.exs`

**ETS 布局：** 单表，键为 `{session_uuid, agent_name}`，O(1) 名称唯一性检查。主 agent 以 `{session_uuid, :__primary__}` 键存储。

**公开 API：**
- `add_instance/2` — 拒绝同 session 重名（跨 type）；首个 agent 自动设为 primary
- `remove_instance/3` — 不可删除 primary agent（须先 `set_primary` 到其他 agent）
- `list/2` — 返回 session 的所有实例
- `get/3` — 单实例查询
- `set_primary/3` + `primary/2` — primary 管理
- `names_for_session/2` — 返回名称列表（供 MentionParser 使用）

- [ ] **Step 1–5**（见英文版 Task 3.2，代码块相同）
- [ ] **提交**：`feat(agent): add Agent.InstanceRegistry per-session ETS + name-uniqueness guard (Phase 3.2)`

---

### 任务 3.3：`Session.Registry` 集成 — agents 字段 + 持久化

**文件：**
- 修改：`runtime/lib/esr/resource/session/registry.ex`
- 修改：`runtime/test/esr/resource/session/registry_test.exs`（扩展）

新增 `add_agent_to_session/4`、`remove_agent_from_session/3`：写穿到 `InstanceRegistry` 并将 agents 列表持久化到 `session.json`。私有辅助 `persist_agents/2`：原子写（temp-rename 模式）。

持久化字段：`"agents": [{"type", "name", "config"}]`，`"primary_agent": name`。

- [ ] **Step 1–5**（见英文版 Task 3.3，代码块相同）
- [ ] **提交**：`feat(session): add_agent_to_session/4 write-through to InstanceRegistry + persist (Phase 3.3)`

---

### 任务 3.4：Session 域 agent 命令（低级 API）

**文件：**
- 新建：`runtime/lib/esr/commands/session/add_agent.ex`
- 新建：`runtime/lib/esr/commands/session/remove_agent.ex`
- 新建：`runtime/lib/esr/commands/session/set_primary.ex`
- 新建对应测试文件

遵循 `@behaviour Esr.Role.Control` + `execute/1` 模式（参见 `cap/grant.ex`）。

关键错误响应：
- `{:error, %{"type" => "duplicate_agent_name"}}` — 同 session 重名
- `{:error, %{"type" => "cannot_remove_primary"}}` — 删除 primary
- `{:error, %{"type" => "not_found"}}` — 未知 agent 名
- `{:error, %{"type" => "invalid_args"}}` — 缺少必要参数

- [ ] **Step 1–5**（见英文版 Task 3.4，代码块相同）
- [ ] **提交**：`feat(commands): add AddAgent, RemoveAgent, SetPrimary session commands (Phase 3.4)`

---

### 任务 3.5：插件 agent type 校验

**文件：**
- 修改：`runtime/lib/esr/commands/session/add_agent.ex`
- 修改：`runtime/test/esr/commands/session/add_agent_test.exs`（扩展）

在 `add_agent.ex` 的 `execute/1` 中，通过 `Esr.Entity.Agent.Registry.list_agents/0` 获取已知 agent type 列表，拒绝未声明的 type：

```elixir
with :ok <- validate_agent_type(type), ...
```

测试：`"cc"` 被接受（`claude_code` 插件已声明）；`"nonexistent_type_xyz"` 返回 `{:error, %{"type" => "unknown_agent_type"}}`。

- [ ] **Step 1–5**（见英文版 Task 3.5，代码块相同）
- [ ] **提交**：`feat(commands): AddAgent validates type against enabled plugin manifest (Phase 3.5)`

---

### Phase 3 PR 检查清单

- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 确认 `InstanceRegistry` 已加入监督树
- [ ] 确认命令模块从 `Esr.Admin.Dispatcher` 可达

---

## Phase 4：Mention 解析器 + primary agent 路由

**PR 标题：** `feat: mention parser + primary-agent routing on plain text (Phase 4)`
**目标分支：** `dev`
**预估 LOC：** ~400
**依赖：** Phase 3

**目标：** 含 `@<name>` 的入站消息路由到指定 agent；不含 mention 的纯文本路由到 session 的 primary agent（规格 Q8=A）。

---

### 任务 4.1：`Esr.Entity.Agent.MentionParser`

**文件：**
- 新建：`runtime/lib/esr/entity/agent/mention_parser.ex`
- 新建：`runtime/test/esr/entity/agent/mention_parser_test.exs`

**算法（规格 §4）：**
1. 扫描 `@[a-zA-Z0-9_-]+` 第一次出现
2. 提取名称，与 `agent_names` 列表做大小写敏感匹配
3. 匹配 → `{:mention, name, stripped_text}`（移除 `@<name>` 并 trim）
4. 不匹配 / 无 `@` → `{:plain, text}`

**返回类型：**
```elixir
{:mention, agent_name :: String.t(), rest :: String.t()} | {:plain, text :: String.t()}
```

测试覆盖（10 例）：leading mention、mid-text mention、孤立 `@`、名称含 `-`、`@unknown`、空 agents 列表、多 `@` 以第一个为准、`@x@y` 模式。

- [ ] **Step 1–5**（见英文版 Task 4.1，代码块相同）
- [ ] **提交**：`feat(agent): add MentionParser — @<name> mention detection (Phase 4.1)`

---

### 任务 4.2：入站 dispatch 路由集成

**文件：**
- 修改：`runtime/lib/esr/entity/slash_handler.ex`
- 新建：`runtime/test/esr/entity/slash_handler_mention_test.exs`

在 `SlashHandler` 中新增 `resolve_routing/2`：

```elixir
@spec resolve_routing(String.t(), String.t()) ::
        {:mention, String.t(), String.t()} | {:primary, String.t()} | {:error, :no_primary}
def resolve_routing(text, session_id) ...
```

逻辑：`MentionParser.parse` → 命中则返回 `{:mention, name, rest}`；未命中则读 `InstanceRegistry.primary` → `{:primary, name}` 或 `{:error, :no_primary}`。

测试：纯文本 → primary、`@alice` → mention、`@unknown` → primary、孤立 `@` → primary。

- [ ] **Step 1–5**（见英文版 Task 4.2，代码块相同）
- [ ] **提交**：`feat(slash_handler): add resolve_routing/2 — @mention + primary fallback (Phase 4.2)`

---

### 任务 4.3：`/session:set-primary` 生命周期集成测试

**文件：**
- 修改：`runtime/test/esr/commands/session/set_primary_test.exs`（扩展）

端到端集成验证：`SetPrimary.execute/1` → `InstanceRegistry` 更新 ETS → `resolve_routing/2` 立即读取新 primary。

```elixir
# alice 是 primary（首个添加）
assert {:primary, ^alice} = SlashHandler.resolve_routing("hello", sess)
SetPrimary.execute(...)  # 提升 bob
assert {:primary, ^bob} = SlashHandler.resolve_routing("hello again", sess)
```

- [ ] **Step 1–5**（见英文版 Task 4.3，代码块相同）
- [ ] **提交**：`test(commands): set_primary lifecycle → resolve_routing routes to new primary (Phase 4.3)`

---

### Phase 4 PR 检查清单

- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 确认 `MentionParser` 正确处理 `@esr-dev`（名称含 `-`）
- [ ] 确认 `resolve_routing/2` 从适配器层可达

---

## Phase 5：Cap UUID 转换 — session: scheme + UUID-only 合约

**PR 标题：** `feat: session cap UUID-only contract + output rendering (Phase 5)`
**目标分支：** `dev`
**预估 LOC：** ~300
**依赖：** Phase 3

**目标：** `session:<x>/...` cap 的输入端只接受 UUID（拒绝 name）；输出端 UUID→name 翻译用于人类可读显示。

**输入 vs 输出对比：**

| 资源类型 | name 输入 | UUID 输入 | 输出显示 |
|---|---|---|---|
| `workspace:<x>/...` | 接受（name→UUID 翻译） | 接受 | UUID→name |
| `session:<x>/...` | **拒绝**（D2, D5） | 接受 | UUID→name |

---

### 任务 5.1：`UuidTranslator` session: scheme — 仅输出方向

**文件：**
- 修改：`runtime/lib/esr/resource/capability/uuid_translator.ex`
- 修改：`runtime/test/esr/resource/capability/uuid_translator_test.exs`（扩展）

新增函数（见规格 §5 代码块）：

```elixir
@spec validate_session_cap_input(String.t()) ::
        :ok | {:error, {:session_name_in_cap, String.t()}}

@spec session_uuid_to_name(String.t(), map()) ::
        {:ok, String.t()} | {:error, :not_found}
```

关键变更：将 `@workspace_scoped_resources` 从 `~w(session workspace)` 改为 `~w(workspace)`，使 `name_to_uuid/1` 不再翻译 `session:` 的 name 形式。

**不添加** `session_name_to_uuid/1`（规格 D2/D5 明确禁止）。

- [ ] **Step 1–5**（见英文版 Task 5.1，代码块相同）
- [ ] **提交**：`feat(cap): UuidTranslator — validate_session_cap_input + session_uuid_to_name output-only (Phase 5.1)`

---

### 任务 5.2：cap 命令拒绝 `session:<name>/<verb>`

**文件：**
- 修改：`runtime/lib/esr/commands/cap/grant.ex`
- 修改：`runtime/lib/esr/commands/cap/revoke.ex`
- 修改对应测试文件

在 `Grant.execute/1` 和 `Revoke.execute/1` 中，在任何翻译前先调用 `validate_session_cap_input/1`：

```elixir
with :ok <- validate_session_cap(perm),
     {:ok, translated_perm} <- UuidTranslator.name_to_uuid(perm) do
  ...
else
  {:error, {:session_name_in_cap, msg}} ->
    {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}}
```

测试：`session:<uuid>/attach` 通过；`session:esr-dev/attach` 返回 `session_cap_requires_uuid`；`workspace:my-ws/read` 不受影响。

- [ ] **Step 1–5**（见英文版 Task 5.2，代码块相同）
- [ ] **提交**：`feat(cap): grant/revoke reject session:<name>/... — UUID-only enforcement (Phase 5.2)`

---

### 任务 5.3：cap 输出渲染 — session UUID→name

**文件：**
- 修改：`runtime/lib/esr/resource/capability/uuid_translator.ex`
- 修改：`runtime/lib/esr/commands/cap/show.ex`、`list.ex`、`who_can.ex`
- 新建：`runtime/test/esr/commands/cap/output_rendering_test.exs`

新增 `render_cap_for_display/1`：

```elixir
@spec render_cap_for_display(String.t()) :: String.t()
```

渲染规则：
- `session:<uuid>/...` + session 存在 → `session:<name>/... (uuid: <uuid>)`
- `session:<uuid>/...` + session 已删（孤儿）→ `session:<UNKNOWN-<8位前缀>>/...`
- `workspace:<uuid>/...` → `workspace:<name>/...`（现有逻辑）
- 其他 → 原样

将 `show.ex`、`list.ex`、`who_can.ex` 中所有 `uuid_to_name/1` 调用替换为 `render_cap_for_display/1`。

- [ ] **Step 1–5**（见英文版 Task 5.3，代码块相同）
- [ ] **提交**：`feat(cap): render_cap_for_display — session UUID→name output rendering + UNKNOWN sentinel (Phase 5.3)`

---

### Phase 5 PR 检查清单

- [ ] 全量测试：`cd runtime && mix test 2>&1 | tail -20`
- [ ] 确认不存在 `session_name_to_uuid`：`grep -r "session_name_to_uuid" runtime/lib/`
- [ ] 确认 `validate_session_cap_input` 在 `grant.ex` 和 `revoke.ex` 中均被调用
- [ ] 确认 `render_cap_for_display` 是 `show.ex`、`list.ex`、`who_can.ex` 的唯一渲染路径

---

<!-- PLAN_END_PHASE_5 — next subagent: append "## Phase 6" here -->
