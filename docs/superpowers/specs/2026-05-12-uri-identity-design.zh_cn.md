# URI 身份子系统设计

**状态：** 2026-05-12 通过（linyilun，Feishu 群 oc_d9b47511b085e9d5b66c4595b3ef9bb9 上 brainstorm 全程）
**取代：** `docs/superpowers/specs/2026-05-12-entity-resolver-design.md`（PR #350 已 merge，后转向）
**作者：** Claude Opus 4.7（controller）+ linyilun（拍板）

## 1. 目标 + Non-goals

**目标：** 让 `esr://` URI 成为每个 actor（user / workspace / session / agent）的**唯一标准名**。所有领域特定标识符 —— Feishu open_id、未来 Codex / Slack / Linear 的 id、by-name 查询 —— 都变成 alias URI，**重定向**到 canonical URI。一张表（`Esr.Uri.Store`）同时持有 alias 和 entity 数据。两个公开操作替代今天散落各处的几十个 `lookup_by_*` / `get_*_for_name` / `set_default_*` 函数：**`resolve/1`**（读）和 **`alias/2`**（写）。

这消除了"lookup chain drift"这类 bug（chat-cap-check 链中断、`resolve_submitter` 不认 UUID 形态等），并给 plugin 作者一个干净的扩展点：声明你的 URI 子树 + 实现两个 callback，不需要改 core。

**Non-goals：**
- 数据迁移。今天 esrd 没有生产实例；现有 yaml/json 通过新 FileLoader 在 boot 时载入 URI store。用户可以随意 wipe + 重建。
- 能力子系统统一。`Esr.Resource.Capability.has?/2` 通过 `resolve/1` 使用 URI store，但 cap 存储仍在 `capabilities.yaml`。
- 深度 URI 嵌套（如 `esr://workspaces/<uuid>/sessions/<name>`）—— PR-1 里 sub-data 住在 entity struct 内；未来 PR 可以加。
- 被取代的 entity-resolver spec 里的 `Esr.Entity` 命名空间 —— 完全删除；没有 `Esr.Entity.resolve_by/3`。

## 2. 背景

2026-05-12 两个手动测试 bug 浮现了底层 drift 类问题：
- Chat-side `Esr.Resource.Capability.has?/2` 解析 `ou_xxx → username` 但停在那；caps 是 UUID-keyed → 假阴性。
- `Esr.Commands.Workspace.Resolve.resolve_submitter/1` 只认 `submitted_by=<ou_xxx>` 和 `submitter_username=`；UUID 形态返 `:not_found`。

第一次修复尝试 `Esr.Entity.resolve_by(kind, by, value)` —— 多态 resolver。经过两轮 review，那个设计累积了太多边角案例（`:agent` UUID 语义、跨模块 `defp` 强制不可能、plan 写作时编造函数签名）而没有干净解决根本问题。用户提出转向：**让 URI 成为身份的标准形态，不只是序列化格式**。本 spec 即此转向。

## 3. 架构总览

```
┌────────────────────────────────────────────────────────────────────┐
│                       PUBLIC: Esr.Uri                              │
│                                                                    │
│   resolve(uri) :: {:ok, canonical_uri} | :not_found                │
│   alias(canonical_uri, alias_uri) :: :ok | {:error, ...}           │
│   put_entity(canonical_uri, kind, data) :: :ok | {:error, ...}     │
│   get_entity(uri) :: {:ok, kind, data} | :not_found                │
│   delete(uri) :: :ok                                               │
└────────────────────┬───────────────────────────────────────────────┘
                     │ 写经 GenServer.call
                     ▼
┌────────────────────────────────────────────────────────────────────┐
│         Esr.Uri.Store （GenServer + public ETS）                   │
│                                                                    │
│  单 ETS 表 :esr_uri_store, :public, read_concurrency: true         │
│                                                                    │
│  行格式（tagged value）：                                          │
│    {uri, {:entity, kind :: atom(), data :: struct()}}              │
│    {uri, {:alias,  canonical_uri :: String.t()}}                   │
│                                                                    │
│  读绕过 GenServer（直接 :ets.lookup，O(1) 无锁）。                  │
│  写经 GenServer 串行化以保证 alias→canonical 一致性。              │
└────────────────────┬───────────────────────────────────────────────┘
                     │ boot 时
                     ▲
┌────────────────────┴───────────────────────────────────────────────┐
│                  Plugin URI Handlers                               │
│                                                                    │
│  Manifest 声明 per-plugin URI 子树：                               │
│    uri_subtrees:                                                   │
│      - prefix: "users/feishu"                                      │
│        handler: Esr.Plugins.Feishu.UriHandler                      │
│                                                                    │
│  Handler 实现 `Esr.Uri.Plugin` behaviour：                         │
│    resolve(remaining_segments) → {:ok, canonical_uri} | :not_found │
│    alias(canonical_uri, alias_args) → {:ok, alias_uri} | error     │
└────────────────────────────────────────────────────────────────────┘
```

