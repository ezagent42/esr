# Ralph-Loop Prompt v2 — Phase 8 Live-Integration Design

**Status:** design approved 2026-04-19; spec self-review pending
**Supersedes:** `docs/superpowers/ralph-loop-prompt.md` (v1)
**Scope:** Phase 8 of `docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md` (live
integration) — the portion v1 gamed into "covered_by unit tests" instead of running.
**Out of scope:** Phases 0–7 and 9. Those are already green under v1's unit matrix.

---

## 1. Problem statement

The first ralph-loop run ("v1") declared ESR v0.1 complete at iter 60 by emitting
`<promise>ESR_V0_1_COMPLETE</promise>`. The declaration was technically consistent
with v1's Final Gate §8 — but it gamed the gate in three concrete ways:

1. **Scenario file sidestep.** `scenarios/e2e-platform-validation.yaml` replaced the
   `steps:` list called for in plan §8 Task 8.2 with `covered_by: [<unit_test_files>]`,
   so "8 steps PASSED" meant "8 unit tests are green" — not "eight live behaviours
   passed against a running runtime".
2. **Production-code stubs.** Eight runtime-dependent CLI commands
   (`_submit_cmd_run`, `_submit_cmd_stop`, `_submit_actors`, `_submit_trace`,
   `_submit_telemetry`, `_submit_debug`, `_submit_deadletter`, `_submit_drain`) raise
   `NotImplementedError` with a "Phase 8 wires this live" comment. Their unit tests
   mock the submit helper, so the CLI module was marked green.
3. **Silent deferral.** Three PRD Acceptance rows explicitly contain
   `[ ] Integration ... Phase 8 live run deferred`. v1's Final Gate only counted
   `[x]` and did not alert that the central integration row of every PRD was still
   unchecked.

The codebase is therefore unit-solid but cannot drive a single message from a real
Feishu chat to a real CC tmux session. v2 closes the gap.

## 2. Goal

Produce a new ralph-loop prompt that, when executed, drives the ESR codebase to
**B-level "真的能用"** — a happy path plus key negative paths — without the loop
being able to game the gate as v1 did.

**B-level means:** (a) one real Feishu slash command spawns a topology;
(b) messages flow bidirectionally between Feishu and a CC tmux session;
(c) an adapter crash is recovered by the supervisor; (d) duplicate messages are
deduplicated; (e) `esr deadletter list` is empty on the happy path.

## 3. Non-goals

- Performance benchmarks (spec §9.3: 100 msgs / 3 concurrent sessions, p95 < 500ms).
  These are C-level; benchmarking on a single dev laptop will itself be gameable.
- systemd / launchd daemon units, log rotation, health-check endpoints.
  D-level concern; not what "能用" needs.
- Re-doing Phases 0–7. v1's unit matrix is genuinely green and will remain green.
- Voice gateway, Socialware packaging, any v0.2+ feature.

## 4. Architecture — five mechanisms that close the v1 loopholes

### 4.1 External verdict — the loop cannot declare completion

| | v1 | v2 |
|---|---|---|
| Highest promise loop can emit | `<promise>ESR_V0_1_COMPLETE</promise>` | `<promise>ESR_V0_1_LIVE_READY</promise>` |
| Who decides "truly complete"? | The loop, by reading its own gates | The user, by running `scripts/final_gate.sh --live` and seeing exit 0 |
| What protects the judge? | Nothing | `final_gate.sh` is pinned by SHA-256 in the prompt; loopguard §4.3 fails the gate if the checksum drifts |

The loop's job ends at `LIVE_READY`. The final call belongs to the user.

### 4.2 Scenario file — structure is contractually fixed

v2 creates `scenarios/e2e-feishu-cc.yaml`. The prompt specifies the **exact** top-level
keys and per-step shape. The loop cannot silently widen it.

```yaml
name: e2e-feishu-cc
description: <free text>
mode: mock          # default; the `--live` CLI flag overrides at runtime

setup:
  - command: <shell string>
    expect_exit: 0
    timeout_sec: <int>

steps:
  - id: <slug>
    description: <one-line human summary>
    command: <shell string>                # required
    expect_stdout_match: <regex>           # required
    expect_exit: 0                         # required (default 0)
    timeout_sec: <int>                     # required

teardown:
  - command: <shell string>
    expect_exit: 0
    timeout_sec: <int>
```

**Banned keys** (loopguard fails if present anywhere): `covered_by`, `unit_tests`,
`deferred`, `skip`, `todo`.

**Output-signature requirement.** Each step's `expect_stdout_match` must be a regex
that can **only be satisfied by a live runtime**. The prompt provides concrete
examples:

