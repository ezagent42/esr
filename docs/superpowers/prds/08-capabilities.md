# PRD 08 — Capability-Based Access Control

**Status:** stub (v1 implementation complete; full FR enumeration deferred to v0.3).

## References

- Design spec: [`docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`](../specs/2026-04-20-esr-capabilities-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-04-20-esr-capabilities-implementation.md`](../plans/2026-04-20-esr-capabilities-implementation.md)
- E2E acceptance: [`docs/superpowers/tests/e2e-capabilities.md`](../tests/e2e-capabilities.md)
- Runnable harness: `scripts/scenarios/e2e_capabilities.py`

## Summary

Capability-based access control for ESR. **One** enforcement lane (post 2026-04-26 Lane A drop):

- **Lane B** — `PeerServer`-side gate on `{:inbound_event, ...}` and `{:tool_invoke, ..., principal_id}`. On inbound deny, dispatches a deny-DM directive to the source app's FAA peer (10-min rate-limit, Chinese deny text). On `tool_invoke` deny, returns an unauthorized `tool_result` so the handler can reply `"❌ 无权限..."` without crashing.

Pre-2026-04-26 there was a Lane A — Python adapter-side gate that ran the same `workspace:<ws>/msg.send` check + sent the deny DM directly. It was removed because it was a duplicate gate (latent allow/deny divergence bug class) and the deny-DM rendering moved to Lane B without user-experience regression. Migration note: `docs/notes/auth-lane-a-removal.md`.

Capabilities live in `~/.esrd/<instance>/capabilities.yaml` and hot-reload via `fs_watch` — no esrd restart needed for grant changes.

## Functional requirements

Enumerated with the unit-test matrix in a follow-up pass during v0.3 ralph-loop enforcement. The spec's §12 acceptance criteria already cover the checklist at a coarser grain, and the e2e-capabilities.md document operationalises each one as a Track. Formalising each into an `FR-CAP-NN` entry + test ID is the next documentation step.
