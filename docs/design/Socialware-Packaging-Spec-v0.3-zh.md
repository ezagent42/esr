# Socialware 打包规范 v0.3

**版本**: 0.3
**状态**: 工作草案
**性质**: Socialware 包格式的规范规约

---

## 0. 什么是 Socialware

一个 **Socialware** 是 ESR 生态的打包、版本化、可安装的组织能力单元。它是"业务功能"或"组织角色"的可移植等价物——通过一条命令就能安装到任何符合 ESR 规范的 runtime 上。

Socialware 对 ESR 的意义, 就像 Docker image 对容器运行时, 或 npm 包对 Node.js: **一个定义良好的可移植单元**。

本规范定义 Socialware 包的规范格式。

---

## 1. 包布局

一个 Socialware 是具有特定结构的目录:

```
my-socialware/
├── socialware.yaml          # 包 manifest (必需)
├── README.md                # 人类可读描述 (必需)
├── CHANGELOG.md             # 版本历史 (版本化发布时必需)
│
├── contracts/               # Agent contracts (如包含 actor 则必需)
│   ├── agent-a.contract.yaml
│   └── agent-b.contract.yaml
│
├── topologies/              # 业务流声明 (如包含流则必需)
│   ├── main-flow.topology.yaml
│   └── exception-flow.topology.yaml
│
├── handlers/                # Python handler 实现 (如包含 handler 则必需)
│   ├── agent-a/
│   │   ├── handler.py
│   │   ├── requirements.txt
│   │   └── CONTRACT_COMPLIANCE.md
│   └── agent-b/
│       ├── handler.py
│       └── requirements.txt
│
├── interfaces/              # 外部接口声明 (可选)
│   ├── customer_inquiry.interface.yaml
│   └── supervisor_dashboard.interface.yaml
│
├── scenarios/               # 测试场景 (发布包必需)
│   ├── basic-flow.scenario.yaml
│   └── takeover.scenario.yaml
│
├── docs/                    # 补充文档 (可选)
│   ├── architecture.md
│   └── configuration.md
│
└── examples/                # 示例配置 (可选)
    └── default-config.yaml
```

### 1.1 必需文件

每个 Socialware **必须**有:
- `socialware.yaml` — 包 manifest
- `README.md` — 人类可读概述

任何非平凡的 Socialware (超出演示的) **必须**还有:
- `CHANGELOG.md` — 版本历史
- `contracts/` 中至少一个 contract
- `topologies/` 中至少一个 topology
- `handlers/` 中至少一个 handler (如果任何 contract 需要实现)
- `scenarios/` 中至少一个 scenario

### 1.2 可选文件

- `interfaces/` — 自然语言或结构化外部接口声明
- `docs/` — 补充文档
- `examples/` — 示例配置文件

---

## 2. Manifest (`socialware.yaml`)

Manifest 是 Socialware 的身份证。它**必须**遵循此结构:

```yaml
# socialware.yaml
schema_version: "esr/v0.3"

name: autoservice
version: 1.2.0
description: "AI 驱动的客户服务自动化, 带人工监督"

authors:
  - name: "Allen Woods"
    email: "allen@ezagent.chat"
    role: "author"

license: Apache-2.0
homepage: "https://github.com/ezagent/autoservice"
repository: "https://github.com/ezagent/autoservice.git"

# Runtime 要求
requires:
  esr_protocol_version: ">=0.3"
  esrd_version: ">=0.3"
  python_version: ">=3.11"

# 声明的组件 (自动从目录检测, 但这里列出以便清晰)
components:
  contracts:
    - feishu-adapter
    - cc-responder
    - operator-console
    - journal
  topologies:
    - autoservice-basic
    - autoservice-takeover
    - autoservice-archive
  handlers:
    - feishu-adapter
    - cc-responder
    - operator-console
    - journal
  external_interfaces:
    - customer_inquiry
    - supervisor_dashboard

# 对其他 Socialware 的依赖 (如使用其他)
dependencies:
  - name: esr-mcp-bridge
    version: ">=0.1"
    required_for: "CC agent 通过 MCP 访问 esrd"

# 此 Socialware 期望的配置参数
configuration:
  - name: feishu_app_id
    type: string
    required: true
    description: "飞书应用 ID"
    secret: false
  - name: feishu_app_secret
    type: string
    required: true
    description: "飞书应用密钥"
    secret: true
  - name: claude_api_key
    type: string
    required: true
    description: "CC agent 使用的 Anthropic API key"
    secret: true
  - name: default_language
    type: string
    required: false
    default: "zh-CN"
    description: "客户响应的默认语言"

# 签名 (已验证包)
signatures:
  - algorithm: "sig/v0.3/ed25519"
    public_key: "..."
    signature: "..."
```

