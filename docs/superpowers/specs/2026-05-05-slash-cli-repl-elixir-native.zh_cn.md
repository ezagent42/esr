# 第二阶段 — slash / CLI / REPL / admin 四路统一（Elixir 原生化）

**日期：** 2026-05-05
**状态：** 草案，待用户评审。
**前序：** PR-180/181/182/183/184/185/186/187（第一阶段 plugin 基础设施，2026-05-04）。
**后继：** 第三阶段（`docs/superpowers/specs/2026-05-05-plugin-physical-migration.md`）消费本阶段确立的契约。

> **配套文件**：本文档的英文原版位于 `docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md`。

---

## 一、为什么需要这个阶段

今天，"按 kind+args 执行命令" 这件事有四条独立代码路径：

1. **Slash 入站** —— 聊天用户输入 `/foo bar=baz`；FAA → FCP → `Esr.Entity.SlashHandler.dispatch/3` → `Esr.Admin.Commands.<Mod>.execute/2`。
2. **Admin 队列文件** —— operator 执行 `esr admin submit foo --arg bar=baz`；Python 把 yaml 写到 `~/.esrd/<env>/admin_queue/pending/<id>.yaml`；`Esr.Admin.CommandQueue.Watcher` 读取；`Esr.Admin.Dispatcher.run_command/2` 检查权限并调用同一个 `Esr.Admin.Commands.<Mod>.execute/2`。
3. **Python click 命令组** —— 手写的 `cli/cap.py` / `cli/users.py` / `cli/daemon.py` 等等（共约 2872 LOC）。每个 click 子命令独立调用 admin 队列提交或读取磁盘上的 JSON dump。**Schema 与 `slash-routes.yaml` 解耦** —— 加一条新命令需要同时改 Elixir 和 Python。
4. **没有 REPL** —— operator 当前只能通过串接 shell 命令（`esr admin submit ...`）来做交互式操作。

PR-21κ（2026-04-30）已经把 Elixir 侧的 dispatch 表合并为单一 yaml schema。**第二阶段完成最后一步**：把 dispatch *模块* 也合并，把 Python 手写的 click 替换为 schema 驱动的 Elixir 原生 CLI，并新增 REPL 作为 operator 的默认入口。

### 目标

1. 单一 Elixir dispatch 路径。`Esr.Entity.SlashHandler` 是唯一入口；`Esr.Admin.Dispatcher` 被删除。
2. Schema 驱动的 CLI：`esr` 二进制读取同一份 `slash-routes.yaml`，自动把每个 kind 暴露为 CLI 子命令。
3. REPL：`esr` 不带参数即进入交互式 shell，直接接受 slash 文本，自动补全数据来自 schema。
4. 净删 ~100 LOC（不是早期估的 ~2500 —— review 修正：`main.py` 大部分命令不在 slash schema 范围内）；价值在契约统一，不在删代码量。
5. Plugin manifest 的 `slash_routes:` 片段一旦合进 registry，新命令立刻同时出现在 chat slash、Elixir CLI、REPL 自动补全中 —— **零额外代码**。

### 非目标

- **Plugin 物理迁移** —— 第三阶段消费本阶段契约，本阶段不做。
- **鉴权模型变更** —— operator principal 仍由 `ESR_OPERATOR_PRINCIPAL_ID` 环境变量提供（或入站 chat 的 sender），鉴权设计另议。
- **替换 admin_queue/pending 文件传输** —— 文件保留；operator 和外部脚本仍可直接写 yaml 文件。Watcher 逻辑只是变薄到"读文件、交给 SlashHandler"。

---

## 二、架构

### 单一 dispatch 路径

