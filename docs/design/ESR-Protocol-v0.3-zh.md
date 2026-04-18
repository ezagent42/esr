# ESR 协议 v0.3

**全称**: ezagent Session Router — 架构治理协议
**版本**: 0.3 (Final)
**状态**: 工作草案
**范围**: 组织内部 AI-agent 网络治理

---

## 0. 摘要

ESR 协议 v0.3 是运行在单个组织内部的 AI-agent 网络架构治理协议。它规范如何声明、组合、验证和治理 agent 的契约边界, 特别是在大量代码由 AI 生成的环境中。

ESR 的范围是**组织内部的**。ESR 意义上的"组织"映射到一个 runtime 实例 (比如 esrd 集群)。跨组织集成显式地在本协议范围之外, 通过每个 Socialware 的外部接口处理 (见 Socialware Packaging Specification)。

---

## 1. 范围

### 1.1 范围内

- Agent contract 声明 (行为边界)
- Topology 组合 (agent 如何合并成业务流)
- 验证 (静态、动态、运行时合规)
- 治理 (在人类权威下的 contract 和 topology 演进)
- 支持跨层引用的最小消息 envelope

### 1.2 范围外

- Agent runtime 语义 (由实现选择; actor model, pipeline, graph 执行都可行)
- 消息传输的线路协议 (实现特定)
- 跨组织联邦 (显式非目标; 见 §11)
- 特定消息保证 (at-least-once, exactly-once 等是 runtime 选择)
- 失败处理语义 (监督策略是 runtime 选择)
- 持久化和状态存储
- 用户界面、工具、CLI (实现产物)

符合规范的实现**可以**使用任何底层 agent 机制。ESR 只要求契约层被正确实现在其上。

---

## 2. 基础假设

以下基于既有的 multi-agent 计算文献被假定为给定:

- **Agent**: 具有身份、状态和行为的可识别实体
- **Message**: 跨 agent 通信的离散单元
- **Failure**: agent 可能失败; 失败处理是 runtime 关注点
- **Trust boundary**: 共享一个 runtime 实例的 agent 集合是一个信任边界; 其内的 agent 相互信任遵守声明的契约

ESR 不重新定义这些概念。它在其上增加一个治理层。

---

## 3. 设计原则

以下原则是规范性的。任何违反使实现不符合规范。

**P1. 实现无关**。协议不规定 agent 如何执行或通信。实现在 runtime 选择上有完全自由。

**P2. 契约中心**。所有规范性内容都处理契约: 它们的声明、组合、验证或治理。其他一切在本协议之外。

**P3. 机器可检验**。每个 ESR 概念必须可机械验证。不能被检查的契约不是有效契约。

**P4. 人类可作者**。Contract 和 topology 必须可在合理时间内被人类编写和审阅。如果编写负担超过治理收益, 设计失败。

**P5. AI 友好**。Contract 和 topology 必须可被 AI 助手阅读和编写。它们作为 AI 代码生成和自我验证的权威上下文。

**P6. 渐进披露**。简单系统应有简单工件。复杂工件只为复杂系统需要。

**P7. 关注点分离**。Contract (允许什么)、topology (如何组合)、verification (是否正确发生)、governance (如何变更) 是四个不同关注点。实现可以支持任何子集。

**P8. 组织边界尊重**。协议在单个组织的信任边界内运作。跨组织集成由应用层机制 (Socialware 外部接口) 处理, 不是协议扩展。

---

## 4. Agent Contracts

### 4.1 目的

Contract 声明 agent 的行为边界: 它接收什么, 它发送什么, 它必须不做什么。contract 是 agent 的公共架构意图——一个保持在声明边界内的承诺。

### 4.2 Contract Schema

符合规范的 contract **必须**声明:

**Identity**
- `id_pattern`: 匹配符合 agent ID 的正则或 glob
- `role`: agent 架构角色的一句描述

**Incoming** (如果 agent 接收消息则必填):
- 订阅列表, 每项:
  - `topic_pattern`: 订阅的 topic 或模式
  - `message_shape`: 预期内容的最小 schema
  - `purpose`: 此订阅存在的原因

**Outgoing** (如果 agent 发送消息则必填):
- 发布列表, 每项:
  - `topic`: 发布到的 topic
  - `trigger`: 此发布何时发生
  - `message_shape`: 外发内容的最小 schema

**Targeting** (可选, 用于直接 agent 到 agent 寻址):
- 允许的 target 模式列表, 每项:
  - `target_pattern`: 允许接收者的 ID 模式
  - `purpose`: 为什么允许直接消息

**Forbidden** (必填, 即使为空):
- 禁止行为的显式列表, 每项:
  - `type`: "publish" | "target" | "side-effect"
  - `specification`: 什么被禁止
  - `rationale`: 说明

