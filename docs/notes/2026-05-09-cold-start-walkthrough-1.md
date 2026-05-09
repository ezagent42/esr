# 2026-05-09 — yao mac cold-start walkthrough #1（首次完整通跑复盘）

> 起源：yao.shengyue 在 mac 上从零起 esrd → 飞书 dog-feed inbound 走通的一次完整尝试。
> branch: `feat/restore-cli-paths`（branched off `3aede56` = origin/dev 当时 tip）
> commit:
>   - `420e398 fix(_ipc_common): inline runtime_home() — drop esr.cli.paths dep`
>   - `2006bc9 refactor(feishu): move app_id/app_secret out of plugin config (Phase 7.D)`
> 第二次复跑 (#2) 计划针对 origin/dev HEAD（含 #269..#281），验证哪些坑在新 dev 已修。

## 通跑路径（最终成功的顺序）

1. **环境**：macOS yao.shengyue user (UID 503，非 admin)，brew 已装 elixir 1.19.5/OTP 28、uv、claude 2.1.131、node、pnpm、tmux。
2. **代码**：`~/Workspace/esr-yao-dev` worktree 从 `origin/dev`(3aede56) 拉 `feat/restore-cli-paths`。
3. **deps**：`cd runtime && mix deps.get && mix compile`（hex.pm 抖一次，加 `HEX_HTTP_CONCURRENCY=1` 重跑）；`cd py && uv sync --no-dev` + `uv pip install -e ../adapters/feishu -e ../handlers/{feishu_app,feishu_thread,cc_session,cc_adapter_runner}`（PyPI 也抖；跳 dev deps 加速）。
4. **escript**：`cd runtime && mix escript.build`（产出 `runtime/esr` 给 admin queue 注 commands）。
5. **配置文件**（手编 `~/.esrd/default/`）：
   - `plugins.yaml` — 顶层 key **必须是 `config:`**（不是 `plugins:`），feishu 段只放 `log_level`，claude_code 段放 `claude_binary`
   - `adapters.yaml` — `instances.<id>.config.{app_id, app_secret}`（per-instance，**both 字段都在这**）
   - `capabilities.yaml` — bootstrap principal + 用户自己的 open_id 都给 `["*"]`
   - `users.yaml` — `users.<name>.feishu_ids: [<open_id>]`（**通过 escript user_add 创建后必须 restart esrd 才能让 watcher 订阅 + 重 load 含 feishu_ids 的 snapshot**）
6. **启动**：`tmux new -s esrd -d ~/.esrd/start-esrd.sh`（脚本里 export `ESR_BOOTSTRAP_PRINCIPAL_ID` + `MIX_ENV=dev` 跑 `mix phx.server`）。
7. **escript 注命令**（admin queue）：必须 `ESR_OPERATOR_PRINCIPAL_ID=<your_open_id> ESRD_HOME=~/.esrd ./esr.sh user_add name=<name>`。env 不设默认是 `ou_unknown`（无 cap）→ `unauthorized`。
8. **飞书后台**（关键 4 项）：
   - 「机器人」启用
   - 「权限管理」勾 `im:message` + `im:message.group_at_msg`（最少；私聊还要 `im:message.p2p_msg`）
   - 「事件配置」勾 **`接收消息 v2.0` (im.message.receive_v1)**
   - 「版本管理与发布」**发布版本**（草稿状态收不到事件！）
9. **改飞书订阅后必须重启 sidecar**：Lark WS 是 connect-time 锁死订阅集，不主动推订阅更新——`pkill feishu_adapter_runner` 让 esrd supervisor respawn。

## 跑出的 7 个代码 bug + dev 修了几条

| # | bug | 发生于 | walkaround | dev 上是否修 |
|---|---|---|---|---|
| **C1** | `_ipc_common/url.py:23 from esr.cli import paths` 任何 sidecar 启动死 | feishu_adapter_runner 重 spawn 时 | commit `420e398` 加 `runtime_paths.py` 抽 `runtime_home()` | ✅ **已修** PR #274（同思路 inline `_runtime_home()` 私函数；我们的 commit 重复，rebase 时 drop） |
| **C2** | Phase 7 `app_secret` 在 plugin config，但 spawn 路径只透传 adapter config → sidecar 拿不到 secret | Lark 鉴权 fail | commit `2006bc9` (Phase 7.D) — secret 移回 adapters.yaml per-instance | ❌ **未修** |
| **C3** | UnboundChatGuard 文本 `/new-workspace` `/new-session`（pre-Phase-6 名字） | bot 第一次回 onboarding 时 | 没修，告诉用户用真名 (`/workspace:new`) | ❌ **未修** |
| **C4** | feishu plugin manifest 缺 `declares.commands` → `feishu_bind` `unknown_kind`（即使 `bind_user.ex` 已实现） | escript 跑 feishu_bind 时 | 跳 dispatcher，sed 直接 edit `users.yaml` append open_id | ❌ **未修**（baseline 早有 3 个 migration_test fail 标记这事） |
| **C5** | `user.watcher` boot 时若 users.yaml 缺席就 `fs_pid: nil` 永不补订阅 | manually edit 后 ETS 不更新 | restart esrd | 🟡 **部分修** PR #280：file 在时改 dir-watch；缺席仍 give up |
| **C6** | `Bootstrap.bootstrap/0` adapters.yaml 缺失时 silent no-op（无 log） | 首次启动看不出来为啥 FAA 没 spawn | grep 源码 + 写 adapters.yaml 触发 | ❌ **未修** |
| **C7** | escript 默认 principal `ou_unknown` 无 cap → 任何 admin 命令 `unauthorized` | escript user_add | export `ESR_OPERATOR_PRINCIPAL_ID` env | ❌ **未修** — PR #281 "first /user:add auto-promotes to admin" 部分缓解（首次 user_add 免 cap，但操作员仍要知道用 escript 跑） |

## 跑出的非代码坑（操作员需知 19 条）

按类别：

**CFG 操作员配置**（8 条）：
- ESRD_HOME 子目录预建多余 (`logs/`, `users/`, `workspaces/` esrd 自建)
- plugins.yaml 顶层 key 是 `config:` 不是 `plugins:`
- ESR_BOOTSTRAP_PRINCIPAL_ID plist 默认是别人的 open_id
- adapters.yaml 必须先创建（不存在 → silent no-op）
- users.yaml 通过 `escript user_add` 创建后必须 restart esrd
- feishu binding 需 `escript feishu_bind`，但 dispatcher unknown_kind → 直接 sed 编辑
- escript 必须先 `mix escript.build` 编译
- escript 运行需 `ESR_OPERATOR_PRINCIPAL_ID` 显式

**CFG-Lark 飞书后台**（4 条）：
- 草稿状态不推任何事件 → 必须发布版本
- 「事件配置」未勾 `im.message.receive_v1` → 只收到 bot.added/deleted
- WS 老连接锁住老订阅集 → 改后必 restart sidecar
- @ bot 走 `im:message.group_at_msg`；私聊要 `im:message.p2p_msg`

**DESIGN 设计陷阱**（5 条）：
- `mix test --max-failures 0` 是 "abort on 0th fail" 跑 0 测假绿
- Lark WS connect-time 订阅锁死
- bot 模板"已绑定的 esr user" 是 hardcoded 模板，不真验证
- principal cap vs esr user identity 两层独立 → 操作员要分别建
- uv sync silent download phase 让人误以为卡死

**ENV 环境**（2 条）：
- WSL PyPI Connection refused
- hex.pm 默认并发 8 偶尔 timeout

详见 [`docs/notes/onboarding-future-work-2026-05-07.md`](onboarding-future-work-2026-05-07.md)（如果搬过来的话）/ 老 path `docs/discuss/note/2026-05-07-onboarding-future-work.md` items 21-30（在 d421212 base 上的 WSL clone）。

## 接下来 PR 候选（已知未修代码 bug）

按优先级：

1. **C2 — `feat/restore-cli-paths` 已 commit `2006bc9`** — push + PR
2. **C3 — UnboundChatGuard 文本** — `runtime/lib/esr/entity/unbound_chat_guard.ex` 一处字符串 grep replace
3. **C4 — feishu plugin manifest `declares.commands`** + Plugin.Loader 把 commands kind 注册到 SlashRoute Registry（中等改动；baseline migration_test 3 fail 自动绿）
4. **C5 残留 — user.watcher** — `runtime/lib/esr/entity/user/watcher.ex` 改成无条件 watch dirname
5. **C6 — Bootstrap.bootstrap/0** — 加一行 `Logger.info "no adapters.yaml at #{path}; skipping feishu adapter spawn"`
6. **C7 — escript principal** — UX 改进，可能跟 PR #281 first-user-auto-promote overlap（待第二次跑确认）

C1 已被 origin/dev #274 修，rebase 时 git 会自动识别 patch-equivalent → drop `420e398`。

## meta：第二次通跑（即将开始）

第二次跑的目的：在 `origin/dev` HEAD（b3c683c，含 #269..#281）上从零再走一次：
- C1 应已不复现
- C5 在 dir-watch 改进下表现如何
- C7 是否被 PR #281 完全覆盖？还是仍要 escript？
- C2/C3/C4/C6 应原样复现 → 据此决定 PR 优先级

第二次跑前已 archive：
- `~/.esrd/default/`（runtime state，整个 archive 到 `~/.esrd/_archive-bootstrap-1/`）
- `~/.esrd/*.sh` helper scripts（archive 到 `~/.esrd/_archive-bootstrap-1/scripts/`）
- 旧 tmux esrd session killed

---

## 2026-05-09 复跑 #2 实跑观察（增补）

### 新发现：**C8 — escript 跟 esrd 默认 ESRD_HOME 不对齐**

**现象**：操作员跑 `./esr.sh user_add name=yao` 不带 `--env=prod` 也不 `export ESRD_HOME=~/.esrd` 时，escript 默默把 admin queue YAML 写到 `~/.esrd-dev/default/admin_queue/pending/`，但 esrd 在监听 `~/.esrd/default/admin_queue/pending/` → 命令永远不到 dispatcher → 60 秒 timeout，操作员看到 `esr exec: timed out after 60s waiting for <ulid>`。

**root cause**：default 不一致。`runtime/lib/esr/cli/main.ex:cmd_exec_kind` 用 `~/.esrd-dev` fallback，`runtime/lib/esr/paths.ex:esrd_home/0` 用 `~/.esrd` fallback。两个文件用不同 default 做同一件事。

**dev tip 状态**：未修。**第一跑遗漏没记**——当时全程都设了 `ESRD_HOME=~/.esrd`，没暴露这条。第二跑用户先没设，直接撞坑。

**修法**：统一到一个 default。最简单是把 `cli/main.ex` 的 fallback 改成跟 paths.ex 一致的 `~/.esrd`，或者 esr.sh wrapper **总是** export `ESRD_HOME=~/.esrd`（默认 prod，操作员要 dev 时显式 `--env=dev` 走 `~/.esrd-dev`）。

**优先级**：中。一次性踩到就知道，但 first-time 操作员**绝对**会撞，因为 `--env=prod` 既不是必填也不是默认显眼。

PR 候选 6 → 现在变成 7 个：C2, C3, C4, C5(残留), C6, C7（如果 #281 没完全覆盖）, **C8**.

### 新发现：**C9 — "instance" 命名歧义**

ESR 里 "instance" 有两个无关含义：

| 含义 | 在哪用 | 个数 |
|---|---|---|
| **A: ESR_INSTANCE** | esrd 进程 state 目录命名（`~/.esrd/<inst>/`），LaunchAgent label | 一个 esrd 进程 ↔ 一个 |
| **B: adapter instance** | `adapters.yaml` 的 `instances:` 顶层 key，每行 = 一个外部 IM app 连接（FAA peer + 1 lark_oapi WS） | 一个 esrd 进程内 ↔ 多个 |

新 operator 看 adapters.yaml `instances:` 时直觉以为是 ESR_INSTANCE 的 list（一份 esrd 多份命名），实际是某个 esrd 内部的多 IM-app 列表。

**修法（candidate）**：把 adapters.yaml 顶层 key `instances:` 重命名为 `adapters:`（schema breaking 但语义清晰）。或起码在 docs 里把这两个 "instance" 的区分写显眼。

**优先级**：低（文档可以解决，不是 blocker）。

### C2 重新分类（基于 b5fe750 复跑实测）

第二跑 secret 放 `adapters.yaml.config.app_secret`（Phase 7.D 形态），sidecar **直接**连上 Lark 成功（log `Handshake-Msg: OK`）。

→ **C2 不是 runtime 数据流 bug**——adapters.yaml 的 config 一直就完整透传给 sidecar (`Jason.encode!(cfg)` in `worker_supervisor.ex`).

C2 实质是 **manifest schema vs 数据流不一致的 UX/doc 陷阱**：
- `runtime/lib/esr/plugins/feishu/manifest.yaml` 的 `config_schema` 仍声明 `app_secret` 是 plugin-level config key
- 真实数据流只透传 adapters.yaml `config:` 给 sidecar，plugin config 永不到 sidecar
- 操作员凭 manifest schema 引导把 secret 写 plugins.yaml → C2 复现
- 操作员凭"per-instance 直觉" 把 secret 写 adapters.yaml → 自然 work

**修法**（commit 2006bc9 已含）：删 manifest config_schema 里 `app_id` + `app_secret`（保留 `log_level` 这条真 plugin-wide 的）、删 dead `get_app_secret/0` + `get_app_id/0`、更新 `plugin.ex` docstring。

**优先级**：中。runtime 不挂，但操作员**绝对**会按 schema 误填一次。一次性踩中就明白；第二次写就对。

### 第二跑实证：bug 现状汇总

| Bug | b5fe750 状态 | 证据 |
|---|---|---|
| **C1** paths.py import | ✅ 已修 (#274) | 我们 commit 420e398 重复，rebase drop |
| **C2** manifest schema vs 数据流不一致 | ❌ 未修 | manifest 仍声明 app_secret 是 plugin-level；操作员按 schema 误填会复现 |
| **C3** UnboundChatGuard 旧 slash 名 | （待验证）| chat 模板 stale |
| **C4** feishu_bind unknown_kind | ✅ 已修 | 第二跑直接成功 |
| **C5** user.watcher boot 时不存在就 give up | ❌ 未修 | 第二跑 feishu_bind 写 yaml 后，bot 仍报"Feishu identity not bound"——ETS 没 reload |
| **C6** Bootstrap.bootstrap silent no-op | （待验证）|  |
| **C7** escript ESR_OPERATOR_PRINCIPAL_ID env required | ✅ 已修 (#281+#282) | sentinel + auto-admin 全自动 |
| **C8** escript vs esrd ESRD_HOME default mismatch | ❌ 未修 | escript 默认 `~/.esrd-dev`，esrd 默认 `~/.esrd` |
| **C9** "instance" 命名歧义（ESR_INSTANCE vs adapter instance）| ❌ 未修（doc only） |  |

→ 真需要 PR 的代码 bug：**C2, C5, C8**（外加 C3 / C6 待第二跑确认）

C5 修法精化：user.watcher 改成无条件 watch dirname（boot 时 file 在不在都订阅），同时 `bind_user.ex` 写完 yaml 后主动 call `sync_reload_user_registry/1`（跟 user_add 一致）。两条都做最稳。

### 第二跑实测变化：cap principal 从 feishu_user → esr_user

第一跑 `capabilities.yaml.principals[].kind = feishu_user`、`id = <feishu open_id>`。
第二跑 b5fe750 (`#281` + `#282`)：`kind = esr_user`、`id = <esr user UUID>`。

cap 表跟 IM 平台**解耦**了。runtime 路径：
```
inbound open_id
   ↓ Registry.lookup_by_feishu_id  → username
   ↓ Registry users.yaml index     → UUID
   ↓ Capabilities.Grants by UUID   → ["*"]
```

正向变化，不是 bug，但**第一跑遗留知识过时了**——以后 rebase 时第一跑那部分文档要更新。

---

### 新发现：**C10 — `bind_user.ex` 不更新 user.json，两源 diverge**

`Esr.Plugins.Feishu.Commands.BindUser.execute` 只调 `Esr.Yaml.Writer.write(users_yaml, ...)`——只写 `users.yaml`，**不更新 `users/<uuid>/user.json.feishu_ids`**。

证据：
- `users.yaml`：`users.yao.feishu_ids: [ou_aee...]` ✅
- `users/32399cb8.../user.json`：`feishu_ids: []` ❌ stale

runtime 影响：当前 0（FileLoader 用 users.yaml 当 canonical，user.json 那字段是僵尸）。

风险：
1. 备份恢复时如果 users.yaml 丢失，`FileLoader.load_from_users_dir/1` 从 user.json 重建 → 所有 feishu binding 静默丢失
2. schema 演进若把 canonical 切到 user.json → 数据已 stale，需 migration

修法：`bind_user.ex` (跟 `unbind_user.ex`) 写完 users.yaml 后，调 `Esr.Entity.User.JsonWriter.update(uuid, fn r -> %{r | feishu_ids: ids} end)` 或类似 atomic 同步。

**优先级**：低-中。属于 C5 同一族（user-bootstrap），归 issue 等同事 user-bootstrap PR pipeline。

---

### 新发现：**C11 — `/session:new` slash schema 缺 `dir` required 标注**

`runtime/priv/slash-routes.default.yaml` 的 `/session:new` route 只声明 `name` + `agent` 两个 args（agent optional default cc）。但 `Esr.Commands.Session.New.execute/1` 在 line 117 调 `validate_args(agent, dir)`，`dir` 必填——nil 直接拒。

`dir` 的真实来源是 agent type 自己的 params declaration（`runtime/test/esr/fixtures/agents/simple.yaml` cc agent 声明 `dir: required: true, type: path`）。但这层 params **不暴露给 slash help**——`/help` 跟 slash schema 都没说 dir 必填。

**复跑实证**：群里发 `/session:new name=test1` 直接 `error: invalid_args`，没具体说哪个字段缺。

**修法**：
- 选 A: slash schema 静态声明 `dir: required: true` 同步进 slash-routes.default.yaml `/session:new` args
- 选 B（更优）: slash dispatcher 动态合并 `agent.params` 进 slash help。`/help /session:new` 时把 cc agent 的 params 列出来
- 都不动 → 错误信息至少要说"`dir` is missing"，不是泛 `invalid_args`

**优先级**：中。冷启动 100% 撞，但有 dir 后能走通。

### 新发现：**C12 — agents.yaml 没零配置 bootstrap，plugin manifest 不声明 default agent**

冷启动后 `~/.esrd/<inst>/agents.yaml` 不存在，`Esr.Entity.Agent.Registry` 启动时空表。即便 `claude_code` plugin 已 enable + `claude_binary` 在 plugins.yaml 配好，ESR **不知道有"cc"这个 agent type 存在**——`/session:new agent=cc` 路径在 `fetch_agent("cc")` 处直接 `:not_found`。

`/agent:add` 命令也救不了——它做的是给 session 加 agent **instance**（Phase 3 multi-agent），第一步就 `validate_agent_type` 查 type 是否在 Registry，发现不存在直接拒。

`/plugin:agent-types` 的 docstring 说"every agent type declared by enabled plugins"——但 wiring 没做，它最终还是读 `Registry.list_agents/0`（即 agents.yaml 内容）。

**当前操作员唯一路径**：手写 agents.yaml 或拷 `runtime/test/esr/fixtures/agents/simple.yaml`。

**plugin / agents.yaml 当前职责重叠**：
- `plugins.yaml.config.claude_code.claude_binary` — plugin 内部 launcher 用
- `agents.yaml.agents.cc.pipeline` — `[FeishuChatProxy, CCProxy, CCProcess, PtyProcess]`

但 `claude_code/manifest.yaml` 已声明 `declares.entities` 含 CCProcess + CCProxy——pipeline 的零件**已经在 plugin manifest**。agents.yaml 等于把 plugin 已知信息再写一遍。

**修法（PR 候选）**：
1. plugin manifest 加 `declares.default_agent: %{name: cc, pipeline: [...], params: [...]}`
2. `Plugin.Loader.run_startup` / register 时把 default_agent 合并到 Agent Registry（cold-start 立刻有 cc type）
3. 操作员可选 override：自己写 agents.yaml > plugin default
4. 同时填 `/plugin:agent-types` 的 wiring：types from manifest + types from agents.yaml 合并展示

→ 冷启动操作员**装 plugin 即得 agent type**，无需手写 agents.yaml。

**优先级**：高。这是 plugin 系统的"零配置"目标的残块——已经做了 #281 + #282 的 user 端零配置，应该把 agent 端补齐。
