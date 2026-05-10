# SessionTemplate + Channel — 实施计划

> **For agentic worker:** 必需 sub-skill：用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 一个 task 一个 task 实施。step 用 checkbox（`- [ ]`）跟踪。

**目标：** 把 session 布线从 plugin 私有代码提升成声明式 bundle/template；per-session 通信 peer 形式化为 `Esr.Channel`。Plugin manifest 加 `channels:` + `agent_kinds:` block；bundle 是一等 artifact（`runtime/lib/esr/bundles/<name>/`）；`agents.yaml` 解散。

**架构：** 5 层划分（Agent type / Channel / Bundle / SessionTemplate / Agent instance）。Plugin ship primitive（manifest yaml）。Bundle ship story（一目录一 template）。操作员可以 drop ad-hoc template 不做 bundle。ESR core ship 0 个 template。

**技术栈：** Elixir 1.19 / Phoenix 1.8 / yaml_elixir + Ymlr（unified-grammar 之后已在 deps）/ ExUnit + ScenarioBash 给 e2e。

**Spec：** `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`（rev-3，2026-05-10 用户确认）。姊妹 spec：`2026-05-09-yaml-layout-v2-per-thing-directories.md`（存储 layout、用户并行进行中）。

**迁移哲学：** 按用户指示**hardcut**。ESR 还没投入使用；不做 v2/legacy/translation-layer。每个改契约的 phase（agents.yaml 解散、agent_instance.json 拆分等）直接删旧形状。**没有双读路径**。

**分支策略：** 一栈 ~10 PR off `origin/dev`，每 phase 一个 PR。subagent + 用户 review 通过后按内存规则 admin-merge。Phase 7 硬依赖 yaml-v2 spec 已合；没合则 Phase 7 stall（不做即时 adapter）。

**英文版：** 完整 step-by-step 在 `docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`（750+ 行，每 step 带可直接抄的代码 + 命令 + 期望输出）。本中文版 phase 摘要 + 关键决策 —— 实施时以英文版为准。

---

## 文件 map（速览）

### 新增顶层目录
- `runtime/lib/esr/channel/` —— channel behaviour + registry
- `runtime/lib/esr/bundle/` —— bundle manifest + loader + registry
- `runtime/lib/esr/session_template/` —— template schema + loader + registry + flow node registry
- `runtime/lib/esr/bundles/` —— 内置 bundle（与 `plugins/` 并列）

### 删除（Phase 6 hardcut）
- `runtime/priv/agents.yaml*`（文件 + priv 种子）
- `runtime/lib/esr/entity/agent/registry.ex`（agents.yaml ETS cache）

---

## Phase 1 — Channel 基础设施

**目标：** 上 `Esr.Channel` behaviour + Registry + plugin manifest `channels:` block 解析。无现存代码改、独立合。

**PR：** `feat/sessiontemplate-phase-1-channel-infra` → `dev`。估计 ~250 LOC + ~150 LOC 测试。

**任务：**

1. 切分支
2. `Esr.Channel` behaviour（4 个 callback：start_link/1, dispatch/2, subscribe/3, config_schema/0 可选）—— TDD 写
3. `Esr.Channel.Registry` ETS 模块 + GenServer 启动
4. `Esr.Plugin.Manifest` 加 `channels:` block 解析（field + type + 测试）
5. `Esr.Plugin.Loader` boot 时把每 plugin 的 channels 注册到 Registry
6. push + PR

**英文版每 step 都有完整 Elixir 代码块。**

---

## Phase 2 — claude_code MCP HTTP Channel

**目标：** 把现有 Elixir 端 MCP HTTP transport（`EsrWeb.McpController`）包成 `Esr.Channel` 实现。在 claude_code manifest 注册。**没有新 transport 代码** —— 只是 behaviour adapter。

**PR：** `feat/sessiontemplate-phase-2-claude-code-mcp-channel` → `dev`。估计 ~300 LOC + ~150 LOC 测试。

**任务：**
1. `Esr.Plugins.ClaudeCode.Channels.McpHttp` 实现 4 个 Channel callback —— GenServer 持有 session_id + pubsub topic
2. claude_code manifest.yaml 加 `channels:` block
3. smoke test：boot esrd → Registry.lookup("claude_code.mcp_http") 返回 module
4. push + PR

---

## Phase 3 — feishu chat Channel

**目标：** 从 `Esr.Entity.FeishuChatProxy` 抽出 channel 形状那半。**重命名模块** `Esr.Entity.FeishuChatProxy` → `Esr.Plugins.Feishu.FeishuChatProxy` 对齐文件路径。在 feishu manifest 注册。

**PR：** `feat/sessiontemplate-phase-3-feishu-channel` → `dev`。估计 ~500 LOC + ~200 LOC 测试。

**任务：**
1. 重命名（一个 commit、无行为变化、grep 替换 + 测试）
2. 抽出 `Esr.Plugins.Feishu.Channels.ChatProxy`（inbound dispatch + outbound emit；router 那半留在原 FCP 里）
3. feishu manifest.yaml 加 `channels:` block
4. push + PR