```
任意来源（chat / file / escript / REPL / HTTP）
        ↓ 生成 SlashEnvelope:
        {
          slash_text:   "/foo bar=baz" | parsed_command_map,
          principal_id: <chat_sender_id | operator_principal_id>,
          reply_to:     callback_pid_or_writer
        }
        ↓
   Esr.Entity.SlashHandler.dispatch/3        ← 唯一入口
        ↓
   Esr.Resource.SlashRoute.Registry.lookup   ← kind → permission + command_module
        ↓
   Esr.Resource.Capability.has?              ← 权限检查
        ↓
   command_module.execute/2                  ← 业务逻辑（不变）
        ↓
   reply_to.send_response(result)            ← chat 出站 | 写 yaml | stdout | WS 推送
```

### 哪些保留、哪些删除

| 模块 | 状态 | 原因 |
|---|---|---|
| `Esr.Resource.SlashRoute.Registry` | 保留 | 单一来源，不变 |
| `Esr.Interface.SlashParse` | 保留 | 文本 → command_map 解析器，不变 |
| `Esr.Entity.SlashHandler` | **扩展** | 成为通用入口；引入 `reply_to` 抽象 |
| `Esr.Admin.Dispatcher` | **拆分后删除** | dispatch + 权限检查迁移到 `SlashHandler`；队列特定职责（cleanup_signal rendezvous、result 时的 secret 脱敏、pending→processing→completed 文件状态机）迁移到新模块 `Esr.Slash.QueueResult`（`register_cleanup/2` API 通过此模块继续可访问）。详见下方"Admin.Dispatcher 实际承担三件事"。 |
| `Esr.Admin.CommandQueue.Watcher` | **变薄** | 保留 file_system watch + boot 时的 stale-`processing/` 恢复；dispatch 委派给 `SlashHandler`；通过 `Esr.Slash.QueueResult` 处理各阶段文件移动 |
| `Esr.Admin.Commands.*` | **重命名 → `Esr.Commands.*`** | 不是 "admin" 专属，就是"命令"而已 |
| slash-routes.yaml 中的 `internal_kinds:` 段 | **保留为独立子命名空间，NOT 扁平合并到 `slashes:`** | 详见下方"`internal_kinds:` 不能扁平合并" —— 扁平合并会改变安全边界 |
| `py/src/esr/cli/{cap,users,notify,reload,admin}.py` | **删除** | 由 Elixir 原生 escript 取代 |
| `py/src/esr/cli/daemon.py` | **短期保留** | lifecycle 与 `launchctl` 绑定；可后续移到 escript 但不是优先项 |
| `py/src/esr/cli/main.py` | **大部分保留** | review 发现这里有 31 个 click 命令，大部分不在 slash-routes.yaml 范围（adapter add/remove/rename/install、handler install、cmd list/install/show/compile、actors、deadletter、trace、debug、drain、scenario）。这些不属于第二阶段 scope；第四阶段清理时再决定 |
| `runtime/scripts/esr`（escript binary） | **新增** | 单一入口；无参数进 REPL，有参数则执行 slash |
| `Esr.Cli`（Elixir 模块集合） | **新增** | schema 驱动的 argv 解析、slash exec、REPL、lifecycle 包装 |

#### Admin.Dispatcher 实际承担三件事

本规格的 subagent review（2026-05-05）发现 Dispatcher 不只是 SlashHandler 的 duplicate，它独占三个职责：

1. **dispatch + 权限检查 + invoke**。这部分确实和 SlashHandler 重复，干净迁移过去。
2. **`cleanup_signal` rendezvous —— 用于长时间运行的 session_end**。`Esr.Admin.Dispatcher` 注册了一个 `pending_cleanups :: %{session_id => task_pid}` map，并暴露 `register_cleanup/2` + `deregister_cleanup/1` 可调函数。`Esr.Admin.Commands.Scope.BranchEnd` 调 `register_cleanup/2` 然后阻塞在 `receive`。`Esr.Entity.Server.build_emit_for_tool("session.signal_cleanup", …)` 直接 `send(Process.whereis(Esr.Admin.Dispatcher), {:cleanup_signal, …})`。**这是命名进程之间的 rendezvous**，不只是 dispatch。必须搬迁，不能直接删。
3. **结果时的 secret 脱敏**。Dispatcher 在持久化到 `completed/<id>.yaml` 之前，把 `args.{app_secret, secret, token}` 字段重写为 `[redacted_post_exec]`。这是运维历史的卫生要求；删除会是安全回归。
4. **二阶段文件移动 + stale-processing 恢复**。`move_pending_to_processing/1` 和 `move_processing_to/2`（`completed/` 或 `failed/`）拥有磁盘上的状态机。Watcher 的 boot 时清扫依赖于 `processing/` 这个中间状态有意义。

