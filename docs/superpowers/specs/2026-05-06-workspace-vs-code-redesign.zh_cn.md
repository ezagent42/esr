# Workspace VS-Code 风格重设计

**状态**：design (2026-05-06)
**Brainstorm**：会话内 2026-05-06
**实现量估算**：~1300-1700 LOC，1 个主 PR + docs 扫尾（rev-3：+ UUID 身份 + name↔id 索引 + cap UUID 翻译层 + 混合 storage 发现 + registered_repos.yaml + 2 个新 slash `/workspace import-repo` & `forget-repo`；− migrator 整体；− 文件 watcher 整体）
**关联**：从 `esr daemon init` PR 推迟（见 `docs/futures/todo.md`）

## 目标

重设计 `workspace` Resource 的数据形态，让它更贴近 operator 的心智模型，同时消除 PR-198 之后我们撞到的 schema-drift 那一类 bug（`/help` 因为 `slash-routes.yaml` 旧字段名而失败）。把单文件 `workspaces.yaml` 替换成 `$ESRD_HOME/<instance>/workspaces/` 下每个 workspace 一个目录，每个目录里有一个仿照 VS Code `.code-workspace` 设计的 `workspace.json`。workspace 仍然是元模型层的 Resource（在 metamodel 里的角色不变）；这次只改它的数据形态、文件 layout、以及 CLI 命令。

## 非目标

- 移除 `workspace` 这个概念（讨论后否决；它仍承担身份、cap 作用域、多 app 路由、metadata 锚点这些功能）
- 自动从 cwd 推断 workspace（`/new-session` 没传 ws 名时不会自动猜"哪个 workspace 的 folders 包含 $PWD"）。workspace 必须按 name 显式引用。（注：另一种 auto-detect 在范围内 —— `/new-session ... cwd=<path>` 静默注册 `<path>/.esr/workspace.json`。这是注册，不是 workspace 身份推断。）
- 兼容旧 `workspaces.yaml` 格式 —— 不做 migrator
- **手编友好的 capabilities.yaml**。caps 内部按 workspace UUID 存（`session:<uuid>/create`），通过 CLI 翻译给 operator 看。手编 capabilities.yaml 不是支持的工作流；operator 只用 `/cap grant` / `/cap revoke` 等。
- **改动 session 已绑定的 workspace**。session 一旦 spawn，workspace 绑定就**不可变**。没有 `/session switch-workspace` 命令。Operator 想换 workspace 必须 `/end-session <sid>` 然后 `/new-session <new_ws> name=<sid>`（`claude --resume` 跨 respawn 恢复对话上下文）。这避免了 cc 进程运行态和 workspace 当前 config 之间的 cwd / env / settings 漂移。

## 问题

今天 `workspace` 是 `~/.esrd/<inst>/workspaces.yaml` 里的一行。三个痛点驱动这次重设计：

1. **Schema drift bug 这一整类**。yaml 是 operator 编辑的，但承载的字段语义归 core 代码所有。Core 演进时（比如 PR-198 把 `Esr.Admin.Commands.*` 改名 `Esr.Commands.*`），旧 yaml 静默被 loader 拒绝。`slash-routes.yaml` 的这次撞到让 operator 的 `/help` 失效，且非常难诊断。
2. **缺少 operator 概念**。Operator 想要 VS Code 那种 per-workspace 设置（cc model 覆盖、allowed tools、logging level）。yaml 行 layout 没法承载这种结构。
3. **多 root 项目**。真实工作往往跨多个 repo（`Workspace/esr` + `Workspace/cc-openclaw` + 工具 repo）。今天 workspace 只能绑一条 repo path。VS Code 的 `folders[]` 数组天然建模这种场景。

## 设计

### 混合 storage：workspace.json 可以住两个地方

一个 workspace 的 `workspace.json` 住在**两个位置之一**。runtime 对两种形态做统一处理 —— 同一份代码路径、同一个 `Workspace` Resource，仅 discovery 层有区别。

**(A) Repo-bound** —— workspace 跟一个 git repo 走：

```
<repo>/.esr/                       # 用户 git repo 内（commit 进 git）
  workspace.json                   # workspace 身份 + 配置
  topology.yaml                    # 项目可分享元数据（同样 commit）
```

队友 clone 这个 repo 的时候自动获得 workspace。这是**项目 workspace 的默认形态**。

