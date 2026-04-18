# ESR Governance Guide v0.3

**Purpose**: practical workflow for humans and AI agents working together under ESR
**Audience**: architects, developers using Claude Code, Socialware authors, operators
**Companion to**: ESR Reposition v0.3 Final, ESR Protocol v0.3, Socialware Packaging Spec v0.3

---

## 0. Core Framing

In AI-assisted development, the bottleneck shifts from writing code to ensuring generated code stays aligned with architectural intent. Traditional code review does not scale when a human architect works with N Claude Code instances producing hundreds of lines per hour.

ESR's answer: **make architectural intent machine-checkable via contracts and topologies**, then design workflows where humans and AI both operate productively within this framework.

This document defines the practical workflow.

---

## 1. Roles

### 1.1 Human Architect

Responsibilities:

- Write and review **contracts** (one-time, high-value investment)
- Write and review **topologies** (core work when launching business flows)
- Review **CHANGE_PROPOSAL** artifacts when contracts or topologies need modification
- Design and approve **Socialware packaging** for distributable business units
- Does NOT review ordinary implementation code (contract verification handles correctness)

Typical time allocation:

- Contract and topology design/review: 50%
- Architecture decisions and alignment: 30%
- New scenario exploration and prototyping: 20%

The architect rarely reads implementation code directly. When they find themselves doing so frequently, it's a signal that contracts aren't strong enough — strengthen the contracts, not the review habit.

### 1.2 AI Developer (Claude Code, Cursor, etc.)

Three distinct working modes, driven by role-specific system prompts:

**Mode A — Topology Designer**:
- Task: implement a new business flow
- Input: business requirements (natural language) + relevant contracts
- Output: topology YAML + design notes
- Prohibited: modifying contracts, writing implementation code

**Mode B — Peer Developer**:
- Task: implement or modify an agent's handler code
- Input: that agent's contract + test scenarios
- Output: handler code + CONTRACT_COMPLIANCE.md
- Prohibited: modifying contracts, exceeding contract boundaries

**Mode C — Change Analyst**:
- Task: analyze a CONTRACT_CHANGE_PROPOSAL or TOPOLOGY_CHANGE_PROPOSAL
- Input: proposal + all affected contracts and topologies
- Output: impact analysis
- Prohibited: making decisions (decisions belong to humans)

Mode switching is enforced through distinct system prompts, selected when the architect starts a CC session.

### 1.3 Verification Infrastructure

Not a person, but a distinct role played by tooling:

- **Static verifier**: checks contract syntax + topology-contract consistency
- **Dynamic verifier**: validates runtime traces against contracts and topology
- **Governance tracker**: tracks contract/topology changes
- **CI/CD integration**: automatic verification on PR

Design principle for verification infrastructure: **make the right thing easy, make the wrong thing immediately detectable**.

### 1.4 Socialware Author

A specialized role for those publishing Socialware packages for others to install:

- Author contracts, topologies, and handlers for a complete business unit
- Document external interfaces with clarity (natural-language descriptions matter)
- Follow Socialware Packaging Specification
- Version appropriately and maintain backward compatibility
- Respond to issues from installers

Socialware authors can be humans, teams, or organizations. The ecosystem is open to contributions.

---

## 2. The `esr` Command-Line Interface

The `esr` CLI is the primary user-facing tool. It wraps lower-level operations into a workflow-oriented command set.

### 2.1 Core Verbs

**`esr use`** — switch context to a specific esrd

```bash
# Connect to local esrd
esr use localhost:4000

# Connect to shared organization esrd
esr use https://esrd.mycompany.example

# Show current context
esr use
  Current context: localhost:4000
  Organization: allen's lab
  Connected: yes
```

Context persists across shell sessions (stored in `~/.esr/config`).

**`esr install`** — install a Socialware into the current organization

```bash
# From registry
esr install autoservice

# From specific version
esr install autoservice@1.2.0

# From git
esr install autoservice --from github.com/ezagent/autoservice

# From local directory
esr install autoservice --from ./my-socialware/

# For a specific target (declares integration intent)
esr install feishu-connector --for autoservice --app-id cli_xxx
```

Output shows every step and reports any failure with actionable detail.

**`esr talk`** — interact with a Socialware via natural language