第二阶段完成后：
- (1) 落到 `SlashHandler.dispatch/3`。
- (2) 成为新的小模块 `Esr.Slash.CleanupRendezvous`（约 80 LOC），全局注册；同样的 `register_cleanup/2` / `deregister_cleanup/1` / `signal_cleanup/1` API。`Esr.Entity.Server.build_emit_for_tool` 重定向其 `send(Process.whereis(...))` 目标。`BranchEnd` 更新调用点。
- (3) 落到 `Esr.Slash.QueueResult.persist/2` —— 由 `ReplyTarget.QueueFile.respond/2` 在 execute/2 返回后调用。脱敏规则不变。
- (4) 也落到 `Esr.Slash.QueueResult` —— Watcher 读 pending、调 `QueueResult.start_processing/1`（move file to processing/）、调用 SlashHandler、收到响应后调 `QueueResult.finish/2`（move to completed/ 或 failed/）。

这意味着原方案的 PR-2.3 拆成两个：
- PR-2.3a：创建 `Esr.Slash.CleanupRendezvous` + `Esr.Slash.QueueResult`。更新 `BranchEnd` 和 `Server.build_emit_for_tool` 使用新模块。**Dispatcher 仍存在** —— 新模块作为并行路径。
- PR-2.3b：删除 `Esr.Admin.Dispatcher`。Watcher 重写为调用 SlashHandler + QueueResult。

原方案的 PR-2.3 不能独立 green —— review 发现 10+ 测试文件 `Process.whereis(Esr.Admin.Dispatcher)` 并断言其活着。拆分后 PR-2.3a 仍 green（Dispatcher 没动），PR-2.3b 在删除时同步更新这些测试。

#### `internal_kinds:` 不能扁平合并

原草案曾建议从 slash-routes.yaml 删 `internal_kinds:` 段、把它的 9 个条目迁到 `slashes:`。Review 抓到两个问题：

1. **Loader 逻辑差异**：`Esr.Resource.SlashRoute.FileLoader` 把两段 yaml 校验为不同的 map 形态。扁平合并需要真正的 loader 改动，不是只编辑 yaml。
2. **安全边界变化**：若干 `internal_kinds:` 条目（`grant`、`revoke`）按设计是 operator 专属的。今天它们只能走 file-queue —— operator 通过 `esr admin submit grant ...` 调用。一旦把它们移到 `slashes:`，任何持有 `cap.manage` 权限的人就能在 chat 里用 slash 文本调用。**也就是说，持 `cap.manage` 的 operator 可以通过 chat 给自己授权更多权限**。今天的 (cap.manage AND admin_queue/pending 写权限) 双因素特权边界，会塌缩为单一的 (cap.manage)。

决定：保留 `internal_kinds:` 作为独立子命名空间。schema dump endpoint（PR-2.1）以独立 JSON section 输出 `slashes:` 和 `internal_kinds:`。`esr exec` 可调用任意 section 的 kind（前提 operator 拥有相应 cap），但**只有 `slashes:` 能从 chat 走 slash 文本调**。Schema 驱动的 CLI/REPL 自动补全展示两者，用 `internal: true` flag 区分。

### `reply_to` 抽象

今天 `SlashHandler.dispatch/3` 接受 `reply_to :: pid()` 然后 `send/2` 结果回去。第二阶段把它扩展为 behaviour：

