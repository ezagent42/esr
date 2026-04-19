# ESR v0.1 Traceability Index

**Purpose:** single-page table linking every spec section, PRD functional requirement, E2E track, and plan phase. Use it to answer "where is X tested?" and "what am I breaking if I remove Y?" in one lookup.

**Legend:**
- **Spec §** — section of `docs/superpowers/specs/2026-04-18-esr-extraction-design.md`
- **PRD FR** — functional requirement id in `docs/superpowers/prds/<NN-name>.md`
- **E2E** — track letter in `docs/superpowers/tests/e2e-platform-validation.md`
- **Plan** — phase / task in `docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md`

---

## Cross-reference table

| Spec § | Requirement summary | PRD FR | E2E | Plan |
|---|---|---|---|---|
| §1.3 | v0.1 is pre-conforming; partial ESR v0.3 subset | — (design statement) | — | intro |
| §2.1 | Four layers: runtime ↔ adapter/handler + command | PRD 01-F02 (supervision tree), PRD 02-F01 (package skeleton) | — | Phase 1 / 2 |
| §2.2 | Elixir / Python ownership boundary | PRD 01-F02, PRD 02-F01 | — | Phase 1 / 2 |
| §2.3 | Canonical flow: external event → adapter → PeerServer → handler → actions | PRD 01-F06, F07; PRD 02-F02, F04; PRD 03-F02, F07 | Track C | Phase 3 / 4 / 5 |
| §3.1 | Supervision tree | PRD 01-F02 | — | Phase 1, Task 1.5 |
| §3.2 | PeerServer state fields + handlers | PRD 01-F05, F06, F20 | B, C, D, F | Phase 1, Task 1.3 |
| §3.3 | AdapterHub: topic-to-actor binding + Phoenix Channels | PRD 01-F08, F09 | A, C | Phase 3, Task 3.3 |
| §3.4 | HandlerRouter: stateless pool + per-call ser/de | PRD 01-F10, F11; PRD 03-F07 | C | Phase 3, Task 3.4 |
| §3.5 | Topology.Registry + Instantiator | PRD 01-F13, F14 | A, B, F | Phase 1, Task 1.8+ |
| §3.6 | Telemetry events + rolling buffer | PRD 01-F15, F16 | E | Phase 1, Task 1.7 |
| §3.7 | Management surfaces (esrd / esr / REPL) | PRD 07 (`esr` CLI) | all (CLI used throughout) | Phase 7 |
| §3.8 | Multi-app hosting + dogfooding (prod/dev) | PRD 04-F05 (feishu instance configs); PRD 07-F01 | envtire env assumption | Phase 0 / 7 |
| §4.1–4.2 | Handler pure fn + purity contract | PRD 02-F04, F05; PRD 05-F03, F04, F05 | H-2 | Phase 2 / 5 |
| §4.3 | Purity CI enforcement (imports + frozen state) | PRD 02-F16, F17 | H-2 | Phase 2 / 5 |
| §4.4 | Action palette: Emit / Route / InvokeCommand only | PRD 02-F02; PRD 01-F07 | H-2 | Phase 2, Task 2.2 |
| §4.5 | State pydantic frozen + schema_version | PRD 02-F05; PRD 05-F03 | F-3 | Phase 5 |
| §5.1 | Adapter factory + allowed_io | PRD 02-F07, F08; PRD 04-F02, F03 | A | Phase 4 |
| §5.2 | Capability declaration enforcement | PRD 02-F18 | A | Phase 2, Task 2.x |
| §5.3 | Directive / Event semantics | PRD 02-F03; PRD 03-F02 | C | Phase 2 / 3 |
| §5.4 | Adapter lifecycle + `esr adapter add` | PRD 07-F04 | A | Phase 7 |
| §5.5 | No adapter nesting — depends_on in topology | PRD 02-F10, F13; PRD 06-F02, F07 | B | Phase 2 / 6 |
| §5.6 | Adapter install flow | PRD 07-F03, F05; PRD 04-F04 | A | Phase 7 |
| §6.1 | Command = typed open-graph pattern + name resolution | PRD 02-F09, F13; PRD 06-F01, F02 | A, B | Phase 2 / 6 |
| §6.2 | EDSL authoring + worked example (two-pattern feishu-to-cc) | PRD 02-F10, F11, F12; PRD 06-F01, F02 | A, B, C | Phase 2 / 6 |
| §6.3 | Canonical YAML schema | PRD 02-F14; PRD 06-F03, F04 | H-4 | Phase 2 / 6 |
| §6.4 | compose.serial | PRD 02-F12; PRD 06-F06 | — (v0.1 doesn't need this path) | Phase 2 |
| §6.5 | Instantiation (CLI + InvokeCommand) + idempotency | PRD 01-F07, F13; PRD 07-F11 | B-3, B-4 | Phase 7 |
| §6.6 | Compilation pipeline | PRD 02-F13; PRD 06-F03 | H-4 | Phase 2 |
| §6.7 | Dead-elim + CSE optimisations | PRD 06-F05, F06 | H-4 | Phase 6 |
| §6.8 | Pattern installation + dep resolution | PRD 07-F08; PRD 06-F08, F09 | A | Phase 7 |
| §7.1 | Transport: Phoenix Channels over WS | PRD 01-F09, F12; PRD 03-F04 | — | Phase 3 |
| §7.2 | Envelope shapes (directive / event / handler_call / handler_reply) | PRD 02-F03; PRD 03-F02, F03, F12 | E-1 | Phase 3 |
| §7.3 | Timeouts + worker crash recovery | PRD 01-F06, F10; PRD 03-F05, F08 | G-4 | Phase 3 |
| §7.4 | Ordering / delivery / dedup | PRD 01-F07; PRD 05-F11 | C-4 | Phase 3 / 5 |
| §7.5 | `esr://` URI (host required) | PRD 01-F17; PRD 02-F15; PRD 03-F12 | — (used in logs) | Phase 1 / 2 |
| §8.1 | Project structure | PRD all | — | Phase 0 |
| §8.2 | Packaging (mix release + uv build) | PRD 01-F01; PRD 02-F01 | — | Phase 0 / 1 / 2 |
| §8.3 | Single-node deployment | PRD 01-F21 | G-4 | Phase 0 / 1 |
| §9.1–9.2 | E2E 8 tracks | all PRDs collectively | A–H | Phase 8 |
| §9.3 | Success gate + latency posture | — (test-level) | all | Phase 8 |
| §10.1 | Migration map cc-openclaw → esr/ | — (planning) | — | Phase 9 |
| §10.2 | Phasing with DAG | — | — | Phase 9 (doc reconciliation) |
| §10.3 | Sidecar stays in cc-openclaw; Feishu inbound no dep on sidecar | PRD 04-F12 (direct WS) | A, C | Phase 9 |
| §11 | Resolved / deferred open questions | scoped into PRDs | — | §11 |
| §12 | References | — | — | — |

---

## Reverse lookup: E2E track → primary PRD FRs

**Track A — Registration:**
- PRD 02-F04 / F07 / F09 (registrations exist)
- PRD 04-F03 / F04 (capability + manifest)
- PRD 05-F02 (handler manifest)
- PRD 06-F08, F09 (pattern install writes compiled YAML)
- PRD 07-F03–F10 (CLI install / add / list)

**Track B — Scheduling + `/new-thread`:**
- PRD 01-F13 (instantiator) / F14 (cascade)
- PRD 02-F02 (InvokeCommand)
- PRD 05-F07 (feishu_app triggers InvokeCommand; idempotent)
- PRD 06-F01, F02 (two patterns)
- PRD 07-F11, F12, F18 (CLI run / stop / debug inject)

**Track C — Bidirectional flow:**
- PRD 01-F06, F07 (PeerServer event handling + action dispatch)
- PRD 04-F07, F12, F17, F18, F21 (feishu send + WS event; cc_tmux send_keys + cc_output)
- PRD 05-F12, F13, F16, F18 (handlers route both directions)

**Track D — Isolation:**
- PRD 01-F04 (one_for_one supervision)
- PRD 05-F11 (per-thread dedup separate)

**Track E — Observability:**
- PRD 01-F15, F16 (telemetry buffer + attach)
- PRD 07-F15, F16, F17 (CLI actors / trace / telemetry)

**Track F — Operations:**
- PRD 01-F13, F14, F18 (instantiator / cascade / persistence)
- PRD 07-F12, F13, F21 (stop / restart / drain)

**Track G — Debug:**
- PRD 01-F18, F19, F20, F21 (persistence / deadletter / pause-resume / BEAM restart)
- PRD 07-F18, F19 (debug subcommands + deadletter)

**Track H — Correctness:**
- PRD 02-F16, F17, F18 (purity + capability)
- PRD 06-F03, F04 (deterministic compiled YAML)
- PRD 01-F07 (action type validation)

---

## Usage guidelines

**When working on a PRD:** cross-check this table to ensure every E2E track that depends on this PRD is covered. If a track depends on your PRD but no FR handles a specific requirement, add one.

**When implementing a plan task:** look up your phase here to see which PRD FRs and E2E tracks you're advancing. Anything you don't understand in the task should have a paper trail back to spec §.

**When writing a test:** if the test file is listed in the PRD unit-test matrix, verify the test name matches. Drift between matrix and actual test name is a ralph-loop failure signal.

**When a bug escapes to E2E:** find the track → find the PRD FR → find the plan task. The unit-test matrix for that FR should have covered it. If not, add the missing test before fixing.

---

*End of Traceability Index.*