**(B) ESR-bound** —— workspace 只住在 ESRD_HOME：

```
$ESRD_HOME/<instance>/workspaces/
  <name>/                          # ESR-managed；没有 git repo
    workspace.json                 # workspace 身份 + 配置
```

仅给那些没有项目 repo 的系统级 workspace 用：
- `default` —— `esr daemon init` 自动创建的兜底 workspace，给 `/new-session name=<sid>` 没有显式 ws 时用
- transient workspace（创建时 `transient: true`）
- ad-hoc scratch workspace —— operator 不想注册任何 repo 但想要一个临时 ws

### Session 运行时状态永远住在 ESRD_HOME

无论 workspace 是 repo-bound 还是 ESR-bound，session 的运行时状态（pid、port、临时 logs、scope 内部文件）都住在 ESRD_HOME 下：

```
$ESRD_HOME/<instance>/sessions/<sid>/
  ... (session-scoped 文件；格式另文定义)
```

这样保证用户的 git repo 干净（没有 `.esr/sessions/<sid>/` 频繁更新污染 working tree），`git status` 跑在 repo 上不会把 ESR 运行时状态看成 untracked。

### Workspace 身份：UUID

每个 workspace 创建时拿一个 **UUID v4**，存在 `workspace.json.id`。这个 UUID 是所有内部引用的规范身份：

- `capabilities.yaml` 用 UUID 存 cap grant（`session:<uuid>/create`、`workspace:<uuid>/manage`）
- session→workspace 绑定按 UUID 存
- chat-current-slot 的"这个 chat 的 default workspace"按 UUID 存

**operator 看到的 name 通过 name↔id 索引翻译。** Operator 输入 `/cap grant linyilun session:esr-dev/create` 时，runtime 把 `esr-dev` 解析成 UUID 然后按 UUID 持久化。`/cap list` 渲染输出时 UUID 翻译回 name。

这层解耦让 `/workspace rename` 真正变成**零成本** —— 改 `workspace.json.name` + 改内存里的 name↔id 索引，**不改 cap yaml、不迁 session 绑定**。引用永远不会过期。

如果 workspace 被删了，残留引用它 UUID 的 cap 渲染成 `workspace:<UNKNOWN-7b9f...>/manage`，operator 用 `/cap revoke` 清理。

### 发现与注册

ESR 从 3 个来源发现 workspace，boot 时和显式 operator 操作时都会用：

1. **ESR-bound**：扫 `$ESRD_HOME/<inst>/workspaces/`，读每个子目录的 `workspace.json`。永远走。
2. **Repo-bound**：扫一个 registered repo path 列表，读每个 `<repo>/.esr/workspace.json`。列表住在 `$ESRD_HOME/<inst>/registered_repos.yaml`（按需创建；包含绝对路径和可选的 friendly 名）。
3. **`/new-session ... cwd=<path>` 触发的自动检测**：当 slash 命令显式提供 `cwd=<path>` 而 ESR 发现 `<path>/.esr/workspace.json` 存在但路径还没在 `registered_repos.yaml` 里 —— 自动注册（加到列表，workspace 加入 registry）。

**Repo 注册是 per-machine 的。** 队友 B clone 一个 repo 之后必须自己跑 `/workspace import-repo <path>` 一次或者通过 `/new-session ... cwd=<path>` 触发自动检测。registered repo 列表不跨机器同步。

### registry 建好之后

两个来源 merge 进内存 registry 之后，runtime 对所有 workspace 一视同仁。Slash 命令按 name 引用 workspace；lookup 翻译成 UUID 然后读对应的 `workspace.json`，不管它住在哪。

如果两个来源里出现同一个 UUID（operator 复制粘贴了 workspace.json），boot 失败并报错，明确说出两个文件路径。Operator 必须在 esrd 启动前手动解决冲突。

### workspace.json schema (v1)