```elixir
defmodule Esr.Slash.ReplyTarget do
  @callback respond(target :: term(), result :: map()) :: :ok | {:error, term()}
end
```

实现：

- `Esr.Slash.ReplyTarget.ChatPid` —— `send(pid, {:reply, text, ref})`。Chat 入站场景。
- `Esr.Slash.ReplyTarget.QueueFile` —— 写 yaml 到 `admin_queue/completed/<id>.yaml`。Admin queue 场景。
- `Esr.Slash.ReplyTarget.IO` —— 打印到 stdout / 格式化 JSON。CLI escript 单次执行场景。
- `Esr.Slash.ReplyTarget.WS` —— 通过 Phoenix.Channel socket 推送 frame。REPL 交互场景。

`SlashHandler.dispatch/3` 的第三个参数从裸 pid 变为 `{module, target}` tuple。chat / queue 路径更新为把现有的 pid/path 包装成这个结构。过渡期接受裸 pid 的 backwards-compat shim 保留。

### Schema dump endpoint

```
GET /admin/slash_schema.json    → 公开 schema（kinds、args、descriptions、categories）
GET /admin/slash_schema.json?include_internal=1 → 添加 permissions、command_module
```

用途：
- escript：启动时读取（本地缓存供离线使用），动态生成 CLI 子命令。
- REPL：同一来源驱动自动补全树。
- 文档生成：替代现有 `gen-docs.sh` 的 slash 抽取逻辑。

JSON shape 镜像内存中的 registry。新增模块：`Esr.Resource.SlashRoute.Registry.dump_json/1`（镜像现有的 `Permission.Registry.dump_json/1`）。

### CLI escript 形态

```
$ esr                               → 进入 REPL
$ esr exec "/foo bar=baz"           → 单次执行 slash
$ esr exec foo --bar=baz            → 等价（argv 翻译为 slash 文本）
$ esr daemon {start,stop,restart,status,doctor}  → lifecycle（launchctl 包装）
$ esr help [kind]                   → schema dump pretty-print
$ esr describe-slashes [--json]     → schema dump（机器可读）
```

argv 翻译：`esr exec foo --bar=baz arg1` ⇒ slash_text `"/foo bar=baz arg1"`。escript 在缓存的 schema 里查 `foo`，拿到规范化的 argname / 位置参数映射，格式化 slash 文本，提交。

`esr exec` 阻塞模型：默认写 admin_queue/pending、轮询 completed/ 取响应 yaml（沿用现有行为）。`--no-wait` 提交后立即退出。`--http`（第三阶段 channel 落地后）走 HTTP `POST /admin/exec` 同步响应。

### REPL 形态

```
$ esr
ESR REPL — connected to esrd-dev (port 4001) — principal linyilun
> /help                              ← 自动补全：tab 补全 / + 命令名 + 参数名
> /plugin list
  installed plugins:
    - bare_component v0.0.1 [enabled]
    ...
> /scope new workspace=esr-dev name=...
  ...
> ^D                                 ← 干净退出
```

实现：Elixir 原生，使用 `IO.gets/1` + ANSI 转义码做自动补全。Erlang shell 的 readline 风格行编辑足够，无需 prompt_toolkit。如果 escript 限制使其困难，回退到 managed `port` 调一个 `linenoise`-like 小辅助程序。

### Lifecycle 命令

`esr daemon start/stop/restart/status/doctor` 包装 `launchctl`（现有 Python 用 subprocess.run 实现）。Elixir 用 `System.cmd("launchctl", [...])`，约 80 LOC。

`doctor` 调现有的 `Esr.Admin.Commands.Doctor` 模块（第二阶段重命名为 `Esr.Commands.Doctor`）；doctor 逻辑本身不变，只是调用路径改了。

---

## 三、迁移顺序（PR 序列）

每个 PR 独立可合并。dev → main promotion 在整链结束后做。

