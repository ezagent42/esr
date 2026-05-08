# Phase 3 + Phase 4 状态 — 2026-05-05 自主运行

**日期：** 2026-05-05
**Specs：**
- `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md` (Phase 3)
- `docs/superpowers/specs/2026-05-05-phase-4-cleanup.md` (Phase 4)

本文档记录 2026-05-05 自主 Phase 2 → 3 → 4 运行中实际交付了什
么、哪些被有意收窄了范围、哪些作为独立后续遗留下来。

## Phase 3 — 插件物理迁移

| PR | # | 主题 | 状态 |
|---|---|---|---|
| PR-3.1 | #203 | 删除 fallback Sidecar 注册；Loader 是唯一来源 | ✅ 已发 |
| PR-3.2 | #204 | StatefulRegistry 取代编译期 MapSet | ✅ 已发 |
| PR-3.3 | #205 | feishu 模块迁入 `runtime/lib/esr/plugins/feishu/` | ✅ 已发 |
| PR-3.4 | — | feishu 插件通过启动钩子拥有 `bootstrap_feishu_app_adapters` | ⏸️ 推迟 |
| PR-3.5 | — | cc_mcp 的 HTTP MCP transport | ⏸️ 推迟 |
| PR-3.6 | #206 | cc 模块迁入 `runtime/lib/esr/plugins/claude_code/` | ✅ 已发 |
| PR-3.7 | #207 | cc 插件不再引用 "feishu" | ✅ 已发 |

**7 个里发了 5 个，2 个推迟。**

### 为什么 PR-3.5 被推迟

**更正（review 后）：** 本笔记早期草稿曾说 PR-22/PR-24 让 HTTP
MCP "基本不再必要" — 那是错的。PR-22/PR-24 修的是 PTY *attach*
生命周期（BEAM 管理 PTY + 二进制 WS 重连）；它们**没有**触及
cc_mcp 生命周期。

准确状态：cc_mcp 仍然是 `claude` 的 stdio 子进程，按 `.mcp.json`
的 `command: "python -m esr_cc_mcp.channel"` 启动。它随 claude
一起死，每次 claude 重启都重启，重启过程中飞行的 notification
会被丢弃 —— 这正是 PR-3.5 想打破的耦合。

按照 Claude Code channel 文档（`docs/notes/claude-code-channels-reference.md`），
`.mcp.json` 支持 `url:` 指向远程 HTTP/SSE MCP 服务器，所以这个
迁移在技术上是可行的：esrd 自己 host 一个 MCP server endpoint，
claude 作为 remote channel 连过来，而不是本地 spawn 一个 stdio
子进程。

PR-3.5 是**为了控制范围**而被推迟的，**不是因为问题已解决**。
当作活的债务对待 —— 当 cc_mcp 生命周期痛点重现，或某个特性
要求 channel 状态在 claude 重启后仍然存活时，再升级。

### 为什么 PR-3.4 被推迟

PR-3.4 想让 `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0`
从 core 移出，进入 feishu 插件的启动钩子。这需要：
- Manifest schema 增加 `startup:` 字段。
- `Esr.Plugin.Loader` 增加 startup-call 约定。
- 新模块 `Esr.Plugins.Feishu.Bootstrap`。
- `Esr.Application.start/2` 中的插件生命周期顺序保证。

这是**插件生命周期基础设施**，不是文件搬运。当作独立的
brainstorm + spec + plan 周期处理。`Esr.Application.start/2`
里残留的那一行 `bootstrap_feishu_app_adapters()` 是**单点
耦合**，不是架构性问题 —— 但它**确实让 "feishu 完全分离" 的说
法不成立**，所以是高优先级债务。

## Phase 4 — 收尾清理

