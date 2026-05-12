# Entity Resolver 设计

**状态：** 2026-05-12 已通过（linyilun，Feishu chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9` 上 brainstorm 全程）
**作者：** Claude Opus 4.7（controller） + linyilun（拍板）

## 1. 目标 + Non-goals

**目标：** 引入 `Esr.Entity.resolve_by/3` 作为**唯一** public API，把任何形态的 ID（UUID / username / feishu open_id / chat_id+app_id / name+scope）翻译成标准 `{kind, uuid}` tuple。底层 store 全私有（物理上够不到），API 不可绕过。封死今天踩到的"lookup chain drift" 类 bug（详见 `docs/futures/todo.md` 2026-05-12 chat-flow validation findings）。

**Non-goals：**
- Sqlite 持久化（本轮不做；未来 PR 在不改 API 形态下可以 ETS → sqlite 直换）
- Capabilities 子系统统一（本轮不做；`Esr.Resource.Capability` 形态不变 —— 它**使用**新 resolver 来修 chat-side cap-check）
- `Esr.Entity.Registry` 的字符串 key 寻址（如 `"feishu_app_adapter_<app_id>"`）—— 是另一个"entity routing key"子系统，留下一轮
- 新的外部 ID 格式（Slack user_id、Telegram user_id）—— schema 容得下，但 by-clause 等具体 plugin 落地时才加

## 2. 背景 —— 触发本次设计的 drift bug

2026-05-12 wipe → register_adapter → /feishu:bind → /session:new 手动测试浮出 8 个 bug，其中 2 个直接属于"lookup chain drift"类：

| Bug | drift 形状 |
|---|---|
| Chat-side cap-check（`Esr.Resource.Capability.has?/2`，capability.ex:32-45）对合法 principal 返回 `false`，因为翻译链停在 `ou_xxx → username` 没继续到 UUID；caps.yaml 是 UUID-keyed | 多源 ETS 查询链短一跳 |
| `Esr.Commands.Workspace.Resolve.resolve_submitter/1`（resolve.ex:71-79）只认 `submitted_by=ou_xxx`（feishu open_id）和 `submitter_username=X`；UUID 形态 `submitted_by=cba75063-...` 直接 `:not_found` | 按 ID 形态 ad-hoc dispatch，覆盖不全 |

另有 sibling 类 —— *envelope arg injection drift* —— 本 spec **不涉及**（独立 audit）：

| Bug | 类别 |
|---|---|
| `Esr.Entity.SlashHandler.merge_chat_context/3`（slash_handler.ex:742-824）少 `workspace_bind_chat` 子句 → `chat_id` 不自动注入 | Envelope 注入 drift（不是 lookup） |
| chat-side render 模板替换吞了 `details:` interpolation | Render drift（不是 lookup） |

两类共享一个根：lookup 链在每个 call site 各组合一次，没有统一 API。

## 3. 架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PUBLIC: Esr.Entity                              │
│                                                                     │
│  resolve_by(kind, by, value) :: {:ok, {kind, uuid}} | :not_found   │
│  actor_for_agent(agent_uuid, role) :: {:ok, actor_id} | :not_found │
│                                                                     │
└──┬─────────────┬─────────────┬─────────────┬───────────────────────┘
   │             │             │             │
   ▼             ▼             ▼             ▼
┌──────┐    ┌──────────┐  ┌─────────┐  ┌──────────┐
│ User │    │Workspace │  │ Session │  │  Agent   │
│Store │    │  Store   │  │  Store  │  │  Store   │      (全私有)
│      │    │          │  │         │  │          │
│ETS   │    │ ETS      │  │ ETS     │  │ ETS      │
│不用  │    │ 不用     │  │ 不用    │  │ 不用     │
│named_│    │ named_   │  │ named_  │  │ named_   │
│table │    │ table    │  │ table   │  │ table    │
└──────┘    └──────────┘  └─────────┘  └──────────┘
```