```json
{
  "$schema": "file:///path/to/runtime/priv/schemas/workspace.v1.json",
  "schema_version": 1,

  "id": "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
  "name": "esr-dev",
  "owner": "linyilun",

  "folders": [
    { "path": "/Users/h2oslabs/Workspace/esr", "name": "esr" },
    { "path": "/Users/h2oslabs/Workspace/cc-openclaw", "name": "cc-openclaw" }
  ],

  "agent": "cc",
  "settings": {
    "cc.model": "claude-opus-4-7",
    "cc.system_prompt_extra": "Project: ESR. Be concise.",
    "cc.allowed_tools": ["Bash", "Edit", "Read", "Grep"],
    "logging.level": "debug"
  },
  "env": {
    "PROJECT_ENV": "dev"
  },

  "chats": [
    { "chat_id": "oc_b7a242b742855d469be27b601abb693b", "app_id": "cli_a97ae5a8d4e39bdd", "kind": "dm" }
  ],

  "transient": false
}
```

| 字段 | 必/可 | 类型 | 用途 |
|---|---|---|---|
| `$schema` | 推荐 | URL | 编辑器 autocomplete + JSON Schema 校验 |
| `schema_version` | 必有 | integer | 版本迁移锚点；v1 必须为 `1` |
| `id` | 必有 | UUID v4 字符串 | 规范身份。`/new-workspace` 时生成。所有内部引用按这个走。**永不变**。形式 `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`（RFC 4122 §4.4）。 |
| `name` | 必有 | string | 显示名。Operator 看到的。通过内存 name↔id 索引和 `id` 互转。可改名（`/workspace rename`）；`id` 不动。同一个 registry 里两个 workspace 的 name 不能重 —— 注册时检查唯一性。 |
| `owner` | 必有 | string | esr-username；必须存在于 `users.yaml` |
| `folders` | 可选 | `{path, name?}` 数组 | 外部 repo 绑定；cwd 解析见下 |
| `agent` | 可选（default `"cc"`）| string | 用哪个 `agents.yaml` entry |
| `settings` | 可选 | 扁平 dot-namespaced map | per-workspace agent / runtime 覆盖 |
| `env` | 可选 | string→string map | 注入到 spawn 出去的 session 的环境变量 |
| `chats` | 可选 | `{chat_id, app_id, kind?}` 数组 | 哪些 chat 默认 route 到这个 workspace |
| `transient` | 可选（default `false`）| bool | 为 `true` 时，最后一个 session 退出自动删 workspace 存储。**只对 ESR-bound workspace 合法**；repo-bound workspace 上设 `transient: true` 写时被拒绝（不会 `rm -rf` 用户的 git repo）。 |

### Cwd 解析（folders → session.cwd）

session 继承的 cwd 取决于 `folders.length` 和 workspace 是 repo-bound 还是 ESR-bound：

| `folders.length` | Repo-bound workspace | ESR-bound workspace |
|---|---|---|
| 0 | （不可能 —— repo-bound 至少一个 folder 即 repo 自身；`/workspace import-repo` 自动把 repo path 设进 `folders[0]`）| `$ESRD_HOME/<inst>/workspaces/<name>/`（self-contained scratch）|
| 1 | `folders[0].path`（即 repo）| `folders[0].path` |
| >1 | `folders[0].path`；agent 收到 `--add-dir <each>` for `folders[1..N]` | `$ESRD_HOME/<inst>/workspaces/<name>/`；agent 收到 `--add-dir <each>` for 所有 folders |

多 folder 时 agent（cc）通过原生 `--add-dir` 拿到所有非 cwd 的 folder，让 LLM 跨它们读。`primary_folder: <i>` 字段可在 v2 加，operator 想显式选 cwd 时用。

repo-bound workspace 中 repo path 永远是 `folders[0]` —— 因为 `.esr/workspace.json` 在它里面。加 folder 进 `folders[1..N]`。

### settings dot-namespace 约定

```
<scope>.<key>: <value>
```

预留 scope：

- `cc.*` —— 覆盖 `agents.yaml` 的 `cc` entry。例：`cc.model`、`cc.allowed_tools`、`cc.system_prompt_extra`
- `<future-agent>.*` —— 未来加 agent_def 时各自的命名空间
- `logging.*` —— per-workspace logger level / format 覆盖

`settings` 的 key 是扁平 dot-string（和 VS Code 一致），不是嵌套对象。这样 JSON Schema 校验更直接，且符合 operator 在 `.vscode/settings.json` 形成的肌肉记忆。

### `<dir>/.esr/topology.yaml`（项目可分享元数据）

可选的伴生文件，住在**用户 git repo 里**（不在 `$ESRD_HOME`）。承载需要跟项目走的元数据 —— commit 进 git、队友 clone 时自动继承。