### 2.1 必需字段

- `schema_version` — **必须**匹配本包目标的 ESR 版本
- `name` — 命名空间内的唯一标识符
- `version` — 语义化版本 (major.minor.patch)
- `description` — 供 registry 使用的一句描述
- `authors` — 至少一位作者
- `requires` — runtime 兼容性声明

### 2.2 可选字段

- `license`, `homepage`, `repository` — 元数据
- `components` — 人类可读列出 (实际内容在目录中)
- `dependencies` — 对其他 Socialware 的引用
- `configuration` — 必需和可选配置参数
- `signatures` — 用于生产中使用的签名包

---

## 3. 外部接口

**外部接口**部分是 Socialware 最独特的方面。它声明包暴露给外部调用者的内容。

外部接口可以是:

- 自然语言接口 (调用者使用纯文本交互)
- 结构化接口 (传统 API 风格)
- 两者的混合

### 3.1 自然语言接口

```yaml
# interfaces/customer_inquiry.interface.yaml
schema_version: "esr/v0.3"

name: customer_inquiry
type: natural_language

description: |
  通过自然语言对话处理客户咨询。
  
  当你想向此 Socialware 发送客户消息并接收响应时使用此接口。
  Socialware 在内部处理语言检测、意图分类和适当路由。
  
  示例查询:
  - "我想退掉订单 #12345"
  - "我的货发到哪儿了?"
  - "我要找人工客服"
  
  响应使用和查询相同的语言。响应可能还包括结构化元数据
  (如推断的意图) 在 `metadata` 字段。

channel: autoservice.customer_channel

input:
  format: "natural_language_message"
  content_type: "text/plain"
  additional_metadata:
    - name: customer_id
      type: string
      description: "外部客户标识符, 用于跟踪"
      required: false
    - name: channel_type
      type: string
      description: "如 'feishu', 'web', 'sms'"
      required: false

output:
  format: "natural_language_response"
  content_type: "text/plain"
  may_include:
    - name: intent
      type: string
      description: "推断的客户意图分类"
    - name: escalated
      type: boolean
      description: "咨询是否升级给人工"

capabilities:
  - "退货处理"
  - "发货跟踪"
  - "投诉解决"
  - "升级到人工客服"

limitations:
  - "无法修改账单信息"
  - "发货后无法取消订单"

access_control:
  public: false
  requires_authentication: true
  authentication_type: "token"
```

注意关键特性: `description`, `capabilities`, `limitations` 字段是**散文**。它们为其他 AI agent (或人类) 阅读和理解而写。没有 OpenAPI 规范, 没有严格 schema。接口由它说它能做什么定义, 调用它的 agent 被信任去恰当地解释。

### 3.2 结构化接口

对结构很重要的情况 (如批量操作、严格契约、非 AI 调用者):

