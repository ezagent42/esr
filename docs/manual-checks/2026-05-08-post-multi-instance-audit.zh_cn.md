# 多实例路由清理后审计 — 2026-05-08

**操作员设想路径**（12 步，基线源自 2026-05-06 rev-3）vs **dev 当前 shipped surface**，时间锚点 `origin/dev` `a69fd6a`（多实例路由清理 PR #261 刚合入）。

> **配套文件：** 英文版本在
> [`2026-05-08-post-multi-instance-audit.md`](2026-05-08-post-multi-instance-audit.md)。
>
> **前置审计：** [`2026-05-06-bootstrap-flow-audit.zh_cn.md`](2026-05-06-bootstrap-flow-audit.zh_cn.md)
> 给出 12 步基线。本审计在 Phase 6 colon-namespace 切换、Phase 7 plugin
> 配置、HR-1..HR-4 hot-reload、PR #248 `/session:*` 命令、PR #261 多实例
> 路由清理全部落地之后，对同样 12 步重新打分。

## 方法

打分维度沿用前置审计：I = interface（入口存在）、F = function（端到端真的能用）、G = grammar（操作员实际敲的字面量是否匹配）。符号：✅ 是 · ⚠️ 部分 · ❌ 否。

审查范围：`runtime/priv/slash-routes.default.yaml`、`runtime/lib/esr/cli/main.ex`、`runtime/lib/esr/commands/**`、`runtime/lib/esr/resource/capability/supervisor.ex`、`runtime/lib/esr/entity/agent/instance_registry.ex`（M-2.7）、`runtime/lib/esr/scope/agent_supervisor.ex`（M-2.6）。证据按项目惯例标注 `file_path:line`。

## 总览表 — 重新打分

| # | 操作员敲 | I | F | G | Net | Δ vs 2026-05-06 |
|---|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | works | 不变 |
| 2 | `esr add user linyilun`（auto-admin） | ✅ | ⚠️ | ⚠️ | colon-namespace 修了 grammar；auto-admin 仍依赖 env | grammar 改进 |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | colon 落地；install verb 还是按本地 path 装 | grammar 改进 |
| 4 | `esr plugin feishu bind linyilun ou_xxx` | ✅ | ✅ | ❌ | bind 是 `esr user:bind-feishu`，plugin-scoped 形态仍缺 | 不变 |
| 5 | `esr plugin install claude_code` | ✅ | ⚠️ | ⚠️ | 同 #3；默认就内置 | 不变 |
| 6 | `esr plugin claude_code set config http_proxy=…` | ✅ | ✅ | ✅ | **Phase 7 + HR-2 闭合**：`/plugin:set` / `/plugin:show-config` / `/plugin:reload` | **完全闭合** |
| 7 | （飞书）`/help` `/doctor` | ✅ | ✅ | ✅ | works as designed | 不变 |
| 8 | （飞书）`/session:new` | ✅ | ✅ | ✅ | **Phase 6 colon-namespace 切换闭合** | **完全闭合** |
| 9 | （飞书）`/workspace:add` | ⚠️ | ⚠️ | ⚠️ | workspace VS-Code redesign + colon 收窄了 gap；心智模型 gap 还在 | 部分闭合 |
| 10 | （飞书）`/agent:add cc name=esr-developer` | ✅ | ✅ | ⚠️ | **M-2 + PR #248 功能闭合**：`/session:add-agent type=cc name=...` 返回 `actor_ids.cc/.pty` | **基本闭合，仅措辞差** |
| 11 | （飞书）纯文本 → 含 cwd 回复 | ✅ | ✅ | ✅ | 今天能跑 | 不变 |
| 12 | （飞书）`/agent:inspect esr-developer` → URL | ❌ | ❌ | ❌ | `/attach` 在 colon 切换中被洗掉；没有任何 slash 返回 PtySocket URL | **退化** |

**净读：** **12 项里 9 项完全闭合**（2026-05-06 时是 7 完全 + 2 部分）。三个改进（#6、#8、#10），一个退化（#12 — 之前 `/attach` 是工作的，现在悄悄消失了），三个结构/模型层 gap 仍在（#2 auto-admin、#4 plugin-scoped grammar、#9 心智模型）。

2026-05-06 之后的几大架构胜利 — colon-namespace、plugin 配置、per-session 多实例 DynSup、原子 `add_instance_and_spawn`、M-3/M-4 legacy 删除 — 闭了 3 步、改进 2 步，**但暴露出之前 ship 的一个操作员入口在 colon 切换时被删掉了**（#12 attach URL）。

---

## 步骤逐项 vs 2026-05-06 审计的差异

### 步骤 6 — `/plugin:set` 落地（Phase 7 + HR-2）