```yaml
schema_version: 1

description: >
  ESR — agent runtime that bridges Feishu chats to Claude Code
  sessions. Elixir (Phoenix) supervisor tree + Python adapter
  sidecars.

role: dev

metadata:
  language: elixir
  domain: agent-orchestration
  pipeline_position: head

neighbors:
  - cc-openclaw
  - cc-mcp-tools
```

Schema：

| 字段 | 类型 | 用途 |
|---|---|---|
| `schema_version` | integer | 版本迁移锚点 |
| `description` | string | free-form，通过 `describe_topology` 暴露给 LLM |
| `role` | string | 语义标签（dev / diagnostic / ...）—— UI 提示 |
| `metadata` | free-form map | verbatim 暴露给 LLM（仍有安全 allowlist 过滤）|
| `neighbors` | string 数组 | 这个项目关联的其他 workspace（LLM 提示，不是 ESR 路由）|

### 切分规则（workspace.json vs topology.yaml）

| 数据种类 | 住哪 | 理由 |
|---|---|---|
| 运行时状态（sessions、临时文件）| `$ESRD_HOME/.../sessions/` | ESR 运行时账本；不污染用户 repo |
| Workspace 身份（id / name / owner / folders / agent）| `workspace.json` | ESR 路由 / auth 必读；不依赖外部 repo 存在 |
| 运行时配置（cc.model / env / chats）| `workspace.json` | 操作配置；ESR 消费 |
| 项目可分享元数据（description / neighbors）| `<dir>/.esr/topology.yaml` | 跟代码走；队友 clone 后受益 |
| 项目级 agent 覆盖 | `<dir>/.esr/agents.yaml`（v2+）| 同 topology |

ESR 路由 / auth 永远不依赖 folder 存在 —— operator 可以 `rm -rf /Users/h2oslabs/Workspace/esr`，ESR 仍能干净 cleanup workspace，因为 workspace.json 包含 cleanup 所需的全部信息。

### 与元模型的关系

`workspace` 仍然是应用层 **Resource**（按 `docs/notes/concepts.md` 的 tetrad：Scope / Entity / Resource / Interface）。它的元模型角色不变 —— workspace 是有限可数的、被 Entity（cc agent、session 等）使用。变化的是：

- **数据形态**：yaml 行 → 目录 + workspace.json
- **存储**：单文件 yaml → per-workspace 目录
- **CLI surface**：一组完整生命周期的 slash（见下）

session 仍是一个 spawn 在 workspace（Resource）上的 **Scope**。Resource → Scope 关系不变。

`docs/notes/concepts.md` 不需要改 —— 它正确描述了 workspace 在元模型层的角色，没承诺具体数据形态。

## CLI surface

所有 workspace 改动走 slash command。手编 `workspace.json` 仅作紧急恢复手段，不是预期工作流；CLI 是规范接口。

