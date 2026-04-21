# PRD 08 — Capability-Based Access Control

**Status:** stub (v1 implementation complete; full FR enumeration deferred to v0.3).

## References

- Design spec: [`docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`](../specs/2026-04-20-esr-capabilities-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-04-20-esr-capabilities-implementation.md`](../plans/2026-04-20-esr-capabilities-implementation.md)
- E2E acceptance: [`docs/superpowers/tests/e2e-capabilities.md`](../tests/e2e-capabilities.md)
- Runnable harness: `scripts/scenarios/e2e_capabilities.py`

## Summary

Capability-based access control for ESR. Two enforcement lanes:

- **Lane A** — adapter-side gate on inbound messages. Drops `msg_received` events whose sender lacks `workspace:<name>/msg.send` for the chat's bound workspace; rate-limits a deny DM to once per 10 minutes.
- **Lane B** — `PeerServer`-side gate on `{:inbound_event, ...}` and `{:tool_invoke, ..., principal_id}`. Denied `tool_invoke` returns an unauthorized `tool_result` so the handler can reply `"❌ 无权限..."` without crashing.

Capabilities live in `~/.esrd/default/capabilities.yaml` and hot-reload via mtime-gated reread (Python) + `fs_watch` (Elixir) — no esrd restart needed for grant changes.

## Functional requirements

Enumerated with the unit-test matrix in a follow-up pass during v0.3 ralph-loop enforcement. The spec's §12 acceptance criteria already cover the checklist at a coarser grain, and the e2e-capabilities.md document operationalises each one as a Track. Formalising each into an `FR-CAP-NN` entry + test ID is the next documentation step.
