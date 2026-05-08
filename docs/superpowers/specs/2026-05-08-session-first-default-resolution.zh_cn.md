# Session-first 默认解析 — 设计

**日期：** 2026-05-08
**状态：** spec rev-1（用户 2026-05-07 已批准框架；等 rev-1 review）
**配套文件：** [`2026-05-08-session-first-default-resolution.md`](2026-05-08-session-first-default-resolution.md)
**驱动审计：** [`docs/manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md`](../../manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md) §3 心智模型 gap + 步骤 9
**相关：** [`docs/notes/concepts.md`](../../notes/concepts.md) tetrad 元模型；[`docs/futures/todo.md`](../../futures/todo.md) "Migrate to session-first model"

## 一、目标

操作员（飞书 / CLI）按 **session** 词汇描述工作，而非 workspace 词汇。本 spec 落地后，审计步骤 9 的路径

```
/session:new                          # 不需要预先建 workspace
/workspace:add-folder path=/foo       # name= 默认 chat-current
/session:add-agent type=cc name=alice
```

在"单 user 单 workspace" 这种最常见场景下**不需要敲 workspace 名**，多 workspace 高级用户**仍可以显式指定**。

## 二、非目标

- 删除 `Esr.Resource.Workspace.*` 资源层。Workspace 按 tetrad 元模型仍是 first-class Resource。
- 删 `/workspace:*` slash。它们继续作为显式注册管理入口。
- per-session view 修改（独立于 workspace 直接改 scope 视图的 `/session:add-folder`）。本 spec 之外，单独追踪。
- Plugin install-by-name registry。`docs/futures/todo.md` 跟踪。
- 把所有 slash 改为 session-first。最小充要变化是 `resolve_workspace` fallback 链 + `/user:use` + add-folder name fallback。

## 三、已锁定的设计决策（飞书 2026-05-07）

| ID | 决策 | 来源 |
|---|---|---|
| D1 | 用 **per-user default** 替代 system `default` workspace | "user default workspace 替代 system default … 可行" |
| D2 | 新 fallback 链：explicit arg → chat-default → user-default → error | "fallback chain（新）chat → user → error" |
| D3 | `Esr.Commands.User.Add` 自动创建 `<username>-default` workspace + 标为 user-default | "P2 选 a — auto-create" |
| D4 | `Esr.Resource.Workspace.Bootstrap` 不再创建名为 `default` 的 workspace。Bootstrap user 拿到 `<bootstrap_user>-default` | "Bootstrap 路径改造" |
| D5 | `/workspace:add-folder name=` 缺省时 fallback 到 chat-current 绑定的 workspace | "C+: add-folder name= 默认 chat-current" |
| D6 | 既有 on-disk `default` workspace 状态：**删除**（不做 migration）。操作员通过 `tools/wipe-esrd-home.sh` 清场。2026-05-07 批准："目前从未部署使用，请帮我删除清空" | 2026-05-08 实环境清空 `~/.esrd` + `~/.esrd-dev` 已执行 |

## 四、架构

### 4.1 元模型对齐

`docs/notes/concepts.md` tetrad：Scope 是 Session 的运行实例；Resource（如 workspace）被 Scope 通过 membership 引用。元模型层无 "default Resource" 概念 — 所有 fallback 都是操作 UX 层。

本 spec 规则：**fallback 优先用系统手头最特定的绑定**。特定性阶梯：

```
explicit arg     ← 操作员敲了
chat-default     ← /workspace:use 给这个 chat 设的
user-default     ← /user:use 给这个 user 设的
（无 fallback）   ← error: no_workspace_resolvable
```

删除 system 这一层和元模型对齐：default 不是 system 的属性，它是 Entity（user）或 Scope（chat）的属性。

### 4.2 新 primitive：User → default workspace 映射

`Esr.Entity.User.Registry`（struct 已有 `:username` + `:feishu_ids`；加 `:default_workspace_id`）：

