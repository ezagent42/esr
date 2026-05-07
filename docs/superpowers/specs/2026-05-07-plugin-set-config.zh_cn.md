# Spec：运营者可设置的 Plugin 级别配置

**日期：** 2026-05-07
**分支：** `spec/plugin-set-config`
**状态：** 草稿 — 待运营者审批后再开 PR

> **英文版：** [`2026-05-07-plugin-set-config.md`](2026-05-07-plugin-set-config.md)

---

## §1 — 范围与动机

2026-05-06 的启动流程审计（`docs/manual-checks/2026-05-06-bootstrap-flow-audit.md`）
暴露了两个结构性缺口。**Step 6** 发现不存在 `/plugin … set config` 命令——manifest
的 `required_env:` 只能在编译期声明需要哪些环境变量，没有运营者在运行时可写的接口。
**Cross-cutting #2** 确认这是已知技术债：TODO "agent (cc) startup config first-class"
早已预见这个需求，但从未立 spec。现有唯一的 per-plugin 调参方式是一个 gitignore 的
bash 片段（`scripts/esr-cc.local.sh`），在 `exec claude` 前 source。这对单机单运营者
可以工作，但无法跨用户账户、跨仓库、跨未来无 shell 入口的 plugin 作者组合使用。

用户已于 2026-05-06 锁定以下决策（全文称"已锁定"）：

1. 扩展 `plugins.yaml`，加入可选的 `config:` map（全局层不新建文件）。
2. 每个 plugin 的 `manifest.yaml` 增加 `config_schema:` 块，声明所有合法 key。
3. Slash 命令使用 colon-namespace 形式（`/plugin:set`、`/plugin:unset`、`/plugin:show`），
   与审计 task 3 建议一致。
4. 重启生效语义（restart-required）。热加载为 Phase 2（本 spec 不涉及）。
5. Plugin 代码通过 `Esr.Plugin.Config.get(plugin_name, key)` 读取配置，ETS 缓存支撑。
6. 三层配置在 session 创建时解析：global / user / project
   （优先级：project > user > global，逐 key 合并）。
7. `scripts/esr-cc.sh` 和 `scripts/esr-cc.local.sh` 在迁移完成后删除。
8. `tests/e2e/scenarios/common.sh` 及依赖场景更新为使用 plugin config。

**不在范围内：** 热加载（Phase 2）；上述三层以外的 per-environment 覆盖；plugin 间配置共享；
从外部 secret store（如 Vault）拉取配置。

---

## §2 — 存储结构

### 2.1 全局层 — `$ESRD_HOME/<inst>/plugins.yaml`

现有文件顶层增加可选的 `config:` map：

```yaml
# $ESRD_HOME/<inst>/plugins.yaml
enabled:
  - feishu
  - claude_code
config:
  claude_code:
    http_proxy: "http://proxy.local:8080"
    https_proxy: "http://proxy.local:8080"
    no_proxy: "localhost,127.0.0.1,::1,.feishu.cn,.larksuite.com"
    anthropic_api_key_ref: "${ANTHROPIC_API_KEY}"
    esrd_url: "ws://127.0.0.1:4001"
  feishu:
    log_level: "info"
```

`PluginsYaml.read_explicit/0` 扩展以读取 `config:` 节；`PluginsYaml.write/2` 同时接收
enabled list 和 config map，使用 tmp-rename 原子写入（保留现有原子性保证）。

向后兼容：只有 `enabled:` 而没有 `config:` 的文件合法；config map 默认为 `%{}`。

### 2.2 用户层 — `$ESRD_HOME/<inst>/users/<username>/plugins.config.yaml`

新文件，每用户每实例一个。路径设计理由：与 `Esr.Users.Registry` 已有的
`$ESRD_HOME/<inst>/users/` per-user 目录对齐。该文件 gitignore（`$ESRD_HOME` 通常在
仓库外）。功能上取代 `scripts/esr-cc.local.sh` 的 per-operator 覆盖能力。

```yaml
# $ESRD_HOME/<inst>/users/linyilun/plugins.config.yaml
config:
  claude_code:
    anthropic_api_key_ref: "${USER_ANTHROPIC_KEY}"
```