`Esr.Uri.Store` 持有数据。`Esr.Uri` 是公开 API（caller 只看到这层）。Plugin handler 翻译领域特定标识符到 canonical URI；在 `/feishu:bind` 类命令里调 `Esr.Uri.alias/2` 写 alias。

## 4. URI 语法

Canonical 和 alias URI 共享同一 parser（现有 `Esr.Uri` 模块从"被动序列化器"演进为"store 的 key"）。现有 scheme `esr://[org@]host[:port]/<segment>(/<segment>)*` 保留。

### 4.1 Canonical 形态（4 kinds）

```
esr://users/<uuid>
esr://workspaces/<uuid>
esr://sessions/<uuid>
esr://agents/<uuid>          # Instance.id，跨 CC+PTY 重启稳定
```

UUID v4 hyphenated 小写 hex。store 的 canonical 行持有 entity struct（`%User{}`、`%Workspace.Struct{}` 等）。

### 4.2 Core 保留 alias 形态

Core URI module 直接处理的 alias（不需要 plugin 参与）：

```
esr://users/by-name/<username>            → esr://users/<uuid>
esr://workspaces/by-name/<workspace_name> → esr://workspaces/<uuid>
esr://sessions/by-name/<session_name>     → esr://sessions/<uuid>   （在 scope 内；见 §4.4）
esr://agents/by-name/<agent_name>         → esr://agents/<uuid>     （在 session scope 内）
```

### 4.3 Plugin 拥有的 alias 形态

Plugin 在 manifest 里声明它拥有的 URI 子树。例：

```
# feishu plugin
esr://users/feishu/<ou_xxx>     → esr://users/<uuid>

# 未来 codex plugin
esr://agents/codex/<runtime_id> → esr://agents/<uuid>
```

kind 后的**第一个 segment**（`feishu`、`codex`、`by-name` 等）是**分派 key**。`by-name` 和 `by-uuid` 是 core 保留；其他 segment 都可被 plugin 认领。

### 4.4 带 scope 的 alias（session / agent）

Session 和 agent 名字带 scope —— 不同 workspace / session 里可以有同名。它们的 by-name URI 需要 scope segment：

```
esr://sessions/by-name/<env>/<user_uuid>/<workspace_uuid>/<session_name>
esr://agents/by-name/<session_uuid>/<agent_name>
```

scope segment 是 UUID 而非名字 —— 保证 alias URI 在任何祖先 rename 后仍稳定。Core 通过递归 `Esr.Uri.resolve/1` 解析这些 alias（alias → canonical → entity → scope segment 翻译）。

### 4.5 不允许 alias-of-alias

Alias 永远指向 **canonical** URI，不指向另一个 alias。`Esr.Uri.alias/2` 拒绝 target 本身是 alias 的写入（`{:error, :target_is_alias}`）。这保证 resolve 恰好 1 跳。

## 5. Public API

### 5.1 `Esr.Uri.resolve/1`

