# Spec：Colon-Namespace Slash 语法 — 完全切换

**日期：** 2026-05-07
**分支：** `spec/colon-namespace-grammar`
**状态：** 等待用户审核 — 尚未开 PR

---

## §1 — 范围与动机

ESR 当前的 slash 入口混用三种分隔符：dash（`/new-session`、`/list-agents`）、空格
（`/workspace info`、`/plugin install`）、和无分隔符裸动词（`/help`、`/attach`）。
这种不一致性在 `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` Cross-cutting 第 1 条
中被明确指出：

> "最主要的 grammar 不匹配来源。ESR 的 slash 语法今天混用了 dash、空格、和无分隔符三种形式。
> 统一的 `<group>:<verb>` 形式能降低操作者的记忆负担，并让多个提案中的 slash 不需要
> 功能改动就能直接工作。"

bootstrap journey 审计的第 8、9、10、12 步全部在 Grammar 维度失分，原因是操作者的自然期望
——`/session:new`、`/workspace:add`、`/agent:add`、`/agent:inspect`——与已发布形式不匹配。

本 spec 将用户于 **2026-05-06（Feishu）锁定** 的决策翻译为完整实现计划。锁定的决策在下文
直接引用，不重新讨论。

**不在范围内：** escript `esr` 子命令语法（`esr workspace list`、`esr cap grant` 等）
**不改变**。该入口通过 `Esr.Cli.Main` catch-all 路由到 `parse_admin_flags/4`，将 token
拼接为 `kind_subaction` 内部 kind 名——从不构造 slash 字符串。colon-namespace 变更仅
适用于 slash 入口（以 `/` 开头的操作者消息，经由 `Esr.Entity.SlashHandler` 分发）。
已通过阅读 `runtime/lib/esr/cli/main.ex:186-199` 确认。

---

## §2 — 入口清单

### 锁定的决策（用户 2026-05-06）

1. **完全切换，无 alias。** 旧 grammar 全部删除。Ship 之后，旧形式的输入返回结构化 error，
   提示新形式。这不是 alias——它是一次性的切换辅助工具。
2. **多动词资源在 verb 部分保留 dash。** `/workspace add-folder` 变为
   `/workspace:add-folder`，不是 `/workspace:addFolder` 也不是 `/workspace:folder add`。
3. **没有 deprecation 期。** 一次 ship，硬切换。

### 裸动词决策（spec 作者，2026-05-07）

以下两个裸动词命令需要不在锁定决策范围内的策略决定：

- `/help` — meta-system；无资源组。
- `/doctor` — meta-system；无资源组。

**决策：** `/help` 和 `/doctor` 保留无冒号形式（bare）。这两个是 meta-system 命令，
不操作资源组。给它们加 `/meta:` 前缀会显得生硬，且会破坏操作者发现所有其他命令时最常用
命令的肌肉记忆。其它所有命令均采用冒号形式。

其余有资源关联的裸动词：

| 裸形式 | 组归属推理 | 新形式 |
|---|---|---|
| `/attach` | 连接到 session | `/session:attach` |
| `/sessions` | 列出 sessions | `/session:list` |
| `/key` | 向 session PTY 发送按键 | `/session:key` |
| `/whoami` | 身份 — user 资源 | `/user:whoami` |
| `/list-agents` | 列出 agents | `/agent:list` |
| `/actors` | 列出 live actor peers（诊断） | `/actor:list` |
| `/new-workspace` | workspace 资源 | `/workspace:new` |
| `/new-session` | session 资源 | `/session:new` |
| `/end-session` | session 资源 | `/session:end` |

### 完整清单表

yaml 中 30 个 primary slash 入口 + 5 个 alias 入口 = 共 35 个有名形式需要迁移。