```elixir
# user.json schema 加：
#
#   {
#     "username": "linyilun",
#     "feishu_ids": ["ou_xxx"],
#     "default_workspace_id": "<uuid>"     // 新
#   }

@spec set_default_workspace(username :: String.t(), ws_id :: String.t()) ::
        :ok | {:error, :not_found | :workspace_gone}

@spec get_default_workspace(username :: String.t()) ::
        {:ok, ws_id :: String.t()} | :not_found
```

ETS-backed（镜像 `ChatScope.Registry.get/set_default_workspace` 今天做法）。持久化到 `Esr.Paths.user_json(user_uuid)` — 既有 helper 在 `runtime/lib/esr/paths.ex:69-70`。

**存储布局其实已经半设计好了：** `runtime/lib/esr/paths.ex:60-74` 字面文档说：
- `users_dir/0` 是 "Top-level dir for user-default workspaces"
- `user_workspace_json/1` 是 "Path to workspace.json for the user-default workspace"

metamodel-aligned-esr 迁移（Phase 1-1b）凿出了这个存储槽，但 `default_workspace_id` 字段从来没穿过 `User.Registry`。本 spec 完成这个穿线。不发明新目录布局。

### 4.3 新 slash：`/user:use workspace=<name>`

对称 `/workspace:use`。设提交 user 的默认 workspace。`name` → workspace_id 通过 `Workspace.NameIndex` 解析后写入 `User.Registry`。

```yaml
"/user:use":
  kind: user_use
  permission: "workspace.create"
  command_module: "Esr.Commands.User.Use"
  requires_workspace_binding: false
  requires_user_binding: true
  category: "Users"
  description: "设当前 user 的 default workspace（per-user 偏好；/session:new fallback 链中 user-default 这一层）"
  args:
    - { name: workspace, required: true }
```

### 4.4 `Esr.Commands.User.Add` 联动建 user-default workspace

今天：`/user:add <username>` 只写 `users.yaml`。

之后：同样写 `users.yaml`，**外加** 创建一个名叫 `<username>-default` 的 workspace（owner = 新 user，location = `{:esr_bound, <esrd>/default/workspaces/<username>-default}`），并设为新 user 的 `default_workspace_id`。单事务；部分失败回滚。

```elixir
# 伪代码（Esr.Commands.User.Add）
with :ok          <- write_user_yaml(name, args),
     {:ok, ws_id} <- create_user_default_workspace(name),
     :ok          <- User.Registry.set_default_workspace(name, ws_id) do
  {:ok, %{
    "action"               => "added",
    "username"             => name,
    "default_workspace_id" => ws_id,
    "default_workspace"    => "#{name}-default"
  }}
end
```

### 4.5 `Esr.Resource.Workspace.Bootstrap` 重写

今天（`runtime/lib/esr/resource/workspace/bootstrap.ex`）：如果不存在则创建一个名字字面量是 `default` 的 workspace。

之后：

1. 读 `ESR_BOOTSTRAP_PRINCIPAL_ID`（既有 env）
2. 通过 `Esr.Entity.User.Registry` 把 principal_id 解析成 user（必须已经通过 env-driven bootstrap 路径存在；如果没有就早 return — 让 `/user:add` 处理）
3. 如果该 user 还没有 default workspace：创建 `<bootstrap_user>-default` 并设为他的 default

字面量名 `default` 不再保留。如果操作员就想要叫 `default` 的 workspace，可以 `/workspace:new name=default`，那就是个普通 ws。

### 4.6 `Esr.Commands.Scope.New.resolve_workspace` 重写

今天的链（`runtime/lib/esr/commands/scope/new.ex:325-339`）：

```
1. explicit args["workspace"]
2. chat-default via ChatScope.Registry.get_default_workspace
3. workspace_exists?("default") → fallback "default"
4. :no_match
```

之后：

```
1. explicit args["workspace"]
2. chat-default via ChatScope.Registry.get_default_workspace
3. user-default via User.Registry.get_default_workspace
4. :no_match → error: no_workspace_resolvable
```