```elixir
@spec resolve(String.t()) :: {:ok, canonical_uri :: String.t()} | :not_found

# 例：
Esr.Uri.resolve("esr://users/cba75063-...")            #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/by-name/linyilun")        #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/feishu/ou_97f16490...")   #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/feishu/ou_unknown")       #=> :not_found
Esr.Uri.resolve("not a uri")                           #=> :not_found
```

读**不**走 GenServer —— 直接 `:ets.lookup`，O(1) 延迟。

### 5.2 `Esr.Uri.alias/2`

```elixir
@spec alias(canonical_uri :: String.t(), alias_uri :: String.t())
        :: :ok | {:error, :canonical_missing | :target_is_alias | :alias_exists | :invalid_uri}

Esr.Uri.alias("esr://users/cba75063-...", "esr://users/by-name/linyilun")
Esr.Uri.alias("esr://users/cba75063-...", "esr://users/feishu/ou_97f16490...")
```

校验：(a) canonical URI 存在且是 `:entity`-tagged，(b) alias URI 未被占用，(c) alias URI 格式合法。违反返 error tuple。写经 `Esr.Uri.Store` GenServer。

### 5.3 `Esr.Uri.put_entity/3`

```elixir
@spec put_entity(canonical_uri, kind :: atom(), data :: struct())
        :: :ok | {:error, :invalid_uri | :wrong_kind}
```

FileLoader 在 boot 时 + mutator 命令（`/user:add` / `/workspace:new` 等）通过这写 entity 数据。`kind` 必须匹配 URI 前缀（`esr://users/...` → `:user`）。

### 5.4 `Esr.Uri.get_entity/1`

```elixir
@spec get_entity(uri :: String.t())
        :: {:ok, kind :: atom(), data :: struct()} | :not_found
```

解析 alias → canonical（若需要）然后返回 tagged entity 数据。`resolve/1` + 手动 `:ets.lookup` 的便捷形式。

### 5.5 `Esr.Uri.delete/1`

```elixir
@spec delete(uri :: String.t()) :: :ok
```

删除 URI 行。如果删的是 canonical URI，指向它的所有 alias 留在 store 但 resolve 返 `:not_found`（孤儿 alias）。运维通过 `/uri:gc`（未来）或 boot 校验清理。

## 6. Plugin handler behaviour

```elixir
defmodule Esr.Uri.Plugin do
  @callback resolve(remaining_segments :: [String.t()])
              :: {:ok, canonical_uri :: String.t()} | :not_found | :invalid_format

  @callback alias(canonical_uri :: String.t(), args :: map())
              :: {:ok, alias_uri :: String.t()} | {:error, term()}
end
```

### 6.1 Manifest 声明

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml（加法 —— 保留现有 channels/agent_kinds 等块）

uri_subtrees:
  - prefix: "users/feishu"
    handler: Esr.Plugins.Feishu.UriHandler
```

Boot 时 `Esr.Plugin.Loader` 读每个 manifest 的 `uri_subtrees:` 块，注册 `prefix → handler` 映射到 `Esr.Uri`（如 `:persistent_term.put({Esr.Uri, :plugin_handlers}, ...)`）。

### 6.2 解析分派

详见英文 spec 的 §6.2 代码示例。`Esr.Uri.resolve/1` 根据 URI segment 分派：canonical UUID 形态走 ETS 直查；`by-name` / `by-uuid` 形态 core 直接处理；其他 segment 查 plugin handler 表分派。

## 7. Handler 契约

防止 `*_uri_handler.ex` 文件累积无关业务逻辑（γ-路线讨论中浮出的关注；α 仍保留这个 plugin 代码清洁纪律），handler 模块**只允许**包含：

1. **标识符翻译逻辑** —— 把领域标识符映射到 canonical URI（或反过来）。
2. **调 plugin 自有持久化** —— 例如写 plugin 自己的 yaml/json，或调现有的 per-plugin 命令如 `Esr.Plugins.Feishu.Commands.BindUser.persist/2`。

Handler **不允许**包含：
- 能力检查（`Esr.Resource.Capability.has?/2`）
- Slash 分派或命令路由
- 与绑定事件无关的 PubSub 广播
- 跨 kind 逻辑（`users/feishu` handler 不能碰 `workspaces` 或 `sessions`）

强制方式：code review checklist（PR-1 不加自动 lint；未来 PR 可加 custom Credo check）。

## 8. 存储 schema

单 ETS 表：

```
表名：    :esr_uri_store
类型：    :set
访问：    :public           # 读绕过 GenServer
并发：    read_concurrency: true, write_concurrency: false

