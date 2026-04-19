# ESR v0.1 — Ralph-Loop Prompt

This document is **the prompt** fed to Claude repeatedly by `ralph-loop` to drive Phases 1–9 of the implementation plan to completion.

- **How to start the loop:**
  ```
  /ralph-loop "$(cat docs/superpowers/ralph-loop-prompt.md)" \
    --completion-promise "ESR_V0_1_COMPLETE" \
    --max-iterations 200
  ```
- **When the loop exits:** Claude emits `<promise>ESR_V0_1_COMPLETE</promise>` — which only happens when every success gate below is green.
- **Loop state file (Claude-maintained):** `.claude/.ralph-loop.local.md`.

The remainder of this file, **everything from the `================= PROMPT BEGIN` line onward**, is the prompt text itself.

---

```
================= PROMPT BEGIN =================

You are an implementation agent working on ESR v0.1. This prompt runs repeatedly; each iteration you see your own prior work in the repo and the loop state file. Make the smallest correct step forward, then exit so the next iteration can continue. Emit the completion promise only when the Final Gate (§8 below) is green.

# 1. Ground truth documents — read these first, every iteration

Before any action, read the current state of:

| Doc | Purpose |
|---|---|
| `docs/superpowers/specs/2026-04-18-esr-extraction-design.md` | architectural decisions, normative |
| `docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md` | phase sequence + per-task TDD steps |
| `docs/superpowers/prds/01..07.md` | every FR and its required unit test |
| `docs/superpowers/tests/e2e-platform-validation.md` | E2E acceptance checkboxes per track |
| `docs/superpowers/traceability.md` | cross-reference when unsure what touches what |
| `docs/superpowers/glossary.md` | canonical term definitions |
| `CHECKLIST.md` | top-level decisions log |
| `.claude/.ralph-loop.local.md` | your own state file — updated at the end of each iteration |

Do not skip these reads. You will **not** reliably remember what you did last iteration without re-reading.

# 2. Skills to use — load when relevant

- `superpowers:test-driven-development` — every FR implemented via red/green/commit. Non-negotiable.
- `superpowers:verification-before-completion` — never claim a test passes without seeing the `PASSED` line.
- `superpowers:systematic-debugging` — when tests fail unexpectedly.
- `superpowers:requesting-code-review` — at the end of each phase boundary.
- `elixir-phoenix-helper` — **every time** you touch Elixir (`.ex`, `.exs`, `mix.exs`, `lib/esr/*`, `lib/esr_web/*`). The skill requires you to (a) check `AGENTS.md` / `CLAUDE.md` / `usage_rules.md` and (b) query Context7 for the Phoenix / Ecto / LiveView API you're about to use. **Skipping this produces deprecated 2023-era code**. No exceptions.
- `commit-work` — for crafting commit messages split by logical chunk.

# 3. Per-iteration algorithm

## 3.1 — Assess current state (max 2 minutes)

### CWD discipline (highest priority — do not skip)

This loop may be running in a Claude Code session whose **primary workdir is a different repo** (e.g. cc-openclaw). The Bash tool's persistent cwd can silently reset back to the primary at any time. Treat every Bash call as having an unknown cwd.

**HARD RULE: every single `Bash` tool call in this loop MUST begin with `cd /Users/h2oslabs/Workspace/esr && `.** No exceptions. Not even `git log`. Not even `pwd`. The cost of one extra `cd` per command is microseconds; the cost of one `git commit` in the wrong repo is hours.

Example good:
```bash
cd /Users/h2oslabs/Workspace/esr && git status
cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -50
cd /Users/h2oslabs/Workspace/esr/runtime && mix test test/esr/peer_registry_test.exs
```

Example bad (will drift):
```bash
git status                                 # cwd is whatever the tool last left it at
make test                                  # same
cd runtime && mix test                     # what if you start in the wrong root?
```

### Pre-flight (first thing, every iteration)

0. Verify the working tree is accessible and is the expected repo:
   ```bash
   cd /Users/h2oslabs/Workspace/esr && pwd && git rev-parse --show-toplevel
   ```
   Both outputs must equal `/Users/h2oslabs/Workspace/esr`. Anything else → immediately emit `<promise>BLOCKED: wrong cwd or repo</promise>` and also send a Feishu note per §3.8 and exit.

1. Read `.claude/.ralph-loop.local.md`. If it is missing or empty, initialise it (§7 schema) and commit it.
2. `cd /Users/h2oslabs/Workspace/esr && git log --oneline -n 20` — see what the last iterations accomplished.
3. `cd /Users/h2oslabs/Workspace/esr && git status` — anything uncommitted? If yes: resolve (commit or discard with explicit reason) before writing new code. Partial commits accumulate over iterations into unreviewable diffs.
4. Run the full test suite to discover current green-status:
   ```bash
   cd /Users/h2oslabs/Workspace/esr && make test 2>&1 | tail -50
   ```
   Record pass/fail counts in the state file §7.3.
5. Run `cd /Users/h2oslabs/Workspace/esr && make lint` to discover current lint status.

## 3.2 — Pick one next task

Choose the **smallest useful step** from the next unfinished FR, following phase dependency order (Phase 1 runtime has no deps; Phase 2 Python SDK has no deps; Phases 3-8 chain downstream). Within a phase, respect the DAG in plan §10.2 / the traceability table.

**Prefer the narrowest red-green-refactor bite:**
1. If the FR has no failing test: write the failing test first
2. If the FR has a failing test: implement the minimum to pass it
3. If the FR has a passing test that doesn't cover an edge case from the PRD: add the edge case

**Do not batch multiple FRs into one code change.** One FR, one test, one implementation, one commit.

If the current phase has many FRs in-flight and it is not obvious which to tackle next: pick the one with the fewest unmet dependencies (every FR has a Dependencies section — satisfy those first).

**If you find yourself about to skip ahead to a later phase because the current phase is hard**, stop and note the blocker in the state file §7.4. Do not skip phases.

## 3.3 — Execute the task

Follow the TDD steps in the plan:

1. **Write the failing test** using the exact test file path listed in the PRD's unit-test matrix and the exact test name.
2. **Run the test**; confirm it fails with the expected error (usually `UndefinedFunctionError` in Elixir or `NameError`/`AttributeError`/`ModuleNotFoundError` in Python).
3. **Write the minimum code to pass**. If you find yourself writing more than ~30 lines to pass one test, you're overshooting — break into smaller tests.
4. **Run the test**; confirm `PASSED`.
5. **Run the full test suite** to check for regressions:
   ```
   make test
   ```
6. **Run lint**:
   ```
   make lint
   ```
7. **Commit** using the `commit-work` skill:
   - Conventional commits format: `feat(<scope>): <summary>` or `test(<scope>): <summary>` or `fix(<scope>): <summary>`
   - `<scope>` is the PRD-section slug: `runtime`, `py`, `ipc`, `adapters/feishu`, `handlers/feishu_app`, `patterns`, `cli`, etc.
   - Include a Co-Authored-By footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`

## 3.4 — Elixir-specific guardrails

If this iteration touches any `.ex`, `.exs`, `mix.exs`, `lib/esr/*`, `lib/esr_web/*`:

1. **FIRST** invoke the `elixir-phoenix-helper` Skill tool to load the skill content.
2. Check for `AGENTS.md` / `CLAUDE.md` / `usage_rules.md` at repo root — obey anything found there.
3. Query Context7 for the specific Phoenix 1.8 / OTP 27 / Elixir 1.19 API you are about to use. Yes, every iteration. Yes, even for GenServer callbacks you think you know.
4. After writing the code, run the skill's "is this idiomatic?" checklist mentally before committing.
5. Run `cd runtime && mix credo --strict && mix dialyzer` — resolve any warnings, do not suppress without a comment.

## 3.5 — Python-specific guardrails

If this iteration touches any `.py` file:

1. Use type hints on every public function (`def public(x: str) -> dict:`).
2. Use `@dataclass(frozen=True)` for value types; pydantic `BaseModel` with `model_config = {"frozen": True}` for handler state.
3. Run `cd py && uv run ruff check . && uv run mypy --strict src/` — clean.
4. If you touched a handler module, run `esr-lint handlers/` (or its in-repo equivalent) — zero violations.

## 3.6 — Update the state file

Before exiting, update `.claude/.ralph-loop.local.md`:
- Which FR you just completed / advanced (tick it in §7.5)
- Current green test count
- Any new blocker observed (§7.4)
- The one you intend to tackle next iteration

Then commit the state file along with the code change (same commit).

## 3.7 — Exit (Claude tries to stop; the loop feeds the prompt back)

Do **not** issue an explicit exit. Simply finish your response. The stop hook sees no `<promise>` tag and re-feeds this prompt.

Unless §8 gate is met — see below.

## 3.8 — Feishu progress reporting

The user is watching progress from Feishu (chat_id `oc_d9b47511b085e9d5b66c4595b3ef9bb9`). **Report only on meaningful state changes**, not every iteration — spamming Feishu is worse than silence. Emit a reply via `mcp__openclaw-channel__reply` when any of the following holds:

- **Phase boundary**: starting or finishing a Phase (1 → 2 → 3 → …). One line each: `▶ starting Phase N` or `✓ Phase N done (X FRs, Y tests green)`.
- **Blocker**: emitted the `<promise>BLOCKED: …</promise>` tag. Include: phase, FR, symptom, evidence link (commit SHA + test name), and the specific question for the user.
- **Unexpected regression**: a previously-green test now fails. Include: test name, what this iteration changed, whether you're investigating.
- **Big milestone**: first live IPC round-trip (Phase 3), first adapter instance registered (Phase 4), first handler round-trip (Phase 5), first pattern instantiation (Phase 6), first E2E track passing (Phase 8), all E2E tracks passing (Phase 8 complete), loop completion.
- **Every 20 iterations**: a brief heartbeat with current phase + FR count.

Each Feishu message is ≤ 4 short sentences. Longer analysis goes in the state file or a dedicated log commit.

Example messages:

```
✓ Phase 1 done: 22 FRs, 78 tests green; moving to Phase 2.
▶ Phase 3 IPC: first handler_call round-trip succeeded — commit 4e2a1f.
⚠ heartbeat: iter 40/200, Phase 4 (adapters/feishu), 4/22 FRs green. No blockers.
🛑 BLOCKED at Phase 5 F12: dedup test fails intermittently. Investigated 6 times. Hypothesis: frozenset iteration order.
```

If the MCP tool call itself fails (channel down, timeout), log the attempt in the state file §7.7 "Feishu reporting log" and continue the iteration — do not let a notification failure block work.

### If MCP channel is unavailable

If `mcp__openclaw-channel__reply` is not listed among available tools this iteration (meaning: this loop is running in a session without the channel MCP loaded), skip Feishu reporting silently and note "feishu unavailable" in state file §7.7. The loop continues in pure commit-history-only mode; the user can track progress via `git log`.

# 4. Ordering (high-level phase sequence)

Work bottom-up along the DAG in plan §10.2:

```
Phase 0, 0B: complete  ← already done in inline mode
            │
            ▼
Phase 1 Elixir Runtime  ──┐
                          │
Phase 2 Python SDK    ────┼──▶ Phase 3 IPC ──▶ Phase 4 Adapters ──┐
                          │                   Phase 5 Handlers  ──┤
                          │                                       ▼
                          │                     Phase 6 Patterns ──▶ Phase 7 CLI ──▶ Phase 8 E2E ──▶ Phase 9 Doc recon
                          ▼
         (Phase 7 CLI read-only parts can start once Phase 2 is usable)
```

Work rules:

- Phase 1 and Phase 2 have no cross-dependency — a single iteration can pick from either.
- Phase 3 depends on Phase 1 (Elixir side) + Phase 2 (Python side); don't start it until both are at least at skeleton level (F01–F05 in each).
- Phases 4 + 5 depend on Phase 3.
- Phase 6 depends on Phase 5 + Phase 4 installed.
- Phase 7 depends on Phase 2 for read-only parts and Phase 3 for runtime-talking parts.
- Phase 8 only runs when every prior phase is green.
- Phase 9 (doc reconciliation) can run any time after Phase 8.

# 5. Blocker handling — do NOT loop forever

If on any single iteration you:
- Cannot find a non-obvious next action
- Hit a test that has failed >5 times with different approaches
- Find a spec/PRD contradiction you cannot resolve

...then **do not guess**. Update `.claude/.ralph-loop.local.md` §7.4 Blocker section with:

```
### Blocker (observed <timestamp>)
**Symptom:** <what you tried, what went wrong>
**Evidence:** <commands run + outputs; test names; line numbers>
**Hypothesis:** <best guess what's wrong with the spec or the plan>
**Needs human:** <specific question the user must answer>
```

…and still exit normally (no `<promise>` emitted). The loop continues; subsequent iterations see the blocker and skip the problem area, working on unblocked FRs. If every remaining FR is blocked, the state file becomes a pure blocker list and the next iteration should write a summary and emit `<promise>BLOCKED: <short-reason></promise>` to alert the user. Use `BLOCKED:` prefix, not the completion promise.

# 6. Code-review checkpoint rule

After finishing **every phase** (i.e. every FR in a PRD is green + acceptance boxes in that PRD are ticked), dispatch a **scoped** code reviewer subagent via the `superpowers:requesting-code-review` skill:

- Scope: only the files touched in that phase.
- Input to the reviewer: the corresponding PRD + the glossary + (for Elixir) the elixir-phoenix-helper references.
- If the reviewer reports any **critical** or **significant** finding: treat it as a blocker for that phase's completion. The next iterations address the findings before advancing to the next phase.
- Minor / polish findings: add to a `REVIEW_FOLLOWUPS.md` file and fix in a bulk pass before Phase 8.

# 7. Loop state file schema

`.claude/.ralph-loop.local.md` layout — replace it fully each iteration (don't accumulate stale content):

```markdown
# ESR v0.1 Ralph Loop State

**Last iteration:** <ISO timestamp>
**Current phase:** <1..9 or "phase-boundary-review">
**Current focus:** <PRD-FR-id, e.g. "PRD 01 F07 action dispatch">

## 7.1 Test counts (from last `make test`)

- Elixir (`mix test`): <pass> passed / <fail> failed / <excl> excluded
- Python (`pytest`): <pass> passed / <fail> failed / <skip> skipped
- Lint (`make lint`): <clean|N issues>

## 7.2 E2E scenario status

- Track A: ☐ pending
- Track B: ☐ pending
- …
- Track H: ☐ pending

(Tick on full pass; re-mark pending on any regression.)

## 7.3 FR checklist

Copy-paste from each PRD's unit-test matrix; tick when test passes.

### PRD 01 — Actor Runtime (22 FRs)
- [x] F01 project scaffold
- [x] F02 supervision tree
- [ ] F03 PeerRegistry  ← current
- …

### PRD 02 — Python SDK (19 FRs)
- …

…through PRD 07.

## 7.4 Blockers

(Empty when unblocked. Use the format in §5.)

## 7.5 Next action (explicit)

"Next iteration, <do X>. File: <path>. Test: <test name>."

## 7.6 Phase completion boundary reviews

- [ ] PRD 01 full-phase review
- [ ] PRD 02 full-phase review
- …

## 7.7 Feishu reporting log

- <iso ts>  <phase>  <what-was-reported>
- <iso ts>  feishu unavailable — skipped
- …
```

# 8. Final Gate — emit `<promise>ESR_V0_1_COMPLETE</promise>` **only** when all these hold

Verify each, with evidence, in your final iteration's response:

1. **`make test` green** — both Elixir (`mix test`) and Python (`uv run pytest`) report zero failures.
2. **Every PRD unit-test matrix test file and test name exists** and passes. Use this shell loop to cross-check:
   ```bash
   # For each PRD, extract the matrix and assert every listed test exists in the test output.
   # (To be implemented as scripts/verify_prd_matrix.py in Phase 2.)
   uv run python scripts/verify_prd_matrix.py
   # Expected exit 0 with "all 127 FR tests located and passed"
   ```
3. **`make lint` clean** — `ruff check`, `mypy --strict`, `mix credo --strict`, `mix dialyzer` all report no issues.
4. **E2E all 8 tracks pass**:
   ```bash
   esr scenario run e2e-platform-validation
   # Expected: "8/8 tracks PASSED; aggregate gate: PASSED"
   ```
5. **Full subagent code review** (from the Post-Implementation Review section of the plan) reports **zero critical** and **zero significant** findings. Minor findings are documented in `REVIEW_FOLLOWUPS.md` and deferred.
6. **All PRD-level acceptance checklists ticked** in `docs/superpowers/prds/*.md`.
7. **Phase 9 (doc reconciliation) commits exist** — the three notes from plan Phase 9 Tasks 9.1/9.2/9.3 appear in `git log`.

Only when all seven conditions are verified: emit, in your final response, the single line:

`<promise>ESR_V0_1_COMPLETE</promise>`

Do not emit this tag speculatively. Verify, then emit.

# 9. Anti-patterns — do NOT do these

These are the ralph-loop specific ways this project will fail if you are careless:

- **Writing code without reading the PRD FR first.** The PRDs are the specification. If the PRD says "PRD 01 F06 tests `inbound_event triggers HandlerRouter.call`," that exact test name must exist in `runtime/test/esr/peer_server_test.exs`. Drifting test names and file paths makes the matrix untracable.
- **Skipping the elixir-phoenix-helper skill activation** when touching Elixir. Phoenix 1.8 changed things (Scopes, Layouts, channel API); writing 1.7-style code creates silent-wrong output.
- **Claiming test success without running the test.** Always capture the actual test output. "I think this passes" is a ralph-loop killer.
- **Committing with lint errors.** Every commit must pass `make lint`. A chain of "fix lint" commits after the fact is noise.
- **Batching multiple FRs into one commit.** One FR = one commit. If you find yourself writing `feat: implement F01, F02, F03` — stop, split.
- **Suppressing dialyzer / credo warnings** without a comment explaining why. If suppression is genuinely needed, add `# credo:disable-for-next-line Credo.Check.XXX` with a one-line justification.
- **Modifying a spec/PRD/plan to match the code** instead of the other way around. The specs are the source of truth. If the spec is wrong, it becomes a **blocker** (§5) until the user resolves.
- **Skipping the state file update.** Without it, the next iteration has no memory of what you just did.
- **Writing new tests inline while implementing — without letting them fail first.** TDD requires seeing the red. A test that "looks right" but has never failed is not a guarantee the code under test produces the expected output.
- **Introducing files outside the paths listed in PRDs / plan.** If you need a new file, the PRD should have declared it. If not: update the PRD first (blocker if the user hasn't reviewed), then add the file.

# 10. Operational notes

- **Working directory:** `/Users/h2oslabs/Workspace/esr/`. Use absolute paths in all commands to avoid the usual "wrong repo" hazard.
- **Python via `uv`:** never call `python` or `python3` directly — the repo's hooks block it. Always `uv run python …`.
- **Elixir via Mix:** from `runtime/`: `mix deps.get`, `mix test`, `mix credo --strict`, `mix dialyzer`.
- **Commit message Co-Authored-By line:** `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` (exactly this, on its own line in the commit body).
- **No pushing:** `git push` is never run inside the loop. Pushing is a user action once the loop emits its completion promise.
- **Feishu notifications:** if you need the user's input on a blocker, you cannot message Feishu from inside the loop (the MCP channel belongs to the human session, not subagents). Write the blocker into the state file §7.4 and emit `<promise>BLOCKED: …</promise>` so the loop exits and surfaces it to the user.

# 11. First-iteration bootstrapping

If `.claude/.ralph-loop.local.md` does not exist, this is iteration 1. Initialise it per §7:

1. Copy the test-count placeholders (all zero).
2. Seed the FR checklist by reading each PRD's unit-test matrix and listing every FR as `- [ ] <FR-id> <short-summary>`.
3. Seed the E2E track list as all ☐ pending.
4. Set "Current phase" = 1, "Current focus" = PRD 01 F01.
5. "Next action" = "Run `mix phx.new runtime ...` per plan Task 1.1 Step 1."
6. Commit the initial state file as `chore: initialise ralph-loop state file`.

Then in the same iteration, perform Task 1.1 Step 1.

================= PROMPT END =================
```

---

## Notes for the user (not part of the prompt itself)

### How to start — two supported modes

**Mode A — current session (recommended when you want Feishu progress reports)**

Run the loop in the Claude Code session that has the `openclaw-channel` MCP loaded (your daily cc-openclaw session, for example). Pros: §3.8 Feishu progress messages reach you in real time. Cons: the session's primary workdir is a different repo, so every Bash command in the loop MUST begin with `cd /Users/h2oslabs/Workspace/esr && …` — this discipline is already hard-coded into §3.1 of the prompt.

Invocation:

```
/ralph-loop "$(cat /Users/h2oslabs/Workspace/esr/docs/superpowers/ralph-loop-prompt.md)" \
  --completion-promise "ESR_V0_1_COMPLETE" \
  --max-iterations 200
```

**Mode B — dedicated esr-rooted session (recommended for strict isolation)**

Run the loop in a fresh Claude Code session whose primary workdir is `/Users/h2oslabs/Workspace/esr/`. Pros: impossible to drift into the wrong repo. Cons: no Feishu channel → §3.8 reports are silently skipped; you monitor via `git log`.

Invocation:

```bash
# Separate terminal
cd /Users/h2oslabs/Workspace/esr
./esr-cc.sh
# Inside the new session:
/ralph-loop "$(cat docs/superpowers/ralph-loop-prompt.md)" \
  --completion-promise "ESR_V0_1_COMPLETE" \
  --max-iterations 200
```

**Which mode should I use?**

Prefer Mode A. The CWD discipline is explicit in the prompt and the guards in §3.1 catch any drift before it touches git; the Feishu visibility is genuinely useful across 17-hour runs. Use Mode B only if you're stress-testing the architecture isolation or running on a box where the Feishu MCP is unreliable.

**Common to both modes:**

- `--max-iterations 200` is a safety valve; at ~5 minutes per iteration the loop caps at ~17 hours wall-clock if it can't converge.
- Interrupt anytime with `/cancel-ralph`; progress is preserved in commit history + state file.
- In Mode A you can still chat with me (this session's Claude) in between loop iterations — the loop fires one prompt per stop-hook cycle, so your interjections land between iterations, not during.

### How to monitor

- `git log --oneline -n 50` — see iteration progress
- `cat .claude/.ralph-loop.local.md` — current state
- `make test` at any time — independent confirmation of green-status

### If the loop emits `<promise>BLOCKED: ...</promise>`

- Read the blocker section in the state file
- Resolve (update spec/PRD/plan, or add a clarifying note the next iteration will see)
- Restart the loop — it will re-read the state file and pick up where it left off

### If the loop emits `<promise>ESR_V0_1_COMPLETE</promise>`

- Verify manually: `make test && make lint && esr scenario run e2e-platform-validation`
- Review the last 20-30 commits for style / coherence
- Run the full subagent code review one more time independently (the loop runs it, but a fresh look can surface things the loop's own reviewer missed)
- Merge to main when satisfied

---

*End of ralph-loop prompt document.*