| 旧形式 | 新形式 | 规则 |
|---|---|---|
| `/help` | `/help` | 裸 meta — 保留原样（见 §2 裸动词决策） |
| `/doctor` | `/doctor` | 裸 meta — 保留原样（见 §2 裸动词决策） |
| `/whoami` | `/user:whoami` | 裸动词 → 冒号，推断 group=user |
| `/key` | `/session:key` | 裸动词 → 冒号，推断 group=session（PTY 属于 session） |
| `/new-workspace` | `/workspace:new` | dash → 冒号，group=workspace，verb=new |
| `/workspace list` | `/workspace:list` | 空格 → 冒号 |
| `/workspace edit` | `/workspace:edit` | 空格 → 冒号 |
| `/workspace add-folder` | `/workspace:add-folder` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace remove-folder` | `/workspace:remove-folder` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace bind-chat` | `/workspace:bind-chat` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace unbind-chat` | `/workspace:unbind-chat` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace remove` | `/workspace:remove` | 空格 → 冒号 |
| `/workspace rename` | `/workspace:rename` | 空格 → 冒号 |
| `/workspace use` | `/workspace:use` | 空格 → 冒号 |
| `/workspace import-repo` | `/workspace:import-repo` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace forget-repo` | `/workspace:forget-repo` | 空格 → 冒号，verb 中 dash 保留 |
| `/workspace info` | `/workspace:info` | 空格 → 冒号 |
| `/workspace describe` | `/workspace:describe` | 空格 → 冒号 |
| `/workspace sessions` | `/workspace:sessions` | 空格 → 冒号（按 workspace 列出 sessions） |
| `/sessions` | `/session:list` | 裸 alias → primary 冒号形式，group=session |
| `/list-sessions`（`/sessions` 的 alias） | 删除——由 `/session:list` 覆盖 | alias 按锁定决策 1 删除 |
| `/new-session` | `/session:new` | dash → 冒号，group=session，verb=new |
| `/session new`（`/new-session` 的 alias） | 删除——由 `/session:new` 覆盖 | alias 按锁定决策 1 删除 |
| `/end-session` | `/session:end` | dash → 冒号，group=session，verb=end |
| `/session end`（`/end-session` 的 alias） | 删除——由 `/session:end` 覆盖 | alias 按锁定决策 1 删除 |
| `/list-agents` | `/agent:list` | dash → 冒号，group=agent，verb=list |
| `/actors` | `/actor:list` | 裸动词 → 冒号，推断 group=actor |
| `/list-actors`（`/actors` 的 alias） | 删除——由 `/actor:list` 覆盖 | alias 按锁定决策 1 删除 |
| `/attach` | `/session:attach` | 裸动词 → 冒号，推断 group=session |
| `/plugin list` | `/plugin:list` | 空格 → 冒号 |
| `/plugin info` | `/plugin:info` | 空格 → 冒号 |
| `/plugin install` | `/plugin:install` | 空格 → 冒号 |
| `/plugin enable` | `/plugin:enable` | 空格 → 冒号 |
| `/plugin disable` | `/plugin:disable` | 空格 → 冒号 |

**Slash 数量：** yaml 中 30 个 primary 入口（已验证：`grep -c '^  "/' runtime/priv/slash-routes.default.yaml` 返回 30）。迁移后：30 个 primary 入口，0 个 alias。

### 已删除的 alias（由新 primary 覆盖，无替换）

| 删除的 alias | 由哪个新形式覆盖 |
|---|---|
| `/list-sessions` | `/session:list` |
| `/session new` | `/session:new` |
| `/session end` | `/session:end` |
| `/list-actors` | `/actor:list` |

---

## §3 — 实现计划

### 3.1 `runtime/priv/slash-routes.default.yaml`（约 80 处 key 编辑）

将所有 30 个 primary slash key 重写为冒号形式。删除所有 `aliases:` 字段（按锁定决策
1——完全切换，无 alias）。`schema_version` 保持为 1；yaml 结构不变，只有 key 字符串变化，
无需 schema 改动。

估计工作量：机械操作；约 500 行中约 80 处字符串编辑。

### 3.2 `runtime/lib/esr/resource/slash_route/registry.ex`

**匹配逻辑分析：** registry 使用 `keys_in_text/1`，按空白符（`~r/\s+/`）分割，不按
冒号分割。`/session:new` 这样的冒号 key 会被当作单个 token，这是正确的——冒号形式不需要
多词分割。`slash_head/1` 同样按空白符分割，对于 `/session:new workspace=foo name=bar`
这样的输入，会正确提取 `/session:new` 作为头部。

**结论：** `registry.ex` 无需任何逻辑改动。ETS 支持的 lookup 接受任意字符串 key；用
`/session:new` 替换 `/new-session` 作为 key 是透明的。

**补丁范围：** 0 逻辑 LOC。只有 yaml（§3.1）改变 key 字符串。

### 3.3 `runtime/lib/esr/resource/slash_route/file_loader.ex`

**分析：** `validate_slash_key/1` 仅验证 key 以 `/` 开头（第 127-128 行）。
`/session:new` 这样的冒号形式仍以 `/` 开头，验证器接受，无需改动。

**结论：** 无需改动。

### 3.4 `runtime/lib/esr/entity/slash_handler.ex` — deprecated_slash 切换辅助

**分析：** `strip_slash_prefix/2` 从用户输入文本中去掉匹配的 `route.slash` 前缀，
使用 `String.split(trimmed, slash, parts: 2)`。对于冒号形式，这正确工作，因为 slash
key 是单个无空格 token。

**新增要求：** 添加硬编码 `@deprecated_slashes` map，捕获旧形式输入并返回结构化 error。
这**不是** alias——只有当 lookup 对已知旧名返回 `:not_found` 时触发，每次调用返回一个
结构化 error。

在 `handle_cast/2` 的 `:not_found` 分支之后添加：

```elixir
@deprecated_slashes %{
  "/new-session"       => "/session:new",
  "/session new"       => "/session:new",
  "/end-session"       => "/session:end",
  "/session end"       => "/session:end",
  "/sessions"          => "/session:list",
  "/list-sessions"     => "/session:list",
  "/workspace sessions"=> "/workspace:sessions",
  "/workspace list"    => "/workspace:list",
  "/workspace edit"    => "/workspace:edit",
  "/workspace add-folder"    => "/workspace:add-folder",
  "/workspace remove-folder" => "/workspace:remove-folder",
  "/workspace bind-chat"     => "/workspace:bind-chat",
  "/workspace unbind-chat"   => "/workspace:unbind-chat",
  "/workspace remove"  => "/workspace:remove",
  "/workspace rename"  => "/workspace:rename",
  "/workspace use"     => "/workspace:use",
  "/workspace import-repo"   => "/workspace:import-repo",
  "/workspace forget-repo"   => "/workspace:forget-repo",
  "/workspace info"    => "/workspace:info",
  "/workspace describe"=> "/workspace:describe",
  "/new-workspace"     => "/workspace:new",
  "/list-agents"       => "/agent:list",
  "/actors"            => "/actor:list",
  "/list-actors"       => "/actor:list",
  "/attach"            => "/session:attach",
  "/whoami"            => "/user:whoami",
  "/key"               => "/session:key",
  "/plugin list"       => "/plugin:list",
  "/plugin info"       => "/plugin:info",
  "/plugin install"    => "/plugin:install",
  "/plugin enable"     => "/plugin:enable",
  "/plugin disable"    => "/plugin:disable"
}
```

`:not_found` 分支变为：

```elixir
:not_found ->
  old = slash_head(text)
  case Map.get(@deprecated_slashes, old) ||
       Map.get(@deprecated_slashes, two_token_head(text)) do
    nil ->
      Esr.Slash.ReplyTarget.dispatch(target, {:text, "unknown command: #{old}"}, ref)
    new_name ->
      Esr.Slash.ReplyTarget.dispatch(
        target,
        {:error, %{
          "type"    => "deprecated_slash",
          "old"     => old,
          "new"     => new_name,
          "message" => "slash command renamed; use #{new_name}"
        }},
        ref
      )
  end
  {:noreply, state}
