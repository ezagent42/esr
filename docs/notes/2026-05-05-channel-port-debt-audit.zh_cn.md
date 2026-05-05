# Channel-Server 移植债务审计

**日期：** 2026-05-05
**范围：** channel-server 原始移植以来沉积的技术债 + Python 侧残留，作为 Phase 2/3 plugin 迁移启动前的检查。
**回答的问题：** "在 Phase 2/3 之前先做一轮破坏性清理，是否能让后续工作更清晰？"
**结论：** **未发现挡路（BLOCKING）债务。** 当前代码状态没有污染 Phase 2/3 spec 的设计假设。只有两个文件够格"立即删"；其它要么本就**不是债**，要么会被 Phase 2/3 工作**自然清理**。

---

## 方法

三路 agent 并发扫描，每条 finding 按以下分桶：
- **DELETE NOW** —— 孤立、零调用方、无设计含义。
- **BLOCKING** —— 必须在 Phase 2/3 之前清掉，否则 spec 的假设站不住。
- **ALONG-THE-WAY** —— 在 Phase 2 / Phase 3 / Phase 4 工作中被自然清理。
- **TAIL** —— 留到 Phase 4 也无所谓。
- **NOT DEBT** —— 看起来可疑但抽象其实是对的。

三路覆盖：(1) `py/src/esr/`，(2) `runtime/lib/esr/` 中 channel 移植残留，(3) `scripts/` + `tests/` shell 工具。

---

## DELETE NOW

| 文件 | LOC | 为何已死 | 调用方 |
|---|---|---|---|
| `py/src/esr/cli/daemon.py` | 237 | macOS launchctl 的 `esrd` 包装器。当前没有运维通过 `uv tool install esr` 安装。开发启动直接走 `scripts/esrd.sh`。 | e2e 0 处，Elixir 0 处，仅 `cli/` 内部自引用 |
| `tests/e2e/_helpers/dev_channels_unblock.sh` | 65 | PR-186 已落地 FCP 进程内自动确认。Scenario 07 用 `\|\| true` 调用此 helper（第 126 行注释明确写了 "redundant safety net"）。 | 1 处（scenario 07），且容错调用 |

**可回收：约 302 LOC + e2e 中的 `websocat` 运行时依赖。**

风险：约等于零。两份文件都有显式的"被 X 取代"标记，且无承重调用方。

---

## BLOCKING（Phase 2 之前必须修）

**（空）**

Elixir 侧审计专门核查了我之前在 Phase 2 spec 中假定为挡路的几项：

| 怀疑项 | 审计结论 |
|---|---|
| Reply 路径缺 `Esr.Slash.ReplyTarget` behaviour，硬编码 FeishuChatProxy 路径 | NOT DEBT —— `SlashHandler.dispatch/2,3` 接受调用方传入的 `reply_to` pid；路由本就 adapter 无关。引入 ReplyTarget behaviour 只会比现有 pid 模式增加摩擦。 |
| CCProcess 有 4 处 feishu 硬编码 | NOT DEBT —— 5 处 grep 命中，全是防御性兜底，dispatch 中没有。`build_channel_notification/2` 中的 "feishu" 字符串是缺失时的默认值，不是断言。 |
| `Esr.Admin.Dispatcher` 混合 3 个职责 | ALONG-THE-WAY —— 三个职责物理上同居，但已按 handler 干净拆分；Phase 2 spec 已规划好拆分（PR-2.4/2.5）。不挡路，**这就是工作本身**。 |
| Scope.Router vs AgentSpawner 注入 platform proxy 边界模糊 | NOT DEBT —— Router 第 8–13 行只是文档注释残留；AgentSpawner 才是真实注入点，边界清晰。 |
| cleanup_signal 收发路径过期 | NOT DEBT —— 双向路径完整（Dispatcher 在 L237–260 接收，Server 在 L898 发送）。 |
| `Esr.Admin.*` 命名空间住户 | TAIL —— Phase 4 PR-4.3 按计划折叠。 |

**含义：** Phase 2 spec 中"需要拆 Dispatcher / 引入 ReplyTarget"的措辞，**就是工作本身**，不是预清理。Phase 2 可以直接开始，无需前置清理。

---

## ALONG-THE-WAY（Phase 2/3 自然清理）

