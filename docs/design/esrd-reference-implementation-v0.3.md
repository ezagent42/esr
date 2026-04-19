# esrd — ESR Protocol v0.3 Reference Implementation

**Version**: 0.3 (Final)
**Implements**: ESR Protocol v0.3
**Language**: Elixir/OTP (core) + Python (handlers)
**Scope**: Organization-internal agent runtime and Socialware host

---

## 0. Positioning

esrd is the first reference implementation of ESR Protocol v0.3. It plays two roles:

**Role 1**: As an **ESR runtime**, esrd implements the protocol's contract layer — contract declaration, topology composition, verification, governance.

**Role 2**: As a **Socialware host**, esrd provides the runtime environment where installed Socialware packages execute.

These two roles are complementary. ESR is the governance framework; Socialware is the unit of capability; esrd is what makes both operational.

### 0.1 One Organization, One esrd

A key architectural commitment: **one esrd instance represents one organization**. The instance may span multiple physical machines (using BEAM distributed), but logically it is one organization's trust boundary.

esrd explicitly does not federate across organizations. Cross-organization integration happens at the Socialware level via external interfaces (described in Socialware Packaging Specification), not at the esrd level.

### 0.2 What esrd Provides vs What It Relies On

| Concern | Handled by |
|---------|-----------|
| Agent scheduling, lifecycle | OTP (GenServer, Supervisor) |
| Message passing internal | Phoenix.PubSub |
| Multi-node clustering | BEAM distributed + libcluster |
| Failure recovery | OTP supervision strategies |
| External client connection | Phoenix Channels over WebSocket |
| **Contract declaration** | **esrd_contract (ESR-specific)** |
| **Topology composition** | **esrd_topology (ESR-specific)** |
| **Verification** | **esrd_verifier (ESR-specific)** |
| **Governance workflow** | **esrd_governance (ESR-specific)** |
| **Socialware hosting** | **esrd_socialware (ESR-specific)** |
| Business logic | Python handlers within Socialware |
| External API integration | Python handlers within Socialware |

The division is clean: esrd reuses OTP for everything runtime-related, and implements only what ESR uniquely provides (contract layer + Socialware hosting).

---

## 1. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ esrd (single organization's runtime)                            │
│                                                                  │
│  Multi-node BEAM cluster (organization-internal distribution):  │
│   node-1 ↔ node-2 ↔ node-3 (via libcluster + BEAM distributed)  │
│                                                                  │
│  Each node runs these OTP applications:                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_runtime                                       │          │
│  │  - PeerServer (GenServer per agent)               │          │
│  │  - PeerRegistry (Registry + Horde for cluster)    │          │
│  │  - PubSub for actor messaging                     │          │
│  │  - DeliveryManager (targeted at-least-once)       │          │
│  │  - DeadLetterChannel                               │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_contract                                      │          │
│  │  - YAML parser                                     │          │
│  │  - Contract registry (ETS)                        │          │
│  │  - Runtime contract enforcement                   │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_topology                                      │          │
│  │  - YAML parser                                     │          │
│  │  - Topology registry                              │          │
│  │  - Activation/deactivation logic                  │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_verifier                                      │          │
│  │  - Static verification                            │          │
│  │  - Dynamic verification from traces               │          │
│  │  - Violation report generation                    │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_governance                                    │          │
│  │  - Proposal storage and tracking                  │          │
│  │  - Impact analysis                                │          │
│  │  - Version management                             │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_socialware                                    │          │
│  │  - Socialware package installer                   │          │
│  │  - Manifest parser                                │          │
│  │  - Handler process supervisor (Python OS procs)   │          │
│  │  - External interface registry                    │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_web (Phoenix application)                     │          │
│  │  - WebSocket endpoint for Python handlers         │          │
│  │  - Phoenix Channels with contract enforcement     │          │
│  │  - JWT authentication                             │          │
│  │  - External-exposure endpoints (for remote calls) │          │
│  └──────────────────────────────────────────────────┘          │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐          │
│  │ esrd_cli (Elixir escript)                         │          │
│  │  - Low-level protocol operations                  │          │
│  │  - Most users prefer `esr` (Python CLI, above)    │          │
│  └──────────────────────────────────────────────────┘          │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ WebSocket (Phoenix Channels)
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Python handler processes (per Socialware, supervised by esrd)   │
│                                                                  │
│  Each handler uses esr-handler-py SDK:                          │
│  - Connects to esrd_web                                         │
│  - Executes on behalf of one or more agents                     │
│  - Business logic, LLM calls, external API integration          │
└────────────────────────────────────────────────────────────────┘
```

### 1.1 OTP Supervisor Tree

```
Esrd.Application
├── Esrd.Runtime.Supervisor
│   ├── Esrd.PeerRegistry
│   ├── Esrd.PeerSupervisor (DynamicSupervisor)
│   │    └── Esrd.PeerServer (one per agent)
│   ├── Esrd.DeliveryManager
│   └── Esrd.DeadLetterChannel
├── Esrd.Contract.Supervisor
│   └── Esrd.Contract.Registry
├── Esrd.Topology.Supervisor
│   └── Esrd.Topology.Registry
├── Esrd.Verifier.Supervisor
├── Esrd.Governance.Supervisor
│   └── Esrd.Governance.ProposalStore
├── Esrd.Socialware.Supervisor
│   └── Esrd.Socialware.HandlerSupervisor (DynamicSupervisor)
│        └── Esrd.Socialware.HandlerProcess (OS process wrapper)
├── EsrdWeb.Endpoint (Phoenix)
└── Cluster.Supervisor (libcluster)
```

### 1.2 Why This Structure

Each concern is an OTP application. This follows OTP best practices and makes each concern independently testable, upgradable, and reasoned about. The `esrd_runtime` at the bottom provides actor mechanics; the upper applications provide ESR-specific governance; `esrd_socialware` ties them together by hosting Socialware packages that use both.

---

## 2. Contract Implementation

### 2.1 Storage

Contracts are YAML files. On load, they are parsed into Elixir structs and stored in ETS for fast lookup:

```elixir
defmodule Esrd.Contract do
  defstruct [
    :schema_version,
    :identity,
    :incoming,
    :outgoing,
    :targeting,
    :forbidden,
    :state,
    :failure_disposition,
    :version
  ]