```bash
esr talk autoservice
  > Show me ongoing conversations
  (response in natural language)
  
  > What's the escalation rate today?
  (response)
  
  > exit
```

`esr talk` connects to the Socialware's natural-language interface (if it has one) and provides a conversational REPL.

**`esr expose`** — make a local Socialware's interface accessible externally

```bash
# Expose a specific interface
esr expose autoservice.supervisor_channel --to-external
  Generated invite link: esr://allens-lab.example/sc-xyz
  Share this with other organizations.

# List currently exposed interfaces
esr expose list
  autoservice.supervisor_channel → esr://allens-lab.example/sc-xyz (public)
  autoservice.customer_channel → esr://allens-lab.example/sc-abc (token-required)
  
# Revoke exposure
esr expose revoke autoservice.supervisor_channel
```

**`esr use remote`** — call an externally-exposed Socialware

```bash
# Connect to an exposed interface
esr use remote esr://allens-lab.example/sc-xyz
  Connected to: autoservice.supervisor_channel
  Protocol: natural_language
  
  > Show me open cases
  (response from the remote Socialware)
```

This is how cross-organization integration happens at the user level. No protocol-level federation is involved — it's simply a wrapped call to the remote Socialware's exposed interface.

### 2.2 Inspection Verbs

```bash
# Overall status
esr status
  Organization: allen's lab
  esrd: running (3 nodes, cluster mode)
  Installed Socialware:
    - autoservice v1.2.0 (4 agents, 3 topologies, 2 interfaces)
    - feishu-connector v0.8.0 (1 agent, 1 interface)
  Exposed interfaces: 2
  Open proposals: 1

# List installed Socialware
esr list
  autoservice v1.2.0 (active)
  feishu-connector v0.8.0 (active)

# Inspect a specific Socialware
esr inspect autoservice
  ...detailed view...

# List available interfaces
esr interfaces list

# Describe a specific interface
esr interfaces describe autoservice/customer_inquiry
  # Shows the natural-language description of what this interface offers
```

### 2.3 Contract and Topology Verbs

Most users won't need these often — they're for architects and Socialware authors:

```bash
# Contract operations
esr contract list
esr contract inspect cc-responder
esr contract verify cc-responder
esr contract load path/to/new.contract.yaml

# Topology operations
esr topology list
esr topology inspect autoservice-basic
esr topology activate autoservice-basic
esr topology retire autoservice-basic

# Verification
esr verify all
esr verify contracts
esr verify topologies
esr verify compatibility  # topology-vs-contracts
```

### 2.4 Governance Verbs

```bash
# Create a proposal
esr proposal create --type contract_change --target cc-responder

# List open proposals
esr proposal list

# Review a proposal (shows impact analysis)
esr proposal review 2026-04-20-expand-cc

# Approve/reject
esr proposal approve 2026-04-20-expand-cc
esr proposal reject 2026-04-20-expand-cc --reason "..."

# Archive and history
esr proposal archive  # list past proposals
esr proposal show 2026-04-15-past-change
```

### 2.5 Runtime Operations

```bash
# Start/stop local esrd (if it's a local daemon)
esrd start
esrd stop
esrd restart

# Logs
esr logs autoservice              # Socialware-specific logs
esr logs --filter violations      # violation events only
esr logs --follow                 # tail -f equivalent

# Initialize organization
esrd init --org-name "my org"
  Creates ~/.esrd/ directory with org config
```

### 2.6 Layered Command Structure

```
esrd (bundled with esrd release, Elixir escript):
  - Low-level operations on local esrd
  - esrd init, esrd start, esrd stop
  - esrd-cli (deeper protocol operations, for debugging)
  
esr (bundled with SocialCommons, Python):
  - User-friendly workflow commands
  - Most users primarily use this
  - Delegates to esrd under the hood
  
BEAM REPL (iex --remsh esrd@host):
  - Native Elixir access
  - For deep diagnostics, experiments, emergency ops
```

Three interfaces, same underlying system. Most users only touch `esr`.

---

## 3. Core Workflows

### 3.1 Setting Up a New Organization

```bash
# Install esrd and esr
apt install esrd
pip install esr-cli

# Initialize
esrd init --org-name "my-org"
esrd start

# Connect the CLI
esr use localhost:4000

# Verify
esr status
  Organization: my-org
  esrd: running
  Installed Socialware: (none)
```

