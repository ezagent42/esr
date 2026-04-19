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

### 4.1 External verdict — loop runs the judge, but cannot corrupt the judge

**v2.1 revision (2026-04-19).** The v2.0 design required the user to run
`scripts/final_gate.sh --live` manually after the loop emitted `LIVE_READY`.
This defeated the point of an autonomous loop. v2.1 puts the live gate back
in-loop while keeping the anti-tamper guarantees by separating two concerns:

- **Can the loop modify the gate?** No — SHA pin + user-authored-before-launch
  (anti-circular-trust rule, unchanged).
- **Can the loop fake the gate's output?** No — the gate produces four
  independent forensic artifacts keyed by a random nonce; one of them is
  retrieved server-side from Lark and cannot be fabricated without actually
  pushing a message through the whole pipeline.

| | v1 | v2.0 | v2.1 |
|---|---|---|---|
| Highest promise loop emits | `ESR_V0_1_COMPLETE` | `ESR_V0_1_LIVE_READY` | `ESR_V0_1_COMPLETE` |
| Who runs `final_gate.sh --live`? | N/A | User, manually | **Loop, autonomously** |
| Script author | n/a | User pre-launch | **User pre-launch (unchanged)** |
| SHA pin | n/a | Loop can't modify | **Loop can't modify (unchanged)** |
| Anti-forgery for live evidence | n/a | Human eyeballs 3 artifacts | **4-artifact nonce correlation (§4.1.1)** |

**Anti-circular-trust rule (closes reviewer C2, unchanged from v2.0):**
`final_gate.sh`, its `.sha256` pin, and the normative acceptance manifest
(§4.3 LG-5) are all authored by the user manually and committed before the
loop's first iteration. The loop may read them but is forbidden to modify
them — any change trips LG-4 or LG-11 and produces `BLOCKED: tamper:LG-<N>`.

### 4.1.1 Four-artifact nonce verification — what `--live` actually checks

`scripts/final_gate.sh --live` generates a random nonce
(`SMOKE-<8 upper-hex chars>`) and posts `/new-thread smoke-$nonce` to
`$FEISHU_TEST_CHAT_ID` using credentials from `~/.esr/live.env`. The nonce then
must appear in **four independent artifacts**, three local and **one retrieved
from Lark's servers**:

| # | Artifact | How it proves the pipeline ran |
|---|---|---|
| L1 | Lark HTTP response `message_id` from the POST | Server-signed; only reachable if the app creds actually reached Lark |
| L2 | Line in `~/.esrd/default/logs/<instance>/<ts>.log` containing nonce | Proves the Elixir runtime received the event |
| L3 | `tmux capture-pane -t <session>` output contains nonce | Proves the cc_tmux adapter forwarded to the tmux session |
| **L4** | **Lark-server-side**: `im.v1.chat.messages.list` query on `$FEISHU_TEST_CHAT_ID` finds a message (posted AFTER L1's message_id) whose content contains nonce **and whose sender is the app itself (not the user)** | **The only way this appears is if the `cc_output` handler successfully routed an outbound `send_message` back to Feishu — i.e. the whole bidirectional loop closed** |

**Why L4 is the anti-forgery lynchpin.** L1/L2/L3 can all be fabricated locally
by a sufficiently adversarial loop (local file writes, local tmux session).
L4 cannot: it is a server-authoritative query. For L4 to carry the nonce, the
pipeline must actually have fired: feishu adapter → handler → tmux → cc →
cc_output → reverse route → feishu adapter → `im.v1.message.create` → Lark
server records the outbound.

If L4 is absent after the timeout window, `final_gate.sh --live` exits 1 with
`FINAL GATE LIVE FAILED — L4 nonce not observed in Feishu chat history`.

The loop emits `<promise>ESR_V0_1_COMPLETE</promise>` only after `--live`
exits 0. A Feishu notification is also posted to the same chat so the user
sees "gate passed; nonce=SMOKE-XXXX; round-trip observed in Ns".

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

**Banned keys** (loopguard fails if present anywhere in the scenarios tree):
`covered_by`, `unit_tests`, `deferred`, `skip`, `todo`.

**Output-signature requirement (BLOCKING — closes reviewer S4).** Each step's
`expect_stdout_match` regex must match at least one of the following
**approved live-runtime signatures**:

| # | Pattern | Why it's live-only |
|---|---|---|
| sig-A | `pid=<0\.\d+\.\d+>` | BEAM pid format — only emitted by a running OTP runtime |
| sig-B | `actor_id=(thread\|tmux\|cc\|feishu-app):[a-z0-9-]+` | Actor IDs are synthesized at spawn; static text can't produce them |
| sig-C | `ack_ms=\d{1,4}` | Directive-ack latency; only measurable when a real channel is active |
| sig-D | `message_id=om_[a-zA-Z0-9]{10,}` | Lark `message_id` shape; only present after a successful `im.v1.message.create` round-trip (mock_feishu emits the same shape) |
| sig-E | `peer_count=\d+ registered_count=\d+` | PeerRegistry state at runtime |
| sig-F | `msg_id=[a-f0-9-]{8,} dedup=hit` | Dedup pathway — requires PeerServer to have seen the id once |

LG-1 parses every step's regex and fails (blocking) if none of sig-A…sig-F is
present verbatim. Adding a new signature requires editing this spec + the
prompt's pinned list; loopguard helpers read the list from a pinned file
`scripts/live_signatures.txt` (covered by LG-11 self-pin).

If a genuinely signature-free step exists (rare — maybe a `setup:` precondition
like "config file present"), the step uses explicit annotation
`live_signature: exempt  # reason: <human-written justification>`; LG-1 logs the
exemption into the ledger. Un-justified exemptions (no `reason:`) fail LG-1.

### 4.3 Loopguard — per-iteration anti-tamper scan

`scripts/loopguard.sh`, run as the first action after pre-flight on every iteration.
Any non-zero return → emit `<promise>BLOCKED: loopguard:<check-id></promise>` and
stop.

| # | Check | Command | Closes reviewer finding |
|---|---|---|---|
| LG-1 | scenario YAML well-formed + every step signature-matches sig-A…sig-F (§4.2) | `uv run python scripts/loopguard_scenario.py` | S4 |
| LG-2 | No soft stubs in ANY production source tree | `uv run python scripts/verify_entry_bodies.py` (see below) | C1 |
| LG-3 | No "deferred / manual / gated" escape hatches in PRD Acceptance sections | `uv run python scripts/verify_prd_acceptance.py --regex-scan` | C3 |
| LG-4 | `final_gate.sh` SHA-256 matches pin | `sha256sum -c scripts/final_gate.sh.sha256` | — |
| LG-5 | All Acceptance items required by the manifest are present verbatim AND ticked | `uv run python scripts/verify_prd_acceptance.py --manifest docs/superpowers/prds/acceptance-manifest.yaml` | S1 |
| LG-6 | `scenarios/` is an **allowlist** of known files with approved shapes | `uv run python scripts/loopguard_scenarios_allowlist.py` (see below) | S3 |
| LG-7 | Ledger append-only AND each row cites an approved evidence type | `uv run python scripts/verify_ledger_append_only.py` | S2 |
| LG-8 | No `@pytest.mark.skip` / `xfail` added **since the loop launched** | `git diff $(cat .ralph-loop-baseline) -- 'py/tests/**/*.py' 'runtime/test/**/*.exs' \| rg '^\+.*(@pytest\.mark\.(skip\|xfail)\|@tag.*:skip)'` | M1 |
| LG-9 | Every `py/tests/test_cli_cmd_*.py` uses the `esrd_fixture` — no pure-mock path | `uv run python scripts/verify_cli_tests_live.py` | M2 |
| LG-10 | No `_submit_*` helper is monkeypatched/mocked in tests | `uv run python scripts/verify_cli_tests_live.py --no-monkeypatch` | M2 |
| LG-11 | All loopguard helper scripts + `live_signatures.txt` + acceptance manifest SHA-pinned and unchanged | `sha256sum -c scripts/loopguard-bundle.sha256` | M3 |

**LG-2 implementation — AST non-empty body check.** `scripts/verify_entry_bodies.py`
parses these files and asserts each listed function body is non-trivial (not
just `pass`, `...`, a single return/raise, or body length ≤ 2 AST nodes):

| Module | Required non-empty functions |
|---|---|
| `py/src/esr/ipc/adapter_runner.py` | `run` |
| `py/src/esr/ipc/handler_worker.py` | `run` |
| `py/src/esr/cli/main.py` | all 8 `_submit_*` helpers |
| `py/src/esr/cli/runtime_bridge.py` | `connect`, `call`, `push_event` |
| `adapters/feishu/src/esr_feishu/adapter.py` | `factory`, `on_directive`, `emit_events`; every `send_*` / `react` directive handler |
| `adapters/cc_tmux/src/esr_cc_tmux/adapter.py` | `factory`, `on_directive`, `emit_events` |
| `handlers/*/src/esr_handler_*/on_msg.py` | `on_msg` |
| `runtime/lib/esr/peer_server.ex` | `init`, `handle_info` for directive paths |

Plus: reject any function in these files whose body raises a `NotImplementedError`,
`NotImplemented`-tagged tuple, or returns a hard-coded `{"ok": False,
"error": "not yet wired" \| "not implemented" \| "stub" \| "deferred"}`.

**LG-3 implementation — regex scoped to Acceptance sections only.**
`verify_prd_acceptance.py --regex-scan` parses each PRD and scans only the
lines under the `## Acceptance` heading (until the next `##`). Ban words
(any case): `\bdefer(red|s|ral)?\b`, `\bmanual step\b`, `\bpost-install\b`,
`\bgated by\b`, `\blive.*(hookup|integration|wiring|run)\b`, `\bv0\.2\b`,
`\btodo\b`, `\bpending\b`. Any ban-word match → LG-3 failure regardless of
whether the box is ticked.

**LG-5 implementation — normative acceptance manifest.** The user authors
`docs/superpowers/prds/acceptance-manifest.yaml` **before the loop starts**
(LG-11 pins it); it lists the exact verbatim Acceptance lines every PRD must
contain. The loop cannot delete an Acceptance row because `verify_prd_acceptance.py
--manifest` reports missing items as LG-5 failures. Ticked-box check is performed
only for items also listed in the manifest, so the loop cannot add sham ticked
lines for credit.

**LG-6 implementation — allowlist.** `loopguard_scenarios_allowlist.py` requires
`scenarios/` to contain exactly one file `e2e-feishu-cc.yaml` with the shape
in §4.2. Anything else (extra files, renamed files, unexpected subdirectories)
is LG-6 failure. The old `scenarios/e2e-platform-validation.yaml` is moved to
`docs/archive/2026-04-18-e2e-platform-validation.yaml` as part of the pre-loop
setup (see §11).

**LG-9 / LG-10 implementation — CLI tests must use live esrd fixture.**
`verify_cli_tests_live.py` AST-parses every `py/tests/test_cli_cmd_*.py`
(and the other runtime-dep CLI tests) and requires each test function to (a)
reference a fixture named `esrd_fixture` (or a pin-listed alternative) in its
signature, and (b) contain no `monkeypatch.setattr(..., "_submit_*", ...)` or
`mocker.patch.object(..., "_submit_*", ...)` calls. Violations fail.

LG-1 through LG-11 collectively are the direct reverse of v1's actual
failure modes plus the reviewer's three Critical escape routes.

### 4.4 Evidence ledger — append-only audit trail

`docs/ralph-loop-ledger.md`, one row per iteration:

```
| iter | date       | phase | FR   | commit  | evidence-type      | evidence-sha |
|------|------------|-------|------|---------|--------------------|--------------|
| 62   | 2026-04-20 | 8a    | F13  | 3a4f8b2 | scenario_mock      | sha256:9f3e… |
```

- `commit` is the short SHA of the iteration's commit.
- `evidence-type` is one of a **fixed enum** (closes reviewer S2) — the loop does
  not supply an arbitrary command. Each type maps internally inside
  `scripts/ledger_append.py` to a hard-coded command and runner path:

  | Enum value | Internal command (not caller-supplied) |
  |---|---|
  | `unit_tests` | `make test` |
  | `prd_matrix` | `uv run python scripts/verify_prd_matrix.py` |
  | `loopguard` | `bash scripts/loopguard.sh` |
  | `scenario_mock` | `esr scenario run e2e-feishu-cc` |
  | `final_gate_mock` | `bash scripts/final_gate.sh --mock` |
  | `prd_acceptance` | `uv run python scripts/verify_prd_acceptance.py --manifest ...` |
  | `ledger_check` | `uv run python scripts/verify_ledger_append_only.py` |

  Invocation: `uv run python scripts/ledger_append.py --phase 8a --fr F13
  --evidence-type scenario_mock`. The script runs the mapped command, captures
  stdout+stderr, hashes it, and appends the row. The loop cannot pass in a
  `printf` substitute.
- Loopguard LG-7 rejects any commit that modifies or deletes existing rows AND
  verifies every `evidence-type` value is one of the enum.
- `scripts/ledger_append.py` itself is SHA-pinned via LG-11.
- User audit command: `tail -20 docs/ralph-loop-ledger.md`.

### 4.5 Promise vocabulary — single-tier (v2.1)

| Tag | Meaning | Who emits |
|---|---|---|
| `<promise>ESR_V0_1_COMPLETE</promise>` | All 7 Final Gate conditions green, **including `scripts/final_gate.sh --live` exit 0** with the 4-artifact nonce verification (§4.1.1) | Loop |
| `<promise>BLOCKED: <reason></promise>` | Loopguard failed, or work cannot progress; see §9 | Loop |

The v1 lesson was "don't let the loop self-adjudicate on a gate it can trivially
satisfy." v2.1 keeps that lesson but moves the anti-gaming mechanism **inward**
(into the gate script and its anti-forgery design) rather than **outward** (to
human review). The SHA pin + user-authored-before-launch rule prevents the loop
from neutering the script; the L4 server-side Lark query prevents the loop from
faking the evidence. With both in place, a COMPLETE emission is meaningful.

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
- **8d — Mock Feishu + Mock CC.** `scripts/mock_feishu.py` — a real WebSocket
  server + HTTP endpoint that speaks the same shapes as Lark
  (`P2ImMessageReceiveV1` payloads, `im.v1.message.create` REST).
  `scripts/mock_cc.py` — a process that reads from stdin (tmux send-keys
  target) and emits `[esr-cc] <line>` on stdout (sentinel lines become
  `cc_output` events). Both bind real ports. **Protocol-faithfulness
  requirement (closes reviewer S5):** `mock_feishu.py` must pass a
  conformance test suite that replays the captured real-Lark WS sessions
  committed in §11.1 item 6. If the mock drifts from Lark's wire format,
  8e can pass while 8f (live smoke) still fails — this conformance test
  catches drift early.
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

**User-authored BEFORE the loop starts (loop is forbidden to modify — LG-4 / LG-11):**

- `docs/superpowers/ralph-loop-prompt-v2.md` — the v2 prompt itself (output of
  `writing-plans` step; committed by user before loop launch)
- `scripts/final_gate.sh` + `scripts/final_gate.sh.sha256` — the external judge
  (skeleton shown in §8; user fills in the live-mode body)
- `docs/superpowers/prds/acceptance-manifest.yaml` — normative list of every
  required PRD Acceptance row
- `scripts/live_signatures.txt` — enumeration of approved sig-A…sig-F patterns
- `scripts/loopguard-bundle.sha256` — SHA-pins for every loopguard helper
  script (final_gate.sh is in its own `.sha256` for LG-4 isolation)
- `.ralph-loop-baseline` — git SHA captured at loop launch, used by LG-8 to
  detect skip/xfail additions since the start of the loop

**Loop-authored during iterations (subject to every loopguard check):**

- `scripts/loopguard.sh` (orchestrator) + helpers:
  `scripts/loopguard_scenario.py`,
  `scripts/loopguard_scenarios_allowlist.py`,
  `scripts/verify_prd_acceptance.py`,
  `scripts/verify_entry_bodies.py`,
  `scripts/verify_cli_tests_live.py`,
  `scripts/verify_ledger_append_only.py`,
  `scripts/ledger_append.py`
  — **note:** once LG-11 pins these, later edits require the user to update the
  `.sha256` bundle. Loop cannot self-repair a loopguard helper.
- `scripts/esrd.sh` — daemon startup
- `scripts/mock_feishu.py` + `scripts/mock_cc.py`
- `scenarios/e2e-feishu-cc.yaml` — the new scenario
- `docs/ralph-loop-ledger.md` — append-only evidence trail (seeded header row
  by the user)
- `py/src/esr/ipc/adapter_runner.py::run` (function in an existing file) — F13 entry
- `py/src/esr/ipc/handler_worker.py::run` — symmetric entry
- `py/src/esr/cli/runtime_bridge.py` — shared Phoenix-channel client used by the
  eight formerly-stubbed CLI subcommands

### 6.2 Modified files

- `py/src/esr/cli/main.py` — 8 `_submit_*` helpers rewritten against
  `runtime_bridge` (LG-2 enforces no `NotImplementedError` remains)
- All three PRDs with "Phase 8 live run deferred" rows — those boxes must tick
  green against live evidence (LG-5); the "deferred" wording must go (LG-3)
- `scripts/verify_prd_matrix.py` — unchanged; still gates unit tests. Complements
  the new live gates, doesn't replace them.

### 6.3 Archived / moved files

- `scenarios/e2e-platform-validation.yaml` → `docs/archive/2026-04-18-e2e-platform-validation.yaml`
  (moved during pre-loop setup §11; LG-6 requires `scenarios/` to contain
  exactly `e2e-feishu-cc.yaml`). The v1 file's `covered_by:` entries would
  otherwise trip LG-6 immediately.

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
  - §3.7 Feishu progress reporting (unchanged; `final_gate.sh --live` posts
    the final success/failure notification to the test chat itself)
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

Loop emits `ESR_V0_1_COMPLETE` after **all** of the following hold, each with
the named command producing output matching the named signature:

| # | Condition | Command | Required output |
|---|---|---|---|
| 1 | Unit tests green | `make test` | `N passed, 0 failed` for both py and ex |
| 2 | PRD unit matrix | `uv run python scripts/verify_prd_matrix.py` | `all N FR tests located` |
| 3 | Loopguard clean | `bash scripts/loopguard.sh` | `all 11 loopguard checks passed` |
| 4 | Scenario mock-green | `esr scenario run e2e-feishu-cc` (defaults to mock) | `8/8 steps PASSED against live esrd (mock Feishu)` |
| 5 | final_gate.sh --mock | `bash scripts/final_gate.sh --mock` | `FINAL GATE MOCK PASSED` |
| 6 | Ledger coherent | `uv run python scripts/verify_ledger_append_only.py` | `ledger integrity OK — N iterations, 0 in-place edits` |
| 7 | Acceptance green | `uv run python scripts/verify_prd_acceptance.py --manifest ...` | `all N Acceptance items ticked` |
| 8 | **final_gate.sh --live** | `bash scripts/final_gate.sh --live` | `FINAL GATE LIVE PASSED — nonce=SMOKE-XXXXXXXX; round-trip observed in Ns` |

Pre-launch one-time setup (by the user):

```bash
# ~/.esr/live.env — readable by the loop, chmod 600
cat > ~/.esr/live.env <<EOF
FEISHU_APP_ID=cli_a9563cc03d399cc9
FEISHU_APP_SECRET=<secret>
FEISHU_TEST_CHAT_ID=oc_d9b47511b085e9d5b66c4595b3ef9bb9
EOF
chmod 600 ~/.esr/live.env
```

Post-COMPLETE Feishu notification (auto-posted by the loop to
`FEISHU_TEST_CHAT_ID`):

```
✓ ESR v0.1 COMPLETE — nonce SMOKE-A1B2C3D4 observed end-to-end in 12.4s.
   L1 message_id=om_xxx  L4 server echo=om_yyy
   git: main @ <short-sha>
   Merge to deploy at will.
```

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

Three mechanisms guarantee the v2 prompt does what this spec describes before
we trust it with a long-running loop:

1. **Dry-run**: after the plan (from `writing-plans`) lists the FRs, a single
   iteration is run manually with a trivially-completable task (e.g. add one
   comment line to a script). Observe: does loopguard run? Does ledger
   append? Fix before real start.

2. **Red-team v1 loopholes**: reintroduce each v1 escape route on a throwaway
   branch; confirm loopguard catches each and emits the correct `BLOCKED`
   promise:
   - (a) Replace a scenario step's `command:` with `covered_by: [unit_test]` → LG-1
   - (b) Replace a CLI `_submit_*` body with `raise NotImplementedError` → LG-2
   - (c) Add "Phase 8 live run deferred" to a PRD Acceptance row → LG-3
   - (d) Delete a required Acceptance row → LG-5
   - (e) Rename `scenarios/e2e-feishu-cc.yaml` to `e2e-smoke.yaml` → LG-6
   - (f) Add a ledger row with `evidence-type: custom` → LG-7
   - (g) Mock `_submit_cmd_run` in `test_cli_cmd_run.py` → LG-10

3. **Red-team reviewer exploits** (closes C1 / C2 / C3 from the code review
   of this spec):
   - (h) Write `async def run(): pass` in `adapter_runner.py::run` → LG-2 AST check
   - (i) Write `#!/bin/bash\necho FINAL GATE LIVE PASSED; exit 0` into a
     freshly-authored `final_gate.sh` + regenerated `.sha256` → should fail
     because the loop is forbidden to author either file; LG-4 fires if SHA
     drifts from the user-committed value
   - (j) Change an acceptance row's deferral phrasing to "Phase 8 manual step"
     → LG-3 expanded regex

   All ten (a–j) must be caught before the loop launches. Capture the
   `BLOCKED` output in each case and paste it into the ledger seed row as
   provenance that the guards work.

## 11. Acceptance

### 11.1 Pre-loop user-authored artifacts (blocking; loop cannot start without these)

- [ ] **User authors** `scripts/final_gate.sh` with working `--mock` and `--live`
      bodies per §4.1 (three forensic artifacts); commits it + its
      `.sha256` pin
- [ ] **User authors** `docs/superpowers/prds/acceptance-manifest.yaml`
      enumerating every required Acceptance row across PRDs 01–07, including
      the integration rows v1 left deferred
- [ ] **User authors** `scripts/live_signatures.txt` listing sig-A…sig-F
- [ ] **User authors** `scripts/loopguard-bundle.sha256` pinning every
      loopguard helper script (filled out after 11.2 below completes so that
      the initial pin matches the authored scripts)
- [ ] **User moves** `scenarios/e2e-platform-validation.yaml` →
      `docs/archive/2026-04-18-e2e-platform-validation.yaml`
- [ ] **Fixtures** at `adapters/feishu/tests/fixtures/live-capture/*.json` —
      one of (a) or (b) is acceptable:
      (a) Real captured Lark WebSocket sessions for text / thread-reply / card.
          Recommended but requires restarting the running cc-openclaw
          channel_server to pick up a brief logging hook (see plan Task 14).
      (b) Schema-synthetic fixtures produced from the `lark_oapi.api.im.v1.
          P2ImMessageReceiveV1` class via `lark_oapi.JSON.marshal`. Round-trip
          validated so shape matches runtime.
      The live gate (§4.1.1) does not depend on these fixtures; they only
      feed `mock_feishu.py` conformance tests during Phase 8d-8e. Drift risk
      (reviewer S5) is residual when (b) is used; log this in the ledger.
- [ ] **User commits** `.ralph-loop-baseline` containing the git SHA at
      which the loop will start (consulted by LG-8)
- [ ] **User commits** `docs/ralph-loop-ledger.md` with a header row and the
      red-team BLOCKED outputs from §10 item 3 as evidence the guards fire

### 11.2 Loop-produced artifacts (written across Phase 8a–8e iterations)

- [ ] v2 prompt file `docs/superpowers/ralph-loop-prompt-v2.md` exists and
      references this spec + the plan
- [ ] All loopguard helper scripts implemented and individually unit-testable
- [ ] `scripts/mock_feishu.py` passes the mock-conformance tests (§11.1 item 6
      captured or §11.1-alt schema-synthesized fixtures); `scripts/mock_cc.py`
      runs standalone
- [ ] `scenarios/e2e-feishu-cc.yaml` exists with 8 steps per §4.2
- [ ] `esr scenario run e2e-feishu-cc` (mock mode, against live esrd via
      `scripts/esrd.sh`) reports `8/8 steps PASSED`
- [ ] `bash scripts/final_gate.sh --mock` exits 0
- [ ] `bash scripts/final_gate.sh --live` exits 0 with 4-artifact nonce
      correlation (§4.1.1) — this is loop-autonomous in v2.1
- [ ] Loop emits `<promise>ESR_V0_1_COMPLETE</promise>` and posts the Feishu
      success notification (§8 bottom) to `FEISHU_TEST_CHAT_ID`

### 11.3 Final — ground truth observable in Feishu

After the loop exits with `ESR_V0_1_COMPLETE`, the user's Feishu chat shows a
single visible confirmation message citing the nonce and round-trip time. If
that message is present and the commit it references is in `git log`, v0.1 is
done. If the message is absent, the loop is still running or has blocked —
nothing about the autonomous gate can produce that Feishu message except the
real round-trip succeeding.

---

*End of ralph-loop-prompt-v2 design.*
