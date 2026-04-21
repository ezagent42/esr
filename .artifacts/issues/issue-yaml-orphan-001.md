---
type: issue
id: issue-yaml-orphan-001
status: open
producer: skill-5
created_at: "2026-04-21"
repo: ezagent42/esr
issue_number: 7
url: https://github.com/ezagent42/esr/issues/7
labels: [bug, architecture, v0.2, P0]
related: [eval-doc-002, coverage-matrix-001]
---

# GitHub Issue Reference: #7

**Title:** [Verify] YAML declarative state vs runtime reconciliation (orphan Python workers)

**URL:** https://github.com/ezagent42/esr/issues/7

**Repo:** ezagent42/esr

**Labels:** bug, architecture, v0.2, P0

## Relationship

- Generated from eval-doc `eval-doc-002` (`.artifacts/eval-docs/eval-yaml-orphan-001.md`)
- Links back to `coverage-matrix-001` (reversed scenario not yet listed in the P0 E2E gap list)

## Scope

4 orphan Python-worker scenarios, all caused by the absence of a reconciliation loop between YAML/Topology.Registry (desired state) and WorkerSupervisor (actual state):

1. **P0** — `esr cmd stop <name>` leaves Python adapter_runner / handler_worker running
2. **P0** — Topology instantiation rollback (failure recovery) doesn't clean up already-spawned Python workers
3. **P1** — Removing adapter from `adapters.yaml` + esrd restart doesn't kill obsolete Python workers
4. **P2** — Manually-spawned Python worker (no YAML entry) is accepted by AdapterSocket without authentication

## Next in pipeline

- Triage: wait for confirmation that this is accepted as a bug (not "by design")
- If accepted: → Skill 2 (test-plan-generator) converts testcases into structured test-plan
- Then: → Skill 3 (test-code-writer) writes pytest/ExUnit E2E tests
- Then: implement the reconciliation loop + `stop_*` APIs per the "修复方向" section of the eval-doc