This is a one-time setup. Future work happens within this organization.

### 3.2 Installing a Socialware (typical user)

```bash
esr install autoservice
  ...checks compatibility...
  ...downloads...
  ...loads contracts...
  ...validates topologies...
  ...starts handlers...
  ...runs smoke tests...
  ✓ autoservice v1.2.0 is installed and running

esr talk autoservice
  > hello
  (autoservice responds)
```

### 3.3 Developing a New Business Flow (architect)

```
Step 1: Human architect writes topology draft
  - References business requirements
  - Consults available contracts, chooses participants
  - Declares message flows

Step 2: Static verifier runs
  - Checks topology references valid contracts
  - Checks all flows are within participant contracts
  - Pass → Step 3
  - Fail → adjust topology OR raise CONTRACT_CHANGE_PROPOSAL

Step 3: CC (Mode A) generates glue configuration from topology
  - Does not modify handler code
  - Produces deployment artifacts

Step 4: Test scenarios authored
  - By architect or CC
  - Covers topology branches and acceptance criteria

Step 5: Dynamic verifier runs
  - Executes test scenarios
  - Collects trace
  - Compares trace to topology and contracts
  - Any violation → feed back to CC for auto-correction

Step 6: Human reviews
  - Architect reviews topology (primary focus)
  - Architect reviews change log (secondary)
  - Merge on approval
```

The architect's actual review time concentrates on Step 1 and Step 6. Other steps are CC + verification automation.

### 3.4 Developing a New Agent/Handler (architect + CC)

```
Step 1: Human architect writes agent contract
  - Declares identity, role, incoming, outgoing, targeting, forbidden
  - This is an investment worth taking time on

Step 2: Static verifier checks contract
  - Syntactic validity
  - No conflicts with existing contracts

Step 3: CC (Mode B) implements the handler
  - Reads only the contract, not other handlers' code
  - Annotates every publish/subscribe/target call with contract clause
  - Produces CONTRACT_COMPLIANCE.md

Step 4: Test scenarios for this agent
  - CC generates scenarios based on contract
  - Human reviews for reasonableness

Step 5: Dynamic verifier runs
  - Contract compliance verified in all scenarios

Step 6: Human reviews contract and compliance report
  - Focus: is the contract well-designed?
  - Not: line-by-line Python review
```

### 3.5 Contract Change Flow (rare but critical)

```
Step 1: Proposal authored
  - By human architect, or by CC (when encountering contract limits)
  - Describes change + rationale

Step 2: CC (Mode C) generates impact analysis
  - Affected topologies list
  - Affected code identification
  - Historical messages potentially invalidated
  - Migration path suggestion

Step 3: Architect decides
  - Accept, reject, or request revision
  - On accept, choose direct upgrade vs staged rollout

Step 4: Implementation
  - Update contract
  - Update affected topologies
  - Full verification pass

Step 5: Record
  - Proposal archived
  - CHANGELOG updated
  - Rationale preserved for future reference
```

Critical: **Step 3's decision authority strictly belongs to the architect**. CC never modifies contracts on its own. This discipline preserves architectural control.

### 3.6 Publishing a Socialware

```
Step 1: Ensure the Socialware meets publishing requirements
  - Manifest complete
  - Contracts, topologies validated
  - Handlers pass compliance checks
  - Scenarios comprehensive
  - README clearly describes the package
  - External interfaces documented with natural-language descriptions

Step 2: Test install locally
  esr install my-socialware --from ./my-socialware/

Step 3: Iterate until install is clean and smoke tests pass

Step 4: Tag version and publish
  esr publish ./my-socialware/ --to registry.example.com

Step 5: Consumers install
  esr install my-socialware
```

---

## 4. Contract Authoring Guidelines

### 4.1 Qualities of a Good Contract

- **Specific rather than abstract**: "MUST NOT publish to customer_messages" is better than "MUST NOT send customer-facing messages"
- **Verifiable rather than principled**: every clause should be mechanically checkable
- **Reasoned rather than arbitrary**: each forbidden item includes rationale
- **Minimal rather than comprehensive**: only declare meaningful boundaries, not implementation details

### 4.2 Common Mistakes