| Slash | 状态 | 行为 |
|---|---|---|
| `/new-workspace <name> [folder=<path>] [owner=<user>] [transient=true]` | refactor | 创建新 workspace。**存储位置取决于 `folder=`**：传了且 `<path>` 是 git repo → 创建 `<path>/.esr/workspace.json`（repo-bound）；自动加进 `registered_repos.yaml`。不传 `folder=` → 创建 `$ESRD_HOME/<inst>/workspaces/<name>/workspace.json`（ESR-bound）。生成新 UUID 作 `id`。自动绑当前 chat。`transient=true` 在 repo-bound 上被拒绝。 |
| `/workspace list` | **新** | 读内存 registry（ESR-bound 扫描 + registered_repos.yaml merge）。输出：name、owner、folder count、chat count、location（`repo:<path>` 或 `esr:<dir>`）。 |
| `/workspace info <name>` | refactor | 读 `workspace.json` + 叠加 `<folders[0]>/.esr/topology.yaml`（如存在）。完整未过滤视图。 |
| `/workspace describe <name>` | refactor | 同 `info` 但过安全 allowlist（沿用 PR-222 的 `Esr.Resource.Workspace.Describe`）。LLM 安全。 |
| `/workspace sessions <name>` | refactor | 列出 `workspace_id` 等于这个 workspace `id` 的所有 session。（session 住 `$ESRD_HOME/<inst>/sessions/`，按 workspace UUID 索引，不在 workspace 自己目录下。） |
| `/workspace edit <name> --set <key>=<value>` | **新** | 更新 workspace.json 的单个标量字段。`--set settings.cc.model=...` 处理嵌套。**不用于 list 字段**（`folders[]`、`chats[]`），用专门的 slash。 |
| `/workspace add-folder <name> --path=<path> [--alias=<name>]` | **新** | 追加 `{path, name?}` 到 `folders[]`。校验 path 存在且是 git repo。 |
| `/workspace remove-folder <name> --path=<path>` | **新** | 删 `folders[]` 里匹配 path 的项。如果有 live session 的 cwd 解析到这个 path → 报错。repo-bound workspace 删 `folders[0]`（即 repo 自身）被拒绝；用 `/workspace remove` 整个删 workspace。 |
| `/workspace bind-chat <name> <chat_id> [--app=<app_id>] [--kind=<dm\|group>]` | **新** | 追加进 `chats[]`。从 chat 调用时 `--app` 默认用 inbound envelope 的 app_id；从 escript / admin queue 调用时必填。`--kind` default `dm`。 |
| `/workspace unbind-chat <name> <chat_id> [--app=<app_id>]` | **新** | 删 `chats[]` 里匹配的项。不带 `--app` 删所有 chat_id 匹配项（跨 app）；带 `--app` 限定到单个 (chat_id, app_id) 对。 |
| `/workspace remove <name> [--force]` | **新** | 从 registry 移除 workspace。**ESR-bound**：删目录 + sessions。**Repo-bound**：删 `<repo>/.esr/workspace.json` + `<repo>/.esr/topology.yaml` + 从 `registered_repos.yaml` 取消注册；`<repo>` 自身**永不动**。不带 `--force` 时如有 live session → 报错。 |
| `/workspace rename <name> <new_name>` | **新** | 更新 `workspace.json.name` + 内存 name↔id 索引。caps + sessions 都按 UUID 引用所以不动。**零成本**操作。（ESR-bound 也 `mv` 目录；repo-bound 因为 `<repo>/.esr/` 在 repo 里，目录路径不变。） |
| `/workspace use <name>` | **新** | 设当前 chat 的 default workspace。按 UUID 存（chat-current-slot ETS 索引旁边）。这个 chat 后续 `/new-session name=<sid>`（不带显式 `<ws>`）默认走 `<name>`。Per-chat 偏好；不影响其他 chat。 |
| `/workspace import-repo <path> [--name=<name>]` | **新** | 把 `<path>` 加进 `registered_repos.yaml` 并把 `<path>/.esr/workspace.json` 加入 registry。`<path>/.esr/workspace.json` 不存在时报错。`--name` 可选 override（除导入时改名外不用）。 |
| `/workspace forget-repo <path>` | **新** | 把 `<path>` 从 `registered_repos.yaml` 移除。Repo 的 `.esr/workspace.json` 不动。Workspace 从 `/workspace list` 消失，直到重新 import 或 auto-detect。 |

`/workspace list` 输出格式（沿用 PR-211 的 escript YAML envelope 约定）：

```
ok: true
data:
  workspaces:
    - name: esr-dev
      id: 7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71
      owner: linyilun
      folders: 2
      chats: 1
      location: repo:/Users/h2oslabs/Workspace/esr
      transient: false
    - name: default
      id: 11111111-2222-4333-8444-555555555555
      owner: linyilun
      folders: 0
      chats: 0
      location: esr:/Users/h2oslabs/.esrd-dev/default/workspaces/default
      transient: false
```

所有命令对 workspace.json 的写都是原子的（写 `workspace.json.tmp`，fsync，rename）。**没有文件 watcher** —— mutation 走 CLI invalidate。

## Session 集成

### `/new-session` 的 workspace 解析顺序

`/new-session [<ws_name>] name=<sid>` 按以下顺序解析 workspace（first match wins）：

1. **显式参数**：`/new-session esr-dev name=<sid>` —— 用 `esr-dev` workspace
2. **Chat default**：如果 inbound chat 跑过 `/workspace use <ws>`，用那个 workspace
3. **Global default**：fallback 到 `default` workspace

`default` workspace 由 `esr daemon init` 自动创建。它是一个 self-contained workspace（空 `folders[]`、空 `chats[]`、owner = bootstrap admin user）。Operator 可以通过 `/workspace edit default --set ...` 配置，或者通过 `/workspace use <other>` 把别的 workspace 作为偏好默认。