| PR | # | 主题 | 状态 |
|---|---|---|---|
| PR-4.1 | — | `Esr.Application.start/2` 插件特定 bootstrap | ⚠️ 部分 — feishu 残留 |
| PR-4.2 | — | 删除 `dev_channels_unblock.sh` | ✅ 已在 Option A 完成 (#191) |
| PR-4.3 | #208 | `Esr.Admin.{Supervisor,CommandQueue.*}` → `Esr.Slash.*` | ✅ 已发 |
| PR-4.4 | #209 | 删除 `permissions_registry.json` 跨语言 dump | ✅ 已发 |
| PR-4.5 | — | CI guard 校验每个插件 manifest 的 `entities:`/`python_sidecars:` 真实存在 | ⏸️ 推迟 |
| PR-4.6 | — | Python CLI 单命令逐个迁移到 escript | ⏸️ 推迟 |
| PR-4.7 | — | 删除 `py/src/esr/cli/` venv | ⏸️ 依赖 PR-4.6 |

**7 个里发了 3 个，1 个部分（PR-4.1，feishu bootstrap 残留），
3 个推迟。PR-4.6 + PR-4.7 是 Phase 4 实际工作量的大头，完全
没动。**

### PR-4.1 状态

PR-4.1 本来想清理的 Application bootstrap：
- ✅ Sidecar fallback 注册（PR-3.1 删除）
- ⏸️ `bootstrap_feishu_app_adapters`（仍在 core；依赖 PR-3.4）
- ✅ `bootstrap_voice_pools`（PR-2.0 删除）

PR-4.1 想做的事大部分由 PR-3.1 和 PR-2.0 顺带做了；feishu
残留这条挂在 PR-3.4 上。

### 为什么 PR-4.5 被推迟

加 CI guard 需要写一个 mix task 挂到 `mix test` /
`scripts/loopguard.sh`。代码量小但触及 CI 表面。最好作为单独
的工具 PR 做，带恰当的集成测试，不要混在 Phase 4 的删除工作
里。

### 为什么 PR-4.6 + PR-4.7 被推迟

按 Phase 4 spec，这两个是 Phase 4 的**主要工作量**（每个 click
子命令一个迁移 PR + 最后 venv 删除，约 14 个子 PR）。出于和
Phase 3 同样的范围控制理由（小聚焦项目优于把太多东西塞进一
期），Python CLI 删除作为独立后续处理。

Elixir-native escript（PR-2.5/2.6）已经覆盖**spec 定义的核心**
operator 表面（`exec`、`help`、`describe-slashes`、`daemon`、
`admin submit`、`notify`）—— 但这是 31 个 click 命令里的约 6
个。剩下 ~25 个命令（admin 子集、cap 子集、users、notify 变体、
adapter、reload 等）**仍然只能用 Python 跑**，直到 PR-4.6/4.7。

## 累计 session 统计

- **22 PR 合并**（#189–#209）
- **Phase 2**：完成（10/10 PR）。
- **Phase 3**：5/7 已发，2 个推迟。
- **Phase 4**：3/7 已发，1 个部分（PR-4.1），3 个推迟。
- **净 LOC delta**：约 -200（voice 删除的 -1577 LOC 被新 DI
  模块 + escript + StatefulRegistry 部分抵消）。
- **测试基线**：全程稳定在 8-10 个既有 flake。22 个 PR 没有
  引入新的测试回归。
- **e2e 08 + 11**：每个 PR 的合并 gate 都通过。

## 这次跑完之后**是真的**

1. **单一 dispatch 路径。** 所有 slash dispatch 走
   `Esr.Entity.SlashHandler`（chat）和 `dispatch_command/2`
   （admin 队列）。`Esr.Admin.Dispatcher` 不存在。
2. **插件无关的 CLI。** `esr` escript 读
   `/admin/slash_schema.json`（PR-2.1）。新插件 slash 路由
   自动出现在 `esr help` 里 —— CLI 零改动。
3. **每个 reply 边界都有 DI。** `Esr.Slash.ReplyTarget`
   （ChatPid / IO / QueueFile / WS）。
4. **插件*模块文件*在 `plugins/<name>/` 下。** feishu 模块在
   `runtime/lib/esr/plugins/feishu/`；cc 模块在
   `runtime/lib/esr/plugins/claude_code/`。
   `runtime/lib/esr/{entity,scope,resource}/` 下已经不再有
   插件模块*文件*。
5. **Stateful peer 注册表。**
   `Esr.Entity.Agent.StatefulRegistry` 取代编译期 MapSet。
   插件 manifest 用 `entities: [{module: ..., kind: stateful}]`
   声明 stateful peer。
6. **Slash 子系统完全在 `Esr.Slash.*` 下。** Supervisor +
   QueueWatcher + QueueJanitor + ReplyTarget +
   CleanupRendezvous + QueueResult + HandlerBootstrap。
   `Esr.Admin.*` 命名空间只剩权限声明的 façade 模块。
7. **`esr` escript 覆盖 spec 定义的核心 operator 表面。**
   `exec`、`help`、`describe-slashes`、`daemon`、`admin submit`、
   `notify` 不需要 Python。escript 是插件无关的 —— 新插件
   slash 路由自动出现。

## 这次跑完之后**不真**

本笔记早期草稿夸大了插件隔离和 Phase 4 的进展。准确的差距：

1. **feishu 生命周期仍由 core 拥有。**
   `Esr.Scope.Admin.bootstrap_feishu_app_adapters/0` 仍然定
   义在 `runtime/lib/esr/scope/admin.ex`，仍然被
   `Esr.Application.start/2` 调用。文件搬运在 PR-3.3 完成；
   *生命周期所有权*迁移是 PR-3.4（推迟）。
   **在 PR-3.4 落地之前，未来开发者无法在不动 core 的情况下
   发布一个 feishu-only 改动。** 这条直接违反 North Star。
2. **cc_mcp 生命周期仍与 claude 耦合。** cc_mcp 作为 `claude`
   的 stdio 子进程运行（按 `.mcp.json` 的 `command:`），每次
   claude 重启都重启。PR-3.5（HTTP MCP transport，esrd 自己
   host）仍然是计划中的修复。
3. **Python CLI 完全完整。** `py/src/esr/cli/main.py`
   （1618 LOC，31 个 click 命令）一行没动。Elixir escript
   覆盖约 6 个 spec 定义的核心命令；剩下约 25 个 click 命令
   （admin 子集、cap 子集、users、notify 变体、adapter、
   reload 等）仍然只能用 Python。PR-4.6（单命令迁移）和
   PR-4.7（venv 删除）是 Phase 4 的大头，完全没动。
4. **`permissions_registry.json` 没了，但 `cap.py` 消费方
   stale 了。** PR-4.4 删除了 boot 时的 JSON dump；Python
   `esr cap list` 仍然读任何已存在的文件，但数据会陈旧 ——
   直到 PR-4.6 把命令迁过来或 PR-4.7 删除 Python CLI。

## 后续工作

- **PR-3.4 / PR-4.1 残留**：feishu 插件启动钩子（插件生命
  周期基础设施）。关闭上面"feishu 仍在 core"的泄漏。**这
  是最高优先级债务** —— 它直接违反 North Star（"feishu
  改动不触及 core"）。
- **PR-3.5**：HTTP MCP transport。cc_mcp 生命周期仍与
  claude 耦合；PR-22/PR-24 没有解决这个。当需要 channel
  状态在 claude 重启后存活时再升级。
- **PR-4.5**：manifest CI guard（小工具 PR）。
- **PR-4.6 + PR-4.7**：Python CLI 单命令迁移 + venv 删除
  （约 14 个子 PR 的聚焦逐命令手术）。escript 覆盖 31 个
  click 命令里的 6 个；剩下 25 个仍只能用 Python。
  在 PR-4.6/4.7 落地前，"无 Python venv 依赖" *只对*
  spec 定义的核心 operator 表面成立，对完整 operator CLI
  不成立。

这些保留在 `docs/futures/todo.md` 里给未来周期。当前架构
operator **可以使用并验证**，但 North Star（"未来开发者无需
协调就能在不同插件上工作"）**尚未达成** —— PR-3.4 具体卡
住了 feishu 这条路径。