end

defmodule Esrd.Contract.Registry do
  @moduledoc "ETS-backed contract store with pattern matching"
  
  def load(contract_yaml_path), do: ...
  def lookup_for(agent_id), do: ...
  def list_all(), do: ...
  def remove(contract_id), do: ...
end
```

### 2.2 Runtime Enforcement

Every `publish` call through esrd_runtime checks against the agent's contract:

```elixir
defmodule Esrd.PeerServer do
  use GenServer
  
  def handle_call({:publish, message}, _from, state) do
    contract = Esrd.Contract.Registry.lookup_for(state.agent_id)
    
    case Esrd.Contract.check_publish(contract, message) do
      :ok ->
        do_publish_internally(message, state)
      {:violation, reason} ->
        :telemetry.execute([:esrd, :contract, :violation], 
                           %{count: 1}, 
                           %{agent: state.agent_id, reason: reason})
        {:reply, {:error, {:contract_violation, reason}}, state}
    end
  end
end
```

Violations are rejected immediately and emit telemetry events for verifier consumption.

### 2.3 Pattern Matching

Contract `id_pattern` uses glob-style matching by default:

- `cc:*` matches `cc:allen-main`, `cc:alice`, `cc:anything`
- `feishu:app1:*` matches `feishu:app1:user_a`, `feishu:app1:user_b`
- `journal` matches only `journal`

More sophisticated matching (regex, wildcards in middle, etc.) is available but SHOULD be used sparingly to keep contracts readable.

---

## 3. Topology Implementation

### 3.1 Storage and Lifecycle

Topologies are YAML files parsed into structs. They have explicit lifecycle states tracked in the registry:

```elixir
defmodule Esrd.Topology do
  defstruct [
    :name, :description, :trigger,
    :participants, :flows, :branches,
    :acceptance_criteria, :contract_dependencies,
    :version, :state  # :defined, :valid, :active, :retired
  ]
end

defmodule Esrd.Topology.Registry do
  def load(path), do: ...            # file → :defined
  def validate(topology_id), do: ... # :defined → :valid or errors
  def activate(topology_id), do: ... # :valid → :active
  def retire(topology_id), do: ...   # any → :retired
  def list_active(), do: ...
end
```

### 3.2 Validation

Validation is a pure function over `(topology, [contracts])`:

```elixir
defmodule Esrd.Topology.Validator do
  def validate(topology, contracts) do
    with :ok <- check_participants_have_contracts(topology, contracts),
         :ok <- check_flows_within_contracts(topology, contracts),
         :ok <- check_message_shapes(topology, contracts),
         :ok <- check_no_forbidden_violations(topology, contracts),
         :ok <- check_acceptance_criteria_valid(topology, contracts) do
      {:ok, topology}
    end
  end
