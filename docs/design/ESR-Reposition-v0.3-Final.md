# ESR v0.3 — Final Reposition

**Version**: 0.3 (Final)
**Date**: April 2026
**Nature**: The defining statement of what ESR is and is not

---

## One-Sentence Definition

**ESR is the architectural governance protocol for AI-agent networks running inside a single organization, and Socialware is the portable business package that gives such organizations their capabilities.**

Read that sentence slowly. Every word matters. It took many rounds of discussion to reach this precision.

---

## The Picture in Full

### The unit: organization = esrd instance

An **organization** in the ESR sense is a trust boundary where AI agents collaborate freely. It maps one-to-one onto an **esrd instance** (which may be a single-machine or a BEAM-distributed cluster — the cluster is internal detail, externally it's one organization).

Examples of organizations:

- A personal lab running its own esrd (one person, small scale)
- A company department running a shared esrd (multiple teams, medium scale)
- An entire company running a multi-node esrd cluster (thousands of agents, large scale)

Within an organization, agents talk to each other freely using ESR's internal protocols. The organization has a trust boundary — inside is trusted, outside is not.

### The currency: Socialware

Within an organization, capabilities are delivered by **Socialware** — a packaged, version-controlled, installable unit that contains everything needed for a specific business function:

- **Contracts** declaring what each agent in the package can do
- **Topologies** declaring how agents compose into business flows
- **Handler code** implementing agent business logic
- **External interfaces** describing (in natural language) what the Socialware offers to the outside world

A Socialware is to an organization what a Docker image is to a container host, or what an npm package is to a Node.js project: **a portable, reusable unit of capability**.

Socialware can be:

- Written by anyone
- Published to registries (public or private)
- Installed via `esr install` command
- Versioned and upgraded
- Forked and modified

**Socialware is what makes ezagent's "Organization as a Service" vision concrete**. Installing a Socialware literally means giving your organization a new AI-powered capability, ready to run.

### The contract layer: ESR's real contribution

The single concept that makes ESR worth having, in an era when actor models and message passing are solved problems, is the **contract layer**.

In systems with substantial AI-generated code, the bottleneck shifts from writing code to ensuring the code respects architectural intent. Human review can't scale with AI code generation. ESR solves this by making architectural intent **machine-checkable**:

- **Contract** declares what an agent can and cannot do
- **Topology** declares how agents compose into business flows
- **Verification** checks that code and behavior stay within contracts, automatically
- **Governance** defines how contracts evolve under human authority

This is ESR's novel contribution. Everything below (actor runtime, message passing) is assumed; everything above (business logic, user experience) is application. ESR is the thin layer in between that makes large multi-agent systems governable.

### Organization-internal vs cross-organization

**Inside** an organization, things are tightly integrated:

- Actors run on a shared BEAM cluster
- Messages pass via Phoenix.PubSub with no network overhead (or with BEAM-distributed overhead, which is minimal)
- Contract and topology enforcement is runtime-native
- Trust is implicit within the organization

**Between** organizations, there is no "ESR federation protocol". Cross-organization integration happens through one of three modes:

**Mode A**: Install the same Socialware in both organizations (each runs its own instance, maybe sharing data via some Socialware-specific sync mechanism).

**Mode B**: One organization exposes a Socialware's natural-language interface; the other organization's agents call it. The "interface" is literally a natural language description of what the Socialware can do — no schema, no API docs, just prose that an AI agent can understand.

**Mode C**: An organization's Socialware includes an adapter that speaks some external system's protocol (e.g., Feishu's API, Anthropic's API, another company's REST endpoints). This is traditional integration, dressed up as an ESR handler.

**All three modes coexist**. There is no single "right way" for organizations to connect. ESR provides the governance layer inside each organization; how organizations connect is a business decision made per relationship.

### The natural-language interface

The most radical implication of this architecture is that **Socialware's external interfaces can be natural language rather than structured APIs**.

Traditional integration:

> "To use our service, read our OpenAPI spec, implement client code that sends POST requests to `/api/v1/query` with a JSON body containing these fields..."

Natural-language integration:

> "Our `autoservice` Socialware handles customer inquiries. Talk to it like you'd talk to a customer service manager. Example queries: 'show me all escalated cases', 'what's the response time for VIP customers?'"

In an era where both sides of the integration are AI agents, the prose description **is** the interface. The agents can read it, understand it, and interact accordingly. This collapses decades of enterprise integration complexity.

This is not a future aspiration. With current LLMs, it works today. Socialware should embrace natural-language interfaces as a first-class option, not as a fallback for when structured APIs are too much work.

---

## What ESR Is Not

Being precise about what ESR isn't is as important as being precise about what it is.

**Not another actor framework.** Erlang, Akka, Ray, Proto.Actor all exist. ESR assumes an actor model; it doesn't reinvent one. Its first implementation (esrd) uses Elixir/OTP because it's mature.

**Not a message bus or queue.** RabbitMQ, Kafka, NATS solve messaging. ESR uses messaging but isn't about messaging. It's about declaring what messages should and shouldn't exist.

**Not a federation protocol.** Matrix, ActivityPub, email — these federate social/communication networks. ESR explicitly does not federate. Cross-organization connection is handled case by case, via handlers and natural-language interfaces.

**Not a workflow engine.** Temporal, Airflow, Prefect orchestrate long-running workflows. ESR's topology looks similar but serves a different purpose — it's architectural contract, not execution plan.

**Not a low-code platform.** Low-code aims to eliminate code. ESR aims to govern the code that AI generates.

**Not an AI framework.** LangChain, AutoGen, CrewAI provide frameworks for building agents. ESR is below them — it's the architectural substrate that frameworks like these can run on top of.

**Not a service mesh.** Istio, Linkerd manage service-to-service communication in microservices. Different layer, different concerns.

These clarifications matter because ESR is small and focused. If you position it broadly, it looks weak against established tools in each broader category. Positioned precisely, it occupies a unique niche that no other tool addresses directly.

---

## Who ESR Is For

**Primary audience**: organizations building non-trivial AI-agent systems where:

- Multiple agents with distinct responsibilities are needed
- Code is substantially AI-generated (Claude Code, Cursor, Copilot)
- Architectural drift is a real risk as code volume grows
- Human architect time is the bottleneck, not code production speed

**Secondary audience**: developers building and publishing Socialware for the ezagent ecosystem.

**Tertiary audience**: organizations wanting to install ready-made Socialware to acquire new AI capabilities without building from scratch.

**Not the audience**: small projects with one or two agents, where full human code review works fine. ESR adds overhead that's only worth paying when the scale justifies it.

---

## The User Experience: `esr` CLI

> **v0.1 CLI subset:** v0.1 implements ``esr use``,
> ``esr status``, ``esr cmd install/run/stop/restart/list/show/
> compile``, ``esr adapter install/add/list``, ``esr handler
> install/list``, ``esr actors list/tree/inspect/logs``,
> ``esr trace``, ``esr telemetry subscribe``, ``esr debug
> {replay, inject, pause, resume}``, ``esr deadletter
> {list, retry, flush}``, ``esr scenario run``, ``esr drain``,
> ``esr-lint``. The Socialware-native verbs below
> (``esr install <socialware>``, ``esr talk``, ``esr expose``)
> land in v0.2 once Socialware packaging is in place. See
> ``docs/superpowers/prds/07-cli.md`` for the full v0.1 matrix.

The experience ESR delivers, from a user's perspective, centers on these commands:

```bash
# Initialize an organization
esrd init --org-name "allen's lab"
esrd start

# Connect to the organization's esrd
esr use localhost:4000

# Install a Socialware
esr install autoservice --from github.com/ezagent/autoservice

# Talk to a Socialware via natural language
esr talk autoservice
  > I want to see ongoing conversations
  (Socialware responds in natural language)

# Install an external connector (specifically a handler for a third-party API)
esr install feishu-connector --for autoservice --app-id cli_xxx

# Expose a Socialware's interface to external callers
esr expose autoservice.supervisor_channel --to-external
  Generated invite: esr://allens-lab.example/sc-xyz

# From another organization, use a remote interface
esr use remote esr://allens-lab.example/sc-xyz
  > Show me the ongoing conversations

# Check organization status
esr status
```

Three verbs are central:

- **`install`**: bring a Socialware into this organization and run it
- **`use`**: switch context to a specific esrd (mostly for local use) or call a remote Socialware interface
- **`talk`**: interact with a local Socialware via natural language

Two verbs handle external exposure:

- **`expose`**: declare that a local Socialware's interface is callable from outside
- **`use remote`**: call a Socialware exposed by another organization

Everything else (configure, upgrade, rollback, inspect, etc.) follows standard tool patterns.

---

## Why This Specific Definition Matters

In earlier versions (v0.1, v0.2), ESR tried to be many things:

- A cross-language actor protocol
- A message routing layer
- A replacement for existing middleware
- A foundation for AI-agent development

Each attempt made the project broader but also more diffuse. Every "ESR is also X" claim required justifying ESR against the incumbents of X.

v0.3 Final is narrower but more defensible:

- ESR **doesn't** compete with actor runtimes — it builds on them
- ESR **doesn't** compete with message buses — it runs on top of them
- ESR **doesn't** compete with federation protocols — it explicitly doesn't federate
- ESR **does** occupy a niche that no existing tool addresses: **architectural governance of AI-generated code in multi-agent systems within an organizational boundary**

Socialware extends this niche outward: ESR in one organization alone is interesting; Socialware as a portable unit traded across organizations is what makes the ezagent vision viable.

The natural-language interface frontier extends it even further: Socialware with NL interfaces can be connected by other AI agents without any human-authored integration. This is the kind of capability that becomes possible only because we committed to a precise, narrow, well-chosen starting position.

---

## The Layering Diagram

```
┌────────────────────────────────────────────────────────────────┐
│  Organization A                    Organization B                │
│                                                                  │
│  ┌───────────────────────────┐   ┌───────────────────────────┐ │
│  │  User via `esr` CLI        │   │  User via `esr` CLI        │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  Installed Socialware(s)  │   │  Installed Socialware(s)  │ │
│  │   - contracts              │   │   - contracts              │ │
│  │   - topologies             │   │   - topologies             │ │
│  │   - handlers (Python)      │   │   - handlers (Python)      │ │
│  │   - external interfaces    │   │   - external interfaces    │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  ESR governance layer:     │   │  ESR governance layer:     │ │
│  │   contract, topology,      │   │   contract, topology,      │ │
│  │   verification, governance │   │   verification, governance │ │
│  └───────────────┬───────────┘   └───────────────┬───────────┘ │
│                  │                                │              │
│  ┌───────────────▼───────────┐   ┌───────────────▼───────────┐ │
│  │  esrd runtime              │   │  esrd runtime              │ │
│  │   (Elixir/OTP)             │   │   (Elixir/OTP)             │ │
│  │   - actor GenServers       │   │   - actor GenServers       │ │
│  │   - BEAM distributed       │   │   - BEAM distributed       │ │
│  │     (multi-node cluster)   │   │     (multi-node cluster)   │ │
│  └────────────────────────────┘   └────────────────────────────┘ │
│          Organization's trust boundary                            │
│                                                                    │
└────────────────────────────────────────────────────────────────┘
                                   │
                                   │ External integration happens at this boundary
                                   │ (not through ESR federation)
                                   ▼
                   ┌─────────────────────────────────────┐
                   │ Options:                             │
                   │  1. Socialware's NL interface        │
                   │  2. Socialware's adapter to API      │
                   │  3. Install same Socialware locally  │
                   └─────────────────────────────────────┘
```

Each organization has a complete ESR stack inside its trust boundary. Between organizations, there is no ESR protocol — just the various external interface options that individual Socialware packages choose to expose.

---

## Document Structure Under This Definition

The v0.3 documentation set consists of:

1. **ESR-Reposition-v0.3.md** (this file) — the anchor definition
2. **ESR-Protocol-v0.3.md** — normative spec for contract, topology, verification, governance (organization-internal)
3. **Socialware-Packaging-Spec-v0.3.md** — normative spec for how Socialware is packaged, including natural-language interface declarations
4. **esrd-reference-implementation-v0.3.md** — how Elixir/OTP implements ESR and hosts Socialware
5. **ESR-Governance-Guide-v0.3.md** — practical workflow guide including `esr` CLI reference
6. **ESR-Playground** (HTML) — interactive visualization of contract + topology + verification

Each document has a specific role. Protocol spec is normative and small. Socialware spec defines the packaging format. esrd is one implementation. Governance is practical guidance. Playground is intuition.

**No additional documents are needed for v0.3**. If a concept doesn't fit in one of these documents, it probably shouldn't be in v0.3.

---

## The Final Test of This Definition

A good definition is one that clearly admits some things and clearly excludes others. Let's test this one:

**Admitted** by this definition:

- Writing a Socialware for customer service automation
- Installing a public Socialware from a registry
- Declaring contracts that AI-generated code must respect
- Verifying topology compliance in tests
- Exposing a Socialware's natural-language interface to external callers
- Running multiple Socialware in one organization's esrd
- Operating a BEAM-clustered esrd across multiple machines within one organization

**Excluded** by this definition:

- Building a public agent network connecting strangers (that's a different kind of project)
- Replacing Kafka or RabbitMQ (wrong layer)
- Providing a low-code UI for building agents (out of scope)
- Federating organizations under a single protocol (explicitly not the goal)
- Orchestrating long-running workflows (that's Temporal's job)
- Standardizing how AI agents talk to tools (MCP does that)

This test confirms the definition is neither too broad nor too narrow. It picks out a specific problem space and stays in it.

---

## Closing

ESR v0.3 is the product of months of iteration. The final definition is small, precise, and novel. It owes much to extensive critique that stripped away everything non-essential.

If you're reading this as a future contributor or user, here is the mindset to adopt:

- **Respect the narrowness of scope**. ESR is a contract layer, not a do-everything framework.
- **Trust the layering**. Agent runtime is not your problem; contract enforcement is.
- **Think in Socialware units**. Business capabilities come in packages, not sprawls of code.
- **Embrace natural-language interfaces**. In the AI era, they're not a compromise; they're often the right choice.
- **Keep organization boundaries explicit**. Trust is bounded; don't pretend otherwise.

Everything in this project flows from these principles.

---

*Final Reposition, v0.3. All subsequent documents derive from this.*