| PR | 范围 | 测试门 |
|---|---|---|
| **PR-2.0** | Voice plugin 删除（我们从未真正使用 voice）。删 `runtime/lib/esr/entity/voice_*.ex`、`py/src/voice_*` 和 `py/src/_voice_common`、voice 测试、`pools.yaml`、`bootstrap_voice_pools/1`、`agents.yaml` 中的 voice agents。 | unit suite green |
| **PR-2.1** | 新增 `Esr.Resource.SlashRoute.Registry.dump_json/1` + `GET /admin/slash_schema.json` 路由，独立 section 输出 `slashes:` 和 `internal_kinds:`。`?include_internal=1` 加权限字符串。无行为变化。 | 新 endpoint 测试 + 手动 curl |
| **PR-2.2** | 引入 `Esr.Slash.ReplyTarget` behaviour + `ChatPid` + `QueueFile` + `IO` + `WS` 实现。`QueueFile` 的 `respond/2` 是**多阶段**（`on_accept` / `on_complete` / `on_failed`）以保留文件状态机。`SlashHandler.dispatch/3` 接受 `{mod, target}` reply tuple；裸 pid 走 backwards-compat。 | 现有 slash + queue 测试不改通过 |
| **PR-2.3a** | 创建 `Esr.Slash.CleanupRendezvous`（`register_cleanup/2`、`deregister_cleanup/1`、`signal_cleanup/1`）和 `Esr.Slash.QueueResult`（`start_processing/1`、`finish/2` 含 secret 脱敏）。更新 `Esr.Admin.Commands.Scope.BranchEnd` 和 `Esr.Entity.Server.build_emit_for_tool("session.signal_cleanup", _)` 使用新模块。**Dispatcher 仍存在** —— 新模块是并行路径。 | scenario 01/07 green；cleanup-signal e2e green；两个新模块的 unit 测试 |
| **PR-2.3b** | 删除 `Esr.Admin.Dispatcher`。`Admin.CommandQueue.Watcher` 重写为调 `SlashHandler.dispatch/3` 配 `QueueFile` reply target；文件移动通过 `Esr.Slash.QueueResult`。更新 10+ 个 `Process.whereis(Esr.Admin.Dispatcher)` 测试到新模块。 | 完整 unit suite + scenario 01/07/08/11 |
| **PR-2.4** | 重命名 `Esr.Admin.Commands.*` → `Esr.Commands.*`（git mv + module 名更新；按 R3v1 教训用显式 `alias` 避免 alias-collapse 灾难，模块重命名是命名空间层级）。`internal_kinds:` 段保留 —— 详见上方"`internal_kinds:` 不能扁平合并"。 | `mix compile --warnings-as-errors` + scenario 01/07/08/11 |
| **PR-2.5** | 新建 `runtime/scripts/esr` escript（`mix escript.build`）：`Esr.Cli.Main.main/1`。实现 `esr exec /<slash text>`、`esr help`、`esr describe-slashes`，加上保留 `esr admin submit <kind>` 和 `esr notify` 别名作为一等 kind-direct 路径（不是仅 slash 翻译 —— 详见 PR-2.7 风险）。约 400 LOC。 | escript build + 冒烟 `esr exec /help` + alias 兼容性测试 |
| **PR-2.6** | `esr daemon` lifecycle（launchctl 包装）。先继续保留 Python（`cli/daemon.py` 不动）—— Elixir port 推迟到第四阶段清理。 | 手动冒烟 + scenario 01 |
| **PR-2.7** | 把 e2e 脚本切到新 escript。**不是 sed sweep**：每个 scenario 手工编辑，因为旧 `--arg session_id=X` 不直接映射到 slash schema 的 `name=X`（参数名不同；语义重映射）。PR-2.5 保留 `esr admin submit <kind> --arg K=V` 作为一等路径，所以改动主要是去掉 `uv run --project py` 前缀。约 22 个调用点散落在 `tests/e2e/scenarios/*.sh` + `common.sh`。 | e2e 01/07/08/11 通过新 CLI 全绿 |
| **PR-2.8** | REPL 实现。约 200 LOC。 | REPL 冒烟（spawn cc、进 REPL、`/help`、退出） |
| **PR-2.9** | **删 `py/src/esr/cli/{cap,users,notify,reload,admin}.py`** + uv pyproject.toml 入口移除。约 1100 LOC 删除（review 实测：不是 2200 —— `main.py` 和 `daemon.py` 短期保留，归第四阶段处理）。验证无遗留调用方。 | 完整 suite + e2e + repo 内 grep 旧调用模式 |