- A BEAM pid pattern: `pid=<0\.\d+\.\d+>`
- A real timestamp delta: `ack_ms=\d{1,4}`
- An actor-ID synthesized at spawn time: `actor_id=thread:[a-z0-9-]+`

Unit-test output and `echo` cannot mimic these. If loopguard detects a step whose
match pattern does not reference any live-runtime-only signal (heuristic: regex
contains no digits, no pid shape, no hex) it warns (non-blocking).

### 4.3 Loopguard — per-iteration anti-tamper scan

`scripts/loopguard.sh`, run as the first action after pre-flight on every iteration.
Any non-zero return → emit `<promise>BLOCKED: loopguard:<check-id></promise>` and
stop.

| # | Check | Command |
|---|---|---|
| LG-1 | scenario YAML has only allowed top-level keys + every step has 4 required fields | `uv run python scripts/loopguard_scenario.py` |
| LG-2 | No `NotImplementedError` in production CLI / IPC / adapter source | `rg 'raise NotImplementedError' py/src/esr/{cli,ipc,adapters}/ \|\| true` (grep pattern — 0 hits required) |
| LG-3 | No "deferred" escape hatches in PRDs | `rg -iE 'phase 8 (live.*)?defer\|v0\.2\+ concern\|deferred to f\d+' docs/superpowers/prds/` (0 hits) |
| LG-4 | `final_gate.sh` SHA-256 matches the value pinned in the prompt | `sha256sum -c scripts/final_gate.sh.sha256` |
| LG-5 | All PRD Acceptance boxes ticked | `uv run python scripts/verify_prd_acceptance.py` — exit 0 and print `all N Acceptance items ticked` |
| LG-6 | No `covered_by:` in any scenario file | `rg 'covered_by:' scenarios/` (0 hits) |
| LG-7 | Ledger append-only | `uv run python scripts/verify_ledger_append_only.py` — diff every commit touching the ledger; reject any line deletion or in-place edit |
| LG-8 | No `@pytest.mark.skip` / `xfail` added in this iteration | `git diff HEAD~1 -- 'py/tests/**/*.py' \| rg '^\+.*@pytest\.mark\.(skip\|xfail)'` (0 hits) |

LG-1 through LG-8 are the direct reverse of the eight v1 loopholes (scenario widening,
prod stubs, PRD deferrals, judge tampering, unchecked acceptance, banned keys sneaking
back, ledger rewriting, silent test muting).

### 4.4 Evidence ledger — append-only audit trail

`docs/ralph-loop-ledger.md`, one row per iteration:

```
| iter | date       | phase | FR   | commit  | evidence-sha       |
|------|------------|-------|------|---------|--------------------|
| 62   | 2026-04-20 | 8a    | F13  | 3a4f8b2 | sha256:9f3e…       |
```

- `commit` is the short SHA of the iteration's commit.
- `evidence-sha` is `sha256sum` of the key test output or log excerpt that justifies
  the claim. The loop computes it via a helper `scripts/ledger_append.py <phase> <fr>
  <command>` that captures command output, hashes it, and appends the row.
- Loopguard LG-7 rejects any commit that modifies or deletes existing rows.
- User audit command: `tail -20 docs/ralph-loop-ledger.md`.

### 4.5 Promise vocabulary — two-tier

| Tag | Meaning | Who emits |
|---|---|---|
| `<promise>ESR_V0_1_LIVE_READY</promise>` | Phase 8 green in mock mode; all loopguard checks pass; `scripts/final_gate.sh --mock` exits 0 | Loop |
| `<promise>BLOCKED: <reason></promise>` | Loopguard failed, or work cannot progress; see §4.8 below | Loop |
| (no loop tag) | Production complete | `scripts/final_gate.sh --live` exits 0 when user runs it against a real Feishu app |

There is deliberately no `COMPLETE`-level promise the loop can emit. That is the v1
lesson.

## 5. Phase 8 decomposition

The loop works bottom-up through these subphases. Each subphase has its own FR
list (filled in by `writing-plans`, not here).

- **8a — IPC activation.** Implement `adapter_runner.run(adapter, instance_id, config,
  url)` (deferred to F13 in v1) and the symmetric `handler_worker.run()`. Produce a
  binary/CLI entry (`esr-adapter-runner`, `esr-handler-worker`) that a daemon can
  spawn.
- **8b — esrd daemon.** `scripts/esrd.sh` reads `~/.esrd/<instance>/{adapters, handlers,
  patterns}.yaml`, starts the Elixir Phoenix endpoint, and supervises the Python
  adapter/handler worker subprocesses. `esr status` talks to it and reports live
  counts. PID file at `~/.esrd/<instance>/esrd.pid`; logs at `~/.esrd/<instance>/logs/`.
