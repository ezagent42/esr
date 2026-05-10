# esrd 管理 —— esrd.sh vs launchd

**适用对象：** 在 macOS 上运行 ESR、需要启动 / 停止 / 重启 / 故障恢复一个 esrd 实例的运维。
**状态：** 截至 2026-05-10 现行有效。
**英文版：** [esrd-management.md](esrd-management.md)。

ESR 对 runtime 守护进程（`esrd`）有**两套**生命周期管理器。搞清楚谁在管你这个实例，是"干净停下"和"僵尸 BEAM 循环"之间的分水岭。

---

## 1. 两套管理器

| 管理器 | 落地物 | 生命周期策略 | 何时使用 |
|---|---|---|---|
| `scripts/esrd.sh` | `$ESRD_HOME/<instance>/esrd.pid`（pidfile） | 一次性启动；手动停止；不自动重启 | 临时的 dev 会话；不希望机器上常驻 agent |
| launchd（`launchctl`） | `~/Library/LaunchAgents/com.ezagent.esrd-<instance>.plist` | KeepAlive=true：launchd 在进程崩溃和被 kill 时自动重启 | 常驻的 dev/prod 环境 —— 是 `--env=dev`、`--env=prod` 的官方默认路径 |

两者**互不协调**。如果同一实例两边同时活跃：launchd 拉起的 BEAM 会占住端口，`esrd.sh` 写出来的 pidfile 指的是另一个（已死的）进程。

实际工作流里，launchd 安装器（`scripts/launchd/install.sh`）是规范路径；`esrd.sh` 是没装 launchd 的环境或测试中使用的兜底（`tests/e2e/scenarios/*` 通过 `ESRD_CMD_OVERRIDE` 调用它）。

---

## 2. 判断当前实例由谁管

按顺序运行下列命令。第一条有输出的就是你的管理器：

```bash
# 1. launchd 已加载？
launchctl list | grep com.ezagent.esrd

# 2. plist 文件存在（无论是否加载）？
ls ~/Library/LaunchAgents/com.ezagent.esrd*.plist 2>/dev/null

# 3. esrd.sh 的 pidfile 存在？
ls ~/.esrd*/*/esrd.pid 2>/dev/null
```

如果 `(1)` 中你这个实例有结果 —— **launchd 在管它**，不要用 `esrd.sh stop`（详见 §5）。
只有 `(3)` 有结果 —— 你走的是 pidfile 路径。

> 自 2026-05-10 起，`esrd.sh stop` 自身会执行 (1)+(2) 检测；如果发现 launchd 在管，会直接拒绝并打印正确的命令给你。

---

## 3. 标准操作 —— 选对工具

### 3.1 启动

| 管理器 | 命令 |
|---|---|
| launchd（一次性安装） | `scripts/launchd/install.sh --env=<dev\|prod\|both>` |
| launchd（安装后 —— KeepAlive 自动启动服务） | 无需操作 |
| esrd.sh | `scripts/esrd.sh start --instance=<name>` |

### 3.2 停止

| 管理器 | 命令 | 效果 |
|---|---|---|
| launchd | `scripts/launchd/uninstall.sh --env=<dev\|prod\|both>` | 完全卸载；删除 plist 文件；`$ESRD_HOME` 下数据保留 |
| launchd（临时） | *按设计不支持* —— KeepAlive=true 意味着 launchd 一定会重启 | 用 uninstall.sh |
| esrd.sh | `scripts/esrd.sh stop --instance=<name>` | 给 pidfile 中的 pid 发 SIGTERM；2 秒后 SIGKILL；删 pidfile |
| esrd.sh 用在 launchd 管的实例上 | （拒绝执行，打印 launchd 入口） | 安全设计：避免 kill / 重启竞态 |

### 3.3 重启

| 管理器 | 命令 |
|---|---|
| launchd | `launchctl kickstart -k gui/$UID/com.ezagent.esrd-<instance>` |
| launchd（通过同一个 CLI） | `scripts/esrd.sh stop --instance=<i> --launchd-restart`（脚本会代理到 launchctl） |
| esrd.sh | `scripts/esrd.sh stop --instance=<i> && scripts/esrd.sh start --instance=<i>` |

### 3.4 状态

| 管理器 | 命令 |
|---|---|
| launchd | `launchctl list \| grep com.ezagent.esrd-<instance>`（最后一列是上次退出码；0 = 干净运行） |
| esrd.sh | `scripts/esrd.sh status --instance=<name>` |

---

## 4. 故障排查

### "我停掉了 esrd，它又回来了"

几乎可以肯定你这个实例装了 launchd plist。症状：`esrd.sh stop` 后几秒，`ps aux | grep mix\ phx.server` 又出现新 PID。原因是 KeepAlive=true。

```bash
# 确认：
launchctl list | grep com.ezagent.esrd

# 修复（彻底停止）：
scripts/launchd/uninstall.sh --env=dev   # 或 prod，或 both
```

### "测试运行留下了僵尸 BEAM"

