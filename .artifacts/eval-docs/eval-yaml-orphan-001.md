---
type: eval-doc
id: eval-yaml-orphan-001
status: draft
producer: skill-5
created_at: "2026-04-21"
mode: verify
feature: "YAML declarative state vs runtime reconciliation (orphan Python workers)"
submitter: Sy Yao
related: [coverage-matrix-001, issue-001]
github_issue: "https://github.com/ezagent42/esr/issues/7"
---

# Eval: YAML 声明式状态 vs 运行时对账（孤儿 Python worker）

## 基本信息
- 模式：验证 (verify)
- 提交人：Sy Yao
- 日期：2026-04-21
- 状态：draft

## 问题概述

ESR 的架构契约是：`adapters.yaml` + `Esr.Topology.Registry` 是"应运行"的声明式 source of truth，`Esr.WorkerSupervisor` 管理"实际运行"的 Python 子进程。两者之间**没有对账（reconciliation）机制**，因此出现了 4 种运行时漂移场景 —— Python 进程在跑，但 YAML / Topology 里没有对应的声明。这些进程成为孤儿：继续往 Phoenix Channel 重连、占内存、占 fd，但没有任何正常运维操作能发现或清理它们。

根本原因：`Esr.WorkerSupervisor` 只暴露 `ensure_adapter/4` 和 `ensure_handler/3`（`runtime/lib/esr/worker_supervisor.ex:53-76`），**没有 `stop_*` / `remove_*` 任何形式的移除 API**。

## Testcase 表格

| # | 场景 | 前置条件 | 操作步骤 | 预期效果 | 实际效果 | 差异描述 | 优先级 |
|---|------|---------|---------|---------|---------|---------|--------|
| 1 | `esr cmd stop <name>` 后 Python worker 应被停掉 | 至少一个 topology 已实例化运行（如 `feishu-app-session`），对应的 Python adapter_runner / handler_worker 子进程在跑 | 1. `esr cmd stop feishu-app-session`<br>2. `ps aux \| grep esr.ipc.adapter_runner`<br>3. `esr actors list` | `ps` 无 adapter_runner；Elixir actor 列表为空 | Elixir actor 被 `PeerSupervisor.stop_peer` 杀掉、Registry ETS 条目被删（`runtime/lib/esr/topology/registry.ex:89-105`），**但 Python 子进程继续跑**。`channel_client.py:22-29` 让它以 30s 间隔永远重连 `ws://127.0.0.1:4001`。 | deactivate 路径完全不触及 WorkerSupervisor；Python worker 成孤儿 | P0 |
| 2 | topology 实例化中途失败（rollback）应清理已起的 Python worker | 一个 topology 有多节点，某节点的 `init_directive` 超时或 handler 加载失败 | 1. `esr cmd run feishu-thread-session tag=bad`（构造让 tmux new_session 超时的参数）<br>2. 观察 rollback 日志<br>3. `ps aux \| grep esr.ipc.` | rollback 同时清理 PeerServer + Python worker；`ps` 无残留 | `rollback_spawned/2`（`runtime/lib/esr/topology/instantiator.ex:338-350`）**只调 `PeerSupervisor.stop_peer` 和 `HubRegistry.unbind`，不触及 WorkerSupervisor**。每次失败重试多一批 Python 孤儿。 | rollback 设计遗漏：前面 `ensure_handler`/`ensure_adapter` 已经起了子进程（`:393,399`），失败时只清 Elixir 侧 | P0 |
| 3 | 编辑 `adapters.yaml` 删条目后重启 esrd，应杀掉已退役的 Python worker | `adapters.yaml` 原有 N 个 adapter 实例且都在跑；手动删除其中一个（如 "feishu-stage"）| 1. 编辑 `~/.esrd/default/adapters.yaml` 删 feishu-stage<br>2. `kill -TERM esrd && 重启 esrd`<br>3. `ps aux \| grep esr.ipc.adapter_runner` | 被删除的 adapter 对应的 Python 进程不在 `ps` 里；pidfile 被清理 | `restore_adapters_from_disk/2`（`runtime/lib/esr/application.ex:101-137`）**只遍历 YAML 声明的条目**。旧的孤儿 pidfile 指向的 Python 进程不在 YAML 里，就没人看它。Python 继续活，成功重连回新 esrd，形成一个 YAML 根本不知道的 adapter binding。| YAML 是"上船时登记册"，read-once；之后不再对比，没有"YAML 里没有就 kill"的清理逻辑 | P1 |
| 4 | 人工启动的 Python worker 应被拒绝或主动清理 | esrd 运行中 | 1. 任意 shell 执行 `uv run python -m esr.ipc.adapter_runner --adapter fake --instance ghost --url ws://127.0.0.1:4001/adapter_hub/socket/websocket?vsn=2.0.0`<br>2. `esr actors list` / 查 AdapterHub.Registry | Elixir 拒绝注册未授权的 adapter（无对应 YAML 声明），或有告警 | Phoenix `AdapterSocket` 无鉴权（`runtime/lib/esr_web/adapter_socket.ex`），任何能连上 WS 的进程都能注册为 adapter；AdapterHub.Registry 接受绑定，且 **WorkerSupervisor 不跟踪它**（因为不是通过 `ensure_*` 来的） | 缺少"未在 YAML 声明就不接受"的鉴权；缺少对 AdapterSocket 的 token/签名 | P2 |

