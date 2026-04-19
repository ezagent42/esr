# Socialware Packaging Specification v0.3

**Version**: 0.3
**Status**: Working Draft
**Nature**: Normative specification of Socialware package format

---

## 0. What Is a Socialware

A **Socialware** is a packaged, version-controlled, installable unit of organizational capability for the ESR ecosystem. It is the portable equivalent of a "business function" or "organizational role"—installable on any ESR-conforming runtime with a single command.

A Socialware is to ESR what a Docker image is to a container runtime, or what an npm package is to Node.js: **a well-defined portable unit**.

This specification defines the canonical format of a Socialware package.

---

## 1. Package Layout

> **v0.1 note:** Socialware packaging lands in v0.2. In v0.1
> patterns, adapters, and handlers ship as independent Python
> packages installable via ``esr cmd install``,
> ``esr adapter install``, ``esr handler install``. Bundling these
> into a Socialware package (with ``socialware.yaml``) is a v0.2
> convergence. See
> ``docs/superpowers/specs/2026-04-18-esr-extraction-design.md``
> for the v0.1 distribution model.

A Socialware is a directory with a specific structure:

```
my-socialware/
├── socialware.yaml          # Package manifest (REQUIRED)
├── README.md                # Human-readable description (REQUIRED)
├── CHANGELOG.md             # Version history (REQUIRED for versioned releases)
│
├── contracts/               # Agent contracts (REQUIRED if package has actors)
│   ├── agent-a.contract.yaml
│   └── agent-b.contract.yaml
│
├── topologies/              # Business flow declarations (REQUIRED if package has flows)
│   ├── main-flow.topology.yaml
│   └── exception-flow.topology.yaml
│
├── handlers/                # Python handler implementations (REQUIRED if package has handlers)
│   ├── agent-a/
│   │   ├── handler.py
│   │   ├── requirements.txt
│   │   └── CONTRACT_COMPLIANCE.md
│   └── agent-b/
│       ├── handler.py
│       └── requirements.txt
│
├── interfaces/              # External interface declarations (OPTIONAL)
│   ├── customer_inquiry.interface.yaml
│   └── supervisor_dashboard.interface.yaml
│
├── scenarios/               # Test scenarios (REQUIRED for published packages)
│   ├── basic-flow.scenario.yaml
│   └── takeover.scenario.yaml
│
├── docs/                    # Additional documentation (OPTIONAL)
│   ├── architecture.md
│   └── configuration.md
│
└── examples/                # Example configurations (OPTIONAL)
    └── default-config.yaml
```

### 1.1 Required Files

Every Socialware MUST have:
- `socialware.yaml` — the package manifest
- `README.md` — human-readable overview

Any non-trivial Socialware (everything beyond a demo) MUST also have:
- `CHANGELOG.md` — version history
- At least one contract in `contracts/`
- At least one topology in `topologies/`
- At least one handler in `handlers/` (if any of the contracts require implementation)
- At least one scenario in `scenarios/`

### 1.2 Optional Files

- `interfaces/` — natural-language or structured external interface declarations
- `docs/` — supplementary documentation
- `examples/` — example configuration files

---

## 2. The Manifest (`socialware.yaml`)

The manifest is the Socialware's identity card. It MUST follow this structure:

```yaml
# socialware.yaml
schema_version: "esr/v0.3"

name: autoservice
version: 1.2.0
description: "AI-powered customer service automation with human supervision"

authors:
  - name: "Allen Woods"
    email: "allen@ezagent.chat"
    role: "author"

license: Apache-2.0
homepage: "https://github.com/ezagent/autoservice"
repository: "https://github.com/ezagent/autoservice.git"

# Runtime requirements
requires:
  esr_protocol_version: ">=0.3"
  esrd_version: ">=0.3"
  python_version: ">=3.11"

# Declared components (auto-detected from directories, but listed here for clarity)
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

# Dependencies on other Socialware (if this Socialware uses another)
dependencies:
  - name: esr-mcp-bridge
    version: ">=0.1"
    required_for: "CC agents to access esrd via MCP"

# Configuration parameters this Socialware expects
configuration:
  - name: feishu_app_id
    type: string
    required: true
    description: "Feishu application ID"
    secret: false
  - name: feishu_app_secret
    type: string
    required: true
    description: "Feishu application secret"
    secret: true
  - name: claude_api_key
    type: string
    required: true
    description: "Anthropic API key for CC agents"
    secret: true
  - name: default_language
    type: string
    required: false
    default: "zh-CN"
    description: "Default language for customer responses"

# Signatures (for verified packages)
signatures:
  - algorithm: "sig/v0.3/ed25519"
    public_key: "..."
    signature: "..."
```

### 2.1 Required Fields