无 `enabled:` 字段，纯 config 文件。文件缺失等价于 `config: {}`。

### 2.3 项目层 — `<repo>/.esr/plugins.config.yaml`

新文件，每仓库一个。仅当当前 workspace 是**仓库绑定**的（即 `workspaces.yaml` 中有
非空 `root:` 字段）时才读取。运营者可将此文件提交到仓库，与同事共享项目级配置
（例如特定网络环境的代理绕过）。Secrets 不应放入此文件——使用 `anthropic_api_key_ref`
引用 env var，而不是写入字面量值。

```yaml
# <repo>/.esr/plugins.config.yaml
config:
  claude_code:
    http_proxy: ""            # 此仓库要求直连（覆盖全局代理）
    project_specific_setting: "some_value"
```

`.esr/` 目录是否提交到 git 由运营者决定；如果只想本地使用，加入 `.gitignore`。

### 2.4 Manifest `config_schema:` 结构

每个 plugin 的 `manifest.yaml` 增加 `config_schema:` map。Plugin 读取的每个 key 都必须
在这里声明。运营者写入 schema 中不存在的 key 时，写入操作被拒绝并报错。

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml（建议新增）
config_schema:
  http_proxy:
    type: string
    description: "HTTP 代理 URL，用于出向 Anthropic API 请求。空字符串 = 不用代理。"
    default: ""
    sensitive: false

  https_proxy:
    type: string
    description: "HTTPS 代理 URL，通常与 http_proxy 相同。"
    default: ""
    sensitive: false

  no_proxy:
    type: string
    description: "逗号分隔的主机/后缀，绕过代理。"
    default: ""
    sensitive: false

  anthropic_api_key_ref:
    type: string
    description: |
      Anthropic API Key 的环境变量引用，如 "${ANTHROPIC_API_KEY}"。
      Plugin 在 session 启动时通过 System.get_env/1 解析实际值。
      切勿将 key 本身直接写在此字段。
    default: "${ANTHROPIC_API_KEY}"
    sensitive: true   # /plugin:show 默认遮罩该值

  esrd_url:
    type: string
    description: "esrd 宿主的 WebSocket URL，控制 HTTP MCP endpoint。默认：ws://127.0.0.1:4001。"
    default: "ws://127.0.0.1:4001"
    sensitive: false
```

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml（建议新增）
config_schema:
  log_level:
    type: string
    description: "feishu adapter 日志详细度（debug|info|warning|error）。"
    default: "info"
    sensitive: false
```

**Phase 1 类型系统：** 仅支持 `string` 和 `boolean`。Integer/list 延至 Phase 2。

**验证规则：**
- `type:` 必填；未知类型 → 拒绝 manifest parse。
- `description:` 必填（强制 plugin 作者文档化每个 key）。
- `default:` 必填；可以为空字符串 `""`。default 在三层均缺失时使用。
- `sensitive: true` → `/plugin:show` 渲染为 `***`，除非调用者持有 `plugin/show-secrets`
  能力且传入 `--show-secrets`。

---

## §3 — 解析算法

解析在 **session 创建时**进行（在 `Esr.Commands.Session.New` 或等效 session-bootstrap 调用内）。
解析结果以 `{session_id, plugin_name, key}` 为键存入 ETS，之后可通过 `Esr.Plugin.Config.get/2` 随时读取。

### 3.1 模块 `Esr.Plugin.Config`

```elixir
@spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
def resolve(plugin_name, opts \\ []) do
  username      = opts[:username]
  workspace_id  = opts[:workspace_id]

  schema   = load_schema(plugin_name)
  defaults = schema_defaults(schema)

  global        = read_global(plugin_name)
  user_layer    = if username,      do: read_user(plugin_name, username),      else: %{}
  project_layer = if workspace_id,  do: read_project(plugin_name, workspace_id), else: %{}

  # 逐 key 合并，右侧优先（Map.merge/2 语义）
  defaults
  |> Map.merge(global)
  |> Map.merge(user_layer)
  |> Map.merge(project_layer)
end
```

