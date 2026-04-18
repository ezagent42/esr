# ESR v0.3 — 最终定位

**版本**: 0.3 (Final)
**日期**: 2026 年 4 月
**性质**: ESR 是什么和不是什么的定义性声明

---

## 一句话定义

**ESR 是运行在单个组织内部的 AI-agent 网络架构治理协议，Socialware 是赋予这些组织能力的可流通业务包。**

请慢慢读这句话。每一个词都重要。我们经过多轮讨论才达到这种精确度。

---

## 完整图景

### 基本单位: 组织 = esrd 实例

ESR 意义上的**组织**是一个信任边界, AI agent 在其中自由协作。它一对一映射到一个 **esrd 实例** (可能是单机的, 也可能是 BEAM 分布式集群——集群是内部实现, 对外看它是一个组织)。

组织的示例:

- 运行自己 esrd 的个人实验室 (单人, 小规模)
- 一个共享 esrd 的公司部门 (多个团队, 中等规模)
- 运行多节点 esrd 集群的整个公司 (数千 agent, 大规模)

在组织内部, agent 通过 ESR 的内部协议自由对话。组织有信任边界——内部可信, 外部不可信。

### 流通物: Socialware

在组织内部, 能力由 **Socialware** 交付——这是一个打包好、版本化、可安装的单元, 包含特定业务功能所需的一切:

- **Contracts** 声明包内每个 agent 能做什么
- **Topologies** 声明 agent 如何组合成业务流
- **Handler 代码** 实现 agent 的业务逻辑
- **外部接口**, 用自然语言描述 Socialware 对外提供什么能力

一个 Socialware 对组织的意义, 就像 Docker image 对容器主机, 或 npm 包对 Node.js 项目: **一个可移植、可复用的能力单元**。

Socialware 可以:

- 由任何人编写
- 发布到 registry (公开或私有)
- 通过 `esr install` 命令安装
- 版本化和升级
- fork 和修改

**Socialware 让 ezagent 的 "Organization as a Service" 愿景变得具体**。安装一个 Socialware 的字面意义就是给你的组织增加一个新的 AI 能力, 开箱即用。

### 契约层: ESR 真正的贡献

在 actor model 和消息传递都是已解决问题的今天, 让 ESR 值得存在的唯一概念是**契约层**。

在大量代码由 AI 生成的系统中, 瓶颈从"写代码"转移到"确保代码尊重架构意图"。人类审查无法和 AI 代码生成同步扩展。ESR 通过让**架构意图变得机器可检验**来解决这个问题:

- **Contract** 声明 agent 能做什么和不能做什么
- **Topology** 声明 agent 如何组合成业务流
- **Verification** 自动检查代码和行为是否停留在 contract 内
- **Governance** 定义 contract 如何在人类权威下演进

这就是 ESR 的新颖贡献。下层 (actor runtime, 消息传递) 是被假定的; 上层 (业务逻辑, 用户体验) 是应用。ESR 是中间的薄薄一层, 让大规模 multi-agent 系统可治理。

### 组织内部 vs 跨组织

**组织内部**, 一切紧密集成:

- agent 运行在共享的 BEAM 集群上
- 消息通过 Phoenix.PubSub 传递, 无网络开销 (或 BEAM distributed 开销极小)
- contract 和 topology 的强制是 runtime 原生的
- 信任在组织内隐式成立

**组织之间**, 不存在 "ESR 联邦协议"。跨组织集成通过三种应用层机制中的一种, 都不在协议范围内:

**Mode A**: 在多个组织中安装同一个 Socialware (每个组织独立运行, 可能通过 Socialware 自己的机制同步数据)

**Mode B**: 一个组织暴露 Socialware 的自然语言或结构化接口; 另一个组织的 agent 调用它。"接口"字面上就是 Socialware 能做什么的自然语言描述——没有 schema, 没有 API 文档, 只有 AI agent 能理解的散文

**Mode C**: 一个组织的 Socialware 包含一个说外部系统协议的 adapter (比如飞书 API, Anthropic API, 另一家公司的 REST 端点)。这是传统集成, 打扮成 ESR handler 的样子

**这三种模式共存**。没有"正确的方式"连接组织。ESR 在每个组织内部提供治理层; 组织如何连接是每对关系的业务决策。

### 自然语言接口

这种架构最激进的含义是 **Socialware 的外部接口可以是自然语言而不是结构化 API**。

传统集成:

> "要使用我们的服务, 请阅读我们的 OpenAPI 规范, 实现发送 POST 请求到 `/api/v1/query` 的客户端代码, 带 JSON 正文包含这些字段..."

自然语言集成:

> "我们的 `autoservice` Socialware 处理客户咨询。像跟客服主管说话那样跟它说话。示例查询: '显示所有升级案例', 'VIP 客户的响应时间是多少?'"

在集成双方都是 AI agent 的时代, 散文描述**就是**接口。agent 可以阅读、理解、相应地交互。这让几十年的企业集成复杂度坍缩。