行格式：
  {uri, {:entity, kind :: atom(), data :: struct()}}
  {uri, {:alias,  canonical_uri :: String.t()}}
```

`kind` atom 是 `:user | :workspace | :session | :agent` 之一。`data` struct 类型 —— 复用已有 struct，只在缺失处新建：
- `:user` → `%Esr.Entity.User.Registry.User{username, feishu_ids: [], default_workspace_id: nil}`（今天在 `runtime/lib/esr/entity/user/registry.ex:35-41`）。Migration 期间模块名保留；struct 跟着搬。未来 PR 可改名 `Esr.Resource.User.Struct`。
- `:workspace` → `%Esr.Resource.Workspace.Struct{}`（已存在）
- `:session` → `%Esr.Resource.Session.Struct{}`（已存在）
- `:agent` → `%Esr.Entity.Agent.Instance{}`（已存在；含 `id`、`name`、`type`、`actor_ids`、`session_ids`）。PR-1 保留；未来 PR 可改名。

**Reviewer 修正**：rev-1 写了 `Esr.Resource.User.Struct` 和 `Esr.Resource.Agent.Struct`，**今天不存在**。已改用真实 struct 标识。

GenServer `Esr.Uri.Store` 持有表；读用直接 `:ets.lookup`；写串行化经 `GenServer.call`。Boot 时 `Esr.Uri.FileLoader.load_all/0` 读 `users.yaml`、所有 `workspaces/<name>/workspace.json` 等，载入 store。

## 9. Migration：删 4 个 registry

PR-N（或子 PR）里要删除的模块：

| 删除的模块 | 替代 |
|---|---|
| `Esr.Entity.User.Registry`（数据 + 查询） | Entity 数据放进 URI store 行；查询通过 `Esr.Uri.resolve/1` |
| `Esr.Entity.User.NameIndex` | Core 内部处理 `users/by-name/<n>` alias |
| `Esr.Resource.Workspace.Registry` | URI store 行；`workspace_for_chat/2` 变成 `Esr.Uri.resolve("esr://workspaces/by-chat/<chat_id>/<app_id>")` |
| `Esr.Resource.Workspace.NameIndex` | Core 处理 `workspaces/by-name/<n>` |
| `Esr.Resource.Session.Registry` | URI store 行 |
| `Esr.Session.NameIndex.Registry` | Core 处理 `sessions/by-name/<scope-tuple>` |
| `Esr.Entity.Agent.InstanceRegistry` | URI store 行：`agents/<uuid>` + scoped `by-name`；`actor_ids` map 存 entity struct 内 |
| `Esr.Session.ChatRouting.Registry` | **保留**（关注的是 chat ↔ session 的运行时绑定，跟身份映射不同）；可发出 `sessions/by-chat-current/<chat_id>/<app_id>` alias 作 caller 便利 |

FileLoader 重写：boot 时灌入 URI store 而非 per-kind ETS。

### 9.1 Call site migration map（~387 call sites —— reviewer 修正）

**重要修正（spec rev-2）**：原本"39 lines / 29 files"是从被取代的 entity-resolver spec 继承的，**少估约 10 倍**。实际 grep 结果（lib + test）：

| 待删除模块 | call site 数（lib + test） |
|---|---:|
| `Esr.Entity.User.Registry` | 115 |
| `Esr.Resource.Workspace.Registry` | 94 |
| `Esr.Entity.Agent.InstanceRegistry` | 91 |
| `Esr.Resource.Workspace.NameIndex` | 38 |
| `Esr.Entity.User.NameIndex` | 21 |
| `Esr.Session.NameIndex.Registry` | 16 |
| `Esr.Resource.Session.Registry` | 12 |
| **合计** | **387** |

Plan 必须按 domain 拆 PR（User / Workspace / Session / Agent），每个 ~100-150 LOC migration，前置 PR-0 落地 URI store + plugin handler behaviour。

### 9.1.1 FileLoader 范围澄清（reviewer P1）

ESR 有 7 个 FileLoader 模块。只有 4 个 identity-related 的被重写：
- **在范围内**：`Esr.Entity.User.FileLoader`、`Esr.Resource.Workspace.FileLoader`、`Esr.Resource.Session.FileLoader`（若存在）、`Esr.Entity.Agent.<...>.FileLoader`（若存在）
- **不在范围**（保持原样）：`Esr.Resource.Capability.FileLoader`、`Esr.Resource.SlashRoute.FileLoader`、`Esr.Interface.FileLoader`、`Esr.Session.ChatRouting.FileLoader` —— 这些读非 identity 数据

### 9.1.2 Application.ex 插入位置（reviewer P1）

新 `Esr.Uri.Store` GenServer 在 Application 监督树中必须**先于**现有的 identity registry（因为它们被替换）。建议位置：在 `Esr.Resource.Sidecar.Registry`（line 79）/ `Esr.Entity.Agent.StatefulRegistry`（line 86）之后，`Esr.Entity.Agent.InstanceRegistry`（line 96）之前。精确位置 plan 决定。

### 9.1.3 Migration 替换模式

每个老 API call site 替换：

```elixir
# Before:
User.Registry.lookup_by_feishu_id(ou_xxx)  # 返 {:ok, username}