### 3.2 Session 创建集成

在 `Esr.Commands.Session.New.execute/1` 中，workspace 查找之后、PtyProcess spawn 之前：

```elixir
enabled_plugins = Application.get_env(:esr, :enabled_plugins, [])

Enum.each(enabled_plugins, fn plugin_name ->
  config = Esr.Plugin.Config.resolve(plugin_name,
    username: cmd["submitter"],
    workspace_id: workspace.id
  )
  Esr.Plugin.Config.store(session_id, plugin_name, config)
end)
```

### 3.3 合并语义 — 空字符串 vs 缺失 key

| 上层提供 key | 值 | 结果 |
|---|---|---|
| 存在 | `"http://proxy.local:8080"` | 该层胜出，代理生效 |
| 存在 | `""` | 该层胜出，代理显式清空（直连） |
| 不存在（key 缺失） | — | 穿透到下层或 schema default |

运营者若要让项目层"取消"全局代理，在项目层写 `http_proxy: ""`；
若对代理无意见则不写该 key，全局值自然传播。

---

## §4 — Slash 命令（colon-namespace）

四条命令均使用 `plugin:` namespace，符合审计 task 3 建议。
新增到 `runtime/priv/slash-routes.default.yaml`。

### 4.1 命令表

| Slash | 参数 | 默认层 | 行为 |
|---|---|---|---|
| `/plugin:set <plugin> key=value [layer=global\|user\|project]` | plugin, key, value, 可选 layer | global | 对 manifest schema 验证 key；原子写入；打印重启提示；使 ETS 缓存失效。 |
| `/plugin:unset <plugin> key [layer=…]` | plugin, key, 可选 layer | global | 从指定层删除 key；幂等（不存在时也返回成功）；原子写入；使缓存失效。 |
| `/plugin:show <plugin> [layer=effective\|global\|user\|project]` | plugin, 可选 layer, 可选 show_secrets | effective（合并后） | 渲染所有 key。Sensitive 值默认显示为 `***`，除非调用者有 `plugin/show-secrets` 能力且传 `--show-secrets`。 |
| `/plugin:list-config` | — | — | 显示所有 enabled plugin 的 effective config；sensitive 遮罩。 |

### 4.2 行为要点

**`/plugin:set`**
- 对不在 schema 中的 key 报错，不写入。
- 写入后调用 `Esr.Plugin.Config.invalidate(plugin_name)` 使 ETS 失效。
- 打印：`"config written: claude_code.http_proxy = \"…\" [global layer]\nrestart esrd to apply."`

**`/plugin:unset`**
- Key 在目标文件中不存在时，静默成功（幂等）。
- 写入后同样使缓存失效。

**`/plugin:show`**
- `layer=effective`（默认）：用调用者的 session 上下文（用户名来自 `cmd["submitter"]`；
  workspace_id 来自 chat 绑定的 workspace）调用 `Config.resolve/2`，渲染合并结果。
- `layer=global|user|project`：只渲染该层的原始 map，不做合并。
- Sensitive key 始终为 `***`，除非同时满足 cap + flag 两个条件。

---

## §5 — Shell 脚本删除计划

### 5.1 `scripts/esr-cc.sh` — 逐行清单