这不是未来愿景。用现在的 LLM, 它今天就能工作。Socialware 应该把自然语言接口作为一等选项, 而不是"结构化 API 太麻烦时的回退"。

---

## ESR 不是什么

对 ESR 不是什么保持精确, 和对 ESR 是什么保持精确同样重要。

**不是又一个 actor 框架**。Erlang, Akka, Ray, Proto.Actor 都存在。ESR 假定 actor model; 不重新发明。它的第一个实现 (esrd) 使用 Elixir/OTP 因为它成熟。

**不是消息总线或消息队列**。RabbitMQ, Kafka, NATS 解决消息传递。ESR 使用消息传递但不是关于消息传递。它是关于声明哪些消息应该和不应该存在。

**不是联邦协议**。Matrix, ActivityPub, email——这些联邦化社交/通信网络。ESR 显式地不联邦。跨组织连接是逐个关系处理的, 通过 handler 和自然语言接口。

**不是工作流引擎**。Temporal, Airflow, Prefect 编排长期运行的工作流。ESR 的 topology 看起来相似但服务不同目的——它是架构契约, 不是执行计划。

**不是低代码平台**。低代码旨在消除代码。ESR 旨在治理 AI 生成的代码。

**不是 AI 框架**。LangChain, AutoGen, CrewAI 提供构建 agent 的框架。ESR 在它们下层——它是这类框架可以运行在其上的架构底座。

**不是 service mesh**。Istio, Linkerd 管理微服务中的服务间通信。不同层, 不同关注点。

这些澄清重要是因为 ESR 小而聚焦。如果你宽泛地定位它, 它在每个更广类别里对比既有工具看起来都弱。精确地定位, 它占据了没有其他工具直接解决的独特 niche。

---

## ESR 适合谁

**主要受众**: 构建重要 AI-agent 系统的组织, 其中:

- 需要多个具有不同职责的 agent
- 代码大量由 AI 生成 (Claude Code, Cursor, Copilot)
- 随着代码量增长, 架构漂移是真实风险
- 人类架构师时间是瓶颈, 不是代码生产速度

**次要受众**: 为 ezagent 生态构建和发布 Socialware 的开发者

**第三受众**: 想安装现成 Socialware 获得新 AI 能力而不从头构建的组织

**不是受众**: 只有一两个 agent 的小项目, 完整的人类代码审查就足够。ESR 增加的开销只有在规模够大时才值得付。

---

## 用户体验: `esr` CLI

从用户视角, ESR 交付的体验围绕这些命令:

```bash
# 初始化一个组织
esrd init --org-name "allen's lab"
esrd start

# 连接到组织的 esrd
esr use localhost:4000

# 安装一个 Socialware
esr install autoservice --from github.com/ezagent/autoservice

# 通过自然语言与 Socialware 对话
esr talk autoservice
  > 让我看看正在进行的对话
  (Socialware 用自然语言回复)

# 安装一个外部连接器 (第三方 API 的 handler)
esr install feishu-connector --for autoservice --app-id cli_xxx

# 将 Socialware 接口暴露给外部调用者
esr expose autoservice.supervisor_channel --to-external
  生成邀请: esr://allens-lab.example/sc-xyz

# 从另一个组织使用远程接口
esr use remote esr://allens-lab.example/sc-xyz
  > 显示正在进行的对话

# 查看组织状态
esr status
```

三个核心动词:

- **`install`**: 把 Socialware 带进这个组织并运行
- **`use`**: 切换上下文到特定 esrd (主要用于本地), 或调用远程 Socialware 接口
- **`talk`**: 通过自然语言与本地 Socialware 交互

两个处理外部暴露的动词:

- **`expose`**: 声明本地 Socialware 接口可从外部调用
- **`use remote`**: 调用另一个组织暴露的 Socialware 接口

其他 (configure, upgrade, rollback, inspect 等) 遵循标准工具模式。

---

## 为什么这个特定定义重要

在早期版本 (v0.1, v0.2), ESR 试图成为许多东西:

- 跨语言 actor 协议
- 消息路由层
- 既有中间件的替代品
- AI-agent 开发的基础

每次尝试让项目变得更宽但也更散漫。每个 "ESR 也是 X" 的声明都要求 ESR 对抗 X 的现有强者。

v0.3 Final 更窄但更有防御力:

- ESR **不**和 actor runtime 竞争——它建立在它们之上
- ESR **不**和消息总线竞争——它运行在它们之上
- ESR **不**和联邦协议竞争——它显式地不联邦
- ESR **确实**占据一个现有工具不直接解决的 niche: **组织边界内 AI 生成的 multi-agent 系统的架构治理**

Socialware 向外扩展这个 niche: ESR 单独在一个组织里已经有趣; Socialware 作为跨组织流通的可移植单元, 才是让 ezagent 愿景成立的关键。

