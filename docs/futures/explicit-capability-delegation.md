# Future: Explicit Capability Delegation (capabilities-v2)

Status: **not started** — future brainstorm target.
Author: brainstorming session with user (linyilun), 2026-04-20.
Relates to: `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`
§1.3, §6.5.

## Why this document exists

The capability-based access control system shipped in `feature/esr-capabilities`
(merged 2026-04-20) deliberately limits itself to **implicit delegation**: a
CC session spawned by a human user inherits that user's *entire*
`principal_id` for the duration of the session. This is documented in the
spec's §6.5.

Implicit delegation is adequate for today's ESR use cases (a single user
running CC sessions from their own machine against their own Feishu
workspaces), but it has concrete limitations that become visible as soon as
any of the following are introduced:

1. Third-party or partially-trusted agents running "on behalf of" a user
2. Long-lived autonomous agents that are not CC sessions
3. Multi-party workflows where one human grants a narrow capability to
   another principal for a limited purpose
4. Time-bound access (e.g., a consultant gets `workspace:proj/msg.send` for
   30 days)
5. Revocation without restarting the session

This document is a placeholder describing what explicit delegation would
look like, so when it's time to implement it there's a starting point and
the existing design's assumptions are captured before they fade.

## What "explicit delegation" means here

> Principal A, holding capability C, issues a *delegation record* granting
> principal B some (subset of) C, with optional time bound, optional
> revocation conditions, and an audit-visible provenance chain.

Concretely, A (a human user holding `workspace:proj/*`) could run:

```
esr cap delegate \
  --from ou_alice \
  --to ag_coordinator_v2 \
  --grant "workspace:proj/msg.send" \
  --grant "workspace:proj/session.switch" \
  --expires 2026-05-20 \
  --note "running the weekly status bot"
```

— and from that point, the runtime would treat tool_invokes from
`ag_coordinator_v2` as authorized for the delegated permissions only, not
for the full `workspace:proj/*` that `ou_alice` holds directly.

## Sketch of what this would change

### Schema

Introduce a `delegations` section, either in `capabilities.yaml` or a
sibling `delegations.yaml` (the latter is cleaner — delegations are
first-class records, not a property of a principal entry):

```yaml
# ~/.esrd/default/delegations.yaml
delegations:
  - id: dg_xyz123           # unique ID for revocation
    from: ou_alice          # delegator principal_id
    to: ag_coordinator_v2   # delegatee principal_id
    granted:
      - "workspace:proj/msg.send"
      - "workspace:proj/session.switch"
    expires: "2026-05-20T00:00:00Z"
    issued: "2026-04-20T00:00:00Z"
    note: "running the weekly status bot"
```

### Check algorithm

`Esr.Capabilities.has?(principal, permission)` today queries a single ETS
table (`Grants`). With delegations, the check becomes a two-step lookup:

1. Does `principal` directly hold `permission` in their
   `capabilities.yaml` entry? → allow.
2. If not: does any active delegation `to: principal` grant `permission`,
   AND is the delegator `from: X` in the delegation still holding
   `permission` themselves (so revoking the delegator's direct grant
   cascades)? → allow.
3. Otherwise deny.

The cascading check is important: if Alice loses `workspace:proj/msg.send`
(an admin revokes it), all delegations she issued for that permission
SHOULD instantly stop working. This naturally supports the "firing an
employee" scenario without having to hunt down every delegation they
issued.

### CLI

Extend `esr cap` with:

- `esr cap delegate --from ... --to ... --grant ... [--expires ...]`
- `esr cap revoke-delegation <delegation_id>`
- `esr cap delegations [--from <principal>] [--to <principal>]`

### Subset validation

At delegation time, reject any `--grant` that the delegator does not
currently hold. This is strict — `--grant workspace:proj/msg.send` fails if
Alice doesn't hold that permission at the moment she issues the delegation.
(We may want to be more lenient later — e.g., allow delegating a narrowed
form: delegator holds `workspace:proj/*`, delegates only `msg.send` — but
strict-equality-or-narrower is the minimum.)

### Transitivity

**Recommend: disallow by default.** If B holds a delegated permission, B
cannot delegate it to C. Transitive delegation creates long chains that
are hard to reason about and audit; the common need (multi-level trust)
can be met by having the original delegator issue multiple parallel
delegations.

An explicit `--redelegate` flag on the delegation record could unlock
this later if a real use case appears.

### Audit

Each `delegate` / `revoke-delegation` action writes a line to a log file
(`~/.esrd/default/delegations.log`, append-only). Not a full audit system;
just enough provenance that "who granted X to Y, when" is answerable.

## Open design questions

These should be resolved during the eventual brainstorm for this work:

1. **Delegation file location and hot-reload semantics**: same
   fs_watch-driven reload as `capabilities.yaml`? Yes probably — consistent
   UX.
2. **Expiry enforcement granularity**: check at every `has?` call (cheap —
   just compare timestamps) or sweep-and-purge periodically? Check-on-call
   is simpler.
3. **Partial delegation**: Alice holds `workspace:proj/*`; can she
   delegate only `workspace:proj/msg.send`? Yes, should be an explicit
   narrowing — but this requires the subset-validation to do "is the
   requested grant a subset of what the delegator holds" (with wildcard
   math), not strict equality.
4. **Delegation-to-same-principal**: should Alice be allowed to delegate
   to herself? (Probably not useful; no harm in allowing if kept simple.)
5. **Revocation UX**: the plan above uses unique IDs. Should we also
   support `esr cap revoke-delegation --from ou_alice --to ag_x`
   (revoke-all-from-A-to-B)?
6. **Agent identity side**: delegations work for any principal_id, but
   for the "autonomous agent" use case we still need a separate story for
   how agents authenticate in the first place. These two topics may or
   may not get bundled into the same brainstorm.

## Non-goals for capabilities-v2

- Distributed consensus about which delegations are active (assume single
  esrd instance holds the canonical state; sync across instances is a
  separate topology problem)
- OAuth/OIDC token-backed delegations (explicit tokens passed between
  independent systems). Start with file-based + CLI-mutated state; graduate
  to tokens only if a concrete use case appears.
- Cryptographic signing of delegation records. If the attack model is
  "someone with FS write access modifies delegations.yaml" — we're already
  trusting FS. Add signatures only when the trust model changes.

## Scope estimate

- 4–6 focused days assuming the design questions above are settled before
  implementation.
- ~300-500 new lines of Elixir (check algorithm extension, delegation
  store, CLI) + ~150 lines of Python (CLI mutators, parallel to
  `esr cap grant`) + docs + tests.
- Does NOT require any backward-incompatible changes to the existing
  capabilities.yaml or `has?` API — delegations are additive.

## Proposed trigger

Open this brainstorm when the first concrete use case lands that cannot
be served by the implicit-inheritance model. Realistic candidates:

- A user asks to run an LLM agent on their behalf with restricted scope.
- A multi-human workspace where users want to share narrow capabilities
  (e.g., "you can act as me for `msg.send` in this workspace only while
  I'm on PTO").
- A first persistent autonomous agent (a runtime peer that is not a CC
  session) is added to ESR.