Tag 元组变为 `{:explicit, name}` / `{:chat_default, name}` / `{:user_default, name}` / `:no_match`。

第 4 步的错误信息改为：

```
no_workspace_resolvable:
  workspace 未指定，chat 没设 default，提交 user 也没 user-default。
  跑 `/user:use workspace=<name>` 设一个，或显式传 `workspace=<name>`。
```

### 4.7 `/workspace:add-folder name=` fallback

今天（`runtime/lib/esr/commands/workspace/add_folder.ex:29-30`）：`name` 必填。

之后：`name` 变为可选。解析：

1. `args["name"]` 给了就用
2. 否则：`ChatScope.Registry.get_default_workspace(chat_id, app_id)` → workspace 名
3. 否则：`User.Registry.get_default_workspace(submitting_user)` → workspace 名
4. 否则：`{:error, %{"type" => "no_workspace_target"}}`

复用同一个链作为 Scope.New 的私有 helper `Esr.Commands.Workspace.Resolve.workspace_for_args/1`，两边一致。

## 五、数据流示例

### 5.1 第一次操作员（单 user 单 chat）

```
admin 设 ESR_BOOTSTRAP_PRINCIPAL_ID=ou_alice（env）
esrd 启动
   → Capability.Supervisor 给 ou_alice 写 admin grant
   → Workspace.Bootstrap 等 — alice 还没在 users.yaml 里
   → 不创建 system "default" workspace（Δ vs 今天）

alice 打开飞书，DM 里 /user:add alice
   → User.Registry.put({alice, [ou_alice]})
   → User.Add 自动建 "alice-default" workspace（owner=alice）
   → User.Registry.set_default_workspace("alice", ws_id)

alice：/session:new
   → 解析链：无 explicit、无 chat-default、user-default = alice-default
   → 在 alice-default workspace 上 spawn scope

alice：/session:add-agent type=cc name=helper
   → 在 per-session AgentSupervisor (M-2.6) 下 spawn (CC, PTY)
```

3 步。操作员不需要建任何 workspace。

### 5.2 多 workspace 操作员

```
alice 有 alice-default + esr-dev + kanban（通过 /workspace:new 建的）

alice 在 chat A：/workspace:use workspace=esr-dev
   → ChatScope.Registry 把 chat A → esr-dev

alice 在 chat A：/session:new
   → 解析：无 explicit，chat-default = esr-dev，胜
   → 在 esr-dev 上 spawn scope

alice 在 chat B：/session:new
   → 解析：无 explicit，无 chat-default，user-default = alice-default，胜
   → 在 alice-default 上 spawn scope（跨 chat 一致性）
```

### 5.3 多 user 共享 chat

```
chat C 通过 /workspace:use 绑到 alice-default（alice 跑的）
bob 进 chat C：/session:new
   → submitting_user = bob
   → 解析：无 explicit，chat-default = alice-default — 等等，那是 alice 的 ws
```

**开放问题（P3 — 需决策）：** 多 user chat 中，chat-default 会盖过 user-default 吗？两种姿态：

- **姿态 A — chat-default 胜（spec rev-1 选这个）：** 简单；和今天 per-chat 语义一致。bob 在 alice 的 workspace 跑 session，需要 alice 给 `workspace:alice-default/session:create` 授权。
- **姿态 B — user-default 胜（备选）：** 每个 user 始终在自己的 workspace 中。bob 的 session 在 bob-default 中跑。多 user chat 变成"每个人在自己的 scope，共享 chat"。和今天 chat-centric 模型分歧。

**spec rev-1 选姿态 A**，理由是和既有 chat-default 语义一致，避免给 bob 创建一个新 workspace 的惊喜。如果未来多 user 共享 chat 真的有摩擦，再单 spec 重新审视。

## 六、迁移