## 证据区

### 日志/代码引用

**核心证据 1：`WorkerSupervisor` 无移除 API**

```
$ grep -n 'ensure_\|remove_\|stop_\|terminate_\|kill_' runtime/lib/esr/worker_supervisor.ex
53:  @spec ensure_adapter(String.t(), String.t(), map() | String.t(), String.t()) ::
55:  def ensure_adapter(adapter_name, instance_id, config, url)
68:  @spec ensure_handler(String.t(), String.t(), String.t()) ::
70:  def ensure_handler(handler_module, worker_id, url)
312:  defp kill_pid(pid) do   # 私有，只在 terminate/2 调，不对外暴露
```

**核心证据 2：`Topology.Registry.deactivate/1` 不调 WorkerSupervisor**

```elixir
# runtime/lib/esr/topology/registry.ex:89-105
def deactivate(%Handle{...peer_ids: peer_ids}) do
  for id <- Enum.reverse(peer_ids) do
    Esr.PeerSupervisor.stop_peer(id)        # 只杀 PeerServer
  end
  :ets.delete(@table, key_for(name, params))
  :telemetry.execute([:esr, :topology, :deactivated], ..., %{
    name: name, params: params, peer_ids: peer_ids
  })
  :ok
end
```
注意：`peer_ids` 是 Elixir actor IDs，不是 Python worker keys。

**核心证据 3：`rollback_spawned/2` 不清理 Python worker**

```elixir
# runtime/lib/esr/topology/instantiator.ex:338-350
defp rollback_spawned(ids, by_id) do
  Enum.each(ids, fn id ->
    Esr.PeerSupervisor.stop_peer(id)        # 只杀 PeerServer
    case Map.get(by_id, id) do
      %{"adapter" => adapter, "id" => node_id} when is_binary(adapter) ->
        HubRegistry.unbind("adapter:#{adapter}/#{node_id}")   # 只解绑
      _ -> :ok
    end
  end)
end
```
前面 `:393,399` 已调用 `WorkerSupervisor.ensure_{handler,adapter}` 起了 Python 子进程，rollback 不清。

**核心证据 4：Python 永久重连无上限**

```python
# py/src/esr/ipc/channel_client.py:22-29
#  - On WS disconnect, schedule a reconnect task with exponential
#    backoff (default 1s, 2s, 4s, 8s, capped at 30s).
#  - ``push()`` calls during the disconnect window queue into a
#    bounded deque (``PENDING_PUSH_CAP``, default 1000); overflow drops
#    oldest. This matches PRD 03 F05's exact numbers.
```
无 max_attempts 上限 —— Python adapter_runner 会永远每 30s 尝试重连，直到被外部 `kill`。

**核心证据 5：pidfile 堆积（实测）**

```
$ ls /tmp/esr-worker-*.pid | wc -l
# bootstrap 会话执行后，/tmp 中有 30+ 条 stale pidfile，指向早就死掉的 pid
# WorkerSupervisor 不扫也不清
```

### 复现环境