- `schema_version` — MUST match the ESR version this package targets
- `name` — unique identifier within a namespace
- `version` — semantic version (major.minor.patch)
- `description` — one-line description for registries
- `authors` — at least one author
- `requires` — runtime compatibility declaration

### 2.2 Optional Fields

- `license`, `homepage`, `repository` — metadata
- `components` — human-readable listing (actual content is in directories)
- `dependencies` — references to other Socialware
- `configuration` — required and optional config parameters
- `signatures` — for signed packages in production use

---

## 3. External Interfaces

The **external interfaces** section is the most distinctive aspect of Socialware. It declares what the package exposes to callers outside the package.

An external interface can be:

- A natural-language interface (the caller interacts in plain text)
- A structured interface (traditional API-style)
- A hybrid of both

### 3.1 Natural-Language Interface

```yaml
# interfaces/customer_inquiry.interface.yaml
schema_version: "esr/v0.3"

name: customer_inquiry
type: natural_language

description: |
  Handle customer inquiries through natural language conversation.
  
  Use this interface when you want to send a customer message to this
  Socialware and receive a response. The Socialware handles language
  detection, intent classification, and appropriate routing internally.
  
  Example queries:
  - "I want to return my order #12345"
  - "What's the status of my shipment?"
  - "I need to speak to a human agent"
  
  The response will be in the same language as the query. The response
  may also include structured metadata (e.g., inferred intent) in the
  `metadata` field.

channel: autoservice.customer_channel

input:
  format: "natural_language_message"
  content_type: "text/plain"
  additional_metadata:
    - name: customer_id
      type: string
      description: "External customer identifier, for tracking"
      required: false
    - name: channel_type
      type: string
      description: "e.g., 'feishu', 'web', 'sms'"
      required: false

output:
  format: "natural_language_response"
  content_type: "text/plain"
  may_include:
    - name: intent
      type: string
      description: "Inferred customer intent classification"
    - name: escalated
      type: boolean
      description: "Whether the inquiry was escalated to a human"

capabilities:
  - "Return handling"
  - "Shipment tracking"
  - "Complaint resolution"
  - "Escalation to human agents"

limitations:
  - "Cannot modify billing information"
  - "Cannot cancel orders after shipment"

access_control:
  public: false
  requires_authentication: true
  authentication_type: "token"
```

Notice the critical feature: the `description`, `capabilities`, and `limitations` fields are **prose**. They're written for other AI agents (or humans) to read and understand. There's no OpenAPI spec, no strict schema. The interface is defined by what it says it can do, and the agent calling it is trusted to interpret appropriately.

### 3.2 Structured Interface

For cases where structure matters (e.g., bulk operations, strict contracts, non-AI callers):

```yaml
# interfaces/inquiry_batch.interface.yaml
schema_version: "esr/v0.3"

name: inquiry_batch
type: structured

description: "Submit multiple inquiries in a single call"

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

### 3.3 Hybrid Interface

A single interface can offer both natural-language and structured variants:

```yaml
# interfaces/supervisor_dashboard.interface.yaml
name: supervisor_dashboard
type: hybrid

# Natural language entry
natural_language:
  description: |
    Query the supervisor dashboard. Accepts free-form questions like:
    - "show me all cases pending review"
    - "what's the average response time today?"
  channel: autoservice.supervisor_nl

# Structured entry for programmatic access
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

Callers can choose which to use based on their capability.

---

## 4. Interface Discovery

When a Socialware is installed, `esrd` makes its external interfaces discoverable:

```bash
# List all externally-accessible interfaces
$ esr interfaces list

autoservice/customer_inquiry (natural_language)
  "Handle customer inquiries through natural language conversation..."

autoservice/supervisor_dashboard (hybrid)
  "Query the supervisor dashboard..."
  
# Show full details of one interface
$ esr interfaces describe autoservice/customer_inquiry
  (prints the full prose description)
```

When exposed externally (`esr expose`), these interfaces are accessible by other ESR instances or by any client that can speak ESR's external protocol.

---

## 5. Handler Code Requirements

Handler code (Python, in `handlers/`) MUST satisfy:

### 5.1 Contract Compliance

Each handler's code MUST respect the corresponding contract. This is verified automatically by:

- Static analysis of `handler.publish()`, `handler.subscribe()`, `handler.target()` calls
- Dynamic tracing during test scenario execution
- Runtime enforcement by esrd (out-of-contract behavior is rejected)

A handler package MUST include a `CONTRACT_COMPLIANCE.md` file documenting how it satisfies the contract.

### 5.2 Dependency Declaration

Each handler MUST include a `requirements.txt` (or `pyproject.toml`) listing its Python dependencies.

The Socialware installer resolves dependencies, creates an isolated environment per handler, and manages installation.

