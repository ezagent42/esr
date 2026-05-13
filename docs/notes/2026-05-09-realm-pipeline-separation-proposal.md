# 2026-05-09 — Realm / pipeline 分离提议（架构讨论存档）

> 起源: yao.shengyue 复跑 walkthrough 后提的设计问题。
> 后来 origin/dev 自己 ship 了 #329 (agents.yaml dissolution + agent_kinds in plugin manifest) + #330 (multi-session-per-instance)，部分实施了这思路。
> 这个 note 留存当时的讨论 + 概念辨析，作为 follow-up 验证 origin/dev 实际实现是否解到了痛点的参考。

## 触发问题

> agents.yaml 当前持久化了"从 feishu 到 CC 的链路"（pipeline）。但同一个 agent 实例可能需要服务**不同链路**——比如：
>
> 1. 开了一个 CC 实例 S1，最开始只跟用户 A 对话
> 2. 后来用户 B 在自己 session 里 add 同样的 agent，CC 的 esr-channel 需要**同时收到两边的对话**
>
> 这个需求真实存在吗？目前能通过修改 agents.yaml pipeline 后再 load 解吗？

## 回答 1：需求真实但分场景

| Use case | 多 session 共享 cc 实例的价值 | 风险 |
|---|---|---|
| 长上下文复用（一个 cc 维护项目知识，多 user 共用） | ✅ 大 | 用户 A 的私密对话可能 leak 给 B |
| 资源节省（避免 N session = N claude 进程） | ✅ 中（claude 起来 ~200MB） | 一挂全挂；scaling 反差 |
| Agent-as-service（cc 是长 running tool，session 是调用入口） | ✅ 大（codex/qwen 类） | claude conversation_id stateful，不天然适配 |

→ CC 类对话型 LLM **共享性差**；codex/qwen/inference 类 agent **共享性强**。Architecture 应同时支持 per-session-spawn 跟 shared-singleton 两种 instance model。当前 dev tip 只支持前者，是 gap。

## 回答 2：改 agents.yaml + reload 不能解

`agents.yaml.pipeline` 是 agent **type** 级声明。改后只影响**新** session，老 session 已 spawn 的 entity tree 不变。runtime 没机制让"已存在的 cc 实例"动态加新 chat 到 inbound chain。

要支持 case，得**架构改动**：cc 实例从 per-session pipeline 抬到 admin-tree singleton（像今天的 FeishuAppAdapter），sessions 通过 proxies 引用。

## 用户提议方案

> 1. agent 加载时不考虑 pipeline，只负责自己的事（CC 启动 esr-channel 等响应即可）
> 2. session 启动时 pipeline 从 **Realm** 模板读，CC 从 esr-channel 看到"新用户加入"事件，按 skill/mcp 指示分用户回复
> 3. user 创建 session 时复用现有 Realm 模板；新链路需求催生新 Realm 模板，不同链路被不同 agent 复用
> 4. 链路优化在 Realm 层做，多 session 通信优化都进 Realm

模型转换：

```
当前 (dev tip @ b5fe750):
  agents.yaml.cc.pipeline = [FCP, CCProxy, CCProcess, PtyProcess]
  → Session.New 按这 pipeline spawn 4 个 entity (per-session)
  → CC 实例 = CCProcess + PtyProcess (per-session 独占)

用户提议:
  agents.yaml.cc = { capabilities, params, declared_handlers }
  realms.yaml.<realm_kind>.pipeline = [...]
  session.json.realm = "<realm_kind>"
  → Session.New 按 realm.pipeline spawn (pipeline 可指 admin singleton OR per-session)
  → CC 实例可单可共享
```

## 评估打分

| 维度 | 评分 | 说明 |
|---|---|---|
| **跟 concept.md rev-10 一致** | ✅ | Realm = class，Session = instance；正是 separating concerns |
| **命名混淆风险** | ⚠️ | workspace.agent 跟 realm 边界要分清。建议: workspace=物理资源（folders/chats/owner），realm=通信结构（pipeline/default agent），session=realm 的 instance 化 + workspace ref |
| **减 drift** | ✅ 中长期 | M realm × N agent → M+N declaration（vs 当前 M×N） |
| **over-engineering** | 🟡 当前 1-1 状态 | 1 agent + 1 pattern 时净增复杂；2-3 agent type × 2 realm pattern 时拐点；≥3×3 时必须做 |

## Claude 自己适配多用户的 risk

> 把"路由"责任部分推给 LLM（claude 看 esr-channel 多线对话，按 system prompt 分 user 回复）

- ✅ 适合：claude 能区分 chat_id；system prompt 教它做 discrimination
- ❌ 风险：claude 出错 → 用户串台；context window 被多用户对话填满；缺 ESR-side 强保证
- → ESR side **必须保留** reply audit + chat_id 验证，不依赖 claude 自律

## 建议（写于 2026-05-09）

| 时段 | 动作 |
|---|---|
| **短期 (1-2 PR)** | 不做 Realm 拆。只修 C12 (plugin 自动声明 agent type) + C14 (params 校验对齐) |
| **中期 (≤3 个月, 等 codex/qwen)** | 写 Realm spec → 实现 1-2 个 realm template (per-session-cc + shared-cc) → 迁移 agents.yaml pipeline 到 realms.yaml |
| **长期** | 多 realm × 多 agent type 矩阵；"agent 不感知 pipeline" 终态 |

## 后续（2026-05-11 origin/dev 现状）

origin/dev 自己 ship 了 **#329 agents.yaml dissolution + agent_kinds in plugin manifest** + **#330 multi-session-per-instance + agent_instance per-file split** + **#323 SessionTemplate + Channel** + **#324..#328 SessionTemplate 实施 8-step**。中期方案部分实现。验跟原提议的 alignment 在 walkthrough #3 (esr-realm-yao worktree) 跑通后回到这条 note 补判定。

需要核的点：
- 拆 agents.yaml 走的是 plugin manifest `agent_kinds:` 字段；命名跟提议的 "Realm" 不同 — origin/dev 用 "SessionTemplate"（#323 spec）。多个概念名 (template / kind / realm) 同时存在，需要文档统一
- multi-session-per-instance (#330) 是否兑现"一个 CC 跨 session 共享"
- agent_kinds in plugin manifest 是否兑现 C12 plugin auto-register 设计
- claude 这边的 channel (#324) 是否就是 shared agent 的实现方式