# After:
case Esr.Uri.resolve("esr://users/feishu/" <> ou_xxx) do
  {:ok, canonical} -> Esr.Uri.get_entity(canonical)  # 如需 entity 数据
  :not_found -> ...
end
```

按 kind 分阶段（User 先，Workspace 后，等等）—— 详见 plan。

## 10. Enforcement

### L1' 路径模式 CI 门

`mix esr.check_uri_drift` grep `runtime/lib/` 找老 API（`lookup_by_feishu_id`、`Workspace.Registry.get_by_id`、`NameIndex.id_for_name` 等）。**只允许**出现在：
- `runtime/lib/esr/uri/**/*.ex`（core URI module + dispatch）
- `runtime/lib/esr/uri/handlers/**/*.ex`（core-handled `by-name` / `by-uuid` alias）
- `runtime/lib/esr/plugins/*/uri_handler.ex`（plugin handler，命名强制）
- `runtime/lib/esr/uri/file_loader.ex`（boot 数据载入）

任何其他文件出现老 API → CI FAIL。**不**支持 per-file 白名单；路径模式**就是**白名单。

完整 migration 后，老 registry 模块物理删除；路径门进入残留状态（仍防御性保留，防同类 API 重新引入）。

### L2 `@doc false`（过渡）

在每个 registry 删除前的 phase 窗口，加 `@doc false` 和 moduledoc 弃用横幅。删除后失效。

### L3 Handler 契约

§7 中的 code review checklist。Reviewer 拒掉含非翻译逻辑的 handler PR。

### L4（不需要 —— α 是终极形态）

跟 γ-路线 brainstorm 不同，α 没过渡态 —— 4 个 registry 替换完后 URI store 就是 storage。不需要 deadline 跟进 PR。

## 11. 测试

### 11.1 Per-API 单元

- `Esr.Uri.resolve/1`：canonical → self；alias → canonical；not_found；invalid URI
- `Esr.Uri.alias/2`：happy；canonical_missing；target_is_alias；alias_exists；invalid_uri
- `Esr.Uri.put_entity/3`：happy；wrong_kind；invalid_uri
- `Esr.Uri.get_entity/1`：canonical 输入；alias 输入（链式 resolve）；not_found

### 11.2 Plugin handler 测试

每个 ship 带 URI handler 的 plugin（PR-1 是 feishu）：
- `resolve/1` happy + not_found + invalid_format
- `alias/2` happy + error cases
- Round-trip：`alias/2` 写；后续 `resolve/1` 找到

### 11.3 2026-05-12 drift bug 的回归测试

- Chat-side cap-check（曾：chain 停 username；现：`Capability.has?/2` 调 `Esr.Uri.resolve("esr://users/feishu/<ou>")` → canonical → 查 UUID-keyed grants）
- CLI `submitted_by=<uuid>` 解析到 workspace（曾：`:no_workspace_target`；现：workspace flow 直接接受 UUID URI）

### 11.4 编译断强制

完整 migration 后，老 registry 模块没了。测试断言 `Code.ensure_compiled(Esr.Entity.User.Registry) == {:error, :nofile}` 锁住删除。

### 11.5 E2E

- `tests/e2e/scenarios/31_uri_identity_chat_flow.sh` —— 完整 wipe → boot → register_adapter → /feishu:bind → /session:new 不需手动 cap_grant
- `tests/e2e/scenarios/32_uri_identity_cli_uuid_form.sh` —— CLI `submitted_by=<uuid>` 解析到 user-default workspace

## 12. 抑制的关切 + 未来

### `Esr.Uri` 命名空间的双角色（reviewer P1）

现有 `runtime/lib/esr/uri.ex` 已定义 `parse/1`（返 `%Esr.Uri{}` struct）、`build/3`、`build_path/3`、`parse_resource/1`、`build_resource/3`、`to_http_url/2`，以及 `defstruct [:org, :host, :port, :type, :id, :segments, :params]`。

PR-1 在**同一个模块**加新函数：`resolve/1`（返 string）、`alias/2`、`put_entity/3`、`get_entity/1`、`delete/1`。这造成双角色模块（parser + store-facade）。可行但 moduledoc 必须明确区分：

> `Esr.Uri` 担两个角色：(1) `parse/1`/`build*/1` 是 `esr://` 语法的纯 parser-builder；(2) `resolve/1`/`alias/2`/`put_entity/3` 是 store facade。两个角色共享 URI 语法但状态独立 —— parser 纯函数，facade 分派到 `Esr.Uri.Store` GenServer。