```

其中 `two_token_head/1` 提取前两个空白分隔 token（用于检测 `/workspace info` 等旧空格形式）。

**生命周期：** `@deprecated_slashes` map 存活至少一个 release。删除由单独 PR 完成。

**估计 LOC：** 约 45 LOC 新增。

### 3.5 `runtime/lib/esr/commands/help.ex`

`render/0` 调用 `Esr.Resource.SlashRoute.Registry.list_slashes/0` 并直接渲染
`route.slash`。yaml 更新后，`route.slash` 已经是 `/session:new`、`/workspace:list` 等。
无需改动渲染逻辑。

`/doctor` 在 help 脚注中以裸形式引用，这是保留形式，无需改动。

**结论：** `help.ex` 无需改动（假设 yaml key 已更新）。

### 3.6 `runtime/lib/esr_web/controllers/slash_schema_controller.ex`

Controller 调用 `Registry.dump/1`，后者原样序列化 `route.slash` 字段。yaml 更新后，
JSON 输出将自动输出冒号形式。无需改动 controller。

schema version 保持为 `1`。

### 3.7 `runtime/test/` — 含 slash 字面量的测试文件

以下测试文件将 slash 名构造为字面字符串，需要更新：

| 文件 | 需要更新的字面量 |
|---|---|
| `runtime/test/esr/entity/slash_handler_dispatch_test.exs` | `/sessions`、`/list-sessions`、`/help`、`/new-workspace`、route 辅助函数 |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | `/help`、`/sessions`、`/list-sessions`、`/workspace`、`/workspace info`、`/new-session` |
| `runtime/test/esr/commands/help_test.exs` | `/help`、`/sessions`、`/new-session` |
| `runtime/test/esr/integration/new_session_smoke_test.exs` | `/new-session` |
| `runtime/test/esr/integration/feishu_slash_new_session_test.exs` | `/new-session` |
| `runtime/test/esr/plugins/feishu/feishu_app_adapter_test.exs` | `/help`、`/whoami`、`/doctor`、`/new-workspace` |

需要新增两个单元测试文件：

1. `runtime/test/esr/resource/slash_route/colon_form_test.exs` — 验证 yaml 中所有冒号
   形式正确加载，并通过 `Registry.lookup/1` 正确解析。
2. `runtime/test/esr/entity/deprecated_slash_test.exs` — 验证 `@deprecated_slashes` 中
   每个 key 返回含正确 `new` 字段的 `deprecated_slash` error。

**估计 LOC：** 已有测试约 80 LOC 编辑；新测试约 50 LOC。

### 3.8 `docs/` — 含旧 slash 名的文档

以下文档引用了旧 slash 名，需要机械更新：

- `docs/dev-guide.md`
- `docs/cookbook.md`
- `docs/futures/channel-client-phx-py-alignment.md`
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` 及 `.zh_cn.md`
- `docs/operations/dev-prod-isolation.md`
- `docs/notes/2026-05-06-scenarios-deletion-and-python-cli-removal.md`
- `docs/notes/2026-05-05-cli-channel-migration.md`
- `docs/notes/erlexec-worker-lifecycle.md`
- `docs/guides/writing-an-agent-topology.md`
- `docs/principles/01-e2e-faces-production.md`
- `docs/superpowers/progress/` 文件（历史笔记；就地添加更正注记）
- `docs/superpowers/plans/` 文件（历史笔记；就地添加更正注记）

