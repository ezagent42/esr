# ESR Protocol v0.3

**Name**: ezagent Session Router — Architectural Governance Protocol
**Version**: 0.3 (Final)
**Status**: Working Draft
**Scope**: Organization-internal AI-agent network governance

---

## 0. Abstract

ESR Protocol v0.3 is an architectural governance protocol for AI-agent networks operating within a single organization. It specifies how to declare, compose, verify, and govern the contractual boundaries of agents, especially in environments where substantial code is AI-generated.

ESR's scope is **organization-internal**. An "organization" in ESR maps to a single runtime instance (such as an esrd cluster). Cross-organization integration is explicitly outside this protocol's scope and is handled per-case via Socialware external interfaces (see Socialware Packaging Specification).

---

## 1. Scope

### 1.1 In Scope

- Agent contract declaration (behavioral boundaries)
- Topology composition (how agents combine into business flows)
- Verification (static, dynamic, runtime compliance)
- Governance (contract and topology evolution under human authority)
- Minimum message envelope for cross-layer reference

### 1.2 Out of Scope

- Agent runtime semantics (chosen by implementations; actor model, pipeline, and graph execution are all viable)
- Wire protocol for message transport (implementation-specific)
- Cross-organization federation (explicitly not a goal; see §11)
- Specific messaging guarantees (at-least-once, exactly-once, etc., are runtime choices)
- Failure handling semantics (supervision strategies are runtime choices)
- Persistence and state storage
- User interface, tooling, and CLI (implementation artifacts)

A conforming implementation MAY use any underlying agent mechanism. ESR only requires that the contract layer be correctly implemented on top.

---

## 2. Foundational Assumptions

The following are assumed as given, based on established multi-agent computing literature:

- **Agent**: an identifiable entity with identity, state, and behavior
- **Message**: a discrete unit of inter-agent communication
- **Failure**: agents may fail; failure handling is a runtime concern
- **Trust boundary**: the set of agents sharing a runtime instance is a trust boundary; agents within it trust each other to abide by declared contracts

ESR does not redefine these concepts. It adds a governance layer on top.

---

## 3. Design Principles

These principles are normative. Any violation makes an implementation non-conforming.

**P1. Implementation-independence.** The protocol does not prescribe how agents execute or communicate. Implementations have full freedom in runtime selection.

**P2. Contract-centricity.** All normative content addresses contracts: their declaration, composition, verification, or governance. Everything else is outside this protocol.

**P3. Machine-checkability.** Every ESR concept must be mechanically verifiable. A contract that cannot be checked is not a valid contract.

**P4. Human-authorable.** Contracts and topologies must be writable and reviewable by humans in reasonable time. If the authoring burden exceeds the governance benefit, the design has failed.

**P5. AI-friendly.** Contracts and topologies must be readable and authorable by AI assistants. They serve as authoritative context for AI code generation and self-verification.

**P6. Progressive disclosure.** Simple systems should have simple artifacts. Complex artifacts are only needed for complex systems.

**P7. Separation of concerns.** Contract (what is allowed), topology (how composed), verification (did it happen correctly), governance (how to change) are four distinct concerns. Implementations may support any subset.

**P8. Organization boundary respect.** The protocol operates within a single organization's trust boundary. Cross-organization integration is handled by application-layer mechanisms (Socialware external interfaces), not by protocol extensions.

---

## 4. Agent Contracts

### 4.1 Purpose

A contract declares the behavioral boundary of an agent: what it receives, what it sends, what it must not do. The contract is the agent's public architectural intent — a commitment to remain within declared bounds.

### 4.2 Contract Schema

A conforming contract MUST declare:

**Identity**
- `id_pattern`: regex or glob matching qualifying agent IDs
- `role`: one-line description of the agent's architectural role

**Incoming** (required if the agent receives messages):
- List of subscriptions, each with:
  - `topic_pattern`: topic or pattern subscribed to
  - `message_shape`: minimum schema of expected content
  - `purpose`: why this subscription exists

**Outgoing** (required if the agent sends messages):
- List of publications, each with:
  - `topic`: topic published to
  - `trigger`: when this publication occurs
  - `message_shape`: minimum schema of outgoing content

**Targeting** (optional, for direct agent-to-agent addressing):
- List of allowed target patterns, each with:
  - `target_pattern`: ID pattern of allowed recipients
  - `purpose`: why direct messaging is permitted

**Forbidden** (required, even if empty):
- Explicit list of prohibited behaviors, each with:
  - `type`: "publish" | "target" | "side-effect"
  - `specification`: what is prohibited
  - `rationale`: explanation