### Spawn 序列

workspace 解析完之后，`/new-session` 按以下步骤跑：

1. 读 `workspace.json`（按 location 走，repo-bound 或 ESR-bound）。文件缺失或 `name` ≠ basename → 报错。
2. 按 cwd 规则解析 cwd。
3. Build env：merge `agents.yaml.cc.env` + `workspace.json.env`（workspace 冲突时优先）。
4. Build settings：merge `agents.yaml.cc.*` 默认值 + `workspace.json.settings.cc.*`（workspace 优先）。
5. Build agent invocation：cc 的 `start_cmd` + `--add-dir <folder>` for each `folders[i]`（如果 cwd 已在第一个就跳过）。
6. 在 `Scope.Supervisor` 下 spawn session；session state 记录到 `$ESRD_HOME/<inst>/sessions/<sid>/`，session 的 `workspace_id = <workspace's UUID>`。**这个 workspace 绑定此刻被记录且不可变**（按非目标 —— 没有 `/session switch-workspace`）。
7. 如果 `transient: true`，挂一个 watch，最后一个 session 退出时删 workspace 目录。

`/end-session <sid>` 跑反向流程 —— 终止 scope、归档 session state、可选触发 transient cleanup。

## describe_topology 集成

`describe_topology(workspace_name)` MCP tool 按以下顺序合并三个数据源，然后过 PR-222 的安全 allowlist（不变）：

1. **workspace.json identity** —— name、owner、role 提示
2. **`<folders[0]>/.esr/topology.yaml`** —— description、metadata、neighbors（如果 folders[0] 存在且这个文件在）
3. **chats** —— `workspace.json.chats[]` 翻译成 LLM 可读形式

**多 folder 行为**：`folders[0]` 是项目元数据的**规范主 folder**。`describe_topology` 只读 `folders[0]/.esr/topology.yaml`。Operator 想要 per-folder 的不同 metadata 时，应该把规范 metadata 放在第一个 folder 里。

为什么是 folders[0] 而不是多 folder merge：

- 跨 folder merge 引入 last-write-wins 的歧义，operator 必须推理。v1 选"first" 确定性的方式避免意外。
- 多 folder merge 可以作为 v2 增强（`primary_folder: <i>` 字段 + per-folder merge 顺序）

这和 `chats[]`（曝光所有 entry 给 LLM）故意不对称：`chats` 是 operator 路由数据没有 merge 语义（"这些 chat 路由到这"），而 topology 文件是分层 metadata 必须仲裁冲突。

安全 boundary 仍在 PR-222 的 `Esr.Resource.Workspace.Describe`。allowlist 不变：`name`、`role`、`chats`（子 allowlist）、`neighbors_declared`、`metadata`。owner / env / settings 排除在外。

## Capabilities + UUID 翻译

这一节摊开"Workspace identity: UUID"那节引用的 cap 存储 / 翻译机制。

### 存储形式（capabilities.yaml）

caps 按 UUID 持久化。Operator 永不直接读：

```yaml
schema_version: 1

principals:
  - id: linyilun
    capabilities:
      - "session:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/create"
      - "session:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/end"
      - "workspace:7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71/manage"
      - "user.manage"          # 全局 perm 没 UUID；不变
      - "adapter.manage"       # 同上
```

Resource-scoped caps（`<resource>:<scope>/<perm>`）当 scope 是 workspace 时用 workspace 的 UUID。非 workspace-scoped 的 cap（`user.manage`、`adapter.manage`、`runtime.deadletter` 等）跟今天一样不变。

### 读路径（CLI 输出翻译）

`/cap list` 或 `/cap show <principal>` 跑时，渲染层把 UUID 翻译回 name：

```bash
$ runtime/esr exec /cap list
ok: true
data:
  - principal: linyilun
    capabilities:
      - "session:esr-dev/create"          # 7b9f3c1a-... → "esr-dev"
      - "session:esr-dev/end"
      - "workspace:esr-dev/manage"
      - "user.manage"
      - "adapter.manage"
```

如果持久化形式中的 UUID 不匹配任何已注册 workspace（e.g. workspace 删了但 cap 残留），渲染字符串成 `<resource>:<UNKNOWN-7b9f3c1a-...>/<perm>`，operator 看到后用 `/cap revoke` 清理。

