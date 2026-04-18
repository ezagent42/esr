# ESR 治理指南 v0.3

**目的**: 人类和 AI agent 在 ESR 下协同工作的实用工作流
**受众**: 架构师、使用 Claude Code 的开发者、Socialware 作者、运维
**配套**: ESR Reposition v0.3 Final, ESR 协议 v0.3, Socialware 打包规范 v0.3

---

## 0. 核心框架

在 AI 辅助开发中, 瓶颈从写代码转移到确保生成的代码与架构意图对齐。当一位人类架构师与 N 个 Claude Code 实例一起每小时生产数百行代码时, 传统代码审查不可扩展。

ESR 的答案: **通过契约和拓扑让架构意图变得机器可检验**, 然后设计工作流让人类和 AI 都能在这个框架内高效工作。

本文档定义实用工作流。

---

## 1. 角色

### 1.1 人类架构师

职责:

- 编写和审阅 **contract** (一次性、高价值投入)
- 编写和审阅 **topology** (启动业务流时的核心工作)
- 审阅 **CHANGE_PROPOSAL** 工件, 当 contract 或 topology 需要修改时
- 为可分发业务单元设计和批准 **Socialware 打包**
- **不**审阅普通实现代码 (契约验证处理正确性)

典型时间分配:

- Contract 和 topology 设计/审阅: 50%
- 架构决策和对齐: 30%
- 新场景探索和原型: 20%

架构师很少直接读实现代码。当发现自己频繁这样做时, 是契约不够强的信号——加强契约, 不是审阅习惯。

### 1.2 AI 开发者 (Claude Code, Cursor 等)

三种不同工作模式, 由角色特定 system prompt 驱动:

**Mode A — Topology Designer**:
- 任务: 实现新业务流
- 输入: 业务需求 (自然语言) + 相关 contract
- 输出: topology YAML + 设计笔记
- 禁止: 修改 contract, 编写实现代码

**Mode B — Peer Developer**:
- 任务: 实现或修改 agent 的 handler 代码
- 输入: 该 agent 的 contract + 测试场景
- 输出: handler 代码 + CONTRACT_COMPLIANCE.md
- 禁止: 修改 contract, 超出 contract 边界

**Mode C — Change Analyst**:
- 任务: 分析 CONTRACT_CHANGE_PROPOSAL 或 TOPOLOGY_CHANGE_PROPOSAL
- 输入: 提议 + 所有受影响的 contract 和 topology
- 输出: 影响分析
- 禁止: 做决策 (决策属于人类)

模式切换通过不同的 system prompt 强制, 架构师启动 CC 会话时选择。

### 1.3 验证基础设施

不是人, 但作为独立角色由工具扮演:

- **静态 verifier**: 检查 contract 语法 + topology-contract 一致性
- **动态 verifier**: 根据运行时 trace 验证契约和拓扑
- **治理跟踪器**: 跟踪 contract/topology 变更
- **CI/CD 集成**: PR 上的自动验证

验证基础设施的设计原则: **让正确的事情容易做, 让错误的事情立即可检测**。

### 1.4 Socialware 作者

为他人安装发布 Socialware 包的专业角色:

- 为完整业务单元编写 contract、topology 和 handler
- 以清晰度记录外部接口 (自然语言描述很重要)
- 遵循 Socialware 打包规范
- 适当版本化和维护向后兼容
- 响应来自安装者的 issue

Socialware 作者可以是个人、团队或组织。生态对贡献开放。

---

## 2. `esr` 命令行接口

`esr` CLI 是主要用户面工具。它把底层操作包装成工作流导向的命令集。

### 2.1 核心动词

**`esr use`** — 切换上下文到特定 esrd

```bash
# 连接到本地 esrd
esr use localhost:4000

# 连接到共享组织 esrd
esr use https://esrd.mycompany.example

# 显示当前上下文
esr use
  当前上下文: localhost:4000
  组织: allen's lab
  已连接: 是
```

上下文跨 shell 会话持久 (存储在 `~/.esr/config`)。

**`esr install`** — 把 Socialware 安装到当前组织

```bash
# 从 registry
esr install autoservice

# 从特定版本
esr install autoservice@1.2.0

# 从 git
esr install autoservice --from github.com/ezagent/autoservice

# 从本地目录
esr install autoservice --from ./my-socialware/

# 为特定目标 (声明集成意图)
esr install feishu-connector --for autoservice --app-id cli_xxx
```

输出显示每一步并用可操作细节报告任何失败。