end
```

Validation failures produce structured error reports naming the exact violation and the contract clause involved.

### 3.3 Activation Effects

Activating a topology:

1. Marks it as `:active` in the registry
2. Updates the monitoring layer to watch for this topology's expected flows
3. Emits a telemetry event for auditing

Activation does NOT create or destroy any agents — agents are lifecycle-managed by Socialware or explicit commands. Topology activation only affects what flows are considered "expected" vs "unexpected" during monitoring.

---

## 4. Verification Implementation

### 4.1 Static Verifier

Pure functions over registered contracts and topologies:

```elixir
defmodule Esrd.Verifier.Static do
  def verify_all(), do: ...              # all-contracts + all-topologies
  def verify_contract(id), do: ...       # single contract validity
  def verify_topology(id), do: ...       # single topology validity
  def verify_compatibility(topology_id, contract_ids), do: ...
end
```

Returns `{:ok, []}` or `{:violations, [%Violation{...}]}`. Reports are structured for machine consumption.

### 4.2 Dynamic Verifier

Consumes telemetry traces and compares against active topology + contracts:

```elixir
defmodule Esrd.Verifier.Dynamic do
  def verify_trace(trace, scenario_id) do
    topology = Esrd.Topology.Registry.active_for_scenario(scenario_id)
    contracts = Esrd.Contract.Registry.all_for_participants(topology)
    
    %{
      expected_flows_missing: find_missing(trace, topology),
      unexpected_flows_observed: find_unexpected(trace, topology),
      contract_violations: find_contract_violations(trace, contracts),
      acceptance_met: check_acceptance(trace, topology)
    }
  end
end
```

### 4.3 Trace Collection

Traces come from `:telemetry` events emitted by esrd_runtime:

```elixir
:telemetry.execute(
  [:esrd, :message, :published],
  %{timestamp: System.monotonic_time()},
  %{source: source_id, topic: topic, payload_size: size}
)

:telemetry.execute(
  [:esrd, :message, :delivered],
  %{timestamp: ..., duration: ...},
  %{source: ..., target: ..., topic: ...}
)
```

These events are captured, structured, and passed to the dynamic verifier or stored for post-hoc analysis.

### 4.4 Runtime Monitor (Optional)

In production, `Esrd.Monitor` runs as a GenServer, subscribed to all telemetry events, comparing them against active topologies in real time. Anomalies emit to `esr._system.monitor.violations`, which operators can subscribe to.

The monitor does not block traffic — it's observational.

---

## 5. Governance Implementation

### 5.1 Proposal Storage

Proposals are structured YAML files stored in a designated directory, also tracked in ETS:

```yaml
# /var/lib/esrd/proposals/open/2026-04-20-expand-cc.proposal.yaml
schema_version: "esr/v0.3"
id: "2026-04-20-expand-cc"
type: contract_change
target: "cc-responder"
change_type: additive

requested_by: "Allen"
requested_at: "2026-04-20T10:00:00Z"

proposed_change:
  add_outgoing:
    - topic: "autoservice.cc_debug"
      trigger: "when debug mode enabled"
      message_shape: { content: string }

rationale: |
  Debug workflow requires CC to emit debug info on separate channel.

impact_analysis:
  affected_contracts: ["cc-responder"]
  affected_topologies: []
  required_code_changes: "minimal, new publish call in handler"
  migration_strategy: "additive; no breaking changes"

status: pending
```

### 5.2 Impact Analysis

Auto-generated on proposal creation:

```elixir
defmodule Esrd.Governance.ImpactAnalyzer do
  def analyze(proposal) do
    %{
      affected_contracts: find_affected_contracts(proposal),
      affected_topologies: find_affected_topologies(proposal),
      required_code_changes: assess_code_changes(proposal),
      migration_strategy: derive_strategy(proposal)
    }
  end