```yaml
# interfaces/inquiry_batch.interface.yaml
schema_version: "esr/v0.3"

name: inquiry_batch
type: structured

description: "单次调用提交多个咨询"

channel: autoservice.batch_channel

input:
  format: "json_schema"
  schema:
    type: object
    properties:
      inquiries:
        type: array
        items:
          type: object
          properties:
            customer_id: { type: string }
            message: { type: string }
          required: [customer_id, message]
    required: [inquiries]

output:
  format: "json_schema"
  schema:
    type: object
    properties:
      responses:
        type: array
        items:
          type: object
          properties:
            customer_id: { type: string }
            response: { type: string }
            status: { type: string, enum: ["handled", "escalated", "failed"] }
    required: [responses]
```

### 3.3 混合接口

单个接口可以同时提供自然语言和结构化变体:

```yaml
# interfaces/supervisor_dashboard.interface.yaml
name: supervisor_dashboard
type: hybrid

# 自然语言入口
natural_language:
  description: |
    查询主管仪表板。接受自由形式的问题, 如:
    - "显示所有待审阅案例"
    - "今天的平均响应时间是多少?"
  channel: autoservice.supervisor_nl

# 程序化访问的结构化入口
structured:
  operations:
    - name: list_pending
      input_schema: { ... }
      output_schema: { ... }
    - name: get_stats
      input_schema: { ... }
      output_schema: { ... }
  channel: autoservice.supervisor_api
```

调用者根据能力选择使用哪个。

---

## 4. 接口发现

当 Socialware 安装后, `esrd` 让它的外部接口可发现:

```bash
# 列出所有外部可访问接口
$ esr interfaces list

autoservice/customer_inquiry (natural_language)
  "通过自然语言对话处理客户咨询..."

autoservice/supervisor_dashboard (hybrid)
  "查询主管仪表板..."
  
# 显示一个接口的完整详情
$ esr interfaces describe autoservice/customer_inquiry
  (打印完整散文描述)
```

当外部暴露时 (`esr expose`), 这些接口可被其他 ESR 实例或任何能说 ESR 外部协议的客户端访问。

---

## 5. Handler 代码要求

Handler 代码 (Python, 在 `handlers/` 中) **必须**满足:

### 5.1 契约合规

每个 handler 的代码**必须**尊重对应的 contract。通过以下自动验证:

- 对 `handler.publish()`, `handler.subscribe()`, `handler.target()` 调用的静态分析
- 测试场景执行期间的动态追踪
- esrd 的运行时强制执行 (超出契约的行为被拒绝)

handler 包**必须**包含一个 `CONTRACT_COMPLIANCE.md` 文件, 记录它如何满足契约。

### 5.2 依赖声明

每个 handler **必须**包含一个 `requirements.txt` (或 `pyproject.toml`) 列出 Python 依赖。

Socialware 安装器解析依赖, 为每个 handler 创建隔离环境, 管理安装。

### 5.3 配置访问

Handler 通过 `esr_handler` SDK 读取配置, SDK 从以下注入值:

1. 安装时用户提供的配置
2. 环境特定覆盖
3. `socialware.yaml` 的默认值

Handler **不得**通过 SDK 以外的来源 (直接文件、环境变量) 临时读取配置。

---

## 6. 场景

`scenarios/` 中的测试场景驱动 Socialware 的自动验证:

```yaml
# scenarios/basic-flow.scenario.yaml
schema_version: "esr/v0.3"

name: basic-customer-inquiry
description: "客户发送简单消息并收到回复"

setup:
  - actor: customer-simulator
    stub: true
  - actor: feishu-adapter
    config: {app_id: "test-app", use_real_api: false}
  - actor: cc-responder
    config: {model: "test-stub"}

steps:
  - action: "customer-simulator 发布消息到 feishu.incoming"
    expected_message:
      content: "我想退掉订单"
      
expected_behavior:
  must_happen:
    - feishu-adapter 发布到 autoservice.customer_messages
    - cc-responder 发布到 autoservice.cc_replies
    - feishu-adapter 发布到 feishu.outgoing
  must_not_happen:
    - 任何对 autoservice.operator_channel 的发布
    
acceptance:
  - customer-simulator 收到响应
  - 响应是非空自然语言
```

