# Developer Notes

Living index of findings surfaced during ESR development that are worth preserving but don't naturally fit in `spec/`, `plan/`, or `@moduledoc`. One file per topic; update this index when you add a note.

**Purpose**: capture empirical insights (API constraints, library gotchas, test-harness pitfalls, architectural debates) discovered during work. These are the "what we learned the hard way" artifacts.

---

## Index

| Topic | File | Summary |
|---|---|---|
| MuonTrap 1.7 wrapper limitation (historical) | [muontrap-mode3-constraint.md](muontrap-mode3-constraint.md) | The `muontrap` binary wrapper cannot provide stdin-write + stdout-read + cleanup-on-BEAM-exit simultaneously. Pick any two. **Superseded** by the erlexec migration — kept for context only. |
| erlexec migration (2026-04-22) | [erlexec-migration.md](erlexec-migration.md) | `Esr.OSProcess` now uses `:erlexec` instead of Port + muontrap. Native PTY + bidirectional I/O + BEAM-exit cleanup in one底座. |
| Feishu WS ownership stays in Python | [feishu-ws-ownership-python.md](feishu-ws-ownership-python.md) | FeishuAppAdapter doesn't own the WS — Python's `MsgBotClient` does, and forwards decoded events over Phoenix channel. Not planned to flip. |
| Capability name format mismatch | [capability-name-format-mismatch.md](capability-name-format-mismatch.md) | Spec uses `cap.*` dotted shape; `Grants.matches?/2` only parses `prefix:name/perm`. Resolve in PR-3 P3-8. |

---

## When to add a note here

- An empirical test revealed a library behaviour different from its docs
- A design choice has a subtle constraint that future engineers will hit
- A refactor discussion produced useful distinctions (not yet a decision — those go in spec)
- A test-harness pitfall caught us and we invented a workaround worth documenting

## When NOT to add a note

- **Spec'd decisions** → `docs/superpowers/specs/`
- **Implementation plans** → `docs/superpowers/plans/`
- **Per-PR progress** → `docs/superpowers/progress/`
- **Current code behaviour** → `@moduledoc` in the module itself
- **Planned future work** → `docs/futures/`

## Format for each note

1. **Context** — when / where the finding surfaced
2. **Observation** — what we saw (with evidence: code, test output, docs link)
3. **Implication** — what it changes for downstream work
4. **Mitigation** — how we work around it today
5. **Future** — when / how we might revisit

Notes are durable; update them when the underlying facts change, don't delete.