**`esr talk`** — 通过自然语言与 Socialware 交互

```bash
esr talk autoservice
  > 显示正在进行的对话
  (自然语言响应)
  
  > 今天的升级率是多少?
  (响应)
  
  > exit
```

`esr talk` 连接到 Socialware 的自然语言接口 (如果有) 并提供对话 REPL。

**`esr expose`** — 让本地 Socialware 接口可外部访问

```bash
# 暴露特定接口
esr expose autoservice.supervisor_channel --to-external
  生成邀请链接: esr://allens-lab.example/sc-xyz
  与其他组织分享此链接。

# 列出当前暴露的接口
esr expose list
  autoservice.supervisor_channel → esr://allens-lab.example/sc-xyz (公开)
  autoservice.customer_channel → esr://allens-lab.example/sc-abc (需 token)
  
# 撤销暴露
esr expose revoke autoservice.supervisor_channel
```

**`esr use remote`** — 调用外部暴露的 Socialware

```bash
# 连接到暴露的接口
esr use remote esr://allens-lab.example/sc-xyz
  已连接: autoservice.supervisor_channel
  协议: natural_language
  
  > 显示未结案件
  (来自远程 Socialware 的响应)
```

这是跨组织集成在用户层发生的方式。协议层不涉及联邦——简单地是对远程 Socialware 暴露接口的包装调用。

### 2.2 检查动词

```bash
# 总体状态
esr status
  组织: allen's lab
  esrd: 运行中 (3 节点, 集群模式)
  已安装 Socialware:
    - autoservice v1.2.0 (4 agent, 3 topology, 2 interface)
    - feishu-connector v0.8.0 (1 agent, 1 interface)
  暴露接口: 2
  打开提议: 1

# 列出已安装 Socialware
esr list

# 检查特定 Socialware
esr inspect autoservice

# 列出可用接口
esr interfaces list

# 描述特定接口
esr interfaces describe autoservice/customer_inquiry
  # 显示此接口提供的自然语言描述
```

### 2.3 Contract 和 Topology 动词

大多数用户不需要经常使用——供架构师和 Socialware 作者使用:

```bash
# Contract 操作
esr contract list
esr contract inspect cc-responder
esr contract verify cc-responder
esr contract load path/to/new.contract.yaml

# Topology 操作
esr topology list
esr topology inspect autoservice-basic
esr topology activate autoservice-basic
esr topology retire autoservice-basic

# 验证
esr verify all
esr verify contracts
esr verify topologies
esr verify compatibility  # topology 对 contract
```

### 2.4 治理动词

```bash
# 创建提议
esr proposal create --type contract_change --target cc-responder

# 列出打开提议
esr proposal list

# 审阅提议 (显示影响分析)
esr proposal review 2026-04-20-expand-cc

# 批准/拒绝
esr proposal approve 2026-04-20-expand-cc
esr proposal reject 2026-04-20-expand-cc --reason "..."

# 归档和历史
esr proposal archive  # 列出过去提议
esr proposal show 2026-04-15-past-change
```

### 2.5 运行时操作

```bash
# 启动/停止本地 esrd (如果是本地 daemon)
esrd start
esrd stop
esrd restart

# 日志
esr logs autoservice              # Socialware 特定日志
esr logs --filter violations      # 仅违反事件
esr logs --follow                 # tail -f 等价

# 初始化组织
esrd init --org-name "my org"
  创建带 org 配置的 ~/.esrd/ 目录
```

### 2.6 分层命令结构

```
esrd (与 esrd release 捆绑, Elixir escript):
  - 本地 esrd 上的低层操作
  - esrd init, esrd start, esrd stop
  - esrd-cli (更深协议操作, 用于调试)
  
esr (与 SocialCommons 捆绑, Python):
  - 用户友好工作流命令
  - 大多数用户主要使用此
  - 在底下委托给 esrd
  
BEAM REPL (iex --remsh esrd@host):
  - 原生 Elixir 访问
  - 用于深度诊断、实验、紧急运维
```

三个接口, 同一底层系统。大多数用户只接触 `esr`。

---

## 3. 核心工作流

### 3.1 设置新组织

```bash
# 安装 esrd 和 esr
apt install esrd
pip install esr-cli

# 初始化
esrd init --org-name "my-org"
esrd start

# 连接 CLI
esr use localhost:4000

# 验证
esr status
  组织: my-org
  esrd: 运行中
  已安装 Socialware: (无)
```

这是一次性设置。未来工作在此组织内发生。