场景在 Socialware 的 CI 中执行 (打包期间), 以及由安装器执行 (部署期间作为冒烟测试)。

---

## 7. 版本化

Socialware 使用**语义化版本** (semver)。

### 7.1 版本号语义

- **Major** (如 1.x → 2.x): 对 contract、topology 或外部接口的破坏性变更
- **Minor** (如 1.1 → 1.2): 追加性变更 (新可选功能、新接口)
- **Patch** (如 1.2.3 → 1.2.4): bug 修复、内部改进

### 7.2 Contract 变更对版本的影响

- 添加新 contract → Minor
- 移除 contract → Major
- 添加到 contract 允许列表 → Minor
- 从 contract 允许列表移除 → Major
- 添加到 contract 禁止列表 → Major
- 修改行为但不改变 contract → Patch

### 7.3 升级路径

Socialware 升级时, 安装器:

1. 检查与当前 esrd 版本的兼容性
2. 列出所有破坏性变更 (如果 major 版本升级)
3. 验证当前 handler 代码可安全停止
4. 应用新包
5. 用新代码重启 handler
6. 运行冒烟测试验证升级

用户可以在冒烟测试失败时回滚到先前版本。

---

## 8. 分发

Socialware 包通过以下方式分发:

### 8.1 文件系统

Socialware 简单地就是一个目录。可以作为以下分发:

- git 仓库 (clone 并安装)
- tarball (下载并解压)
- zip 文件 (同上)

### 8.2 Registry

中心化 registry (类似 npm、pypi) 托管公开 Socialware。Registry 提供:

- 搜索和发现
- 版本管理
- 通过 `esr install <名称>` 下载和安装
- 签名验证
- 依赖解析

### 8.3 私有分发

组织可以为内部 Socialware 托管私有 registry:

```bash
esr install my-internal-service --from registry.example.com
```

---

## 9. 安全考虑

### 9.1 Handler 隔离

每个 handler 在隔离进程中运行, 带有限的文件系统和网络访问。配置控制 handler 能调用哪些外部 API。

### 9.2 签名验证

生产 Socialware **应**由作者的 Ed25519 密钥签名。安装器根据已知密钥验证签名。

### 9.3 契约强制

即使 Socialware 已安装, 它的 agent 仍在声明契约内运作。试图超出声明行为的恶意 Socialware 会被运行时强制捕获。

### 9.4 配置密钥

标记 `secret: true` 的配置参数被特殊处理:

- 静态加密存储
- 从不被记录或显示
- 只注入到需要它的特定 handler
- 可轮换而无需重装 Socialware

---

## 10. 示例: 一个最小 Socialware

为了让规范具体化, 这是一个最小 "hello world" Socialware:

```
hello-socialware/
├── socialware.yaml
├── README.md
├── contracts/
│   └── greeter.contract.yaml
├── topologies/
│   └── greet.topology.yaml
├── handlers/
│   └── greeter/
│       ├── handler.py
│       ├── requirements.txt
│       └── CONTRACT_COMPLIANCE.md
├── interfaces/
│   └── hello.interface.yaml
└── scenarios/
    └── basic.scenario.yaml
```

每个文件内容最小。这是最简单的完整 Socialware, 作为更复杂包的脚手架。

安装并与它对话:

```bash
$ esr install hello-socialware
$ esr talk hello-socialware
> Hello!
(Hello yourself!)
```

这是 ESR 生态最简单样子。

---

## 11. 与其他 ESR 文档的关系

本规范依赖:

- **ESR 协议 v0.3** 对 contract、topology、verification 的定义
- **esrd 参考实现 v0.3** 对 Socialware 实际运行方式的定义
- **ESR 治理指南 v0.3** 对开发和发布 Socialware 工作流的定义

它也影响:

- **ezagent registry** (未来)——Socialware 包如何被存储和搜索
- **`esr` CLI**——用户如何与 Socialware 包交互

---

*Socialware 打包规范 v0.3 结束*
