# Phase 4 — 清理收尾

**日期：** 2026-05-05
**状态：** 草案，待用户审阅。
**前置：** Phase 2 + Phase 3 必须先合并。
**后续：** 无 —— 这是清理尾段。

---

## 一、为什么需要这个阶段

Phase 1–3 都会交付过渡代码。这是有意为之的设计 —— 我们倾向于"先加新路径，再删旧路径"的渐进式迁移，而非大爆炸式重写。这样每个 PR 都能独立审阅、独立合并、独立回滚。代价是当尘埃落定后，仓库里会残留：

- `Esr.Application.start/2` 中的 fallback 注册，仅仅因为 Phase 1 的 stub manifest 并未真正接管这些数据。
- 旧的 bash + websocat dev-channels 解锁脚本，已被 Phase 1 PR-186 中 FCP 进程内自动确认替代。
- Stub manifest（Phase 1 PR-180 创建的最小 voice/feishu/claude_code 三个）—— voice 在 Phase 2 PR-2.0 中删除；feishu/claude_code 在 Phase 3 中被完整 plugin 目录替代。
- `Esr.Admin.*` 命名空间 —— Phase 2 删除 Dispatcher 并重命名 Commands 之后，剩下的只是几个非 admin 的守卫（PendingActionsGuard、CapGuard），不足以撑起一个顶层命名空间。
- 重复的 `permissions_registry.json` JSON dump（为 Python CLI 的 `cap list` 创建）—— 一旦 Elixir 原生 CLI 直接对接 registry，这份 dump 就成了死代码。
- 几个 Python CLI 子模块，Phase 2 PR-2.9 没动它们，因为它们覆盖的是 slash schema 之外的功能：`daemon.py`、`main.py` 中 31 个命令（adapter 管理、scenario runner、deadletter、trace、debug）。Phase 4 决定每个子命令的命运。
- 被 `tools/esr-debug`（PR-187）替代的旧 e2e 辅助脚本：`tests/e2e/_helpers/dev_channels_unblock.sh`。

Phase 4 的目标是把所有这些清理合并成一个干净的 PR 系列，**没有任何行为变化** —— 每一处删除都必须从结构上保证安全（即新路径已在 Phase 1–3 中被验证完全覆盖旧路径）。

### 目标

1. Phase 4 之后，`py/src/esr/cli/` 下若还有 Python，那必然是 Phase 4 明确决定保留并附带书面理由的部分。
2. `Esr.Application.start/2` 表现为"先启动 core，再请求 plugin 注册其贡献"，**不包含任何 plugin 特定知识**。
3. Stub manifest 删除完毕；只有真实的 plugin manifest 存在于 `runtime/lib/esr/plugins/<name>/manifest.yaml`。
4. `Esr.Admin.*` 命名空间要么解决到剩下的住户，要么完全合并到别处，无任何悬挂引用。
5. `tests/e2e/_helpers/` 只包含真正在用的内容。
6. 文档反映 Phase-4 之后的现实（无"feishu plugin 即将到来"之类的过期表述）。

### 非目标

- 新功能。Phase 4 完全是关于删除 + 整理。
- Auth 模型变更（仍是单独的 brainstorm 议题）。
- 分发打包（mix release 等）—— 如果运维团队想要的话可作为 Phase 5。

---

## 二、清理范围

### Group A —— `Esr.Application.start/2` 中 plugin 特定的 bootstrap

Phase 1 之后，`Esr.Application.start/2` 注册 fallback 的 Sidecar 映射（`feishu → feishu_adapter_runner`、`cc_mcp → cc_adapter_runner`），以便在 plugin manifest 接管之前，已有测试不会破。Phase 3 落地后，manifest 接管这些。**删除 fallback** （约 6 行）。

`Esr.Application` 和 `Esr.Scope.Admin` 中的 `bootstrap_feishu_app_adapters/0` 及类似 feishu 特定的 bootstrap，迁入 feishu plugin 自己的启动钩子（Phase 3 PR-3.3 完成概念上的迁移；Phase 4 验证旧函数已死并删除）。