自然语言接口前沿再进一步扩展它: 带 NL 接口的 Socialware 可以被其他 AI agent 连接, 无需任何人类编写的集成代码。这种能力只因为我们承诺了精确、窄、精心选择的起点才可能。

---

## 分层图

```
┌────────────────────────────────────────────────────────────────┐
│  组织 A                              组织 B                       │
│                                                                  │
│  ┌───────────────────────────┐   ┌───────────────────────────┐ │
│  │  用户通过 `esr` CLI         │   │  用户通过 `esr` CLI         │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  已安装的 Socialware        │   │  已安装的 Socialware        │ │
│  │   - contracts              │   │   - contracts              │ │
│  │   - topologies             │   │   - topologies             │ │
│  │   - handlers (Python)      │   │   - handlers (Python)      │ │
│  │   - external interfaces    │   │   - external interfaces    │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  ESR 治理层:                 │   │  ESR 治理层:                 │ │
│  │   contract, topology,      │   │   contract, topology,      │ │
│  │   verification, governance │   │   verification, governance │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  esrd runtime              │   │  esrd runtime              │ │
│  │   (Elixir/OTP)             │   │   (Elixir/OTP)             │ │
│  │   - actor GenServers       │   │   - actor GenServers       │ │
│  │   - BEAM distributed       │   │   - BEAM distributed       │ │
│  │     (多节点集群)             │   │     (多节点集群)             │ │
│  └────────────────────────────┘   └────────────────────────────┘ │
│          组织的信任边界                                            │
│                                                                    │
└────────────────────────────────────────────────────────────────┘
                                   │
                                   │ 外部集成在这个边界发生
                                   │ (不通过 ESR 联邦)
                                   ▼
                   ┌─────────────────────────────────────┐
                   │ 选项:                                │
                   │  1. Socialware 的 NL 接口             │
                   │  2. Socialware 的 API adapter       │
                   │  3. 本地安装同一个 Socialware         │
                   └─────────────────────────────────────┘
```

每个组织在它的信任边界内有完整的 ESR 栈。组织之间没有 ESR 协议——只有各个 Socialware 包自己选择暴露的各种外部接口选项。

---

## 本定义下的文档结构

v0.3 文档集包含:

1. **ESR-Reposition-v0.3-Final.md** (本文件)——定义性锚点
2. **ESR-Protocol-v0.3.md**——contract, topology, verification, governance 的规范规约 (组织内部)
3. **Socialware-Packaging-Spec-v0.3.md**——Socialware 包格式的规范规约, 包括自然语言接口声明
4. **esrd-reference-implementation-v0.3.md**——Elixir/OTP 如何实现 ESR 并承载 Socialware
5. **ESR-Governance-Guide-v0.3.md**——实用工作流指南, 包括 `esr` CLI 参考
6. **ESR-Playground** (HTML)——contract + topology + verification 的交互可视化

每份文档有特定角色。Protocol 规范是规范性的且小。Socialware 规范定义打包格式。esrd 是一个实现。Governance 是实用指导。Playground 是直觉。

**v0.3 不需要其他文档**。如果一个概念不适合放进其中一份, 它可能就不应该在 v0.3 里。

---

## 对此定义的最终检验

一个好的定义是清楚地包括某些事情和清楚地排除另一些事情。让我们检验这个:

本定义**包括**:

- 为客户服务自动化编写 Socialware
- 从 registry 安装公开 Socialware
- 声明 AI 生成代码必须尊重的 contract
- 在测试中验证 topology 合规
- 把 Socialware 的自然语言接口暴露给外部调用者
- 在一个组织的 esrd 中运行多个 Socialware
- 在一个组织内的多台机器上运行 BEAM 集群化的 esrd

本定义**排除**:

- 构建连接陌生人的公开 agent 网络 (那是另一种项目)
- 替代 Kafka 或 RabbitMQ (层次错了)
- 提供构建 agent 的低代码 UI (范围外)
- 把组织联邦化到一个单一协议下 (显式非目标)
- 编排长期运行工作流 (那是 Temporal 的工作)
- 标准化 AI agent 如何与工具对话 (MCP 做那件事)

此检验确认定义既不过宽也不过窄。它挑出一个特定问题空间并留在其中。

---

## 结语

ESR v0.3 是数月迭代的产物。最终定义是小的、精确的、新颖的。它得益于大量批评——剥去了所有非本质的东西。

如果你作为未来贡献者或用户在读这份文档, 这里是应采纳的心态:

- **尊重范围的窄**。ESR 是契约层, 不是万能框架
- **信任分层**。Agent runtime 不是你的问题; 契约执行才是
- **以 Socialware 为单位思考**。业务能力以包的形式出现, 不是散落的代码
- **拥抱自然语言接口**。在 AI 时代, 它们不是妥协; 往往是正确选择
- **保持组织边界显式**。信任是有界的; 不要假装不是

项目中的一切都源自这些原则。

---

*最终定位, v0.3。所有后续文档由此派生。*