**估计 LOC：** 文档中约 40 行编辑。

---

## §4 — 迁移说明

### 操作者升级

所有操作者与部署同步升级。不存在滚动升级路径——按锁定决策 3，没有 deprecation 期。
`@deprecated_slashes` map 提供一个 release 的宽限窗口，旧名称产生可操作的 error
而不是 `unknown command`。

### Adapter sidecar 验证

Adapter sidecar（Feishu、未来的 Telegram）不直接构造 slash 名称——它们透传用户输入的
原始文本。已通过阅读 `runtime/lib/esr/entity/slash_handler.ex` 确认：dispatch 路径接收
原始 `envelope["payload"]["text"]` 或 `envelope["payload"]["args"]["content"]`，并对其
调用 `Registry.lookup(text)`。Adapter 是透明的。

### Plugin manifest 验证

Plugin manifest（`runtime/lib/esr/plugins/*/manifest.yaml`）不固定 slash 名称。已通过
grep 确认：`grep -rn 'slash\|/new-session\|/plugin\|/workspace' runtime/lib/esr/plugins/*/manifest.yaml`
无匹配。Plugin manifest 声明 `name`、`description`、`agents`、`required_env` 等字段，
无一引用 slash 命令字符串。

### E2E scenario 验证

E2E scenario（`tests/e2e/scenarios/*.sh`）通过 admin queue 使用内部 kind 名称调用
runtime（`esr admin submit session_new`、`esr admin submit session_end`、
`esr admin submit plugin_list` 等）——**不**使用 slash 文本。已通过阅读
`tests/e2e/scenarios/01_single_user_create_and_end.sh:33-43` 和
`tests/e2e/scenarios/11_plugin_cli_surface.sh:51-57` 确认。

**结论：** slash grammar 变更无需更新任何 e2e scenario 文件中的功能代码。

需要更新注释的 e2e scenario 文件：
- `tests/e2e/scenarios/common.sh`
- `tests/e2e/scenarios/01_single_user_create_and_end.sh`
- `tests/e2e/scenarios/02_two_users_concurrent.sh`

---

## §5 — 风险登记

### 风险 1：本 repo 之外的脚本或文档引用旧名称

**概率：** 中。操作者可能在 Feishu 聊天历史或本地脚本中保存了 `/new-session` 等。

**缓解：** `@deprecated_slashes` map 对每个已删除名称产生结构化 error
`{"type": "deprecated_slash", "old": ..., "new": ..., "message": "slash command renamed; use <new>"}`。
操作者第一次使用时收到可操作的错误提示。

### 风险 2：在途分支将 slash 名构造为字符串字面量

**概率：** 低中。任何添加了 `/new-session` 或 `/workspace info` 字面量测试的分支在
合并时都会冲突。

**缓解：** 在当前在途分支（`feature/t12-channel-server-detach-notification`）合并进
`dev` 之后再落地本 PR。如果分支必须并发合并，在本 PR 落地后 rebase 并更新其 slash
字面量。

### 风险 3：Feishu 聊天历史——操作者滚动翻回旧形式消息重新执行