`bootstrap_voice_pools/1` 在 Phase 2 PR-2.0 中已删除；Phase 4 仅验证并清理任何残留的死调用点。

**测试**：scenario 01/07/08/11 仍然通过。`Esr.Application.start/2` 必须能在 `enabled_plugins: []` 下干净地编译并启动（Phase-1 PR-2.7 的 e2e 08 已经覆盖这点）。

### Group B —— Phase-1 stub manifest

PR-180 在 `runtime/lib/esr/plugins/{voice,feishu,claude_code}/manifest.yaml` 添加了 3 个 stub manifest，只是**声明** core 中已经包含的内容。在以下事件之后：

- Voice 删除（Phase 2 PR-2.0）：`voice/` 目录已经消失。
- Feishu 完整抽离（Phase 3 PR-3.3 + PR-3.4）：`feishu/` manifest 现在指向同目录中的真实模块。
- Claude_code 完整抽离（Phase 3 PR-3.6 + PR-3.7 + PR-3.8）：`claude_code/` manifest 现在指向同目录中的真实模块。

**Phase-4 对 stub manifest 没有清理工作** —— Phase 3 已经在迁移过程中用真实 manifest 覆盖了它们。Phase 4 只需验证 manifest 描述的是真实 plugin 内容（CI 守卫：每个 manifest 中 `entities:` 声明的模块都必须可加载；每个 `python_sidecars:` 引用的模块必须在磁盘上存在）。

### Group C —— 旧的 bash + websocat 辅助脚本

`tests/e2e/_helpers/dev_channels_unblock.sh` 在 PR-186 的 FCP 进程内自动确认落地后（2026-05-04），仍然被保留在 scenario 07 中作为"冗余的安全网"。先验证这层安全网不必要，再删除：

- 在 scenario 07 中把 helper 这一行注释掉，连续运行 5 次（当前行为：通过 —— 已在 2026-05-04 手工验证）。
- 删除 `dev_channels_unblock.sh` 文件本身，以及 scenario 07 中的 `BOOTSTRAP="$(...)/dev_channels_unblock.sh"` 这一行。
- 删除 scenario 07 step 2 中的调用点。

**测试**：scenario 07 连续 5 次通过。

### Group D —— `Esr.Admin.*` 命名空间的归宿

Phase 2 删除 `Esr.Admin.Dispatcher` 并将 `Esr.Admin.Commands.*` 重命名为 `Esr.Commands.*` 之后，`Esr.Admin.*` 命名空间只剩：

- `Esr.Admin.CommandQueue.Watcher` —— 文件 watcher；Phase 2 之后它只是 SlashHandler 的薄包装。迁到 `Esr.Slash.QueueWatcher`（更靠近它的同类 `Esr.Slash.QueueResult` + `Esr.Slash.CleanupRendezvous`）。
- `Esr.Admin.Supervisor` —— 上面 watcher 的 supervisor。要么并入 `Esr.Slash.Supervisor`，要么直接删掉、把 watcher 挂到顶层 `Esr.Supervisor` 的 children 列表里。

迁完之后，`Esr.Admin.*` 没有住户 —— 命名空间本身从 `mix.exs` 查找路径以及任何 moduledoc 引用中删除。

`PendingActionsGuard` 和 `CapGuard` **今天就不在** `Esr.Admin.*` 中（它们在 `EsrWeb.PendingActionsGuard` 和 `Esr.Entity.CapGuard`）；review 抓出原 spec 的措辞错误。它们留在原位。

**测试**：重命名 + supervisor 重整之后全套测试通过。

### Group E —— `permissions_registry.json` 跨语言 dump

今天 `Esr.Resource.Permission.Registry.dump_json/1` 把权限表写到 `~/.esrd/<env>/permissions_registry.json`，让 Python 的 `esr cap list` 不用走 RPC 也能漂亮打印。Phase 2 的 Elixir 原生 `esr cap list` 直接调用 registry 之后，这份 JSON dump 就没人读了。