PR-2.0 独立（删 voice）。其余必须按序；PR-2.5 起依赖 PR-2.3b + PR-2.4。

### 实际 LOC delta

Subagent review 实测 Python CLI：3083 LOC 跨 10 个文件，其中只有 `cap.py` (229) + `users.py` (403) + `notify.py` (91) + `reload.py` (78) + `admin.py` (90) = **891 LOC** 是干净的第二阶段删除目标。`main.py` (1618 LOC、31 click 命令) 和 `daemon.py` (237 LOC) 承载的功能大部分不在 `slash-routes.yaml` 范围内（adapter 管理、scenario runner、deadletter、trace、debug 等）—— 这些不在第二阶段 scope。

加上：约 200 LOC 的 `Esr.Admin.Dispatcher`（拆分，不全删 —— 约 80 LOC 移到 `CleanupRendezvous`、约 50 LOC 移到 `QueueResult`，真正删的约 70 LOC）+ Watcher 中约 50 LOC 重复逻辑。

新代码：约 400 LOC `Esr.Cli` escript + 约 200 LOC REPL + 约 80 LOC `CleanupRendezvous` + 约 120 LOC `QueueResult` + 约 100 LOC `ReplyTarget` 实现 = 约 900 LOC。

**净删：约 891 + 120 - 900 ≈ 100 LOC**（且架构更干净；价值在单一来源契约统一，不在 LOC 数）。早期"~2500+ LOC 删除"估算是错的 —— 第二阶段的价值在契约统一，不在删代码量。

---

## 四、风险与缓解

### YAML 注释保留

`esr cap grant` 当前用 Python 的 `ruamel.yaml` round-trip 保留 `capabilities.yaml` 中的注释。Elixir 的 `yaml_elixir` **不**保留注释。Subagent review 发现 `etc/capabilities.yaml.example` 在头部 ship 了 11 行注释解释 grant 格式 —— operator 把这文件复制到 `~/.esrd/<env>/capabilities.yaml`，每次 `esr cap grant` 都会静默 strip 这 11 行。这比"informational" 严重。

**策略**（review 后选定）：

1. **头部重新发出**：`Esr.Slash.QueueResult.persist_yaml/2` 和 `Esr.Commands.Cap.Grant` 维护一个硬编码 `@header` 常量，对应 `etc/capabilities.yaml.example` 的注释块。每次写入时 writer 在解析-然后-序列化的 body 之前重新发出 header。Operator 编辑 body 不会丢 header；operator 编辑 header... 那就别编辑（header 是文档不是配置）。
2. **一次性 schema 迁移**：PR-2.4 ship 一个一次性 pass，把 `~/.esrd/<env>/` 下所有 yaml 文件用规范化 header 重新发出，然后才允许后续写入。无损过渡。
3. **PR-2.4 release notes 中说明**：「yaml 注释保留改为 header 重新发出；如果你加了自定义注释，请复制到 operator 笔记 —— 下次写入时会丢失。」

这是 review 推荐选项 (a) "header 重新发出"。可接受；常见模式（kubectl 同样做）。

### escript 分发

escript 打包 BEAM bytecode 但运行时需要 Erlang。**已经存在**（esrd 的 BEAM 同一份安装）。零新增依赖。是否把构建好的 escript 提交到 git？还是安装时构建？选择：安装时构建，由 `scripts/launchd/install.sh` 调 `mix escript.build`。git 干净。

### REPL 交互性