end
```

### 5.3 Approval Workflow

CLI commands drive the workflow:

```bash
esr proposal create --target cc-responder --type contract_change
esr proposal review 2026-04-20-expand-cc
esr proposal approve 2026-04-20-expand-cc   # requires explicit authorization
esr proposal reject 2026-04-20-expand-cc --reason "..."
```

On approval, the proposal's changes are applied atomically, all dependent topologies are re-validated, and the proposal is archived.

---

## 6. Socialware Hosting

### 6.1 Installation

When a user runs `esr install my-socialware`:

1. The Socialware package is downloaded (from filesystem, git, or registry)
2. `socialware.yaml` is parsed
3. Compatibility is checked against current esrd version
4. Contracts are loaded via `esrd_contract`
5. Topologies are loaded (not yet activated)
6. Handler dependencies are resolved (Python virtualenvs created per handler)
7. External interfaces are registered with `esrd_socialware`
8. Handlers are started as OS processes, supervised by esrd
9. Topologies are activated
10. Smoke-test scenarios are run
11. On success, installation is committed

Any step failure rolls back previous steps.

### 6.2 Handler Supervision

Each Socialware handler is an OS-level Python process, wrapped in an OTP-compatible interface:

```elixir
defmodule Esrd.Socialware.HandlerProcess do
  use GenServer
  
  # Starts a Python subprocess, monitors it, restarts on crash
  def init(config) do
    port = Port.open({:spawn_executable, "python3"}, [
      {:args, [config.handler_script]},
      {:env, prepare_env(config)},
      :exit_status,
      :stderr_to_stdout
    ])
    {:ok, %{port: port, config: config, restarts: 0}}
  end
  
  def handle_info({port, {:exit_status, status}}, state) when port == state.port do
    # Handler crashed; OTP supervisor decides restart strategy
    {:stop, {:handler_exit, status}, state}
  end