| 行号 | 内容 | 迁移目标 |
|---|---|---|
| 1-8 | 头注释、`set -euo pipefail` | 随文件删除 |
| 10-11 | `ESR_WORKSPACE` + `ESR_SESSION_ID` guard | BEAM 设置的 PtyProcess spawn env，不是 plugin config |
| 13-21 | `SCRIPT_DIR`、`REPO_ROOT`、`ESRD_INSTANCE`、`ESRD_HOME_DIR`、`WORKSPACES_YAML` | launchd plist 已有 `ESRD_HOME`、`ESRD_INSTANCE`，非 plugin config |
| 27 | `export PATH=...` | 移入 launchd plist `EnvironmentVariables` 或 Elixir spawn env |
| 30 | `source esr-cc.local.sh` | **删除。** 运营者覆盖移至 user 层 `plugins.config.yaml` |
| 33 | `source .mcp.env` | **删除。** Secrets 移至 `anthropic_api_key_ref`（引用 env var）|
| 36-39 | `yq` 存在检查 | Elixir workspace 查找无需 yq |
| 41-44 | `workspaces.yaml` 存在检查 | Elixir 已有 workspace 查找 |
| 46-67 | yq 解析 workspace root | 替换为 `Esr.Resource.WorkspaceRegistry.root_for/1` |
| 70-71 | `mkdir -p "$cwd"` | Elixir 在 spawn 前完成 |
| 74-85 | `ESR_ESRD_URL` → HTTP URL 推导 | Elixir PtyProcess 已知 HTTP endpoint；以 env var 传给 claude |
| 87-96 | `.mcp.json` 写入 | Elixir PtyProcess（或辅助模块）写入 |
| 99-106 | `session-ids.yaml` resume 查找 | 移入 Elixir；`--resume <id>` 作为 arg 传给 erlexec |
| 117-125 | `CLAUDE_FLAGS` 构建 | Elixir 构建参数列表，通过 erlexec `args:` 传入 |
| 124-125 | `settings_file` 查找 | Elixir 读 workspace role；传 `--settings` arg |
| 138-151 | `~/.claude.json` workspace-trust 预写 | Elixir 通过 `File.write/2` 在 spawn 前完成 |
| 155 | `exec claude ...` | erlexec PTY spawn 替代整个 shell |

**esr-cc.local.sh 5 行导出：**

| 导出变量 | 迁移目标 |
|---|---|
| `http_proxy=http://127.0.0.1:7897` | `/plugin:set claude_code http_proxy=http://127.0.0.1:7897 layer=user` |
| `https_proxy=http://127.0.0.1:7897` | `/plugin:set claude_code https_proxy=http://127.0.0.1:7897 layer=user` |
| `no_proxy=localhost,...` | `/plugin:set claude_code no_proxy=… layer=user` |
| `HTTP_PROXY=$http_proxy` | 同 http_proxy（大写别名，plugin 同时设置两者）|
| `HTTPS_PROXY=$https_proxy` | 同 https_proxy |

**esr-cc.local.sh.example 注释行（12-13）：**

| 变量 | 迁移目标 |
|---|---|
| `ESR_ESRD_URL=ws://127.0.0.1:4001` | `/plugin:set claude_code esrd_url=ws://… layer=user` |

### 5.2 引用 `esr-cc.sh` 的文件清单（须更新）

| 文件 | 行号 | 变更 |
|---|---|---|
| `runtime/lib/esr/entity/pty_process.ex` | 350 | `default_start_cmd/0` 指向 `esr-cc.sh`；替换为 Elixir 原生构建 claude 命令行 |
| `runtime/lib/esr/entity/unbound_chat_guard.ex` | 104 | 提示文本引用 `--start-cmd scripts/esr-cc.sh`；更新 |
| `runtime/test/esr/commands/workspace/info_test.exs` | 22 | fixture 用 `start_cmd: "scripts/esr-cc.sh"`；更新 |
| `runtime/test/esr/resource/workspace_registry_test.exs` | 20 | 同上 |
| `scripts/final_gate.sh` | 342 | `start_cmd=scripts/esr-cc.sh`；更新 |
| `tests/e2e/scenarios/07_pty_bidir.sh` | 48 | 注释提到 `esr-cc.sh chdir`；更新注释 |
| `docs/dev-guide.md` | 37, 212 | 第 37 行示例命令含 `start_cmd=scripts/esr-cc.sh`；第 212 行说明 `esr-cc.sh` 写 `session-ids.yaml`。两处均需更新为 Elixir 原生启动方式。 |
| `docs/cookbook.md` | 74 | `workspace add` 示例含 `--start-cmd scripts/esr-cc.sh`；更新为省略 `--start-cmd`（默认自动推导）。 |
| `docs/futures/todo.md` | 56 | TODO "Spec: agent (cc) startup config first-class" 引用了 `scripts/esr-cc.sh` 和 `scripts/esr-cc.local.sh`。Sub-phase D 落地后标记为 resolved。 |
| `docs/notes/pty-attach-diagnostic.md` | 177 | 引用 `scripts/esr-cc.sh` 的 workspace 预信任说明；更新或删除。 |