### 5.3 Configuration Access

Handlers read configuration through the `esr_handler` SDK, which injects values from:

1. User-provided config at install time
2. Environment-specific overrides
3. Defaults from `socialware.yaml`

Handlers MUST NOT read configuration from ad-hoc sources (files, environment variables directly) without going through the SDK.

---

## 6. Scenarios

Test scenarios in `scenarios/` drive the Socialware's automated verification:

```yaml
# scenarios/basic-flow.scenario.yaml
schema_version: "esr/v0.3"

name: basic-customer-inquiry
description: "Customer sends a simple message and receives a reply"

setup:
  - actor: customer-simulator
    stub: true
  - actor: feishu-adapter
    config: {app_id: "test-app", use_real_api: false}
  - actor: cc-responder
    config: {model: "test-stub"}

steps:
  - action: "customer-simulator publishes message to feishu.incoming"
    expected_message:
      content: "I want to return my order"
      
expected_behavior:
  must_happen:
    - feishu-adapter publishes to autoservice.customer_messages
    - cc-responder publishes to autoservice.cc_replies
    - feishu-adapter publishes to feishu.outgoing
  must_not_happen:
    - any publication to autoservice.operator_channel
    
acceptance:
  - customer-simulator receives response
  - response is non-empty natural language
```

Scenarios are executed by the Socialware's CI during packaging, and by the installer during deployment (as smoke tests).

---

## 7. Versioning

Socialware uses **semantic versioning** (semver).

### 7.1 Version Number Semantics

- **Major** (e.g., 1.x → 2.x): breaking changes to contracts, topologies, or external interfaces
- **Minor** (e.g., 1.1 → 1.2): additive changes (new optional features, new interfaces)
- **Patch** (e.g., 1.2.3 → 1.2.4): bug fixes, internal improvements

### 7.2 Contract Change Impact on Version

- Adding a new contract → Minor
- Removing a contract → Major
- Adding to a contract's allowed list → Minor
- Removing from a contract's allowed list → Major
- Adding to a contract's forbidden list → Major
- Modifying behavior without changing contract → Patch

### 7.3 Upgrade Path

When a Socialware upgrades, the installer:

1. Checks compatibility with the current esrd version
2. Lists all breaking changes (if major version bump)
3. Verifies current handler code can be stopped safely
4. Applies the new package
5. Restarts handlers with the new code
6. Runs smoke tests to verify the upgrade

Users can roll back to a previous version if smoke tests fail.

---

## 8. Distribution

Socialware packages are distributed through:

### 8.1 Filesystem

A Socialware is simply a directory. It can be distributed as:

- A git repository (clone and install)
- A tarball (download and extract)
- A zip file (same)

### 8.2 Registry

A centralized registry (analogous to npm, pypi) hosts public Socialware. The registry provides:

- Search and discovery
- Version management
- Download and installation via `esr install <name>`
- Verification of signatures
- Dependency resolution

### 8.3 Private Distribution

Organizations can host private registries for internal Socialware:

```bash
esr install my-internal-service --from registry.example.com
```

---

## 9. Security Considerations

### 9.1 Handler Isolation

Each handler runs in an isolated process with limited filesystem and network access. Configuration controls what external APIs a handler can call.

### 9.2 Signature Verification

Production Socialware SHOULD be signed by the author's Ed25519 key. The installer verifies signatures against known keys.

### 9.3 Contract Enforcement

Even if a Socialware is installed, its agents still operate within their declared contracts. A malicious Socialware that tries to exceed its declared behavior is caught by runtime enforcement.

### 9.4 Configuration Secrets

Configuration parameters marked `secret: true` are handled specially:

- Stored encrypted at rest
- Never logged or displayed
- Injected only into the specific handler that needs them
- Rotatable without reinstalling the Socialware

---

## 10. Example: A Minimal Socialware

To make the specification concrete, here is a minimal "hello world" Socialware:

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

With minimal content in each file. This is the simplest complete Socialware and serves as the scaffold for more complex packages.

Install it and talk to it:

```bash
$ esr install hello-socialware
$ esr talk hello-socialware
> Hello!
(Hello yourself!)
```

This is what the ESR ecosystem looks like at its simplest.

---

## 11. Relationship to Other ESR Documents

This specification relies on:

- **ESR Protocol v0.3** for the definitions of contract, topology, verification
- **esrd Reference Implementation v0.3** for how Socialware runs in practice
- **ESR Governance Guide v0.3** for the workflow of developing and publishing Socialware

And it informs:

- **The ezagent registry** (future) — how Socialware packages are stored and searched
- **The `esr` CLI** — how users interact with Socialware packages

---

*End of Socialware Packaging Specification v0.3*