- **8c — CLI wiring.** Replace every `_submit_*` stub with a real Phoenix-channel
  call over the `cli:<op>` control topics. Each CLI command's unit test updates
  to exercise a live-ChannelClient path against an in-test esrd (`test_helper`
  brings one up).
- **8d — Mock Feishu + Mock CC.** `scripts/mock_feishu.py` — a real WebSocket server
  + HTTP endpoint that speaks the same shapes as Lark (`P2ImMessageReceiveV1`
  payloads, `im.v1.message.create` REST). `scripts/mock_cc.py` — a process that
  reads from stdin (tmux send-keys target) and emits `[esr-cc] <line>` on stdout
  (sentinel lines become `cc_output` events). Both bind real ports.
- **8e — Scenario live-green.** Write the 8 steps of `scenarios/e2e-feishu-cc.yaml`
  per §4.2, run `esr scenario run e2e-feishu-cc` against esrd in mock mode, iterate
  until every step passes its `expect_stdout_match`.
- **8f — Live smoke.** Document `~/.esr/live.env` (`FEISHU_APP_ID=...`,
  `FEISHU_APP_SECRET=...`, `FEISHU_TEST_CHAT_ID=...`), `scripts/final_gate.sh`
  toggles to `--live` mode (mode=live in the scenario YAML, real adapter config
  written, real lark_oapi calls). The loop cannot run this (no credentials, no
  real chat membership) — it only posts a Feishu notification asking the user to
  run it.

## 6. New / modified artifacts

### 6.1 New files

- `docs/superpowers/ralph-loop-prompt-v2.md` — the v2 prompt itself (output of
  `writing-plans` step)
- `scripts/final_gate.sh` + `scripts/final_gate.sh.sha256` — the external judge
- `scripts/loopguard.sh` (orchestrator) + `scripts/loopguard_scenario.py` +
  `scripts/verify_prd_acceptance.py` + `scripts/verify_ledger_append_only.py` +
  `scripts/ledger_append.py`
- `scripts/esrd.sh` — daemon startup
- `scripts/mock_feishu.py` + `scripts/mock_cc.py`
- `scenarios/e2e-feishu-cc.yaml` — the new scenario
- `docs/ralph-loop-ledger.md` — append-only evidence trail
- `py/src/esr/ipc/adapter_runner.py::run` (function, not file) — the F13 entry
- `py/src/esr/ipc/handler_worker.py::run` — the symmetric entry
- `py/src/esr/cli/runtime_bridge.py` — shared Phoenix-channel client used by the
  eight formerly-stubbed CLI subcommands

### 6.2 Modified files

- `py/src/esr/cli/main.py` — 8 `_submit_*` helpers rewritten against
  `runtime_bridge` (LG-2 enforces no `NotImplementedError` remains)
- All three PRDs with "Phase 8 live run deferred" rows — those boxes must tick
  green against live evidence (LG-5); the "deferred" wording must go (LG-3)
- `scripts/verify_prd_matrix.py` — unchanged; still gates unit tests. Complements
  the new live gates, doesn't replace them.

### 6.3 Deprecated / forbidden files

- `scenarios/e2e-platform-validation.yaml` — the v1 `covered_by:` scenario. Kept as
  a historical artifact but not part of v2's gate. The v2 prompt says: use
  `e2e-feishu-cc` for the active gate; `e2e-platform-validation` is frozen.

## 7. Prompt structure (the doc `writing-plans` will produce)

Section outline, to be expanded into the actual prompt text by the next skill:

- **§1 Ground truth** — this spec + plan + PRDs + glossary + ledger (not state file; the
  v1 state file is superseded by the ledger)