**State** (可选):
- 持久性 (无、内存中、持久)
- 是否可被其他 agent 查询

**Failure disposition** (可选):
- 预期失败模式
- 恢复期望

### 4.3 Contract 唯一性

在一个 runtime 实例内, 对任何给定的 `id_pattern`, 最多**可**有一个活跃 contract。冲突是规范违反。

### 4.4 Contract 变更类别

- **Additive**: 只添加允许的行为
- **Restrictive**: 移除允许的行为或添加禁止项
- **Neutral**: 只变更文档、理由或元数据

Restrictive 变更**必须**重新验证所有依赖的 topology。

### 4.5 Contract 格式

实现**必须**记录它选择的格式。强烈建议使用人类可读文本格式 (YAML, TOML, 结构化 Markdown)。二进制或不透明格式不符合规范。

---

## 5. Topology 声明

### 5.1 目的

Topology 声明特定 agent 组如何合并以实现业务结果。它是架构师的显式声明: "在这些条件下, 系统流应该长这样"。

### 5.2 Topology Schema

符合规范的 topology **必须**声明:

**Identity**
- `name`: 唯一 topology 标识符
- `description`: 业务目的, 一段话

**Trigger**
- 此 topology 变为活跃的条件
- 可引用事件、控制消息或始终开启

**Participants**
- 涉及的 agent 列表, 每项:
  - `agent_ref`: 匹配某个 contract 的 id_pattern 的引用
  - `role_in_this_topology`: 此 agent 在此特定流中的角色

每个 participant **必须**有已注册的 contract。

**Flows**
- 有序或条件性的消息交换
- 每项:
  - `from`: 源 participant
  - `to`: 目的地 (participant 或 topic 模式)
  - `via_topic` 或 `via_target`: 路由信息
  - `trigger_condition`: 此交换何时发生
  - `expected_behavior`: 此交换产生什么结果

**Branches** (可选)
- 特殊条件下的替代流

**Acceptance Criteria**
- 指示成功的可观察条件
- 典型: "最终, 这些消息已发送, 这些状态已观察"

**Contract Dependencies** (派生, 自动生成)
- 此 topology 依赖的 contract 条款集合
- 实现**应**自动计算此项

### 5.3 Topology 有效性

topology **有效**当:

1. 每个 participant 有已注册的 contract
2. 每个 flow 项在相关 participant 的 contract 内
3. 每个被引用的消息形式匹配 contract 声明
4. 没有 flow 违反任何 participant 的禁止列表
5. acceptance criteria 只引用契约化的行为

无效 topology **必须不**被激活。

### 5.4 Topology 生命周期

- **Defined**: 已编写, 尚未验证
- **Valid**: 通过验证
- **Active**: 已部署, 影响 runtime
- **Retired**: 不再活跃, 保留作参考

实现**必须**防止无效 topology 变为活跃。

---

## 6. 验证

### 6.1 静态验证

部署前, 实现**应**验证:

- 每个 contract 语法有效
- 每个 topology 语法有效
- 每个 topology-contract 引用一致
- 无 contract 冲突
- 所有引用可解析

输出: pass/fail 加详细违反报告。

### 6.2 动态验证

测试或 staging 时:

- 记录可观察消息和状态转换
- 对比 trace 和 participant contract (是否观察到任何禁止行为?)
- 对比 trace 和活跃 topology (预期流是否发生? 是否出现意外流?)

实现**必须**提供 trace 发射机制。机制是实现特定的。

### 6.3 运行时合规监控 (可选)

生产环境中:

- 持续监控违反 contract 的消息
- 检测未声明在任何活跃 topology 中的流
- 发射可观察性信号, 不是硬失败

生产环境**不应**脆弱; 监控是观察性的。

### 6.4 违反报告

所有验证模式**必须**生成报告, 包含:

- **Location**: 哪个工件或行为被违反
- **Description**: 具体违反的规则
- **Evidence**: 造成违反的实际行为
- **Suggestion**: 可能的修复, 可确定时

报告**必须**机器可解析, 以支持 AI 驱动的自动修正。

---

## 7. 治理

### 7.1 变更提议

提议变更**必须**表达为结构化工件, 包含:

- **Type**: additive / restrictive / neutral / new / deletion
- **Target**: 哪个 contract 或 topology 被影响
- **Proposed change**: 准确的修改
- **Rationale**: 为什么需要变更
- **Impact assessment**: 自动计算的列表:
  - 受影响的依赖 topology
  - 需要调整的现有代码
  - 会变为无效的历史消息

### 7.2 授权

变更**必须**在生效前被指定权威授权。规范不规定权威是谁; 这是组织决策。

- Restrictive 变更**必须**要求显式授权
- Additive 变更**可**在文档化规则下自动批准
- Neutral 变更**可**自动批准

