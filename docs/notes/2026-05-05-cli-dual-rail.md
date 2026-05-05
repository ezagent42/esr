# e2e CLI rail history (Phase A → C — 2026-05-05)

**Status:** Phase C deleted the Python rail. `runtime/esr` (Elixir
escript) is the canonical operator CLI; `esr_cli` in common.sh is now
escript-only. The dual-rail history below is preserved as the record
of how the migration was verified.

## Why this exists

Pre-Phase-A every e2e scenario invoked the Python CLI directly:

```bash
uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit ...
```

— 27 sites across 8 scenario scripts. The "escript replaces Python CLI"
claim shipped in Phase 2 (PR-2.5/2.6 escript build) had **zero e2e
coverage**. We could merge "Phase 2 done" while the escript covered
none of the surface that operators actually use.

The dual-rail pattern fixes that. The same e2e assertions run via
either rail; a failing escript rail tells us exactly which commands
need porting before PR-4.6 / PR-4.7 (Python CLI deletion) can land.

## How it works

`tests/e2e/scenarios/common.sh` exports a single helper:

```bash
esr_cli() {
  if [[ "${RUN_VIA:-python}" == "escript" ]]; then
    # Reads ${ESRD_HOME}/${ESR_INSTANCE}/esrd.port; sets ESR_HOST.
    # Falls back to 127.0.0.1:4001 if the port file is absent.
    ESR_HOST="..." "${_E2E_REPO_ROOT}/runtime/esr" "$@"
  else
    uv run --project "${_E2E_REPO_ROOT}/py" esr "$@"
  fi
}
```

Scenarios call `esr_cli admin submit foo --arg bar=baz` instead of
the explicit `uv run` form. The same assertions (`assert_contains
"$OUT" "ok: true"`) compare the Python rail's output today and the
escript rail's output post-migration.

Make targets:

| Target | What it runs |
|---|---|
| `make e2e` | All scenarios on Python rail (default — preserves the pre-Phase-A baseline). |
| `make e2e-cli` | CLI-touching scenarios (08 + 11) on whichever `RUN_VIA` selects. |
| `make e2e-escript` | `RUN_VIA=escript make e2e-cli` shortcut. |

## Two-phase migration discipline

Per user 2026-05-05: every code-composition migration must show
e2e green at **both** ends:

1. **Phase A — gate exists.** Same e2e, RUN_VIA toggle reveals which
   commands the new rail can't handle. Today: most are red.
2. **Phase B — fill the gaps.** Each PR adds one slash-route family
   (`/actors`, `/cap`, `/users`, `/reload`, …) until the escript rail
   matches the Python rail assertion-for-assertion.
3. **Phase C — delete the old rail.** Once `RUN_VIA=escript make e2e`
   is fully green, switch e2e default to escript-only and delete
   `py/src/esr/cli/`. Until then, the Python rail stays — it is the
   baseline that proves we haven't regressed user-visible behavior.

Each migration PR's description must answer:

- **Surface change?** Y/N. If Y, list new e2e assertions added.
- **Code path change under same e2e?** Path moved from A → B.
- **Dual-rail evidence:** e2e was green on Python rail before, green
  on escript rail after. The unchanged-assertion + changed-rail IS
  the migration proof.

## Expected escript-rail failures today

Without running the suite (the actual sweep happens in the PR's CI
section), the predicted red set:

1. **`esr actors list`** — used by scenarios 01, 02, 04, 05. The
   escript has no `actors` command and no `/actors` slash route.
   Closes via Phase B-1.
2. **`admin submit X` output format mismatch** — escript renders
   `"ok: " <> Jason.encode!(result)` whereas Python emits multi-line
   YAML (`ok: true\nsession_id: ...`). Assertions like
   `assert_contains "$OUT" "ok: true"` may pass or fail depending on
   exact substring. Phase B-1 standardises.
3. **`admin submit help`** (e2e 08) — escript exec path uses HTTP
   schema dump for `help`, but the queue-file dispatch for
   `admin submit help` may not produce the expected `ok: true`
   envelope. Will surface in CI. Phase B-1 audits.

The point of the PR isn't to fix these. The point is to make them
**measurable**. Phase B PRs each turn one assertion green.

## Phase progression (2026-05-05 autonomous run)

| Phase | PR | Outcome |
|---|---|---|
| A   | #211 | dual-rail switch + `RUN_VIA={python,escript}` toggle |
| B-1 | #212 | escript `render_result/1` aligned to Python YAML envelope; `/actors` slash route |
| D-1 | #213 | deleted hardcoded `StatefulRegistry.register/1` fallbacks; Loader is canonical |
| B-2 | #214 | escript click-style flag parser + `/cap {list,show,who-can,grant,revoke}` |
| B-3 | #215 | `/users {list,add,remove,bind-feishu,unbind-feishu}` + `user.manage` permission |
| C   | #216 | **deleted `py/src/esr/cli/`** + `[project.scripts] esr` entry; e2e default rail flipped to escript-only |

After Phase C `esr_cli` rejects `RUN_VIA=python` with a hard error so
a stale CI config can't silently degrade.

## Files touched

- `tests/e2e/scenarios/common.sh`: added `esr_cli()` helper, switched
  `assert_actors_list_*` + `register_feishu_adapter` helpers.
- `tests/e2e/scenarios/{01,02,04,05,08,11}*.sh`: 27 inline calls
  switched to `esr_cli`.
- `Makefile`: added `e2e-08`, `e2e-11`, `e2e-cli`, `e2e-escript`.
- This note.

## Reference

- Memory rule (2026-05-05): "Completion claim requires invariant
  test." Multi-PR phase isn't done because PRs merged — it's done
  because a test fails when the goal is unmet. Dual-rail is the
  test for "Python CLI replacement complete".
- North Star: plugin isolation. The escript dispatching purely via
  slash routes (no plugin-name hardcoding) directly serves the goal
  of "future devs work on different plugins without coordination."