**概率：** 中。Feishu 显示消息历史；旧的 `/new-session` 消息仍然可见。

**缓解：** 同风险 1——`@deprecated_slashes` 切换辅助对旧形式输入触发。

### 风险 4：Registry lookup 多词前缀候选生成与冒号形式 key

**概率：** 无（by design）。`registry.ex:307-315` 中的 `keys_in_text/1` 通过按空白
分割并组合子集来生成候选。对于 `/session:new`，只有一个空白分隔 token，候选列表为
`["/session:new"]`。ETS lookup 直接找到它。空白分割前缀逻辑对冒号形式无关且无害。

---

## §6 — 测试计划

### 单元测试（新增）

**文件：** `runtime/test/esr/resource/slash_route/colon_form_test.exs`

覆盖：
- 每个冒号形式 slash key 通过 `Registry.lookup/1` 解析到预期的 kind。
  抽检：`/session:new`、`/workspace:add-folder`、`/plugin:enable`、`/agent:list`、
  `/actor:list`、`/user:whoami`、`/session:attach`、`/session:key`。
- `/help` 和 `/doctor` 仍然解析（保留裸形式）。
- 旧形式 key（`/new-session`、`/workspace info`）迁移后返回 `:not_found`。

**文件：** `runtime/test/esr/entity/deprecated_slash_test.exs`

覆盖：
- `@deprecated_slashes` 中每个 key，dispatch 旧形式时返回 `type == "deprecated_slash"`
  且 `new == <预期新形式>` 的 reply。
- 带尾部参数的完整旧形式输入（如 `/new-session esr-dev name=x`）被正确处理：提取
  `/new-session` 作为头部并返回正确 error。
- 旧的两 token 形式（`/workspace info`、`/plugin list`）产生正确 error。

### 单元测试（更新）

- `registry_test.exs` — 将所有 fixture slash key 从旧形式更新为冒号形式。
- `slash_handler_dispatch_test.exs` — 更新所有 route/envelope 辅助函数为冒号形式。
- `help_test.exs` — 更新 route fixture 为冒号形式；断言渲染输出显示冒号名称。
- `new_session_smoke_test.exs` 和 `feishu_slash_new_session_test.exs` — 将所有
  `/new-session` 字面量替换为 `/session:new`。
- `feishu_app_adapter_test.exs` — 替换 `/new-workspace`、`/whoami`（注意：`/help` 和
  `/doctor` 保留裸形式；只有 `/whoami` 改为 `/user:whoami`）。

### E2E 测试（代表性 scenario）

grammar 变更不影响 e2e scenario（它们使用内部 kind 名称）。以下两个代表性 scenario
应在所有代码改动落地后继续通过：

1. `tests/e2e/scenarios/01_single_user_create_and_end.sh` — 通过 admin queue 的
   session 生命周期（基于 kind，不受 slash 重命名影响）。
2. `tests/e2e/scenarios/08_plugin_core_only.sh` — plugin admin 入口；该 scenario 使用
   基于 kind 的提交，不使用 slash 文本，因此验证命令模块在重命名后仍然正常工作。

---

## §7 — spec 作者做出的决策汇总

以下微观决策是在 spec 撰写过程中做出的，**不在**用户锁定范围内。请用户确认：

1. **`/help` 和 `/doctor` 保留裸形式。** 备选：`/meta:help`、`/meta:doctor`。
   spec 作者选择裸形式，因为这两个是操作者用来发现所有其他命令的命令；给它们加冒号
   前缀在最关键的发现时刻增加了摩擦。

2. **`/sessions` → `/session:list`（不是 `/session:sessions`）。** primary 形式
   `/sessions` 是一个 list 动作；冒号形式规范化为 verb `list`。

3. **`/actors` → `/actor:list`。** 使用单数 `actor` 组名；yaml 使用
   `category: "诊断"` 但功能上的组是 `actor`。

4. **`/key` → `/session:key`。** `/key` 命令向 chat 当前绑定 session 的 PTY 发送按键。
   组是 `session`，因为目标始终是 session 的 PTY。

5. **`/workspace sessions` → `/workspace:sessions`（不是 `/session:list workspace=<n>`）。**
   保留语义区分：`/session:list` 列出当前 chat 绑定 workspace 的 sessions，而
   `/workspace:sessions` 接受显式 workspace 参数。

6. **`@deprecated_slashes` 生命周期：至少一个 release，删除通过单独 PR 完成。**
   spec 未设定硬性截止日期；后续 PR 标题 `chore: remove deprecated_slash map`
   是预期的删除载体。