### 5.3 系统环境变量（保留在 launchd plist）

`ESRD_INSTANCE`、`ESRD_HOME` 保留在 launchd plist 中作为系统 env var。
`ANTHROPIC_API_KEY` 同样保留——plugin config 只存 `anthropic_api_key_ref`（引用字符串），
在 session 启动时由 Elixir 调用 `System.get_env/1` 解析实际值，不写入任何 yaml。

---

## §6 — E2E 迁移

### 6.1 `tests/e2e/scenarios/common.sh` 分析

该文件设置的所有 env var（`ESR_E2E_RUN_ID`、`ESRD_INSTANCE`、`ESRD_HOME`、
`MOCK_FEISHU_PORT` 等）全部是测试基础设施变量，**不迁移到 plugin config**。
`common.sh` 本身不 source `esr-cc.sh` 也不设置代理/API key 变量。

Sub-phase C 落地后，任何启动真实 `claude` 子进程的 e2e 测试都需要在实例的
`plugins.yaml` 中预置相关 plugin config key。为此在 `common.sh` 增加辅助函数：

```bash
seed_plugin_config() {
  local cfg_file="${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml"
  mkdir -p "$(dirname "${cfg_file}")"
  local proxy="${ESR_E2E_HTTP_PROXY:-}"
  local api_key_ref="${ESR_E2E_ANTHROPIC_KEY_REF:-\${ANTHROPIC_API_KEY}}"
  cat >> "${cfg_file}" <<YAML
config:
  claude_code:
    http_proxy: "${proxy}"
    https_proxy: "${proxy}"
    anthropic_api_key_ref: "${api_key_ref}"
YAML
}
```

### 6.2 逐场景影响

| 场景 | 直接引用 esr-cc.sh？ | 所需变更 |
|---|---|---|
| `01_single_user_create_and_end.sh` | 无 | 如启动真实 CC session，Sub-phase C 后需调用 `seed_plugin_config` |
| `02_two_users_concurrent.sh` | 无 | 同 01 |
| `04_multi_app_routing.sh` | 无 | 同 01 |
| `05_topology_routing.sh` | 无 | 同 01 |
| `06_pty_attach.sh` | 隐式（PtyProcess → esr-cc.sh） | Sub-phase D 后 PtyProcess 不再调用 esr-cc.sh；验证场景仍通过 |
| `07_pty_bidir.sh` | 第 48 行注释；隐式通过 session_new | 更新第 48 行注释；Sub-phase D 后验证场景通过 |
| `08_plugin_core_only.sh` | 无 | 无需变更 |
| `11_plugin_cli_surface.sh` | 无 | Sub-phase B 落地后增加 `/plugin:set`/`/plugin:unset`/`/plugin:show` 断言 |

### 6.3 Makefile / CI 影响

Makefile 不直接引用 `esr-cc.sh`；所有场景通过 `start_esrd` → `esrd.sh start` 启动 BEAM。
Sub-phase D 后整条链路无需 `esr-cc.sh`，**Makefile 本身不需修改**。
`scripts/final_gate.sh:342` 需更新（§5.2 已列出）。

---

## §7 — 实现分阶段

### Sub-phase A — Manifest + 存储扩展（约 200 LOC）

**目标：** schema 可解析；`plugins.yaml` 支持读写 `config:` 节；暂无用户可见 slash。

- `Esr.Plugin.Manifest`：增加 `config_schema` 字段；`parse/1` 读取并验证。
- `Esr.Plugin.PluginsYaml`：扩展 read/write 支持 config map。
- 新模块 `Esr.Plugin.Config`：`resolve/2`、`get/2`、`store/3`、`invalidate/1`；
  `Esr.Application.start/2` 创建 `:plugin_config_cache` ETS 表。

**独立可发布门控：** `Esr.Plugin.Config.resolve/2` 单元测试覆盖所有层组合后通过。

---