按 D6：既有 `~/.esrd*/default/workspaces/default/workspace.json` 等旧状态在 2026-05-08 已 wipe（实环境，prod + dev 两个 instance）。生产备注：未来跑这段代码的部署在 first boot 前用 `tools/wipe-esrd-home.sh` 清掉既有 `default` workspace。脚本 docstring 已涵盖。

`tools/wipe-esrd-home.sh` 更新一段说明，提到本 spec 也 bump 了 bootstrap 行为（无 op 改名 — 脚本不 care，反正全删）。

## 七、测试矩阵

加 / 改（按文件 LOC 估算）：

| 文件 | 内容 | LOC |
|---|---|---:|
| `runtime/test/esr/entity/user/registry_test.exs` | 新 `set/get_default_workspace` 测试 | +60 |
| `runtime/test/esr/commands/user/add_test.exs` | 断言自动创建 workspace + user-default link | +40 |
| `runtime/test/esr/commands/user/use_test.exs`（新） | `/user:use` happy + error path | +80 |
| `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs` | 重写 fallback 链测试；加 user-default branch | +60 |
| `runtime/test/esr/commands/workspace/add_folder_test.exs` | 新增 name 缺省时的 chain fallback 测试 | +40 |
| `runtime/test/esr/resource/workspace/bootstrap_test.exs`（新或替换） | bootstrap 创建 `<user>-default`，不是 `default` | +60 |
| `runtime/test/esr/application_first_boot_test.exs` | 删针对 system "default" 名字的断言 | -20 |

E2E scenario 19（新）：完整的 first-time-operator 路径，证明审计步骤 9 序列在不敲 workspace 名情况下能跑通。

## 八、Slash schema delta

| Slash | 改动 |
|---|---|
| `/user:use` | 新 — args：`workspace`（必填） |
| `/workspace:add-folder` | `name` 变 **可选**；fallback 到 chat-current → user-default |
| `/session:new` | 形态不变；`resolve_workspace` 实现把 system "default" 分支换成 user-default |
| `/user:add` | 结果 map 多 `"default_workspace_id"` + `"default_workspace"` 两个 key |

## 九、不变量门槛

本 spec 落地后：

1. `grep -rn '"default"' runtime/lib/esr/resource/workspace/bootstrap.ex` 字面量名零 hit；bootstrap 用户的 workspace 名从 user 计算来。
2. `Esr.Commands.Scope.New.resolve_workspace/1` 不再引用字面量 `"default"`（AST 搜索验证）。
3. 新 e2e scenario：fresh-install + `user:add` + `session:new` + `add-agent` 全路径不调用任何 `/workspace:*` 也能成功。
4. 多 chat 一致性测试：同一个 user 在两个无 chat-default 的 chat 各跑一次 `/session:new` → 都绑到 user-default。
5. `User.Registry.set_default_workspace(user, ws_id)` 在后续步骤失败时回滚（`Esr.Commands.User.Add` 的原子组合事务）。

## 十、超范围 follow-up（独立 spec）

- `/session:add-folder` 直接修改运行中 scope 的 workspace 视图（审计步骤 9 后半野心）。
- `/user:use` 接受跨 instance 解析的 `name`。
- 多 tenant fallback（admin 代另一 user 操作 — 需要 cap 设计）。
- §5.3 姿态 B（user-default 在共享 chat 中盖过 chat-default）。

## 十一、估算 LOC

| 区域 | LOC |
|---|---:|
| Lib（User.Registry + User.Use + Bootstrap 重写 + resolve_workspace + add-folder fallback + Scope.New 错误信息） | ~250 |
| 测试（按矩阵） | ~280 |
| E2E scenario 19 | ~120 |
| 文档（本 spec + zh_cn + manual-checks 更新 + futures/todo.md 更新 + slash-routes.default.yaml） | ~150 |
| **总计** | **~800 LOC** |

单 PR 范围内，净删（去掉 system "default" 分支 + 简化）~20 LOC，净增 ~780 LOC。