| 项目 | 由谁清理 |
|---|---|
| `py/src/esr/cli/main.py`（1618 LOC、31 个 click 命令；约 10 个未用） | Phase 2 PR-2.9 —— Elixir 原生 CLI 整体替代 |
| `py/src/esr/cli/notify.py`（91 LOC） | Phase 2 |
| `py/src/esr/cli/reload.py`（78 LOC） | Phase 2 |
| `py/src/esr/cli/users.py`（403 LOC，PR-21a 多用户的脚手架，未启用） | Phase 2 |
| `py/src/esr/cli/cap.py` + `admin.py`（319 LOC） | Phase 2 |
| `py/src/esr/cli/adapter/feishu.py`（7032 LOC —— 注：大部分是自动生成 + create-app 向导） | Phase 2（Elixir 移植）或 Phase 3（移入 feishu plugin） |
| `Esr.Admin.Dispatcher`（整个模块） | Phase 2 PR-2.1 删除 |
| `Esr.Scope.Admin.bootstrap_feishu_app_adapters/1` | Phase 3 PR-3.3 迁入 feishu plugin 启动钩子 |
| CCProcess 的 feishu 兜底字符串（防御性默认值） | Phase 3 拓扑完全 plugin 注入后 |
| `pre-merge-dev-gate.sh` 中 agent-browser 内联调用 | 可后续折入 `tools/esr-debug` —— 不挡路 |

---

## TAIL（Phase 4）

| 项目 | Phase 4 PR |
|---|---|
| `Esr.Admin.*` 命名空间删除（把 `CommandQueue.Watcher` 迁到 `Esr.Slash.QueueWatcher`） | PR-4.3 |
| `permissions_registry.json` 跨语言 dump | PR-4.4 |
| `py/src/esr/cli/` venv 移除 | PR-4.7 |
| `py/src/esr/verify/`（`esr lint` 工具，约 80 LOC，零调用方） | PR-4.6 |
| `scripts/esr-cc.local.sh`（10 LOC，gitignored，运维按需创建） | PR-4.6 若仍未用 |

---

## NOT DEBT（本就正确）

- **Slash dispatch 抽象** —— `SlashHandler.dispatch/2` 通过调用方传入的 reply pid 实现 adapter 无关。
- **Adapter 命名** —— `adapter_runner` 是 ESR 自己的命名，不是 channel-server 导入。
- **CCProcess neighbor 偏好** —— 优先 `feishu_chat_proxy`，回退 `cc_proxy`。回退是干净的多态，不是耦合。
- **代码注释中无 "channel-server" / "channel_server" 字符串** —— 移植没留指纹。

---

## 建议

### 方案 A —— 保守（约 302 LOC 回收，零风险）

Phase 2 启动前一个小 PR：
1. 删除 `py/src/esr/cli/daemon.py`。
2. 删除 `tests/e2e/_helpers/dev_channels_unblock.sh` 及其在 scenario 07 中的调用行。
3. 跑 scenario 07 + 08 + 11 确认通过。

**推荐方案。** 这正是用户授权的"尽早清除"，纯粹的孤立移除，并能消除 e2e 的 `websocat` 依赖。

### 方案 B —— 中度（约 1,200 LOC 回收）

方案 A + 删除 `cli/notify.py`、`cli/reload.py`、`cli/users.py`、`cli/verify/`，并在 `main.py` 中移除它们的 click group 注册。**注意：** 需要编辑 `main.py` 删注册行，但 Phase 2 PR-2.9 反正会重写整个 `main.py`。净效果：做两遍。除非想让 `main.py` 更小、更便于 Phase 2 设计阅读，否则跳过。

### 方案 C —— 激进（删除整个 `py/src/esr/cli/`）

跳过 —— 这本来**就是** Phase 2 PR-2.9 的工作。提前做意味着中间一段时间没有 `esr` CLI 可用。

---

## 待决策

用户从 A / B / C 中选择，或推翻审计的整个框架。

若选 A：我开一个小 PR（`feature/audit-immediate-cleanup`），删两个文件，跑 e2e，合并，然后启动 Phase 2 PR-2.0。

若选 B：上面那个 PR 加上 click group 注册编辑。面更广，但都是机械性工作。

若选 C：审计建议否决；直接启动 Phase 2 即可。