**State** (optional):
- Persistence (none, in-memory, persistent)
- Queryability by other agents

**Failure disposition** (optional):
- Expected failure modes
- Recovery expectations

### 4.3 Contract Uniqueness

At most one contract MAY be active for any given `id_pattern` within a runtime instance. Conflicts are a specification violation.

### 4.4 Contract Change Categories

- **Additive**: only adds allowed behaviors
- **Restrictive**: removes allowed behaviors or adds forbidden items
- **Neutral**: only changes documentation, rationale, or metadata

Restrictive changes MUST re-verify all dependent topologies.

### 4.5 Contract Format

Implementations MUST document their chosen format. Human-readable text formats are strongly preferred (YAML, TOML, structured Markdown). Binary or opaque formats are non-conforming.

---

## 5. Topology Declarations

### 5.1 Purpose

A topology declares how a specific group of agents composes to achieve a business outcome. It is the architect's explicit statement: "under these conditions, the system flow should look like this".

### 5.2 Topology Schema

A conforming topology MUST declare:

**Identity**
- `name`: unique topology identifier
- `description`: business purpose in one paragraph

**Trigger**
- Conditions under which this topology becomes active
- May reference events, control messages, or be always-on

**Participants**
- List of agents involved, each with:
  - `agent_ref`: reference matching a contract's id_pattern
  - `role_in_this_topology`: this agent's role in this specific flow

Every participant MUST have a registered contract.

**Flows**
- Ordered or conditional message exchanges
- Each entry:
  - `from`: source participant
  - `to`: destination (participant or topic pattern)
  - `via_topic` or `via_target`: routing information
  - `trigger_condition`: when this exchange occurs
  - `expected_behavior`: what outcome this exchange produces

**Branches** (optional)
- Alternative flows for special conditions

**Acceptance Criteria**
- Observable conditions indicating success
- Typically: "at the end, these messages have been sent and these states observed"

**Contract Dependencies** (derived, auto-generated)
- Set of contract clauses this topology depends upon
- Implementations SHOULD auto-compute this

### 5.3 Topology Validity

A topology is **valid** if:

1. Every participant has a registered contract
2. Every flow entry is within the relevant participant's contract
3. Every message shape referenced matches contract declarations
4. No flow violates any participant's forbidden list
5. Acceptance criteria reference only contracted behaviors

Invalid topologies MUST NOT be activated.

### 5.4 Topology Lifecycle

- **Defined**: authored, not yet validated
- **Valid**: passes validation
- **Active**: deployed and influencing runtime
- **Retired**: no longer active, kept for reference

Implementations MUST prevent invalid topologies from becoming active.

---

## 6. Verification

### 6.1 Static Verification

Before deployment, implementations SHOULD verify:

- Each contract is syntactically valid
- Each topology is syntactically valid
- Every topology-contract reference is consistent
- No contract conflicts exist
- All references resolve

Output: pass/fail with detailed violation report.

### 6.2 Dynamic Verification

During test or staging:

- Record observable messages and state transitions
- Compare trace against participant contracts (was any forbidden behavior observed?)
- Compare trace against active topology (did expected flows occur? did unexpected flows occur?)

Implementations MUST provide a mechanism for emitting traces. The mechanism is implementation-specific.

### 6.3 Runtime Compliance Monitoring (optional)

In production:

- Continuously monitor messages violating contracts
- Detect flows not declared in any active topology
- Emit observability signals, not hard failures

Production SHOULD NOT be brittle; monitoring is observational.

### 6.4 Violation Reports

All verification modes MUST produce reports with:

- **Location**: which artifact or behavior was violated
- **Description**: the specific rule broken
- **Evidence**: actual behavior that caused violation
- **Suggestion**: possible fix, where determinable

Reports MUST be machine-parseable to support AI-driven auto-correction.

---

## 7. Governance

### 7.1 Change Proposals

A proposed change MUST be expressed as a structured artifact containing:

- **Type**: additive / restrictive / neutral / new / deletion
- **Target**: which contract or topology is affected
- **Proposed change**: the exact modification
- **Rationale**: why the change is needed
- **Impact assessment**: auto-computed list of:
  - Dependent topologies affected
  - Existing code requiring adjustment
  - Historical messages that would become invalid

### 7.2 Authorization

Changes MUST be authorized by a designated authority before taking effect. The specification does not mandate who the authority is; this is organizational.

- Restrictive changes MUST require explicit authorization
- Additive changes MAY be auto-approved under documented rules
- Neutral changes MAY be auto-approved

### 7.3 Versioning

Contracts and topologies MUST have version identifiers. Implementations MUST support:

- Multiple versions coexisting during migration
- Querying active version
- Rolling back

---

## 8. Minimum Message Envelope

To support contract verification, every message in an ESR-conforming system MUST have at least:

- `source`: sending agent's identifier
- `destination_indicator`: either `topic` (broadcast) or `target` (targeted), or both
- `payload`: content, opaque to ESR
- `metadata`: key-value map, keys prefixed `esr.` are reserved

Implementations MAY add additional fields (id, timestamp, ttl, reply_to, etc.). Contracts MAY reference runtime-specific fields, with the understanding that such contracts become implementation-bound.

### 8.1 Agent Identity

Agent IDs are strings unique within a runtime instance. Implementations define their own naming scheme but MUST document it.

Contracts reference agents by ID patterns. The pattern language (regex, glob, etc.) is implementation-defined and MUST be documented.

---

## 9. Capability Declaration

A runtime MUST declare which ESR capabilities it supports:

- `contract_declaration`: authoring and storing contracts
- `topology_composition`: authoring and storing topologies
- `static_verification`: pre-deployment checks
- `dynamic_verification`: execution trace comparison
- `runtime_monitoring`: production compliance observation
- `governance_workflow`: structured change proposals

Supporting all six is **full-ESR-conforming**. Supporting a subset is **partial-ESR-conforming**, with the subset documented.

---

## 10. Conformance

### 10.1 MUST

1. Provide at least contract_declaration and static_verification
2. Document contract format, topology format, identity scheme, pattern syntax
3. Produce machine-readable violation reports
4. Prevent invalid topologies from activation (if static_verification supported)

### 10.2 SHOULD

1. Provide dynamic_verification
2. Provide governance_workflow
3. Clearly separate implementation-specific features from protocol behavior in documentation

### 10.3 MAY

1. Add runtime-specific features (patterns, standard libraries)
2. Bundle development tools (CLI, UI, testing)
3. Optimize for specific deployment scenarios

---

## 11. Explicit Non-Goals

Being clear about non-goals is as important as being clear about goals.

### 11.1 Cross-Organization Federation

ESR explicitly does **not** define a protocol for organizations to interconnect. Integration between organizations is handled through one of three application-layer mechanisms, all outside the protocol:

- **Mode A**: Install the same Socialware in multiple organizations (each runs independently)
- **Mode B**: Expose a Socialware's natural-language or structured interface to external callers
- **Mode C**: Include an adapter within a Socialware that speaks an external protocol (e.g., Feishu API)

No "ESR federation protocol" exists or is planned. See ESR Reposition Final for the rationale.

### 11.2 Runtime Reinvention

ESR does not specify actor scheduling, message delivery guarantees, supervision, transport protocols, or any other concerns solved by established agent runtimes. These are assumed.

### 11.3 Application Concerns

Business logic, LLM prompt design, content moderation, user experience — all are application concerns. ESR's contracts may declare boundaries on such behaviors, but the protocol does not specify how they should be implemented.

---

## 12. Relationship to Prior Versions

### 12.1 v0.1 to v0.2 transition

v0.2 reduced protocol primitives from six to two (Peer and Message), removing Lobby, MembershipMode, PublishAuthority, and View as protocol-level concepts.

### 12.2 v0.2 to v0.3 transition

v0.3 fundamentally repositions the protocol:

- **v0.2** attempted to specify agent communication semantics (peer identity, message delivery, etc.).
- **v0.3** removes all such specification, treating it as implementation concerns.
- **v0.3** adds explicit specification of contract declaration, topology composition, verification, and governance — the governance layer above any actor runtime.

This is a conceptual refactor, not a feature addition. Existing v0.2 implementations can adapt by keeping their runtime but adopting the v0.3 contract layer.

### 12.3 v0.3 Final Clarifications

During v0.3 development, additional clarifications emerged:

- ESR scope is explicitly organization-internal
- Cross-organization integration is handled by Socialware external interfaces, not protocol extensions
- Natural-language interfaces are a first-class feature of Socialware (not the protocol, but an ecosystem convention)
- Organization boundary = runtime instance boundary (e.g., one esrd cluster)

These clarifications are reflected throughout this Final version.

---

## 13. Relation to Socialware

This specification does not define Socialware. Socialware is an ecosystem convention built on top of ESR, specified separately in **Socialware Packaging Specification v0.3**.

A Socialware is a packaged unit containing contracts, topologies, handler code, and external interface declarations. Understanding Socialware is essential for using ESR practically, but it is not part of the protocol.

---

*End of ESR Protocol v0.3 Final*