`Esr.Entity` 是 caller 唯一可见的模块。每个 `*Store` 自己持有 ETS 表（**不**用 `:named_table`），外部 `:ets.lookup` 物理上够不到。Store 从今天的 `Esr.Entity.User.Registry` 等改名为 `Esr.Entity.UserStore` 等，名字本身就提醒"这是私有实现，别直接 call"。

## 4. Public API

### 4.1 `resolve_by/3`

```elixir
@spec resolve_by(kind :: kind(), by :: atom(), value :: term()) ::
        {:ok, {kind(), uuid_string()}} | :not_found | :invalid_format

@type kind :: :user | :workspace | :session | :agent
@type uuid_string :: <<_::36*8>>  # 36 字符带破折号的 UUID v4
```

`:not_found` —— value 格式合法但没找到对应 entity。
`:invalid_format` —— value 字面格式就不符合 by-clause 期望（比如 `:user :uuid "not-a-uuid"`）。让 caller 能区分"数据被破坏"和"参数类型错"。

**不**提供 `:ambiguous` —— duplicate 在写入侧防（add_user 防 username 重复、workspace.new 防名字重复、...）。出现 duplicate state = 数据坏 = let-it-crash。

### 4.2 `actor_for_agent/2`

```elixir
@spec actor_for_agent(agent_uuid :: uuid_string(), role :: atom()) ::
        {:ok, actor_id()} | :not_found
```

Role 按 kind 定义：
- cc-kind agent：`:primary`（CC actor_id）、`:terminal`（PTY actor_id）
- codex-kind agent（未来）：`:primary`（codex_runtime actor_id），无 `:terminal`

Role 合法性按 agent kind 的 manifest 声明校验；未知 role 返 `:not_found`（不 raise，因为 caller 可能要按 kind probe 能力）。

### 4.3 覆盖矩阵（13 个 by-clause）

| kind | by | value 类型 | 返回 | 语义 |
|---|---|---|---|---|
| `:user` | `:uuid` | uuid_string | user_uuid | UUID 正向校验 |
| `:user` | `:username` | string | user_uuid | 人读名 |
| `:user` | `:feishu_id` | string（`ou_*`） | user_uuid | Feishu open_id → esr user |
| `:workspace` | `:uuid` | uuid_string | workspace_uuid | UUID 正向校验 |
| `:workspace` | `:name` | string | workspace_uuid | 按名字 |
| `:workspace` | `:chat_binding` | `%{chat_id, app_id}` | workspace_uuid | 该 chat 绑的 workspace（workspace.chats[]） |
| `:workspace` | `:owner_default` | uuid_string（user_uuid） | workspace_uuid | 该 user 的 default_workspace_id |
| `:session` | `:uuid` | uuid_string | session_uuid | UUID 正向校验 |
| `:session` | `:name_in_scope` | `%{name, workspace_uuid, user_uuid, env}` | session_uuid | 名字在 `(env, user, workspace)` 4-tuple scope 内唯一（今天实际 key —— 见 §5.3） |
| `:session` | `:chat_current` | `%{chat_id, app_id}` | session_uuid | chat-current session |
| `:agent` | `:uuid` | uuid_string | agent_uuid（稳定 instance-level UUID） | UUID 正向校验 |
| `:agent` | `:name_in_session` | `%{name, session_uuid}` | agent_uuid | 名字在 session 内唯一 |
| `:agent` | `:primary_for_session` | uuid_string（session_uuid） | agent_uuid | session 的主 agent（mention 路由用） |

## 5. 每 kind 语义

### 5.1 `:user`

UUID 稳定身份；username + feishu_ids 是可变属性。

`:feishu_id` 链：`feishu_id → username → uuid`。老 API 只暴露第一跳（`lookup_by_feishu_id/1` 返 username）。新 API 内部把链补完。

### 5.2 `:workspace`

名字在实例内唯一。`chat_binding` 返回 `chats[]` 包含 (chat_id, app_id) 的 workspace。`owner_default` 读 user 的持久化 `default_workspace_id` 字段（从 user.json 来，启动时镜像到 ETS）。