### Sub-phase B — Slash 命令（约 250 LOC）

**目标：** 运营者可通过 Feishu slash 命令设置/删除/查看 config。

**依赖：** Sub-phase A。

- 新增 `Esr.Commands.Plugin.SetConfig`、`UnsetConfig`、`ShowConfig`、`ListConfig`。
- 更新 `slash-routes.default.yaml`，加入四条 colon-namespace 路由。

**门控：** `/plugin:set claude_code http_proxy=http://test:8080` 写入 plugins.yaml；
`/plugin:show claude_code` 渲染该值；`/plugin:unset` 删除。

---

### Sub-phase C — claude_code 插件迁移（约 150 LOC + manifest 新增）

**目标：** `claude_code` 插件从 `Esr.Plugin.Config` 读取代理和 API key 配置，
不再依赖 shell env var。

**依赖：** Sub-phase A。

- 在 `claude_code/manifest.yaml` 加入 `config_schema:`（见 §2.4）。
- `Esr.Entity.PtyProcess` 或新模块 `Esr.Plugins.ClaudeCode.Launcher`：
  - 将 esr-cc.sh 中的 `.mcp.json` 写入、`--resume` 构建、`CLAUDE_FLAGS` 构建、
    workspace-trust 写入全部移入 Elixir。
  - 从 `Esr.Plugin.Config.get("claude_code", "http_proxy")` 读取值，作为
    erlexec spawn 的 `{:env, […]}` 传给子进程。
- Session 创建时调用 `Config.resolve` + `store`（§3.2）。

**门控：** 单元测试验证当 `plugins.yaml` 中设置 `http_proxy` 时，
`PtyProcess.build_env/1` 包含 `{"HTTP_PROXY", "…"}`。

---

### Sub-phase D — Shell 脚本删除 + E2E 更新（约 300 LOC 删除/修改）

**目标：** 删除 `esr-cc.sh` + `esr-cc.local.sh`；e2e 套件继续通过。

**依赖：** Sub-phase C（所有逻辑已迁移到 Elixir）。

- `git rm scripts/esr-cc.sh scripts/esr-cc.local.sh scripts/esr-cc.local.sh.example`
- 更新 §5.2 中列出的所有文件。
- 在 `tests/e2e/scenarios/common.sh` 加入 `seed_plugin_config` 函数。
- 更新 `CLAUDE.md` 及相关运营文档。

**门控：** `make e2e`（全六个场景）通过；尤其 `make e2e-07`（与 PtyProcess 耦合最深）。

---

### Sub-phase E — Feishu 插件迁移（可选，约 50 LOC）

**目标：** feishu 插件从 plugin config 读取 `log_level` 等可调参数。

**依赖：** Sub-phase A。

**门控：** feishu e2e 场景不受影响。如 feishu 今天无运营者可调参数，跳过本阶段。

---

## §8 — 风险登记

| # | 风险 | 概率 | 缓解措施 |
|---|---|---|---|
| R1 | 删除 `esr-cc.sh` 破坏 launchd plist / 运营者肌肉记忆 | 中 | Sub-phase D 合并前更新所有文档并发 Feishu 公告 |
| R2 | 项目层空字符串 vs 缺失 key 语义歧义 | 低 | Spec 明确：空字符串胜出（§3.3 表格）；单元测试覆盖空字符串场景 |
| R3 | `/plugin:set` 后 ETS 缓存陈旧 | 中 | 写入后同步调用 `invalidate/1`（§3.1）；运行中 session 的 config 在重启前保持不变（可接受） |
| R4 | Schema 漂移——运营者手动在 plugins.yaml 中写入未知 key | 低 | `/plugin:set` 写入时验证；启动时对 schema 外 key 发出 Logger.warning |
| R5 | Sensitive 值在日志中泄露 | 中 | `Esr.Plugin.Config` 模块不记录 sensitive 值；添加 `sanitize/1` 辅助函数在 debug 日志前遮罩 |
| R6 | 项目层 `.esr/plugins.config.yaml` 意外提交 secrets | 低 | Schema `sensitive: true` 描述字段明确警告；运营文档要求不在项目层写明文 key |
| R7 | 运营者脚本仍调用已删除的 `esr-cc.sh` | 低 | 文件删除后脚本立即报错，信号明确 |