### 7.3 版本化

Contract 和 topology **必须**有版本标识符。实现**必须**支持:

- 迁移期多版本共存
- 查询活跃版本
- 回滚

---

## 8. 最小消息 Envelope

为支持 contract 验证, ESR 符合规范系统中的每条消息**必须**至少有:

- `source`: 发送 agent 的标识符
- `destination_indicator`: `topic` (广播) 或 `target` (定向), 或两者
- `payload`: 内容, 对 ESR 不透明
- `metadata`: 键值映射, 前缀 `esr.` 的键被保留

实现**可**添加其他字段 (id, timestamp, ttl, reply_to 等)。Contract **可**引用 runtime 特定字段, 但这种 contract 将变为实现绑定。

### 8.1 Agent Identity

Agent ID 是字符串, 在 runtime 实例内唯一。实现定义自己的命名方案, 但**必须**文档化。

Contract 通过 ID 模式引用 agent。模式语言 (正则、glob 等) 是实现定义的, **必须**文档化。

---

## 9. Capability 声明

Runtime **必须**声明它支持哪些 ESR capability:

- `contract_declaration`: 编写和存储 contract
- `topology_composition`: 编写和存储 topology
- `static_verification`: 部署前检查
- `dynamic_verification`: 执行 trace 比较
- `runtime_monitoring`: 生产合规观察
- `governance_workflow`: 结构化变更提议

支持全部六项是 **full-ESR-conforming**。支持子集是 **partial-ESR-conforming**, 子集需文档化。

---

## 10. 符合性

### 10.1 必须

1. 至少提供 contract_declaration 和 static_verification
2. 文档化 contract 格式、topology 格式、身份方案、模式语法
3. 生成机器可读违反报告
4. 防止无效 topology 激活 (如果支持 static_verification)

### 10.2 应该

1. 提供 dynamic_verification
2. 提供 governance_workflow
3. 在文档中清晰分离实现特定功能和协议行为

### 10.3 可以

1. 添加 runtime 特定功能 (模式、标准库)
2. 捆绑开发工具 (CLI, UI, 测试)
3. 为特定部署场景优化

---

## 11. 显式非目标

清楚非目标和清楚目标同样重要。

### 11.1 跨组织联邦

ESR **显式不**定义组织互联协议。组织间集成通过三种应用层机制之一处理, 都在协议之外:

- **Mode A**: 在多个组织安装同一 Socialware (每个独立运行)
- **Mode B**: 将 Socialware 的自然语言或结构化接口暴露给外部调用者
- **Mode C**: 在 Socialware 内包含一个说外部协议的 adapter (如飞书 API)

不存在也不计划 "ESR 联邦协议"。理由见 ESR Reposition Final。

### 11.2 Runtime 重新发明

ESR 不规定 actor 调度、消息投递保证、监督、传输协议或任何既有 agent runtime 解决的关注点。这些被假定。

### 11.3 应用关注点

业务逻辑、LLM prompt 设计、内容审核、用户体验——都是应用关注点。ESR 的 contract **可**声明对这些行为的边界, 但协议不规定它们如何被实现。

---

## 12. 与先前版本的关系

### 12.1 v0.1 到 v0.2 转变

v0.2 把协议原语从六个减少到两个 (Peer 和 Message), 移除 Lobby, MembershipMode, PublishAuthority, View 作为协议级概念。

### 12.2 v0.2 到 v0.3 转变

v0.3 根本性地重新定位协议:

- **v0.2** 试图规定 agent 通信语义 (peer 身份、消息投递等)
- **v0.3** 移除所有这类规定, 把它当作实现关注点
- **v0.3** 添加显式规范: contract 声明、topology 组合、验证、治理——任何 actor runtime 之上的治理层

这是概念重构, 不是特性添加。既有 v0.2 实现可以通过保留它们的 runtime 但采纳 v0.3 契约层来适配。

### 12.3 v0.3 Final 澄清

v0.3 开发期间, 出现了额外澄清:

- ESR 范围显式是组织内部的
- 跨组织集成由 Socialware 外部接口处理, 不是协议扩展
- 自然语言接口是 Socialware 的一等功能 (不是协议的, 而是生态约定)
- 组织边界 = runtime 实例边界 (如一个 esrd 集群)

这些澄清反映在本 Final 版本各处。

---

## 13. 与 Socialware 的关系

本规范不定义 Socialware。Socialware 是建立在 ESR 之上的生态约定, 单独规定在 **Socialware Packaging Specification v0.3**。

一个 Socialware 是包含 contract、topology、handler 代码和外部接口声明的打包单元。理解 Socialware 对实际使用 ESR 至关重要, 但它不是协议的一部分。

---

*ESR 协议 v0.3 Final 结束*