### 5.3 `:session`

session 名字唯一性按 4-tuple `(env, user_uuid, workspace_uuid, name)` scope（实际见 `runtime/lib/esr/session/name_index/registry.ex:48,132`）。同一个人读名（比如 `test-cc`）在不同 user 之间、或不同 workspace 之间可以并存；只在同一个 user+workspace 对子里强制唯一。所以 `:name_in_scope` by-clause 要 4 个字段全给。`chat_current` 返回该 chat 最近一次 `/session:bind-chat` 绑的 session（或在 chat 上下文里 `/session:new` 自动绑的）。

### 5.4 `:agent`

**稳定身份模型。** 今天 `Esr.Entity.Agent.Instance.id`（supervisor 重启稳定的 UUID）就是 agent UUID。CC 和 PTY 的 actor_id 是**每次 spawn** 时 mint 的，`:one_for_all` 重启可能换 —— 这些**不是** agent 身份。要拿 actor pid 走 `actor_for_agent/2`。

**Breaking change：`InstanceRegistry.primary/2`**。今天（instance_registry.ex:170-178）返 `{:ok, agent_name :: String.t()}`。PR-1 改成返 `{:ok, agent_uuid :: uuid_string()}`，让 resolver"永远返 UUID"契约不开口子。5 个 caller 同 PR migrate —— 拿到 UUID 后按需 `actor_for_agent/2` 拿 actor pid，或直接向下游传 UUID。`:agent :primary_for_session` by-clause 直接 delegate 到改后的 `primary/2`。

**未来 codex 等新 kind。** plugin manifest 里 `actor_roles` 块声明：

```yaml
# 未来 codex plugin 的 manifest 片段
agent_kinds:
  codex:
    module: Esr.Plugins.Codex.Agent
    actor_roles: [:primary]   # 没 terminal
```

`resolve_by(:agent, ...)` 不管 kind 都返 agent_uuid；`actor_for_agent(uuid, :primary)` 对任何 kind 都成立；`actor_for_agent(uuid, :terminal)` 对没 terminal 的 kind 返 `:not_found`。

## 6. 私有 store 模块

4 个新 store 替换今天暴露 lookup 的 registry：

| 新 | 替换 | Public surface |
|---|---|---|
| `Esr.Entity.UserStore` | `Esr.Entity.User.Registry` | lookup 全 `defp`；mutator 保留（`load_snapshot_with_uuids`、`set_default_workspace`、`add_user`、...） |
| `Esr.Entity.WorkspaceStore` | `Esr.Resource.Workspace.Registry` + `Esr.Resource.Workspace.NameIndex` 合并 | lookup `defp`；mutator 保留（`put`、`delete`、`add_chat_binding`、...） |
| `Esr.Entity.SessionStore` | `Esr.Resource.Session.Registry`（今天内置 name index 为 inline ETS `:esr_resource_session_name_index`，**没有**独立 NameIndex 模块）+ `Esr.Session.NameIndex.Registry`（live-session URI claim 的 4-tuple map；合并到同一 store 后两份 name map 都在底下） | lookup `defp`；mutator 保留 |
| `Esr.Entity.AgentStore` | `Esr.Entity.Agent.InstanceRegistry`（改名，instance lifecycle 不动） | lookup `defp`；mutator 保留（`add_instance`、`remove_instance`、`set_primary`、...） |

ETS 表选项调：去掉 `:named_table`。每个 Store GenServer 把表 reference 放自己 state，读全部由 `Esr.Entity` dispatch。Mutator 保 public 给 FileLoader、命令模块（`/user:add`、`/workspace:new`、...）、lifecycle owner 调用。

## 7. Migration map（41 个 call site，分布在 29 个文件）

grep baseline（2026-05-12 跑 origin/dev）：