- 操作系统：Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu 24.04.3 LTS)
- 软件版本：Elixir 1.19.5 / OTP 28.4.2；Python 3.13 (py/.venv)；uv 0.7.15
- 配置：ESR v0.2-channel 分支（feat/sy-discuss，commit d34304b）；默认 `mix.exs` + `py/pyproject.toml`
- 测试基线：636 tests / 630 passed（`.artifacts/bootstrap/test-baseline.json`）—— 全部绿路径测试均通过，说明这不是"功能没做完"的 bug 而是**边界路径没覆盖**的设计缺口

## 分流建议

**建议分类**：疑似 bug（设计缺口类）

**判断理由**：

1. **违反了 YAML-as-source-of-truth 的架构契约** —— `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` §2 明确 YAML 是 Command 层的 canonical artifact，Elixir 应照章执行；现状里 Elixir 只在启动时 read-once，没有任何"持续对账"的语义。

2. **稳定可复现** —— testcase 1 和 2 是正常运维路径（`esr cmd stop` 和 topology 实例化失败），每次都会产生孤儿，没有依赖任何偶发条件。

3. **后果累积** —— 孤儿不会自我清理，长时间运行后会占用越来越多内存 + 网络 fd + pidfile 磁盘空间。配合另外两个已知问题（ELIXIR-1 flaky 也可能触发 rollback；`:esr_actor_states` ETS 表无 TTL），v0.2 的长跑稳定性存在系统性风险。

4. **但不是"功能坏了"类 bug** —— 健康路径（启动 → 运行 → 正常停止）所有功能都可用、测试全绿。这是**可用性成熟度**的缺口，不是功能缺陷。所以优先级定为 P0（testcase 1, 2）+ P1 (3) + P2 (4) 的分层。

5. **Coverage gap 归类**：属于 `.artifacts/coverage/coverage-matrix.md` 的 "E2E 缺口清单 P0 运维/可观测性"中**之前未列**的反向场景。coverage-matrix 原本只列了正向 "kill -9 esrd → auto-restore"，没有反向的 "YAML 删除 / rollback / 人工进程 → 孤儿清理" 对称面。需要补录。

## 修复方向（非阻塞性建议，给未来 Skill 2 参考）

建议引入 **ReconcileLoop GenServer**，每 30-60 秒执行一次：

1. **三元对账**：
   - `Esr.Topology.Registry.list_active()` → 应跑的 (adapter, instance) / (handler, worker_id) 集合 A
   - `Esr.WorkerSupervisor.list/0` → ESR 已知跟踪的集合 B
   - 扫 `/tmp/esr-worker-*.pid` + 对每个 pid `kill -0` → 磁盘上活着的集合 C
   - 计算 `C − A`（实际跑但没声明）= 要 kill 的孤儿
   - 计算 `A − C`（声明了但没跑）= 要 `ensure_*` 补起来

2. **给 `Esr.WorkerSupervisor` 加 API**：
   - `stop_adapter(name, instance_id)` → SIGTERM + 500ms + SIGKILL，清 pidfile
   - `stop_handler(module, worker_id)` → 同上

3. **`Topology.Registry.deactivate/1` 补调 WorkerSupervisor**：deactivate 时按 peer 的 `adapter` 字段反查并 stop。

4. **`Instantiator.rollback_spawned/2` 补调 WorkerSupervisor**：清理已起的 handler/adapter worker。

5. **Python 侧 watchdog**：`channel_client.py` 加 `max_reconnect_attempts` 参数（默认 ∞，但可配成"连不上 N 分钟就自杀"）；或者加一个父进程心跳检测（收不到 esrd 的 heartbeat push 就自杀）。

6. **（P2 选做）AdapterSocket 鉴权**：`runtime/lib/esr_web/adapter_socket.ex` 的 `connect/3` 回调对比 `adapters.yaml` / Topology.Registry，未声明的 (adapter, instance) 拒绝加入。

上述改动建议走 `test-plan-generator` 先出 test-plan，再用 `test-code-writer` 写 E2E 测试，最后实现。

## 后续行动

- [x] eval-doc 已创建
- [x] eval-doc 注册到 artifact registry (id: `eval-doc-002`)
- [x] GitHub issue 已创建 (https://github.com/ezagent42/esr/issues/7, labels: bug, architecture, v0.2, P0)
- [ ] 用户确认 testcase 表格 (status: draft → confirmed)
- [ ] coverage-matrix 补录反向场景