`Esr.Commands.Plugin.{Set, Unset, ShowConfig, ListConfig, Reload}` 全部存在（`runtime/lib/esr/commands/plugin/`）。Slash 路由 `/plugin:set`、`/plugin:show-config`、`/plugin:list-config`、`/plugin:unset`、`/plugin:reload` 全部接通。三层配置（manifest 默认 / global / workspace overlay）+ 每个 plugin manifest `hot_reloadable: true` opt-in 通过 HR-1..HR-4 全部落地。**操作员需求完全满足。**

### 步骤 8 — Colon-namespace 切换（Phase 6）

`/session:new`、`/session:attach`、`/session:detach`、`/session:share`、`/session:add-agent`、`/session:set-primary`、`/session:remove-agent` 全部在 `runtime/priv/slash-routes.default.yaml` 里。短横线形态（`/new-session` 等）已经全部下线。

### 步骤 10 — 多实例 agent spawn（M-2 + PR #248）

`/session:add-agent type=cc name=alice` 走的是 `Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn/2`（M-2.7）— 在 per-session `Esr.Scope.AgentSupervisor`（M-2.6）下原子 spawn，`(CC, PTY) :one_for_all`。返回结果带 `actor_ids.cc` + `actor_ids.pty` UUID v4。三个兄弟 agent（alice/bob/carol）共存无冲突（`tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh` 验证）。

### 步骤 12 — **退化**：TUI URL 入口消失

2026-05-06 审计把步骤 12 打成 I=⚠️、F=✅、G=❌ — `/attach` 是工作的，只是 chat-scoped（不能按 name 找）。Phase 6 colon 切换之后，独立的 `/attach` slash 被删除。`/session:attach` 存在但：(a) 只接 UUID，(b) 只返回 `{"attached": true}` — **没有 URL**。`EsrWeb.PtySocket` 还在（`runtime/lib/esr_web/pty_socket.ex`），但没有任何操作员可见的 slash 暴露指向它的 URL。

**具体结论：** 飞书操作员今天没有任何方式拿到任何 session 的可点击 web TUI URL。Web 层 ship 了，但从操作员侧无法触达。

---

## 横向 gap 重打分

### 1. Colon-namespace grammar — **闭合**

Phase 6 切换落地，每个操作员 slash 现在都是 `<group>:<verb>`。

### 2. 操作员设 plugin 配置 — **闭合**

Phase 7 + HR-1..HR-4 ship 了三层配置 + `/plugin:set/unset/reload` + manifest `hot_reloadable` opt-in。

### 3. 心智模型对齐围绕 `add` — **部分**

Workspace VS-Code redesign 加了 `/workspace:add-folder`、`/workspace:use`、`/workspace:bind-chat`。Session 方向仍要求 workspace 预存在才能 `/session:new`；没有 `/session:add-folder` 修改运行中 session 的 workspace，也没有 `/session:new <NAME>` 在底层 lazy 创建 transient workspace。

`docs/notes/concepts.md` 的元模型 **是** session-first（Scope = Session 的运行实例；workspace = Scope 引用的 Resource）。impl 是 workspace-first。`docs/futures/todo.md` 标 "Migrate to session-first model"。

### 4. First-user-auto-admin — **仍 gap**

`runtime/lib/esr/resource/capability/supervisor.ex:38-46` 仍然要求 `ESR_BOOTSTRAP_PRINCIPAL_ID` env。"首次 `user:add` 在没有 admin grant 时自动给 admin" 的路径从来没接。~30 LOC。

### 5. `esr.sh` 引用 — **闭合**

audit task 1（按记忆）替换了 `Esr.Commands.Doctor` 里的 stale 引用。

---

### Session-first 默认解析 — **2026-05-08 闭合**

PR（本分支）落地 `2026-05-08-session-first-default-resolution.md` spec：
per-user default workspace 替代 system "default"；`/user:add` 自动建 `<username>-default`；
新增 `/user:use` slash；`/workspace:add-folder name=` 走同一 fallback 链。审计 step 9 的
session-first 1-2-3 路径（`/session:new` → `/workspace:add-folder` → `/session:add-agent`）
现在不敲 workspace 名也能跑通。e2e scenario 19 验证。

## 多实例路由清理后新冒出的 gap

这些是被多实例工作 *引入或暴露* 的 gap。

### A. `/session:list` + `/session:list-agents` — **缺失**

`/session:attach` 的描述字面写着 `"用 /session:list 查 UUID"`（`runtime/priv/slash-routes.default.yaml:309`），但 `/session:list` **没接**。同一个文件 337 行注释 `# /session:end, /session:list, /session:bind-workspace, /session:info — deferred`。

`/agent:list` 存在但列的是 **plugin 声明的 agent 类型**（"cc" 等），不是 session 内实例。M-2 启用 per-session 多实例之后，操作员的 session 里有 `cc:alice` + `cc:bob` + `cc:carol`，没有 slash 能枚举它们。