```bash
grep -rn "lookup_by_feishu_id\|UserRegistry\.get_default_workspace\|UserRegistry\.get_by_uuid\|UserRegistry\.get_by_username\|NameIndex\.id_for_name" runtime/lib/ \
  | grep -v "user/registry.ex\|user/name_index.ex\|user/file_loader.ex"
```

返 41 行、29 文件。PR-1 **全部** migrate。3 个 wave：

**Wave A —— drift-fix call site（3 文件，本 PR 修的 bug 对应的回归测试就锁这几处）：**
- `runtime/lib/esr/resource/capability.ex:32-45` —— chat-cap-check 链
- `runtime/lib/esr/commands/workspace/resolve.ex:61-79` —— resolve_submitter + lookup_user_default。**注意**：今天 caller 手里是 username，但 `:workspace :owner_default` 收 user_uuid。migration 改成先 `resolve_by(:user, :username, ...)` 再 `:owner_default`，每处机械两步。`resource/workspace/bootstrap.ex:54,77,102` 同样的形状（Wave B）。
- `runtime/lib/esr/entity/slash_handler.ex` —— chat-flow lookup（多行）

**Breaking 改动点（在 Wave A 内）**：`runtime/lib/esr/entity/agent/instance_registry.ex:170-178` —— `primary/2` 返回从 `{:ok, name}` 改 `{:ok, uuid}`。5 个 caller 同 PR 内迁（拿到 UUID 后按需 `actor_for_agent/2` 拿 actor_id）：
- `runtime/lib/esr/entity/slash_handler.ex:365`（mention 路由）
- `runtime/lib/esr/commands/agent/primary.ex:30`（`/agent:primary` slash）
- `runtime/lib/esr/commands/agent/set_primary.ex`（rename consumer）
- `runtime/lib/esr/commands/agent/list.ex`（显示渲染）
- `runtime/lib/esr_web/adapter_channel.ex`（legacy）

**Wave B —— 高频路由（5 文件）：**
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` —— FCP lookup
- `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex` —— FAA lookup
- `runtime/lib/esr/entity/agent/mention_parser.ex` —— mention → agent
- `runtime/lib/esr/entity/server.ex` —— entity server lookup
- `runtime/lib/esr/session/router.ex` —— session router

**Wave C —— 剩余 21 文件，机械替换：**
- `runtime/lib/esr/commands/{actors,agent,workspace,session,pty,...}/...ex` —— 命令 dispatch lookup
- `runtime/lib/esr/persistence/ets.ex` —— boot 时批量读

每个 call site 改 `Esr.Entity.resolve_by(kind, by, value)` + `case` on `{:ok, {_, uuid}}` / `:not_found`。没有 call site 保留老形态 —— 这是 choke-point 强制。

## 8. 老 API 废止

Wave C 跑完后，老 public 函数以 `defp` 形式藏在新 store 内部：

```elixir
# Esr.Entity.UserStore
defp lookup_by_feishu_id_internal(feishu_id) do
  case :ets.lookup(state.feishu_id_table, feishu_id) do
    [{^feishu_id, username}] -> {:ok, username}
    [] -> :not_found
  end