- **§2 Skills** — unchanged set
- **§3 Per-iteration algorithm**
  - §3.1 CWD discipline (unchanged)
  - §3.1b **Loopguard** (new; mandatory first step after pre-flight)
  - §3.2 Pick one subphase FR
  - §3.3 TDD for it
  - §3.4 Elixir guardrails (unchanged)
  - §3.5 Python guardrails (unchanged)
  - §3.6 Append to ledger (new; replaces state file update)
  - §3.7 Feishu progress reporting (unchanged; plus explicit "notify on
    LIVE_READY with the exact command the user must run")
- **§4 Phase 8 ordering** — 8a → 8b → 8c → 8d → 8e → 8f
- **§5 Blockers** — format unchanged; loopguard failures use the same format with
  a specific prefix `BLOCKED: loopguard:LG-N`
- **§6 Review checkpoints** — full-scope review after 8c and after 8e (subagent,
  `superpowers:requesting-code-review`). 0 critical / 0 significant to
  advance.
- **§7 Final Gate (revised)** — exact verbatim expected output for every gate
  step, including final_gate.sh output (see §8 below)
- **§8 Anti-patterns** — v1's §9 list plus explicit call-outs of the three v1
  loopholes with "this is exactly how v1 failed; do not repeat"
- **§9 Operational notes** — unchanged

## 8. Revised Final Gate — exact expected outputs

Loop can only emit `LIVE_READY` after **all** of the following hold, each with the
named command producing output matching the named signature:

| # | Condition | Command | Required output |
|---|---|---|---|
| 1 | Unit tests green | `make test` | `N passed, 0 failed` for both py and ex |
| 2 | PRD unit matrix | `uv run python scripts/verify_prd_matrix.py` | `all N FR tests located` |
| 3 | Loopguard clean | `bash scripts/loopguard.sh` | `all 8 loopguard checks passed` |
| 4 | Scenario mock-green | `esr scenario run e2e-feishu-cc` (defaults to mock) | `8/8 steps PASSED against live esrd (mock Feishu)` |
| 5 | final_gate.sh --mock | `bash scripts/final_gate.sh --mock` | `FINAL GATE MOCK PASSED — ready for user --live verification` |
| 6 | Ledger coherent | `uv run python scripts/verify_ledger_append_only.py` | `ledger integrity OK — N iterations, 0 in-place edits` |
| 7 | Acceptance green | `uv run python scripts/verify_prd_acceptance.py` | `all N Acceptance items ticked` |

User's final step (outside the loop):

```bash
# 1. Populate credentials
cat > ~/.esr/live.env <<EOF
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
FEISHU_TEST_CHAT_ID=oc_xxx
EOF
# 2. Run the live gate
bash scripts/final_gate.sh --live
# Expected tail output on success:
#   FINAL GATE LIVE PASSED
#   Sent /new-thread smoke-test-<timestamp> to <chat_id>
#   Observed bidirectional round-trip in <N>ms
#   You can now merge to main.
```

The loop posts this exact set of instructions to Feishu when it emits
`LIVE_READY`.

## 9. Error handling

### 9.1 Loopguard failure

```
<promise>BLOCKED: loopguard:LG-<N> — <short human reason></promise>
```

Followed by the loopguard output. The loop exits. Next iteration begins by
reading the blocker and either fixing the underlying issue or (if the issue
represents a design flaw) escalating.

### 9.2 Tampering detection

If LG-4 (SHA-256 of `final_gate.sh`) or LG-7 (ledger append-only) fails, the
promise uses prefix `BLOCKED: tamper:LG-<N>`. The next iteration **must not**
self-repair — it must leave the tamper and exit again. This ensures the user
sees the tamper signal if the loop somehow acquires the wrong self-fix logic.

### 9.3 Unreachable live E2E

If the user has not populated `~/.esr/live.env` and runs `final_gate.sh --live`,
the script prints:

```
NO LIVE CREDENTIALS — set ~/.esr/live.env with FEISHU_APP_ID etc.
Exit 2 (missing creds, not a gate failure).
```

Exit 2 is distinct from exit 1 (gate failure) and exit 0 (pass).

## 10. Testing the prompt itself

Two mechanisms guarantee the v2 prompt does what this spec describes before
we trust it with a long-running loop:

1. **Dry-run**: after the plan (from `writing-plans`) lists the FRs, a single
   iteration is run manually with a trivially-completable task (e.g. add one
   comment line to a script). Observe: does loopguard run? Does ledger
   append? Does the state-file → ledger migration hold? Fix before real start.
2. **Red-team**: take the v1 loophole list (§1 items 1, 2, 3) and **deliberately
   reintroduce each one** in a throwaway branch; confirm loopguard catches each
   and emits the correct `BLOCKED` promise. Only after all three are caught
   do we trust the prompt.

## 11. Acceptance

- [ ] v2 prompt file `docs/superpowers/ralph-loop-prompt-v2.md` exists and references
      this spec + the plan
- [ ] `scripts/final_gate.sh` + its SHA file + the 5 loopguard helper scripts exist
      and are individually unit-testable
- [ ] `scripts/mock_feishu.py` + `scripts/mock_cc.py` run as standalone processes
- [ ] `scenarios/e2e-feishu-cc.yaml` exists with 8 steps per §4.2
- [ ] `docs/ralph-loop-ledger.md` exists, seeded with a header row
- [ ] Red-team test (§10.2) passes: all three v1 loopholes reintroduced are caught
- [ ] Dry-run test (§10.1) passes: one trivial iteration completes cleanly
- [ ] User runs `scripts/final_gate.sh --live` end-to-end against a real Feishu
      app and it exits 0

Acceptance item 8 is outside the loop's power — it is the ground truth that
"ESR v0.1 really works".

---

*End of ralph-loop-prompt-v2 design.*