- 验证没有调用方读这份文件（`grep permissions_registry.json runtime/ py/`）。
- 删除 `dump_json/1` 函数本身，以及 `Esr.Resource.Permission.Bootstrap` 中启动期对它的调用。
- 在运维 setup 笔记里删除任何 `~/.esrd/<env>/` 中曾被 check-in 的该文件。

**测试**：`esr cap list`（新的 Elixir 原生）返回相同内容；全套测试通过。

### Group F —— Phase 2 PR-2.9 之外残留的 Python CLI

`py/src/esr/cli/main.py`（1618 LOC、31 个 click 命令）和 `daemon.py`（237 LOC）在 Phase 2 之后仍然存活，因为它们覆盖的是 slash schema 之外的功能。Phase 4 给每个幸存命令归类：

| 命令 | 类别 | Phase 4 动作 |
|---|---|---|
| `esr daemon {start,stop,status,restart,doctor}` | lifecycle（launchctl） | 移植到 escript（约 80 LOC Elixir 替代 237 LOC Python） |
| `esr use <host:port>` | dev 实例切换 | 移植到 escript 或 shell 函数（trivial） |
| `esr status` | esrd 健康检查 | 通过 slash 路由 + JSON 序列化移植到 escript |
| `esr drain` | 维护 | 通过 slash 路由移植到 escript |
| `esr trace` | 遥测 | 当前通过 dist Erlang 调用 BEAM；可移植，也可保留为薄 Python shim |
| `esr lint <path>` | yaml lint | 通过 Elixir slash + yaml parser 移植；或彻底删除（运维很少用） |
| `esr scenario run` | e2e runner | 这只是 shell 出 `bash tests/e2e/scenarios/...` —— escript 中改成薄 shell wrapper |
| `esr adapters list` | adapter 表 | 通过 slash 路由 + JSON 移植 |
| `esr adapter {add,remove,rename,install}` | adapter 管理 | 每个都是 admin_queue 提交；移植到 slash + escript |
| `esr handler install` | handler 安装 | admin_queue 提交 |
| `esr cmd {list,install,show,compile}` | 编译产物管理 | 通过 slash 路由移植 |
| `esr actors list` | actor 清单 | 通过 slash 路由移植到 escript |
| `esr deadletter` | deadletter 检查 | 移植 |
| `esr debug` | debug 命令 | 已被 `tools/esr-debug`（PR-187）大量覆盖 —— 删除整个 click `esr debug` group |

Phase 4 估算：约 600 LOC Elixir 替代 ~1900 LOC Python。净删 ~1300 LOC。

**测试**：全套测试通过；e2e 脚本完成迁移；`esr` CLI 不再有 `uv run` 入口点。

### Group G —— Python venv 移除

Group F 完成之后，`py/src/esr/` 下唯一可能残留的是 `runtime_bridge.py`（esrd lifecycle）和 `paths.py`（路径常量），即便它们也可以内联折入 escript 或直接删除。之后：

- `py/pyproject.toml` 失去 `esr` console_scripts 入口点。
- 整个 `py/src/esr/cli/` 删除。
- 通过 `uv tool install esr` 安装的运维需要重装，指向新的 Elixir escript 二进制。

**测试**：`which esr` 解析到 escript 二进制；`esr` 成功运行。

---

## 三、迁移顺序

Phase 4 在结构上比 Phase 1–3 风险都低（它只是删除）。每个 PR 都可以小且独立。

