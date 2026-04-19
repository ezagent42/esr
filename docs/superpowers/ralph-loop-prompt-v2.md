# ESR v0.1 Phase 8 — Ralph-Loop Prompt v2.1

This document is **the prompt** fed to Claude repeatedly by `ralph-loop` to drive Phase 8 live integration to completion. It supersedes `ralph-loop-prompt.md` (v1), which was gamed. See `docs/superpowers/specs/2026-04-19-ralph-loop-prompt-v2-design.md` (v2.1) for design rationale and `docs/superpowers/plans/2026-04-19-ralph-loop-prompt-v2-implementation.md` for the pre-loop infrastructure plan.

**Start invocation (from repo root):**

```
/ralph-loop "$(cat docs/superpowers/ralph-loop-prompt-v2.md)" \
  --completion-promise "ESR_V0_1_COMPLETE" \
  --max-iterations 300
```

**Loop-exit condition:** Claude emits `<promise>ESR_V0_1_COMPLETE</promise>` — and only after `scripts/final_gate.sh --live` exits 0 with the 4-artifact nonce correlation (spec §4.1.1). The loop runs `--live` itself; no manual step after.

---

```
================= PROMPT BEGIN =================

You are an implementation agent working on ESR v0.1 Phase 8 live integration.
This prompt runs repeatedly; each iteration you see your own prior work in the
repo and the ledger file.

# 1. Ground truth (read every iteration)

| Doc | Purpose |
|---|---|
| `docs/superpowers/specs/2026-04-19-ralph-loop-prompt-v2-design.md` | normative v2.1 design |
| `docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md` (§Phase 8) | subphase 8a-8f |
| `docs/superpowers/prds/0[1-7]-*.md` | unit FR definitions (unchanged from v1) |
| `docs/superpowers/prds/acceptance-manifest.yaml` | normative acceptance rows (LG-5) |
| `docs/ralph-loop-ledger.md` | evidence trail (append-only) |

Do not skip these reads.

# 2. Skills

- `superpowers:test-driven-development` — non-negotiable per FR
- `superpowers:verification-before-completion` — capture output before claiming PASS
- `superpowers:systematic-debugging` — on unexpected failure
- `superpowers:requesting-code-review` — at phase 8c and 8e boundaries
- `elixir-phoenix-helper` — every time you touch Elixir
- `commit-work` — conventional commits

# 3. Per-iteration algorithm

## 3.1 — CWD discipline

**HARD RULE: every Bash call MUST begin with `cd /Users/h2oslabs/Workspace/esr && `.**
Even `pwd`. Even `git log`. The v1 loop drifted into other repos.

Pre-flight:
```bash
cd /Users/h2oslabs/Workspace/esr && pwd && git rev-parse --show-toplevel
# both must equal /Users/h2oslabs/Workspace/esr
```

## 3.1b — Loopguard (blocking)

**Every iteration, right after pre-flight:**
```bash
cd /Users/h2oslabs/Workspace/esr && bash scripts/loopguard.sh
```
Exit 0 → proceed. Non-zero → emit `<promise>BLOCKED: loopguard:LG-<id></promise>`, stop.

## 3.2 — Pick the smallest next task

Work bottom-up: 8a (IPC activation, the F13 run() entries) → 8b (esrd daemon) → 8c (CLI `_submit_*` wiring) → 8d (mock_feishu.py, mock_cc.py) → 8e (scenario e2e-feishu-cc live-green in mock mode) → 8f (loop runs final_gate.sh --live autonomously; spec §4.1.1 4-artifact nonce check).

One FR per commit. Prefer the narrowest red-green-refactor bite.

## 3.3 — TDD for the task

1. Write the failing test with the exact file path the PRD unit-test matrix lists.
2. Run the test; confirm the expected failure.
3. Write minimum code to pass.
4. Run the test; confirm PASS.
5. Run `make test` to check for regressions.
6. Run `make lint`.
7. Commit (conventional-commits; include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).

## 3.4 — Elixir guardrails (when touching .ex / .exs / mix.exs / runtime/lib/)

1. Invoke the `elixir-phoenix-helper` Skill tool.
2. Check `AGENTS.md` / `CLAUDE.md` / `usage_rules.md` at repo root.
3. Query Context7 for the Phoenix 1.8 / OTP 27 / Elixir 1.19 APIs you will use.
4. `cd runtime && mix credo --strict && mix dialyzer` — clean.

## 3.5 — Python guardrails (when touching .py)

1. Type hints on every public function.
2. `@dataclass(frozen=True)` for value types; pydantic frozen for handler state.
3. `cd py && uv run ruff check . && uv run mypy --strict src/` — clean.

## 3.6 — Append to ledger (not state file)

Before committing, append a row via:
```bash
cd /Users/h2oslabs/Workspace/esr && uv run --project py python scripts/ledger_append.py \
    --ledger docs/ralph-loop-ledger.md \
    --phase <8a..8f> --fr <FR-id> \
    --evidence-type <enum-value-from-spec-§4.4>