**Mistake 1: Embedding business logic**

```yaml
# Wrong
outgoing:
  - topic: customer_replies
    condition: "after analyzing intent and generating empathetic response with 200-300 words"

# Right
outgoing:
  - topic: customer_replies
    trigger: "on receipt of customer_messages"
    message_shape: { content: string, metadata: {...} }
```

**Mistake 2: Omitting the forbidden list**

A contract without a `forbidden` section is almost always incomplete. Explicitly stating what's prohibited is as important as stating what's allowed.

**Mistake 3: Contracts that are too permissive**

If a contract allows nearly any behavior, it has lost its value. A good contract is like a good API: it clearly states what CAN be done, and implicitly restricts everything else.

### 4.3 Maturity Indicators

A mature contract shows:

- **Low violation rate**: new code rarely violates it (not too strict, not too loose)
- **Low change rate**: stable for weeks (the design thinking converged)
- **Role clarity**: reading the contract alone conveys the agent's role

---

## 5. Topology Authoring Guidelines

### 5.1 Qualities of a Good Topology

- **Tells a story**: reads like a business flow, not a connection list
- **Participants clearly assigned**: each participant's role is stated
- **Branches explicit**: alternative paths named, not implied
- **Acceptance criteria mechanically checkable**: testable conditions

### 5.2 Topology Scope

One topology, one business scenario. Not one business domain.

Good: `business/takeover.topology.yaml` describing only the takeover flow
Bad: `business/autoservice.topology.yaml` trying to describe all of AutoService

Small topologies are easier to review, verify, and modify. Large topologies inevitably become unreadable monsters.

### 5.3 Topology Relationships

Multiple topologies may involve the same agents. This is normal — agents are assets, reused across businesses.

Note:

- Two topologies might both expect an agent to behave a certain way, but only one can win in practice. When priorities matter, declare them explicitly.
- Topologies couple indirectly through shared agents; changing one topology may affect another. Impact analysis spans topologies.

---

## 6. CC Prompt Templates

### 6.1 Mode A: Topology Designer

```
You are CC in Topology Designer mode.

Your task: based on business requirements, design a topology file.

Resources:
- Business requirements: <inline text or file reference>
- All relevant contracts: <paths>
- Existing related topologies (for reference): <paths>

Rules:
1. You only output topology YAML and a DESIGN_NOTES.md explaining design decisions
2. You may not modify any contract files
3. You may not write any Python handler code
4. Every message flow must be feasible within participant contracts
5. If contract modification is needed, output a CONTRACT_CHANGE_PROPOSAL.md
   instead of making changes yourself

Outputs:
- <topology_name>.topology.yaml: primary artifact
- DESIGN_NOTES.md: explanation of key decisions
- (optional) CONTRACT_CHANGE_PROPOSAL.md: if contract change needed

Self-check before delivery:
- Run static verifier
- Confirm zero violations
- DESIGN_NOTES explains all tradeoffs
```

### 6.2 Mode B: Peer Developer

```
You are CC in Peer Developer mode.

Your task: implement an agent's Python handler code.

Resources:
- This agent's contract: <path>
- Test scenarios: <path>
- Base SDK documentation: esr-handler-py reference

Rules:
1. Your code must strictly adhere to the contract
2. Annotate each handler.publish/subscribe/target call with the 
   matching contract clause in a comment
3. If a business need requires behavior beyond the contract, stop and 
   output a CONTRACT_CHANGE_PROPOSAL.md
4. Do not depend on other agents' internal implementations; rely only 
   on what their contracts declare

Outputs:
- Handler implementation code
- CONTRACT_COMPLIANCE.md listing all I/O operations and their contract clauses
- Unit tests

Self-check before delivery:
- Run static analysis on all publish/subscribe/target calls
- Verify each is within contract
- Run dynamic verifier; all test scenarios pass
```

### 6.3 Mode C: Change Analyst

