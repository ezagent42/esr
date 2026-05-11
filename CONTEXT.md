# ESR

The runtime that lets human operators drive AI agents through chat
(today: Feishu) — and the supporting harness that makes adding new
operators / new flows / new agent kinds drift-free.

This file is the project-level glossary. It captures **terms operators
and contributors actually use**, not implementation jargon. The
authoritative architecture-level domain reference is
[`docs/notes/concepts.md`](docs/notes/concepts.md) (concepts rev-11
covers Session / Entity / Resource / Interface / Realm / Bundle /
SessionTemplate). This file complements it with operator-facing and
e2e-harness terms.

## Language

### Operator-journey terms (introduced 2026-05-10 in the guide-driven-e2e spec)

**journey**:
The full operator path end-to-end, from fresh install to first agent reply. One per project; indexed by `docs/guides/full-user-journey.md`.
_Avoid_: workflow, e2e flow, full path.

**flow**:
A sub-segment of the **journey** (bootstrap, workspace+session, pty-attach, plugin-lifecycle, etc). One flow ↔ one **guide** ↔ one-or-more **scenarios**.
_Avoid_: sub-flow, leg, stage.

**guide**:
A **flow**'s human-readable markdown document at `docs/guides/flow-<topic>.md`. Doubles as the fence source for replay.
_Avoid_: doc, runbook, walkthrough (those are the form; "guide" is the role).

**scenario**:
A **flow**'s machine execution shell at `tests/e2e/scenarios/<n>.sh`, linked back to its **guide** via a `# Replays:` header.
_Avoid_: test, e2e test (still ambiguous between scenario and unit test).

**fence**:
A markdown code block with a recognized language tag (`chat-input`, `chat-output`, ...) inside a **guide**, machine-replayed by `scripts/replay-guide.sh`.

### Cross-references with `docs/notes/concepts.md`

The architecture-level terms — **Session**, **Entity**, **Resource**, **Interface**, **Realm**, **Bundle**, **SessionTemplate**, **Channel** — are owned by `docs/notes/concepts.md` (rev-11). Don't redefine here. When this glossary references them, it links into that document.

## Relationships

- A **journey** contains N **flows**.
- A **flow** is documented by exactly 1 **guide**.
- A **flow** is executed by ≥1 **scenarios** (typically 1; advanced flows may have permutations).
- A **guide** contains M **fences** (M = 2 × number of operator steps).
- A **scenario** ↔ **guide** mapping is 1:1 in v1; future permutations track via `# Replays:` header pointing at the same guide.

## Example dialogue

> **Operator:** "Where do I find the canonical sequence for getting from `esrd` install to my first CC reply in Feishu?"
> **Maintainer:** "That's the **journey**, indexed at `docs/guides/full-user-journey.md`. Each step in that index is a **flow**, and each **flow** has its own **guide** with **fences** that double as the e2e replay source."

## Flagged ambiguities

- "scenario" historically referred to bash scripts under `tests/e2e/scenarios/`. The new convention preserves that meaning + binds each scenario to a guide via the `# Replays:` header.
- "test" alone is ambiguous (unit vs e2e). Prefer **scenario** for e2e shell scripts; "test" for unit + property tests under `runtime/test/`.