end
```

外部 caller 物理上够不到 `lookup_by_feishu_id_internal/1`。drift bug pattern（链停一跳）再要被引入 = 编译失败。

## 9. 测试

**Per by-clause 单测**（13 by-clause × {happy / :not_found / :invalid_format}）：
- `runtime/test/esr/entity/resolver_test.exs` —— 覆盖矩阵全覆盖

**回归测今天 2 个 drift bug**（spec 存在的理由）：
- `runtime/test/esr/integration/chat_cap_check_regression_test.exs` —— chat-side cap-check 现在能经 `ou_xxx → username → uuid` 链找到 UUID-keyed cap。链再短一跳 = 这个 test 失败。
- `runtime/test/esr/integration/resolve_submitter_uuid_form_test.exs` —— `Esr.Commands.Workspace.Resolve` 现在接受 `submitted_by=<uuid>` + `submitted_by=<ou_xxx>` + `submitter_username=X`。

**老 API 编译断 fixture：**
- `runtime/test/esr/entity/old_api_unreachable_test.exs` —— 用 `Code.ensure_compiled/1` + `function_exported?/3` 断言 `Esr.Entity.User.Registry.lookup_by_feishu_id/1`（和 sibling）未定义。锁住物理封死。

**E2E scenarios**（按用户 2026-05-12 指令"plan 里面要规划好 e2e 测试"）：
- `tests/e2e/scenarios/31_entity_resolver_chat_flow.sh` —— 今天失败 flow 的完整复现：wipe → boot → `register_adapter` → `/feishu:bind` → `/session:new name=test-cc`（**不**传 explicit `workspace=`）。断言 session 起来（chat 回复含 `session started: <UUID>`），且 **operator 不需要先跑 `cap_grant target_principal_id=linyilun`**、**也不需要先 `/workspace:bind-chat`** —— resolver 链能直接经 UUID 找到 user-default workspace + caps。
- `tests/e2e/scenarios/32_entity_resolver_cli_uuid_form.sh` —— CLI submit `submitted_by=<uuid>` 成功。今天的 bug：`resolve_submitter` 不认 UUID 形态 → `:no_workspace_target`。

**私有 ETS 的 test fixture 模式**（没 `:named_table`）：
- Store 提供测试专用 helper `Esr.Entity.UserStore.__test_ets_refs__/0`（`if Mix.env() == :test` 编译期保护），返回私有 ETS 表 reference 供直接 test setup。生产 caller 看不见。
- 替代方案：测试通过 public mutator (`add_user`、`set_default_workspace`、...) 构造 fixture state ——这些 mutator 本来就为生产用而存在。新测试推荐用这条路；`__test_ets_refs__` 留给迁移现有"直接 poke ETS"的测试。

## 10. Open questions / 未来防护

**Sqlite 持久化（未来 PR）。** 今天 ETS；当跨重启持久化变重要时 sqlite 是直接候选 —— public API 不动，只换 store 内部存储。触发条件：当 `users.yaml + user.json` drift 反复出现时（今天的"feishu_bind 不更新 user.json"是早期信号）。

**`Esr.Entity.Registry` 字符串 key 寻址（未来 PR）。** 今天全局 `Esr.Entity.Registry` 用 `"feishu_app_adapter_<app_id>"` 等字符串 key 注册进程。是另一种 drift surface（register/lookup key 对齐，见 [[feedback_register_lookup_key_parity]]）。本轮不动，未来 PR 用同样剧本：tuple key、统一 `Esr.Entity.register_process(kind, id, pid)` API。

**`capability.ex` 的 UUID 翻译跳（PR-1 内顺手）。** 本 spec 落地后，chat-cap-check 修正是 Wave A migration 之一。`docs/futures/todo.md` 行 `chat-cap-check-username-to-uuid-hop` 记录此项。

**Codex / 其他 agent kind（plugin 落地时）。** Manifest 的 `agent_kinds.<kind>.actor_roles` 块本 PR 就 ship（声明性）。runtime 在 plugin load 时注册 role。`actor_for_agent(uuid, role)` 查这个 registry。未来加新 kind = 只改 plugin manifest，不动 core。

## 11. 引用

- Brainstorm 全程：Feishu chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9`，2026-05-12
- Memory：[[feedback_uuid_is_canonical_identifier]]（UUID 是标准 ID 原则）
- Memory：[[feedback_register_lookup_key_parity]]（key 格式 drift 类）
- Todo：`docs/futures/todo.md` 行 `chat-cap-check-username-to-uuid-hop`、`resolve-submitter-format-agnostic`
- 被替换的现有模块：`runtime/lib/esr/entity/user/registry.ex`、`runtime/lib/esr/resource/workspace/registry.ex`、`runtime/lib/esr/entity/agent/instance_registry.ex`
- 现有 public API caller 全景：`grep -rn "lookup_by_feishu_id\|UserRegistry\.get_*\|NameIndex\.id_for_name" runtime/lib/`（41 行、29 文件）