### 3.2 安装 Socialware (典型用户)

```bash
esr install autoservice
  ...检查兼容性...
  ...下载...
  ...加载 contract...
  ...验证 topology...
  ...启动 handler...
  ...运行冒烟测试...
  ✓ autoservice v1.2.0 已安装并运行

esr talk autoservice
  > hello
  (autoservice 响应)
```

### 3.3 开发新业务流 (架构师)

```
Step 1: 人类架构师写 topology 草稿
  - 参考业务需求
  - 查阅可用 contract, 选择 participant
  - 声明消息流

Step 2: 静态 verifier 运行
  - 检查 topology 引用有效 contract
  - 检查所有 flow 在 participant contract 内
  - 通过 → Step 3
  - 失败 → 调整 topology 或发起 CONTRACT_CHANGE_PROPOSAL

Step 3: CC (Mode A) 从 topology 生成粘合配置
  - 不修改 handler 代码
  - 产生部署工件

Step 4: 测试场景编写
  - 由架构师或 CC
  - 覆盖 topology 分支和接受条件

Step 5: 动态 verifier 运行
  - 执行测试场景
  - 收集 trace
  - 对比 trace 和 topology + contract
  - 任何违反 → 反馈给 CC 进行自动修正

Step 6: 人类审阅
  - 架构师审阅 topology (主要焦点)
  - 架构师审阅变更日志 (次要)
  - 批准时 merge
```

架构师的实际审阅时间集中在 Step 1 和 Step 6。其他步骤是 CC + 验证自动化。

### 3.4 开发新 Agent/Handler (架构师 + CC)

```
Step 1: 人类架构师写 agent contract
  - 声明 identity、role、incoming、outgoing、targeting、forbidden
  - 值得花时间投入

Step 2: 静态 verifier 检查 contract
  - 语法有效性
  - 与现有 contract 无冲突

Step 3: CC (Mode B) 实现 handler
  - 只读 contract, 不读其他 handler 代码
  - 每个 publish/subscribe/target 调用注释契约条款
  - 生成 CONTRACT_COMPLIANCE.md

Step 4: 此 agent 的测试场景
  - CC 基于 contract 生成场景
  - 人类审阅合理性

Step 5: 动态 verifier 运行
  - 所有场景中验证契约合规

Step 6: 人类审阅 contract 和合规报告
  - 焦点: contract 是否设计良好?
  - 不是: 逐行 Python 审阅
```

### 3.5 Contract 变更流 (罕见但关键)

```
Step 1: 提议编写
  - 由人类架构师, 或 CC (当遇到契约限制时)
  - 描述变更 + 理由

Step 2: CC (Mode C) 生成影响分析
  - 受影响 topology 列表
  - 受影响代码识别
  - 可能被无效化的历史消息
  - 迁移路径建议

Step 3: 架构师决策
  - 接受、拒绝或要求修订
  - 接受时, 选择直接升级 vs 分阶段推出

Step 4: 实施
  - 更新 contract
  - 更新受影响 topology
  - 完整验证通过

Step 5: 记录
  - 提议归档
  - CHANGELOG 更新
  - 理由保留供未来参考
```

关键: **Step 3 的决策权严格属于架构师**。CC 从不自行修改 contract。此纪律保留架构控制。

### 3.6 发布 Socialware

```
Step 1: 确保 Socialware 满足发布要求
  - Manifest 完整
  - Contract、topology 已验证
  - Handler 通过合规检查
  - 场景全面
  - README 清晰描述包
  - 外部接口以自然语言描述记录

Step 2: 本地测试安装
  esr install my-socialware --from ./my-socialware/

Step 3: 迭代直到安装干净且冒烟测试通过

Step 4: 标签版本并发布
  esr publish ./my-socialware/ --to registry.example.com

Step 5: 消费者安装
  esr install my-socialware
```

---

## 4. Contract 编写指南

### 4.1 好 Contract 的品质

- **具体而非抽象**: "MUST NOT publish to customer_messages" 好于 "MUST NOT send customer-facing messages"
- **可验证而非原则性**: 每个条款应机械可检查
- **有推理而非任意**: 每个禁止项包含理由
- **最小而非综合**: 只声明有意义的边界, 不是实现细节

### 4.2 常见错误

**错误 1: 嵌入业务逻辑**

```yaml
# 错
outgoing:
  - topic: customer_replies
    condition: "在分析意图并生成 200-300 词同理心响应后"

# 对
outgoing:
  - topic: customer_replies
    trigger: "收到 customer_messages 时"
    message_shape: { content: string, metadata: {...} }
```