### 写路径（CLI 输入翻译）

`/cap grant <principal> session:<name>/create` 跑时：

1. 通过内存 registry 把 `<name>` 解析成 UUID。`<name>` 不存在 → 报错。
2. 持久化为 `session:<uuid>/create`。

`/cap revoke` 同样先翻 name → UUID 再匹配。

### 运行时 cap 检查

ESR 检查"principal P 是否有 cap `session:<uuid>/create`"时，匹配完全在 UUID 域里 —— 不涉及 name。`Esr.Resource.Capability.Grants` matcher 跟今天一样，只是输入是 UUID 字符串而不是 name 字符串。

### 为什么这样让 rename 零成本

`/workspace rename esr-dev esr-prod` 之后：

1. `workspace.json.name` 从 `"esr-dev"` 变成 `"esr-prod"`
2. 内存 name↔id 索引重建（`esr-dev` 行删除，`esr-prod` 行加；`id` 仍是同一个 UUID）
3. capabilities.yaml **不动**。持久化的 UUID 仍指向同一个 workspace —— 它的 name 现在显示成另一个而已
4. 之后 `/cap list` 显示 `session:esr-prod/create`（因为 renderer 通过新索引把 UUID 翻成 "esr-prod"）

没有文件重写。没有原子事务。没有锁协调。整个 rename 是两个写（workspace.json + 索引），cap 层完全无感。

### 其他用 UUID 的子系统

- **session→workspace 绑定**：session 创建时存。形式 `session.workspace_id = "<uuid>"`。session 永不带 workspace name。
- **chat-current-slot 的 "default workspace"**：按 (chat_id, app_id) 存 UUID。`/workspace use <name>` 持久化前先把 name 解析成 UUID。
- **Slash command admin queue payload**：参数用 operator 看的 name。Name → UUID 在 slash dispatch 层翻译，在 command module 看到 args 之前。

## 移除老 `workspaces.yaml`

**没有 migrator**。老的单文件 `workspaces.yaml` 格式和新 layout 不兼容，翻译它的代价（工程 + 表面积）不值。

新代码下 esrd 第一次启动时：

1. 检测到 `$ESRD_HOME/<inst>/workspaces.yaml`（legacy 文件）
2. **删了**（`rm`）。WARN 级 log 写删除路径，给 operator 留 audit trail
3. 创建 `$ESRD_HOME/<inst>/workspaces/default/workspace.json`（系统 `default` workspace，ESR-bound，owner = bootstrap admin）
4. Operator 必须重建之前的 workspace：
   - 每个项目 repo：`cd <repo> && /workspace import-repo .`（或者从 chat 用 `/new-workspace <name> folder=<path>`）
   - 每个 chat-binding：`/workspace bind-chat <name> <chat_id>`
   - 每个非 trivial 的 setting（env、settings.cc.* 等）：用 `/workspace edit` 重新设

这比一个 migrator 麻烦更多，但：

- 当前 operator 基数小（用户的两个实例：`~/.esrd-dev` 和 `~/.esrd`）
- 每个实例 workspace 数量一只手能数过来（用户 dev 环境 2 个：`default` 和 `esr-dev`；prod 同规模）
- migrator 要为每种 legacy yaml 形态分别写代码（pre-PR-22 带 `root:`、pre-PR-21θ 带 `cwd:`、当前形态）—— 200+ LOC 只跑一次的代码
- "删 + 重建"流程强制 operator 走新 CLI，正好验证我们想验证的工作流

合并实现 PR 之前，operator 必须记下现有 workspace 的非默认 setting（每个跑 `runtime/esr exec /workspace info <name>`，把值复制到笔记里）。合并后，通过新 CLI 重新设置那些值。

实现 PR 加一个 boot 时的一次性 WARN log，列出删了的 yaml 路径，给万一漏看 heads-up 的 operator 留 paper trail。

## 范围之外

