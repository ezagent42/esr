# Developer Notes

Living index of findings surfaced during ESR development that are worth preserving but don't naturally fit in `spec/`, `plan/`, or `@moduledoc`. One file per topic; update this index when you add a note.

**Purpose**: capture empirical insights (API constraints, library gotchas, test-harness pitfalls, architectural debates) discovered during work. These are the "what we learned the hard way" artifacts.

---

## Index

| Topic | File | Summary |
|---|---|---|
| MuonTrap 1.7 wrapper limitation | [muontrap-mode3-constraint.md](muontrap-mode3-constraint.md) | The `muontrap` binary wrapper cannot provide stdin-write + stdout-read + cleanup-on-BEAM-exit simultaneously. Pick any two. |

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