**错误 2: 省略 forbidden 列表**

无 `forbidden` 部分的 contract 几乎总是不完整的。显式声明什么被禁止与声明什么被允许同样重要。

**错误 3: 过于宽松的 contract**

如果 contract 几乎允许任何行为, 它已失去价值。好 contract 像好 API: 清楚说明能做什么, 并隐式限制其他一切。

### 4.3 成熟度指标

成熟的 contract 显示:

- **低违反率**: 新代码很少违反它 (不太严, 不太松)
- **低变更率**: 数周稳定 (设计思考已收敛)
- **角色清晰**: 单读 contract 就传达 agent 的角色

---

## 5. Topology 编写指南

### 5.1 好 Topology 的品质

- **讲故事**: 读起来像业务流, 不是连接列表
- **Participant 明确分配**: 每个 participant 的角色被声明
- **分支显式**: 替代路径被命名, 不是暗示
- **Acceptance criteria 机械可检查**: 可测试条件

### 5.2 Topology 范围

一个 topology, 一个业务场景。不是一个业务领域。

好: `business/takeover.topology.yaml` 只描述接管流
差: `business/autoservice.topology.yaml` 试图描述所有 AutoService

小 topology 更易审阅、验证、修改。大 topology 不可避免地变成无人能理解的怪物。

### 5.3 Topology 关系

多个 topology 可能涉及同一 agent。这是正常的——agent 是资产, 跨业务复用。

注意:

- 两个 topology 可能都期望 agent 以特定方式行为, 但实际上只有一个能赢。当优先级重要时, 显式声明
- Topology 通过共享 agent 间接耦合; 变更一个 topology 可能影响另一个。影响分析跨 topology

---

## 6. CC Prompt 模板

### 6.1 Mode A: Topology Designer

```
你是 Topology Designer 模式下的 CC。

你的任务: 基于业务需求, 设计一份 topology 文件。

资源:
- 业务需求: <内联文本或文件引用>
- 所有相关 contract: <路径>
- 现有相关 topology (供参考): <路径>

规则:
1. 你只输出 topology YAML 和解释设计决策的 DESIGN_NOTES.md
2. 你不能修改任何 contract 文件
3. 你不能写任何 Python handler 代码
4. 每一条消息流都必须在相关 participant 的 contract 内可行
5. 如果需要 contract 修改, 输出 CONTRACT_CHANGE_PROPOSAL.md
   而非自作主张

输出:
- <topology_name>.topology.yaml: 主产物
- DESIGN_NOTES.md: 解释关键决策
- (可选) CONTRACT_CHANGE_PROPOSAL.md: 如需 contract 变更

交付前自检:
- 运行静态 verifier
- 确认 0 违反
- DESIGN_NOTES 解释所有权衡
```

### 6.2 Mode B: Peer Developer

```
你是 Peer Developer 模式下的 CC。

你的任务: 实现 agent 的 Python handler 代码。

资源:
- 此 agent 的 contract: <路径>
- 测试场景: <路径>
- 基础 SDK 文档: esr-handler-py 参考

规则:
1. 你的代码必须严格遵守 contract
2. 每个 handler.publish/subscribe/target 调用前在注释中标注
   匹配的 contract 条款
3. 如果业务需要超出 contract 的行为, 停下并输出 
   CONTRACT_CHANGE_PROPOSAL.md
4. 不依赖其他 agent 的内部实现; 只依赖它们 contract 声明的行为

输出:
- Handler 实现代码
- CONTRACT_COMPLIANCE.md: 列出所有 I/O 操作及其 contract 条款
- 单元测试

交付前自检:
- 对所有 publish/subscribe/target 调用运行静态分析
- 验证每个在 contract 内
- 运行动态 verifier; 所有测试场景通过
```

### 6.3 Mode C: Change Analyst

```
你是 Change Analyst 模式下的 CC。

你的任务: 分析 CHANGE_PROPOSAL 并产出影响报告。

资源:
- Proposal 文件: <路径>
- 所有当前 contract 和 topology: <路径>
- Git 历史 (变更记录)

规则:
1. 你分析; 你不决策
2. 输出是客观影响评估, 不是"建议批准"或"建议拒绝"
3. 分析必须覆盖:
   - 直接影响: 哪些 contract/topology/代码直接受影响
   - 间接影响: 可能通过什么路径受影响
   - 风险: restrictive 变更的具体风险点
   - 替代方案: 满足需要但影响更小的其他方案

输出:
- IMPACT_ANALYSIS.md: 结构化影响分析
- (可选) ALTERNATIVES.md: 替代方案探索

不输出:
- "批准"或"拒绝"推荐
- 强烈偏向特定选择的措辞
```