`mix test` 和 `iex -S mix` 通过 `:exec.run_link/2` 拉起 OS 子进程。BEAM 被硬杀（终端断开、shell 卡住时 `kill -9`、OOM）会让 link 的 exec-port 断开，OS 子进程重新挂到 init 下。2026-05-10 那次清理（见 §6）找到 198 个这种形态的僵尸 BEAM。

现已落地的两层防御：
- `runtime/test/test_helper.exs` 注册了 `System.at_exit/1` 钩子：测试 BEAM 退出前遍历 `:exec.which_children/0`，对每个子进程调用 `stop_and_wait/2`，2 秒 SIGTERM 宽限期后 SIGKILL。
- `esrd.sh stop` 在 launchd 管的实例上拒绝执行（避免 kill / 重启竞态）。

如果以上仍然出现僵尸：

```bash
# 盘点：
ps -eo pid,ppid,command | grep -E 'beam.*phx.server|feishu_adapter_runner'

# 批量清掉孤儿 BEAM（init 收养的、没有 controlling tty 的）。
# 仅在没有正在使用的活的 esrd 时使用，或按 ppid=1 精确目标。
# （注意：launchd 拉起的 esrd-dev 也是 ppid=1，先确认 launchctl list。）
ps -eo pid,ppid,command | awk '$2 == 1 && /mix phx.server/ { print $1 }' | xargs -n1 kill -TERM
```

### "esrd.sh start 提示 'already running'，但我连不上"

pidfile 是脏的，指向一个早已死掉的 PID，但路径上的检查恰好过了，因为另一个进程现在占用了那个 PID 号。绕过：

```bash
rm "$ESRD_HOME/<instance>/esrd.pid"
scripts/esrd.sh start --instance=<instance>
```

---

## 5. 为什么 `esrd.sh stop` 在 launchd 管的实例上要拒绝执行

2026-05-10 之前，`esrd.sh stop` 会愉快地给 pidfile 里的 BEAM 发 SIGTERM。那个 BEAM 有时是 launchd 拉起的；launchd 的 `KeepAlive=true` 立刻又重启一个。运维看到 `esrd[<i>] stopped` 就以为成功了 —— 紧接着的下一步操作（启动、端口探测、smoke-* 清理）和重启竞态，从迷惑日志到真实僵尸进程都可能发生。

修复：`cmd_stop` 调用 `is_launchd_managed`（plist 文件 + `launchctl list` 命中），命中即短路并打印正确工具的指引。需要"踢一下当前 launchd 管的进程"的运维可以传 `--launchd-restart`，脚本会代理到 `launchctl kickstart -k`。

实现细节见 commit "chore(scripts): esrd.sh stop detects launchd-managed instance"。

---

## 6. 参考：2026-05-10 僵尸 BEAM 清理事件

观察到的状态：

- 198 个僵尸 BEAM（全部在跑 `mix phx.server` 或 `mix test` 后台 BEAM）
- 78 个孤儿 `feishu_adapter_runner` python 旁车进程（每一个 = 一个僵尸 BEAM 经由 erlexec exec-port 拉起的子）
- 进程关系链：`BEAM（init 收养）→ erlexec exec-port → python 旁车`

根因：几个月里测试和 dev 会话的 BEAM 没有任何一次干净退出。硬杀（终端关闭、`kill -9`、OOM）绕过了 erlexec 的 `:kill_timeout`，孤立 exec-port，旁车进而挂到 init 下。

清理动作：

```bash
ps -eo pid,ppid,command | awk '$2 == 1 && /mix (phx.server|test)/ { print $1 }' | xargs -r kill -TERM
sleep 5
ps -eo pid,ppid,command | awk '$2 == 1 && /mix (phx.server|test)/ { print $1 }' | xargs -r kill -KILL
```

结果：剩 1 个 BEAM —— 正在被用户用来测 Feishu 的 launchd 管的 esrd-dev。

同窗口落地的预防修复：
1. `runtime/test/test_helper.exs` 中的 `System.at_exit/1` 钩子 —— 测试 BEAM 退出前先杀 exec 子进程。
2. `esrd.sh stop` 的 launchd 检测 —— launchd 管的实例上拒绝 pidfile-stop（本次提交）。
3. 本文档。

---

## 7. 相关文档

- `docs/operations/dev-prod-isolation.md` —— 完整的 dev/prod 双 esrd 安装与日常运维
- `docs/notes/erlexec-migration.md` —— `Esr.OSProcess` 为什么用 erlexec，以及 BEAM 退出时的清理保证（test_helper.exs 现在为它兜底）
- `docs/notes/erlexec-worker-lifecycle.md` —— PR-21β 的孤儿进程事故复盘（8 倍孤儿，是从 `spawn_worker.sh` 迁移到 erlexec 的动因）
- `scripts/launchd/install.sh` / `scripts/launchd/uninstall.sh` —— launchd 规范入口
- `scripts/esrd.sh` —— pidfile 兜底（现已感知 launchd）