```
You are CC in Change Analyst mode.

Your task: analyze a CHANGE_PROPOSAL and produce an impact report.

Resources:
- Proposal file: <path>
- All current contracts and topologies: <paths>
- Git history (change log)

Rules:
1. You analyze; you do not decide
2. Output is objective impact assessment, not "recommend approve" or "recommend reject"
3. Analysis must cover:
   - Direct impact: which contracts/topologies/code are directly affected
   - Indirect impact: what might be affected through what paths
   - Risks: specific risk points of restrictive changes
   - Alternatives: other solutions that meet the need with less impact

Outputs:
- IMPACT_ANALYSIS.md: structured impact analysis
- (optional) ALTERNATIVES.md: exploration of alternatives

Do not output:
- "approve" or "reject" recommendations
- Strongly biased wording toward a particular choice
```

---

## 7. Review Checklists

### 7.1 Reviewing a Topology

- [ ] Is the story clear? Can a reader understand the business flow?
- [ ] Is each participant's role clearly stated?
- [ ] Does static verification pass?
- [ ] Are branches complete? Are non-happy-path scenarios covered?
- [ ] Are acceptance criteria mechanically verifiable?
- [ ] Is there content that seems to belong to a different topology?

### 7.2 Reviewing a Contract

- [ ] Can the role be stated in one clear sentence?
- [ ] Is the forbidden list explicit and reasoned?
- [ ] Do incoming/outgoing cover the full envisioned behaviors?
- [ ] Is business-level detail leaking into the contract?
- [ ] If this agent appears in other topologies, does the contract still fit?

### 7.3 Reviewing a CHANGE_PROPOSAL

- [ ] Is the rationale sufficient?
- [ ] Does impact analysis cover all paths?
- [ ] Are there alternatives with smaller impact?
- [ ] Is the change additive or restrictive? Restrictive needs extra care.
- [ ] If approved, is migration plan clear?

### 7.4 Reviewing a Socialware (as author)

- [ ] Does manifest completely describe the package?
- [ ] Are external interfaces documented clearly in natural language?
- [ ] Do scenarios cover realistic use cases?
- [ ] Does README explain the package's value proposition?
- [ ] Are configuration parameters well-documented?
- [ ] Are secrets clearly marked?

---

## 8. Typical Project Directory

```
my-project/
├── esrd-config/               # Organization-level esrd config
│   └── cluster.yaml
│
├── installed-socialware/      # Metadata of installed Socialware
│   ├── autoservice@1.2.0/
│   └── feishu-connector@0.8.0/
│
├── my-socialware/             # A Socialware being developed locally
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

This structure keeps every artifact in its place. Contracts and topologies are first-class, not buried in code.

---

## 9. Meta-Advice for Architects

**Advice 1: Invest in contracts, not in code review**

Your time on contracts compounds. Your time on code review doesn't.

**Advice 2: Allow contracts to be rough at first, refine with use**

The first version of a contract won't be final. Expect 5-10 iterations before it stabilizes. This is normal; you're calibrating with real use.

**Advice 3: Treat CHANGE_PROPOSAL as a thinking tool**

When CC raises a CHANGE_PROPOSAL, don't just think "approve or reject". It's an opportunity to reconsider architecture — it reveals a limitation of your original contract, or a new direction in the business.

**Advice 4: Learn to say "no"**

When a business need seems to "require" loosening a contract, first ask "can we reshape the business instead?" Every restrictive contract loosening becomes permanent debt.

**Advice 5: Ecosystem building starts with contracts**

When others build on your project later, contracts are the most valuable asset. Contracts are transferable, reusable architectural knowledge. Code isn't.

**Advice 6: Share Socialware, not just code**

The ezagent ecosystem's flywheel is Socialware flowing between organizations. When you build something reusable, package it as Socialware and share. This compounds the community's capability.

---

## 10. Glossary

- **ESR**: the architectural governance protocol
- **esrd**: first reference implementation of ESR, Elixir/OTP-based
- **Organization**: the trust boundary of one esrd instance
- **Socialware**: packaged, distributable business unit (contracts + topologies + handlers + interfaces)
- **Contract**: declaration of an agent's behavioral boundary
- **Topology**: declaration of how agents compose in a business flow
- **Verification**: automated checking of contract/topology compliance
- **Governance**: process of evolving contracts and topologies under human authority
- **Handler**: Python process implementing an agent's business logic
- **Interface**: a Socialware's external entry point (natural-language or structured)
- **esr** (lowercase italic in CLI): the primary user-facing command-line tool
- **Proposal**: structured request for contract or topology change

---

*End of ESR Governance Guide v0.3 Final*