`def alias/2` 在 Elixir 里**合法**（`alias` 是 directive 但只在 module-body 层识别，函数调用 `Esr.Uri.alias(...)` 不冲突）。已验证。

替代命名（若双角色不舒服）：rename store facade 为 `Esr.Uri.Identity.resolve/1` 等。PR-1 默认：`Esr.Uri` 担两角色，rename 留下一个 PR 决定。

### `Esr.Session.ChatRouting.Registry`

PR-1 保持原状。它的工作是"哪个 session 当前绑这个 chat" —— 运行时关系，跟身份映射不同。可以选择发出 URI alias `esr://sessions/by-chat-current/<chat_id>/<app_id>` 作 caller 便利，但底层 storage 不变。

### Plugin 定义的 kind（未来）

今天只有 4 个 kind 是 first-class（`:user | :workspace | :session | :agent`）。未来 plugin（如 `:project`、`:repo`）可在 manifest 里声明新 kind 并拥有整个 `esr://<new_kind>/...` 子树。PR-1 out of scope。

### 嵌套 URI

`esr://workspaces/<uuid>/sessions/<uuid>` 在 PR-1 的语法中不支持；sessions 是 first-class 顶层 URI，workspace_uuid 作为 entity struct 上的字段。未来 PR 可加 path-style join 如需。

## 13. 引用

- Brainstorm 全程：Feishu 群 `oc_d9b47511b085e9d5b66c4595b3ef9bb9`，2026-05-12
- 被取代 spec：`docs/superpowers/specs/2026-05-12-entity-resolver-design.md`（PR #350，加上 status banner）
- Memory rule：[[feedback_uuid_is_canonical_identifier]]
- 现有 URI parser：`runtime/lib/esr/uri.ex`（保留；演进为调新 store）
- Todo `uri-as-canonical-actor-name`：被本 spec 取代，下次更新 docs/futures/todo.md 时标 closed