end
```

OTP supervision handles restart strategies (one_for_one, rate limiting, etc.) at Elixir level. Python handlers crash cleanly and are restarted — no need for Python-side supervision logic.

### 6.3 External Interface Registry

When Socialware declares external interfaces in `interfaces/*.yaml`, they are registered:

```elixir
defmodule Esrd.Socialware.InterfaceRegistry do
  def register(interface), do: ...
  def list_public(), do: ...
  def list_exposed(), do: ...
  def describe(interface_id), do: ...
end
```

Interfaces can be:

- **Internal only**: accessible by agents inside the organization
- **Public within org**: accessible by any authenticated user
- **Exposed**: accessible from outside the organization (requires explicit `esr expose`)

### 6.4 Upgrades

Upgrading a Socialware:

1. Parse new manifest, check compatibility
2. For major version bumps, show breaking changes to user
3. Gracefully stop affected handlers
4. Apply new contracts and topologies
5. Re-validate everything
6. Start new handlers
7. Run smoke tests
8. On any failure, roll back

---

## 7. Python Handler SDK (esr-handler-py)

> **v0.1 implementation note:** In esrd v0.1 the Python Handler SDK uses
> a pure-function model — handlers return ``(new_state, actions:
> [Emit | Route | InvokeCommand])`` rather than calling
> ``handler.publish()`` inline. The imperative SDK described below
> remains valid for future versions; the pure-function model is the
> practical starting point that enables CI-enforced purity and
> simpler testing (see ``docs/superpowers/prds/02-python-sdk.md``
> and ``docs/superpowers/prds/05-handlers.md``).

### 7.1 Role Reminder

Python handlers are NOT agents. Agents (identity, state, subscriptions, routing) live in BEAM GenServers. Python handlers are the **business implementation** behind agents — where LLM calls, external API interactions, and domain logic happen.

### 7.2 Core API

```python
from esr_handler import Handler, Message
from pathlib import Path

# Contract-aware initialization
handler = Handler.connect(
    url="wss://esrd.localhost:4000/socket",
    agent_id="cc:allen-main",
    token="<jwt>",
    contract_path=Path("contracts/cc-responder.contract.yaml")
)

# Subscribing (validated client-side against contract)
@handler.on("autoservice.customer_messages")
def on_customer_message(msg: Message):
    reply_text = call_claude_api(msg.content)  # business logic
    
    # Publishing (also validated client-side)
    handler.publish(
        topic="autoservice.cc_replies",
        content=reply_text,
        metadata={"in_reply_to": msg.id}
    )

# Blocking main loop
handler.run()
```

### 7.3 Client-Side Validation

The SDK loads the local contract copy and validates all outgoing publish/subscribe/target calls before sending them over the wire. This means:

- Violations are caught at development time by the SDK
- IDEs can integrate to give live feedback
- Runtime rejection from esrd is a second layer of defense

### 7.4 Static Analyzer

Bundled with the SDK:

```bash
$ esr-handler-lint handlers/cc-responder/handler.py \
    --contract contracts/cc-responder.contract.yaml
```

Scans the Python AST for publish/subscribe/target calls, verifies each against the contract, generates a `CONTRACT_COMPLIANCE.md` report.

This is the primary tool for CC Mode B — it lets AI-written code self-verify before submitting a PR.

---

## 8. BEAM REPL as Native Management Interface

An often-overlooked feature of esrd: because it's built on OTP, a production esrd cluster is fully inspectable and manageable via BEAM REPL.

```bash
$ iex --remsh esrd@host1
iex> Esrd.Contract.Registry.list_all()
[...]
iex> Esrd.Topology.Registry.list_active()
[...]
iex> Esrd.Runtime.PeerRegistry.count()
42
iex> Esrd.Monitor.current_violations()
[]
```

All high-level CLI commands (`esrd-cli`, `esr`) are thin wrappers over these Elixir function calls. For deep diagnostic or exceptional operations, administrators can go directly to the REPL.

This also gives "free" tools:

- `:observer.start()` — visual process tree and supervision
- `:recon` — performance analysis
- `Phoenix.LiveDashboard` — web-based real-time monitoring

---

## 9. Deployment Topologies

### 9.1 Single-Node (Development / Small Org)

```
One machine:
  - Elixir release running esrd
  - Phoenix endpoint on :4000
  - Python handlers connect via localhost
```

Sufficient for single-user development, demos, and small-team use (up to a few hundred agents).

### 9.2 Multi-Node Cluster (Production)

```
Three or more machines:
  - Same Elixir release, connected via libcluster
  - Load balancer fronts WebSocket connections
  - Handlers distributed across nodes based on load
```

Uses BEAM distributed for cross-node communication. No custom federation protocol required — everything is internal.

### 9.3 Storage

- **Contracts and topologies**: filesystem (single node) or shared storage (S3, etc.) for cluster
- **Proposal archive**: same
- **Runtime state**: in-memory (ETS) with periodic checkpoints
- **Message retention** (if JournalPeer used): external DB (PostgreSQL, etc.)

### 9.4 Observability

- Telemetry → Prometheus
- Logs → journald or structured logger
- Violations → dedicated topic, observable via dashboard
- LiveDashboard for real-time health

---

## 10. Development Roadmap (Phase A)

### Sprint 0 (1 week): Elixir Ramp-Up

Allen and CC ramp up on Elixir/OTP/Phoenix.

### Sprint 1 (1 week): Contract Core + Registry

- `esrd_contract` OTP application
- YAML parser
- Static verifier (contract only)
- `esrd-cli contract {load, list, inspect, verify}`

### Sprint 2 (1 week): Runtime + Topology

- `esrd_runtime` with PeerServer, PeerRegistry, basic pub/sub
- `esrd_topology` with YAML parsing and validation
- Runtime contract enforcement

### Sprint 3 (1 week): Phoenix Channels + Python SDK

- `esrd_web` Phoenix application
- PeerChannel implementation
- `esr-handler-py` minimal version
- Client-side validation in SDK

### Sprint 4 (1 week): Verification + Governance

- Dynamic verifier with telemetry trace consumption
- `esrd_governance` with proposal storage
- CLI commands for proposals

### Sprint 5 (1-2 weeks): Socialware Support + Official Handlers

- `esrd_socialware` with manifest parsing and handler supervision
- Official handler: MCP Bridge (CC integration)
- Official handler: Feishu adapter
- End-to-end demo: install a Socialware, run it, verify compliance

### Phase A Completion Criteria

1. esrd release installable on Linux
2. `esr` CLI working (install, use, talk, status)
3. Python developers can write a handler in an afternoon
4. CC via MCP Bridge successfully uses esrd
5. Feishu messages flow through esrd bidirectionally
6. At least one dogfooding success: esrd team uses esrd to coordinate esrd development

---

## 11. What esrd Explicitly Does Not Do

Defending against scope creep:

- **Actor scheduling algorithm**: OTP handles this
- **Supervision strategy design**: OTP has well-known strategies; esrd uses them
- **Message transport optimization**: Phoenix Channels is sufficient
- **LLM integration**: belongs in Socialware handlers
- **Domain vocabulary**: no "customer", "operator", "takeover" etc. anywhere in esrd
- **Cross-organization federation**: explicitly out of scope (see ESR Reposition v0.3 Final §11.1)
- **User management**: delegated to external IAM systems
- **Payment/billing**: ezagent's concern, not esrd's

If a feature request lands that falls in these categories, the answer is "no, that's not esrd's job".

---

*End of esrd Reference Implementation v0.3 Final*