- 从 cwd 自动推断 workspace（`/new-session` 不带 name 解析成"哪个 workspace 的 folders 包含 $PWD"）。YAGNI；显式 name 避免歧义。（注：另一种 auto-detect 在范围内 —— `/new-session ... cwd=<path>` 静默注册 `<path>/.esr/workspace.json`。这是注册，不是 workspace 身份推断。）
- 多 root cwd 选择（永远 cwd = workspace 的 `folders[0]`，repo-bound；ESRD_HOME dir，ESR-bound 多 folder）。`primary_folder` 字段 v2 加。
- 项目级 `<dir>/.esr/agents.yaml` 覆盖。v2+。
- registered_repos.yaml 跨机器同步。每台机器独立注册 repo。
- workspace.json 的文件 watcher / hot-reload。**所有 workspace mutation 走 CLI**；CLI inline 失效内存 registry。手编 workspace.json 仅作紧急恢复用，operator 必须 `runtime/esr daemon restart`（或 v2 加 `/workspace reload <name>`）让改动生效。

## 风险与待解问题

1. **首次 boot 的数据丢失**。新代码无条件删 `~/.esrd/<inst>/workspaces.yaml`。Operator 必须**升级前**记下 workspace setting（每个跑 `/workspace info <name>` 或 `cat workspaces.yaml`）。PR description 必须显眼地说这件事。Operator 升级前 procedure 在实现 plan 里。
2. **`transient: true` + 并发 `/new-session` race**。最后一个 session 在 transient workspace 下退出时，cleanup hook 必须和并发的 `/new-session` 协调。用 `Esr.Resource.Workspace.Registry` GenServer 的串行化状态机 —— cleanup 和 register 都是 `handle_call`，自然在同一个进程上 serialised。
3. **`/workspace remove` repo-bound workspace**。Spec 说删 `<repo>/.esr/workspace.json` + `topology.yaml` + 从 `registered_repos.yaml` 取消注册，但**永不动 `<repo>` 本身**。边界情况：如果 `<repo>/.esr/` 已经 gitignore 或者还有其他 ESR 相关文件（v2 未来：agents.yaml override）？实现要明确 `rm <repo>/.esr/workspace.json` 和 `rm <repo>/.esr/topology.yaml`，不要 `rm -rf <repo>/.esr/`。实现测试要验证。
4. **跨机器共享 FS 不支持**。`$ESRD_HOME` 是 per-host。Symlink / NFS-mount / Dropbox-sync `~/.esrd-dev/` 在多 host 之间是 undefined 行为（atomic-rename + fsync 跨文件系统语义不同；进程名 registry 假设一个 BEAM 占有这个目录）。这次重设计不改这个 posture。Repo-bound workspace.json + 项目的 `.esr/topology.yaml` **是** 故意 repo-shared 且 version-control 跟踪的，但 `registered_repos.yaml` 和内存 registry 仍 per-host。
5. **UUID 碰撞**。UUID v4 每对碰撞概率 ~5×10⁻³⁶。我们规模（per-machine 个位数 workspace）下统计上不可能，但 registry merge 步骤仍校验：两个 `workspace.json` 文件加载出同一个 UUID → boot 失败、报错时显示两个文件路径。Operator 编辑其中一个的 `id` 解决。
6. **远程（非本地）repo 上的 repo-bound workspace.json**。Operator 在共享文件系统（sshfs 等）打开 ESR-managed repo 时，文件锁语义可能跟不上。v1 推荐只用本地 repo；远程场景归 risk #4（共享 FS）。

## Docs 扫尾

实现 plan 的 checklist 必须包含更新这些 docs 反映新形态：

- `README.md`（EN + 中文 zh）—— workspace 章节
- `docs/dev-guide.md` —— 入门 workspace 创建步骤
- `docs/cookbook.md` —— 提到 workspace 的 recipe
- `docs/notes/concepts.md` —— **不需要改**（元模型层不变；上面已说明）
- `docs/notes/actor-topology-routing.md` —— workspace 路由相关
- `docs/futures/todo.md` —— 关掉 workspace-redesign 条目，重开 "init redesign" 加更新依赖
- 任何 `docs/superpowers/specs/*` 引用了 workspace.yaml 形态的文件
- `docs/architecture.md` —— workspace 章节（如有）

## 参考

- Brainstorm 会话 2026-05-06（飞书 transcript）
- VS Code workspace schema：`https://code.visualstudio.com/docs/editor/workspaces`
- PR-222（`Esr.Resource.Workspace.Describe` 安全 boundary —— 这次重设计逐字保留）
- PR-22（删 `workspace.root` —— 部分前导）
- PR-21θ（从 `<root>/.worktrees/<branch>` 派生 cwd —— 也是前导）
- `docs/notes/concepts.md`（元模型 tetrad）