`IO.gets/1` 能用但缺少 tab 补全。Erlang 的 `:edlin` 可调但有点工作量。如果纯 Elixir 自动补全实施起来麻烦，回退方案：用 `rlwrap` 作为外部包装：
```bash
exec rlwrap -C esr -f <(esr describe-slashes --rlwrap-completion) ...
```
`rlwrap` 安装率高，回退优雅。先用 `:edlin` 风格，必要时启用 `rlwrap`。

### Operator 肌肉记忆

旧命令名保留（`esr cap list`、`esr admin submit foo`、`esr notify ...`）—— 这些是新 escript 内部的 alias，最终调 `esr exec`。零关学习。Bash 补全脚本从 schema dump 重新生成。

### 预编译脚本兼容性

调用 `esr admin submit foo --arg bar=baz` 的现有脚本继续工作 —— `esr admin` 在新 escript 中是 thin dispatcher，调 `esr exec foo --bar=baz`。`esr notify` 同样（alias 调 `esr exec notify ...`）。

### 回滚计划

每个 PR 独立 `git revert`，直到 PR-2.9（Python 删除）—— 那个 PR 回滚需要"从前一个 commit restore"，标准 git 工作流。

---

## 五、给第三阶段提供的 plugin 契约

第三阶段 plugin 通过以下机制消费第二阶段的契约：

1. Plugin manifest 的 `slash_routes:` 片段在 boot 时合进 `Esr.Resource.SlashRoute.Registry` —— 第一阶段已经做了。
2. Plugin 的 `Esr.Commands.<Plugin>.<Cmd>` 模块在 boot 时加载到 dispatch 表 —— 第一阶段已经做了。
3. **第二阶段对 plugin 不要求任何额外改动**就能让其命令出现在 CLI/REPL 表面。Plugin 命令自动出现在 `esr help`、`esr describe-slashes --json`、REPL 自动补全和 `esr exec /<plugin-cmd>`，因为 schema 是单一来源。

这就是为什么"plugin → 自动 CLI + REPL + slash"不是 over-engineering：schema 驱动所有四个表面；plugin 贡献 schema 片段；其他自动跟随。

---

## 六、不在本阶段范围

列出供 reviewer 确认 scope：

- **Plugin 物理迁移**（第三阶段，独立 spec）。
- **Channel 抽象**（第三阶段 PR-3.1；`docs/issues/02-cc-mcp-decouple-from-claude.md`）。
- **鉴权模型重构**（独立 brainstorm；`ESR_OPERATOR_PRINCIPAL_ID` 环境变量保留）。
- **同步 slash exec 的 HTTP API**（`POST /admin/exec` JSON body）—— 已提及但推迟到第三阶段 channel 抽象落地之后；admin_queue 文件路径仍是 v1 transport。
- **分发方式（mix release vs escript）** —— v1 选 escript；mix release 是第四阶段清理选项。

---

## 七、待决问题

1. **REPL 行编辑**：edlin vs rlwrap —— 先用 edlin，如果摩擦高再回退 rlwrap。决定推迟到 PR-2.8 实施。
2. **`esr admin submit` alias 保留**：永远保留 backwards-compat，还是 1 个 release 后弃用？建议永远保留 —— 零成本，operator 脚本/wiki 里到处都是。
3. **Schema dump 鉴权**：`/admin/slash_schema.json` 公开还是要求 token？建议 `?include_internal=0` 公开（不暴露权限字符串），`?include_internal=1` 要 token。决定推迟到 PR-2.1。
4. **文件状态机 ownership**：subagent review 抓到今天 watcher **不**拥有文件移动 —— `Esr.Admin.Dispatcher` 才是。第二阶段拆分后，`Esr.Slash.QueueResult` 拥有 `start_processing/1`（pending → processing）和 `finish/2`（processing → completed/failed，包括 secret 脱敏）；Watcher 主循环通过这些调用驱动状态机。Boot 时 stale-`processing/` 恢复迁到 `QueueResult.recover_stale/1`。