**修复范围：** ~150 LOC 横跨两个 `Esr.Commands.Session.{List, ListAgents}` 模块 + slash 路由 + e2e 断言。所有未关项目里 leverage 最高的。

### B. `/session:attach name=<n>` + TUI URL 返回器 — **缺失**

`/session:attach` 只接 UUID。Phase 6 之前的 `/attach` 返回可点击的 `EsrWeb.PtySocket` URL — 这个入口在 colon 切换里没了。两个耦合的改动需要做：

1. `Esr.Commands.Session.Attach` 接受 `args.name`（在 chat-scope attached sessions 里通过 NameIndex 解析）。
2. 成功结果带 `attach_url` 字段 — 由 PtySocket 一次性签名 token 支撑。

不做这两个，"点链接打开 agent terminal" 在飞书侧从结构上不可能。

### C. 多实例辅助命令 — **缺失**

M-2 让多实例成为常态后：
- `/session:rename-agent name=<old> to=<new>` — 没接。操作员要重命名只能 remove + 再 add（state 丢失）。
- `/session:show-primary` — 只有 setter（`/session:set-primary`）；没只读查询。
- `/session:detach-agent` — `/session:detach` 是把整个 session 从 chat detach；没有按 agent 粒度的 detach。

这些虽小但操作员一旦开始用多实例就立刻能看到。

### D. `@mention` 路由还没 e2e 自动断言

scenario 14 和 scenario 18 都刻意跳过 `@alice` / `@bob` 路由断言，因为 admin-submit harness 没法把入站飞书消息注入到路由管线（`Esr.Entity.Agent.MentionParser` + `Esr.Entity.SlashHandler.resolve_routing/2` 只对真入站才 fire）。`docs/futures/todo.md` 标 `e2e-14-routing` 跟踪。runtime 路径 ship 了且单元测了；只是 e2e gate 缺。

### E. PT-side ActorQuery resolution e2e gate — 部分

`runtime/test/esr/integration/m5_actor_query_spawn_test.exs`（M-5.1）只断言 `find_by_name` 返回 CC pid，跳过 PT（PT 生命周期绑活进程，索引注册和同步断言会赛跑）。scenario 18 功能上覆盖但 bash harness 还没探活 registry — 依赖 B（TUI URL）先落地，之后 e2e 才能 `curl` attach URL 验证存活。

---

## 推荐 follow-up（按 leverage 排序）

| # | 内容 | 估算 LOC | 备注 |
|---|---|---:|---|
| 1 | `/session:list` + `/session:list-agents` | ~150 | 修 `/session:attach` 自指文档 gap。leverage 最高。 |
| 2 | First-user-auto-admin | ~30 | `Esr.Resource.Capability.Supervisor` 单文件。 |
| 3 | `esr daemon init` + `esr daemon clear` | ~250 + ~700 | 把 fresh-host 4 步合一。和 `docs/futures/todo.md` 里 `tools/wipe-esrd-home.sh` 方向一致。 |
| 4 | `/session:attach name=<n>` + TUI URL | ~300 | 恢复 Phase-6 之前的 attach UX，再加多实例支持。 |
| 5 | Session-first 迁移 brainstorm + spec | 仅 spec | `docs/futures/todo.md` 标 "Migrate to session-first model" — 写代码前先设计。 |
| 6 | `/session:rename-agent`、`/session:show-primary`、`/session:detach-agent` | ~200 | 三个小 slash 一捆，闭合审计步骤 10 余项。 |
| 7 | `@mention` 路由 e2e harness gap | ~100 | mock-feishu 入站注入 OR test-mode admin verb。闭合 `e2e-14-routing` + 改进 scenario 18。 |
| 8 | Plugin install-by-name（registry） | 仅 spec | Plugin spec Phase 2。推迟。leverage 比 #1-#6 低。 |

前三个（#1、#2、#3）成簇为"操作员前 30 分钟踩到的"。中间三个（#4、#5、#6）成簇为"多实例工作让它成为可能但还没收尾的"。#7 和 #8 是更大的结构性工作。

---

## 见

- [`2026-05-06-bootstrap-flow-audit.zh_cn.md`](2026-05-06-bootstrap-flow-audit.zh_cn.md) — 前置审计，12 步基线
- [`docs/futures/todo.md`](../futures/todo.md) — 持久 TODO；本审计若干条目映射到那里
- [`docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md`](../superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md) — 今天落地、触发本审计的 spec
- [`runtime/priv/slash-routes.default.yaml`](../../runtime/priv/slash-routes.default.yaml) — slash 命令权威源
- [`tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh`](../../tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh) — 与本审计同时落地的多 CC e2e gate