| PR | Group | 范围 | 测试门 |
|---|---|---|---|
| **PR-4.1** | A | 删除 `Esr.Application.start/2` 中已被 manifest 取代的 plugin 特定 bootstrap。 | scenario 01/07/08/11 通过 |
| **PR-4.2** | C | 删除 `tests/e2e/_helpers/dev_channels_unblock.sh` + scenario 07 调用点。 | scenario 07 连续 5 次通过 |
| **PR-4.3** | D | 把 `Esr.Admin.CommandQueue.Watcher` 迁到 `Esr.Slash.QueueWatcher`；重整监督树；删除空的 `Esr.Admin.*` 命名空间。 | 全套测试 |
| **PR-4.4** | E | 删除 `permissions_registry.json` dump + Python `cap list` 中文件读取代码路径（Phase 2 已替换消费者）。 | scenario 01/07/08/11 + `esr cap list` 冒烟 |
| **PR-4.5** | B | 添加 CI 守卫，验证每个 plugin manifest 的 `entities:` 与 `python_sidecars:` 都是真实存在的。 | 新门测试 |
| **PR-4.6** | F | 逐命令移植：`main.py` 中每个 click 子命令在自己的 commit 中被移植或删除。约 14 个子 PR，按类别嵌套或分组。 | 全套测试 + 每组 e2e |
| **PR-4.7** | G | 最终移除：`py/pyproject.toml` 入口点、`py/src/esr/cli/`、uv tool install 文档。运维重装。 | 运维手工验证 |

依赖关系：PR-4.1 → PR-4.5（先验证再加严）；PR-4.6 → PR-4.7（先移植再删除）；其它独立。

---

## 四、风险与缓解

### "死代码"其实还活着

grep 可能漏掉调用方（字符串拼接、Code.eval、动态 atom）。缓解：每个"删除 X"的 PR 都跑全套 + 4 个 e2e scenario。如果有隐藏调用方，e2e 会失败把它暴露出来。

### 运维对 `esr` 重装感到惊讶

Phase 4 Group G 改变了运维安装 `esr` 的方式。缓解：在 PR-4.7 的 commit message 中给出清晰的迁移说明；在删除前的一个 minor 版本里给 `py/pyproject.toml` 的 `esr` 脚本钉一个废弃通知（即让 Python 入口点打印"this is now an Elixir escript; please install via `mix escript.install`"并退出）。

### 测试 fixture 引用了已删除的 helper

`scenario 07` 通过 `BOOTSTRAP="$(...)/_helpers/dev_channels_unblock.sh"` source 这个文件。如果删了文件却漏掉 source 行，scenario 会以 `command not found` 失败。缓解：PR-4.2 同时原子地删除两者；CI 门跑 scenario 07。

### `Esr.Admin.*` 重命名打破 supervisor child specs

今天 `Application.start/2` 把 `Esr.Admin.Supervisor` 列为 child。重命名/删除会破坏启动。缓解：PR-4.3 同一个 diff 内同时落地重命名 + supervisor 列表编辑；二者无法分离。

### 文档腐化

`Esr.Admin.*` 一旦删除，每篇提到它的文档都会出错。缓解：PR-4.3 在 `docs/`、`docs/notes/`、`docs/operations/` 中 grep `Esr.Admin\.`，逐处更新或删除。

---

## 五、范围之外

- 分发打包（mix release vs escript）—— 可作为 Phase 5。
- Auth 模型变更。
- 添加新 plugin（tlg / codex 等）—— 那是 Phase 4 落地之后正常的产品工作。
- 重写测试（Phase 4 纯粹是删除；测试重写在 Phase 2/3 中已经做了）。

---

## 六、待澄清的问题

1. **`tests/e2e/_helpers/`** —— 这个目录还需不需要？如果现在只有 `tools/esr-debug` 在用，helpers 目录可能直接为空。决定推迟到 PR-4.2 实现时。
2. **`scenarios/e2e-*.yaml` 引用**：scenario yaml 文件的 setup 节引用了 Python `uv run` 路径；PR-4.6 必须更新这些。容易。
3. **`Esr.Admin.Supervisor` 最终归宿**：放在 `Esr.Slash.Supervisor` 下还是顶层 `Esr.Supervisor` 下？建议 `Esr.Slash.Supervisor`（重命名后唯一的 child 是 `Esr.Slash.QueueWatcher`）。
4. **Phase 5 分发**：如果运维团队想要 `mix release` 打包代替 escript，单独 brainstorm。不属于 Phase 4。