---

## 7. 审阅清单

### 7.1 审阅 Topology 时

- [ ] 故事清楚吗? 读者能理解业务流吗?
- [ ] 每个 participant 的角色清楚地陈述?
- [ ] 静态验证通过?
- [ ] 分支完整? 非 happy path 场景覆盖?
- [ ] Acceptance criteria 机械可验证?
- [ ] 有看似属于另一个 topology 的内容?

### 7.2 审阅 Contract 时

- [ ] 角色能一句清楚陈述?
- [ ] Forbidden 列表显式且有推理?
- [ ] Incoming/outgoing 覆盖所有设想行为?
- [ ] 业务级细节泄漏到 contract 里?
- [ ] 如果此 agent 出现在其他 topology, contract 仍合适?

### 7.3 审阅 CHANGE_PROPOSAL 时

- [ ] 理由充分?
- [ ] 影响分析覆盖所有路径?
- [ ] 有影响更小的替代方案?
- [ ] 变更是 additive 还是 restrictive? Restrictive 需要额外小心
- [ ] 如果批准, 迁移计划清楚?

### 7.4 审阅 Socialware (作为作者)

- [ ] Manifest 完整描述包?
- [ ] 外部接口用自然语言清楚记录?
- [ ] 场景覆盖实际用例?
- [ ] README 解释包的价值主张?
- [ ] 配置参数记录良好?
- [ ] 密钥明确标记?

---

## 8. 典型项目目录

```
my-project/
├── esrd-config/               # 组织级 esrd 配置
│   └── cluster.yaml
│
├── installed-socialware/      # 已安装 Socialware 的元数据
│   ├── autoservice@1.2.0/
│   └── feishu-connector@0.8.0/
│
├── my-socialware/             # 本地开发中的 Socialware
│   ├── socialware.yaml
│   ├── contracts/
│   ├── topologies/
│   ├── handlers/
│   ├── interfaces/
│   └── scenarios/
│
├── proposals/
│   ├── open/
│   └── archive/
│
└── docs/
    ├── architecture.md
    └── governance-decisions.md
```

这个结构让每个工件有它的位置。Contract 和 topology 是一等公民, 不埋在代码里。

---

## 9. 给架构师的元建议

**建议 1: 投资于契约, 不是代码审阅**

你在 contract 上的时间会复利。代码审阅不会。

**建议 2: 允许 contract 初期粗糙, 在使用中精炼**

第一版 contract 不会是最终版。期待 5-10 次迭代才稳定。这是正常的; 你在用实际使用校准。

**建议 3: 把 CHANGE_PROPOSAL 当作思考工具**

当 CC 提出 CHANGE_PROPOSAL, 别只想"批准还是拒绝"。这是重新考虑架构的机会——它揭示了原 contract 的局限, 或业务的新方向。

**建议 4: 学会说"不"**

当业务需要看似"要求"放松 contract 时, 先问"能不能重塑业务而非放松 contract?" 每次 restrictive contract 放松成为永久债务。

**建议 5: 生态建设从 contract 开始**

当未来其他人基于你的项目构建时, contract 是最宝贵的资产。Contract 是可传递、可复用的架构知识。代码不是。

**建议 6: 分享 Socialware, 不仅仅是代码**

ezagent 生态的飞轮是 Socialware 在组织间流动。当你构建可复用的东西, 打包为 Socialware 并分享。这让社区的能力复利。

---

## 10. 术语表

- **ESR**: 架构治理协议
- **esrd**: ESR 的第一个参考实现, 基于 Elixir/OTP
- **组织**: 一个 esrd 实例的信任边界
- **Socialware**: 打包、可分发的业务单元 (contract + topology + handler + interface)
- **Contract**: agent 行为边界的声明
- **Topology**: agent 在业务流中如何组合的声明
- **验证**: contract/topology 合规的自动化检查
- **治理**: 在人类权威下演进 contract 和 topology 的流程
- **Handler**: 实现 agent 业务逻辑的 Python 进程
- **接口**: Socialware 的外部入口 (自然语言或结构化)
- **esr** (小写斜体 CLI): 主要用户面命令行工具
- **Proposal**: contract 或 topology 变更的结构化请求

---

*ESR 治理指南 v0.3 Final 结束*