```
Evidence-type values: unit_tests, prd_matrix, loopguard, scenario_mock,
final_gate_mock, prd_acceptance, ledger_check. The script captures the mapped
command's output, sha256s it, and writes a row.

## 3.7 — Exit (loop feeds prompt back)

Do not issue an explicit exit. Finish your response. The stop hook re-feeds
this prompt.

Only emit `<promise>ESR_V0_1_COMPLETE</promise>` when §7 Final Gate (all
8 conditions including `--live`) is green.

## 3.8 — Feishu progress reporting

Report via `mcp__openclaw-channel__reply` to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`
ONLY on:
- Phase boundary: `▶ Phase 8<a-f> start` / `✓ Phase 8<a-f> done`
- Blocker (`<promise>BLOCKED: ...</promise>` emitted)
- Regression (previously-green test now red)
- `ESR_V0_1_COMPLETE` emission — `final_gate.sh --live` itself posts the
  success summary to the test chat (nonce, message_ids, round-trip time).
  No separate MCP reply needed.

- Every 30 iterations: heartbeat (phase, FR count, blockers).

If the MCP channel tool isn't available this iteration, skip silently.

# 4. Phase 8 subphase ordering

8a → 8b → 8c → 8d → 8e → 8f. Don't skip ahead unless the current subphase
has a genuine blocker (in which case log it in the ledger and the state
of the iteration).

# 5. Blockers

Format per spec §5 / v1 §5. If you emit `<promise>BLOCKED: ...</promise>`,
the loop exits and surfaces it to the user. Do NOT self-repair a loopguard
tamper signal (LG-4 / LG-11) — leave it, exit.

# 6. Review checkpoints

After 8c green and after 8e green, dispatch a scoped code reviewer via
`superpowers:requesting-code-review`. Critical/Significant findings are
blockers for the next subphase.

# 7. Final Gate — emit ESR_V0_1_COMPLETE only when all 8 hold

| # | Condition | Command | Expected output |
|---|---|---|---|
| 1 | Unit tests | `make test` | `N passed, 0 failed` (py and ex) |
| 2 | PRD matrix | `uv run --project py python scripts/verify_prd_matrix.py` | `all N FR tests located` |
| 3 | Loopguard | `bash scripts/loopguard.sh` | `all 11 loopguard checks passed` |
| 4 | Scenario mock | `uv run --project py esr scenario run e2e-feishu-cc` | `8/8 steps PASSED against live esrd (mock Feishu)` |
| 5 | Final gate mock | `bash scripts/final_gate.sh --mock` | `FINAL GATE MOCK PASSED` |
| 6 | Ledger | `uv run --project py python scripts/verify_ledger_append_only.py` | `ledger integrity OK — N iterations, 0 in-place edits` |
| 7 | PRD acceptance | `uv run --project py python scripts/verify_prd_acceptance.py --manifest docs/superpowers/prds/acceptance-manifest.yaml` | `all N Acceptance items ticked` |
| 8 | **Final gate LIVE** (v2.1) | `bash scripts/final_gate.sh --live` | `FINAL GATE LIVE PASSED — nonce=SMOKE-XXXXXXXX; round-trip observed in Ns` |

Only when all 8 are green: emit `<promise>ESR_V0_1_COMPLETE</promise>`.
`--live` is autonomous (spec §4.1.1 4-artifact nonce check); no manual
step required after.

# 8. Anti-patterns (how v1 failed — do not repeat)

- Do NOT replace a scenario step's `command:` with `covered_by:` — LG-1.
- Do NOT write `raise NotImplementedError` in an entry point — LG-2.
- Do NOT write an empty body for `run()` or any `_submit_*` — LG-2 (AST).
- Do NOT add "deferred" / "manual step" / "post-install" in a PRD acceptance
  row — LG-3.
- Do NOT modify `final_gate.sh` or any loopguard helper — LG-4 / LG-11.
- Do NOT delete an acceptance row to avoid ticking it — LG-5.
- Do NOT add a file to scenarios/ — LG-6.
- Do NOT edit an old ledger row in place — LG-7.
- Do NOT add @pytest.mark.skip / @tag :skip — LG-8.
- Do NOT write CLI tests that skip esrd_fixture — LG-9.
- Do NOT monkeypatch `_submit_*` in tests — LG-10.

# 9. Operational notes

- Working dir: `/Users/h2oslabs/Workspace/esr/`.
- Python via `uv run --project py` (hook blocks bare python/python3; pyyaml is in py/).
- Elixir via `cd runtime && mix ...`.
- Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Never `git push` from the loop.
- Feishu notification: §3.8.

================= PROMPT END =================
```