---

## Phase 4 — Bundle 基础设施 + 第一个 bundle（scenario 27, 29）

**目标：** Bundle / SessionTemplate 注册路径端到端。Ship `runtime/lib/esr/bundles/feishu-cc/`（第一个 bundle）。Ship e2e scenario 27（缺依赖 loud-fail）+ scenario 29（外部路径 install）。

**PR：** `feat/sessiontemplate-phase-4-bundle-infra-plus-feishu-cc` → `dev`。估计 ~700 LOC + ~300 LOC 测试。

**任务：**
1. `Esr.Bundle.Manifest` parser（mirror `Esr.Plugin.Manifest`）
2. `Esr.SessionTemplate.Parser` + `FlowNodeRegistry`（内置 `MentionParser`、`<route_to_agent>`）
3. `Esr.Bundle.Loader` + `Esr.Bundle.Registry` + `Esr.SessionTemplate.Registry`（两 ETS：bundle 元数据 + parsed template by name）
4. 第一个 bundle：`runtime/lib/esr/bundles/feishu-cc/{manifest,template}.yaml`
5. `/plugin:install` 修改：copy 后看 `template.yaml` 是否存在 → bundle 路径或 plugin 路径
6. e2e scenario 27 —— 装 feishu 不装 claude_code、装 feishu-cc bundle、看 Logger.warning + `template_dependency_unmet` 错误、再装 claude_code 自动注册
7. e2e scenario 29 —— cp bundle 到 `/tmp/external_bundle`、`/plugin:install --path=...`、template 注册 + `/session:new` 跑通、disable → 自动注销
8. push + PR

---

## Phase 5 — `/session:new` 切换（scenario 24, 26）

**目标：** `/session:new` 走 template + 通过 SessionTemplate 实例化 session。**Hardcut 删现有硬编码 session pipeline**。ESR 未投产、不做 compat shim。

**PR：** `feat/sessiontemplate-phase-5-session-new-cutover` → `dev`。估计 ~500 LOC + ~200 LOC 测试 + 2 e2e。

**reviewer 修正（Open Q A）：** 现有 pipeline 不是"硬编码 Elixir" —— 是通用 walker，已经 yaml-driven 了（`agent_spawner.ex:262-290`）。Phase 5 切的是 *输入源*：从 agents.yaml-derived `agent_def` 切到 template-derived `agent_def`。spawn 逻辑不变。

**任务：**
1. `Esr.Session.DefaultTemplate` 模块：从 `plugins.yaml > config.session.default_template` 读；如果没设、且只有一个 template 注册则 boot 时自动选为 default
2. 重写 `Esr.Commands.Session.New`：接受 `template=` arg，从 template 构 `agent_def` map（取代 `agent_spawner.ex:137` 的 `Esr.Entity.Agent.Registry.agent_def/1` 查找），per-session AgentSupervisor 下起 Channel；`AgentSpawner.do_create/1` 和 walker（`agent_spawner.ex:262-290`）**不变**
3. **Hardcut on source switch**：删 `agent_spawner.ex:137` 的 `Esr.Entity.Agent.Registry.agent_def/1` 查找；spawn walker 留着
4. 操作员 default-template UX：`/plugin:set plugin=session key=default_template value=feishu-cc` 不需要 esrd restart
5. e2e scenario 24 —— template 实例化的 session 端到端（同 scenario 22 形状但走 template loader）
6. e2e scenario 26 —— 操作员 drop `~/.esrd-<inst>/<inst>/session_templates/foo.yaml`、`/plugin:reload session_templates`、`/session:new template=foo` 跑通
7. push + PR

---

## Phase 6 — agents.yaml 解散（13 个消费者）

**目标：** 删 `agents.yaml`。Agent type 定义移进 plugin manifest `agent_kinds:` block。**Hardcut**。

**PR：** `feat/sessiontemplate-phase-6-agents-yaml-dissolve` → `dev`。估计 ~800 LOC + ~300 LOC 测试。

**注意（reviewer Open Q B）：** 13 个消费者是最坏情况。Phase 5 已经把 `commands/session/new.ex` 和 `session/agent_spawner.ex` 迁了，到 Phase 6 实际触及 **≤11** 个文件。

**任务：**
0. **先定位 agents.yaml 在哪** —— `find runtime -name 'agents*.yaml'` + grep。reviewer 指出 priv 里其实没有种子文件（runtime_home-相对、operator 环境特定）。Task 6.6 删的目标可能是 `tools/wipe-esrd-home.sh` 和 first-run seed 代码、不是 priv 文件
1. plugin manifest 加 `agent_kinds:` block 解析（mirror Phase 1 的 `channels:` 块）
2. `extract_handler_modules/1`（application.ex）从 plugin registry 读
3. **删 `Esr.Entity.Agent.Registry` 的 FragmentMerger 调用** —— reviewer 指出 FragmentMerger **是通用的**（其它 FileLoader 也用），不动；只删 Agent Registry 的调用
4. **8 个 sub-task per consumer**（不是一个 mega task）：spawner / snapshot_registry / workspace.remove / agent_types / capability / session.router / cc_process moduledoc / claude_code manifest moduledoc。每个 sub-task 独立 commit
5. cap-source 迁移验收测试：snapshot 前后 cap 解析结果字节相同
6. **删 agents.yaml 文件**（Task 6.0 实测后定位的所有目标）
7. `git grep -l agents.yaml runtime/lib/` 必须为空（moduledoc 历史注释除外）
8. push + PR