---

## §9 — 测试计划

### 单元测试

| 测试 | 被测模块 | 断言 |
|---|---|---|
| Manifest parser 接受合法 `config_schema:` | `Esr.Plugin.Manifest` | `parse/1` 返回含 `declares.config_schema` map 的 struct |
| Manifest parser 拒绝缺少 `type` 的 schema 条目 | `Esr.Plugin.Manifest` | 返回 `{:error, {:config_schema_missing_field, …}}` |
| Manifest parser 拒绝未知 type `integer`（Phase 1）| `Esr.Plugin.Manifest` | 返回 `{:error, {:config_schema_unknown_type, …}}` |
| `resolve/2` 仅全局层 | `Esr.Plugin.Config` | 返回 defaults + global；user/project 缺失时不影响结果 |
| `resolve/2` user 层覆盖 global 一个 key | `Esr.Plugin.Config` | 该 key 用 user 值；其余 key 用 global 值 |
| `resolve/2` project 层覆盖 user + global | `Esr.Plugin.Config` | project 值在所有提供的 key 上胜出 |
| `resolve/2` project 层空字符串覆盖 global 非空 | `Esr.Plugin.Config` | `""` 胜出 `"http://proxy.test"` |
| `resolve/2` project 层缺失 key 不覆盖 global | `Esr.Plugin.Config` | global 值传播 |
| `/plugin:set` 对 schema 验证；拒绝未知 key | `Esr.Commands.Plugin.SetConfig` | 返回错误文本；plugins.yaml 不变 |
| `/plugin:set` 合法 key 写入正确文件 | `Esr.Commands.Plugin.SetConfig` | 读取目标文件可见更新后的 key |
| `/plugin:show` 不带 `--show-secrets` 遮罩 sensitive 值 | `Esr.Commands.Plugin.ShowConfig` | 输出包含 `***` |
| `/plugin:show --show-secrets` 需要 `plugin/show-secrets` cap | `Esr.Commands.Plugin.ShowConfig` | 无 cap 报错；有 cap 显示真实值 |
| `/plugin:unset` 对缺失 key 幂等 | `Esr.Commands.Plugin.UnsetConfig` | 返回 `:ok`；文件不变 |

### E2E 测试

| 测试 | 场景 | 门控 |
|---|---|---|
| 冒烟：CC agent 使用 plugin config 中设置的代理调用 Anthropic API | 新场景或 `07_pty_bidir.sh` 扩展 | `ESR_E2E_HTTP_PROXY` 设置 → session 解析 → PtyProcess 传 `HTTP_PROXY` env 给 claude 子进程 |
| 删除后回归：无 `esr-cc.sh` 时 `make e2e` 通过 | 全六个 Makefile 场景 | Sub-phase D 门控 |
| Plugin CLI 界面包含新 slash 命令 | `11_plugin_cli_surface.sh` | `/plugin:set`、`/plugin:unset`、`/plugin:show` 返回预期输出 |

---

## 待运营者确认的问题

1. **用户层路径**：`$ESRD_HOME/<inst>/users/<username>/plugins.config.yaml` 命名可以吗？
   还是倾向于 `plugins.yaml`（与全局文件同名）？

2. **项目层适用范围**：当前 spec 限定"仅 repo-bound workspace（有非空 `root:`）"才读项目层。
   ESR-bound workspace（无 git root，如 scratch workspace）是否也应读取其自身目录下的
   `.esr/plugins.config.yaml`？

3. **逐 key 还是整 map 合并**：spec 选择逐 key 覆盖（深合并），更灵活。
   另一选项是"项目层存在则替换整个 plugin block"（浅合并），更简单但灵活性差。确认选逐 key？

4. **Sensitive 遮罩行为**：`/plugin:show` 默认遮罩，解除遮罩需要 `plugin/show-secrets` 能力
   + `--show-secrets` flag。能力名 `plugin/show-secrets` 合适吗，还是折入 `plugin/manage`？