---

## Phase 7 — Multi-session-per-instance（scenario 25）

**目标：** 一个 `Instance` 注册多 session；reply routing 携带 incoming session 上下文。

**硬依赖：** yaml-v2 spec 必须已合（per-instance JSON 文件拆分）。否则本 phase stall。

**PR：** `feat/sessiontemplate-phase-7-multi-session-per-instance` → `dev`。估计 ~250 LOC + ~150 LOC 测试 + 1 e2e。

**任务：**
0. 检查 yaml-v2 已合（`agent_instance.v2.json` 存在），否则 halt 不做 workaround
1. schema v1 → v2：`session_id`（单数）→ `session_ids`（数组、min 1）
2. 一次性迁移脚本 `mix esr.migrate_agent_instances_v1_to_v2`（boot 时检测 v1 文件就跑、idempotent）
3. `Esr.Entity.Agent.Instance` 结构 `session_id :: String` → `session_ids :: [String]`
4. `InstanceRegistry`：`add_instance_and_spawn/2` 接受 `session_ids` list；`lookup/2` 匹配 name + 任一 session_id；新 API `attach_to_session/3`
5. CCProcess：reply 用 incoming `current_session_id` 路由
6. cc_mcp tool catalog：tool 调用 body 携带 `current_session_id`；CC system prompt 提示用户 disambiguation
7. 新 slash `/agent:add-session session=<sid> name=<n>`，cap `agent.attach`
8. e2e scenario 25 —— 两 session 共享 CC instance，各自 reply 落各自 chat
9. push + PR

---

## Phase 8 — Docs + scenario 28 + CI gate

**目标：** 收尾。concepts.md 更新；自动生成 `docs/grammar/templates.md`；Bundle drift CI gate；e2e scenario 28（两 agent kind 组合）验证抽象不是 CC 专用。

**PR：** `feat/sessiontemplate-phase-8-docs-and-finalize` → `dev`。估计 ~300 LOC + ~200 LOC 测试 + 1 e2e。

**任务：**
1. `docs/notes/concepts.md` rev-11 加 Bundle 作为 runtime 一等概念
2. `mix esr.gen_bundle_docs` mix task（mirror unified-grammar 的 gen_command_docs pattern）→ 写 `docs/grammar/templates.md`
3. `mix esr.check_bundles` CI gate（校 bundle 依赖 + template 引用完整性）
4. 接到 `.github/workflows/ci.yml`
5. e2e scenario 28 —— stub 第二 agent kind（`Esr.Plugins.StubAgent.*`）+ stub bundle，验证 session 创建无需改 feishu 或 claude_code
6. todo.md + manual-checks 同步关闭 "Channel abstraction" 这条
7. push + PR

---

## 验收（全部 phase 合后）

- [ ] `git grep -l agents.yaml runtime/lib/` 零 hit
- [ ] `runtime/lib/esr/bundles/feishu-cc/{manifest,template}.yaml` 存在
- [ ] `mix esr.check_bundles` CI gate 全绿
- [ ] 所有 6 个 e2e scenarios（24-29）在 fresh-install 跑全绿
- [ ] `/session:new template=feishu-cc name=foo` 不需要显式 channel/agent 参数
- [ ] 操作员在 `/tmp/external_bundle/` ship 的 bundle 通过 `/plugin:install` 端到端注册
- [ ] 两 session 共享 CC instance，reply routing 各自分明
- [ ] Stub 第二 agent kind boot 不需要改 feishu 或 claude_code 一行代码

---

## Spec coverage 自查

每 spec 段对应 phase：
- §3 5 层划分 → Phase 1, 4 (新层本身)
- §4 决策 → Phase 1-7 架构
- §5.1 Channel behaviour → Phase 1
- §5.2 Channel kind discovery → Phase 1, 2, 3
- §5.3 Bundle layout → Phase 4
- §5.4 默认 template 选择 → Phase 5
- §5.5 Install lifecycle → Phase 4
- §5.6 存储 → Phase 7（硬依赖 yaml-v2）
- §6.1 13 个消费者 → Phase 6（每 task）
- §10 验收 → 上面验收 block
- §10.1 e2e → Phase 4 (27, 29), Phase 5 (24, 26), Phase 7 (25), Phase 8 (28)

**Hardcut 审计：** Phase 6 直接删 agents.yaml（无 v1/v2 双读）。Phase 7 ship v2 schema + 一次性迁移（无即时 fallback）。Phase 5 删现有硬编码 session pipeline（无并行 path）。全部符合"无 v2/legacy/translation layer"规则。

**英文版 step-by-step 完整代码：** `docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`
