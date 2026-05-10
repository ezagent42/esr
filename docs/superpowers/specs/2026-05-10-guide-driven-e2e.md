# Guide-driven e2e (anti-drift)

**Status:** Draft — pending user approval
**Date:** 2026-05-10
**Author:** Claude (with linyilun)
**Sister docs:** none yet — this is the first iteration on the e2e harness's foundational shape.

---

## 1. Why now

Phase 5 of the SessionTemplate + Channel migration shipped a regression in
`Esr.Commands.Session.New.execute/2`: the bare `/session:new name=test-cc`
form (no `agent=`, no `dir=`, no `workspace=`) hit a stale `validate_args`
gate that pre-dated the template-driven cutover. **Scenario 25** (the
explicit Phase 5 invariant test, named `25_session_template_instantiation.sh`)
ran green in CI. Production hit `error: invalid_args` on the first try.

Investigation showed three root causes:

1. **Path mismatch.** Every existing e2e scenario invokes `session_new`
   via `esr_cli admin submit session_new --arg dir=... --arg ...`. This
   bypasses `Esr.Entity.SlashHandler.merge_chat_context/3` — the layer
   that injects `chat_id`/`app_id`/`caller_principal_id` from the chat
   envelope. Production users type `/session:new ...` in Feishu chat,
   which goes through the SlashHandler path. The two paths supply
   different argument shapes to `execute/2`.

2. **Argument coverage hole.** All 24 scenarios pass `--arg dir=` and
   most pass `--arg agent=` or `--arg workspace=`. The bare `name=`-only
   form — the form an operator actually types — was never tested. The
   bug only fires when both `agent` and `dir` are absent.

3. **Guide drift.** `docs/guides/operator-bootstrap-journey.md` and
   sibling guides describe operator journeys with copy-paste blocks,
   but no machine readback ties the guide to the e2e suite. When
   implementation changes (Phase 5), the guide quietly drifts from
   reality. Users following the guide hit a wall the suite never
   exercised.

This spec proposes a structural fix: **guides become the source of
truth; e2e scenarios are mechanical replays of guide steps**. Drift
between implementation and guide surfaces in CI as a guide-replay
failure, not as a production-only operator-visible failure.

---

## 2. Goals & non-goals

### Goals

- **Lock guides as the source of operator-journey truth.** Every chat-
  callable command and every CLI-callable command appears in at least
  one guide step.
- **Mechanical replay.** A new `mix esr.replay_guide` mix task parses
  every `docs/guides/*.md`, extracts machine-readable input/output
  pairs, drives them through the production code path (mock_feishu for
  chat, `esr_cli admin submit` for CLI-only), asserts outputs match.
- **Coverage gate.** `mix esr.check_guide_coverage` enumerates all
  registered command kinds and asserts each appears in at least one
  guide step. Fails the build when a new command lacks guide coverage.
- **Failure mode is actionable.** When replay sees a mismatch, it emits
  a unified diff naming the guide path + step number + expected vs
  actual output, and exits non-zero. Devs either fix the implementation
  or update the guide.
- **Three-layer separation.** **Infra** (mock_feishu, mock_claude_code)
  is stable, tracks external products. **Guides** (markdown narratives)
  are operator-facing source-of-truth. **Replay engine** is the bridge.
  Each layer has one purpose; changes in one don't ripple.

### Non-goals

- **Not replacing `Esr.Commands.Meta`-driven `docs/grammar/*` generation.**
  Per-command reference (the `command_meta()` callback → `commands.md`
  + `errors.md`) stays as-is. That's a different artifact (single-command
  dictionary) from a guide (multi-command journey).
- **Not auto-generating guides.** Guides are human-written narratives.
  Auto-derivation from `Esr.Commands.Meta` is tracked as a follow-up
  in `docs/futures/todo.md`; this spec only embeds machine-readable
  fences inside human-written prose.
- **Not testing the Feishu protocol.** mock_feishu's contract with real
  Feishu is the infra layer's concern (separate spec / out of scope).
- **Not replacing unit tests.** Replay tests sit above unit tests in
  the pyramid; they're operator-journey integration tests. Unit tests
  for individual functions stay.
- **Not full-fidelity Lark integration.** Real Feishu sidecar against
  Lark API is a release-time smoke test (manual or scheduled), out of
  scope here. Replay uses mock_feishu.

---

## 3. Architecture — three layers

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 3 — REPLAY ENGINE  (changes per spec; rarely after this)       │
│   mix esr.replay_guide     — parse + drive + assert                  │
│   mix esr.check_guide_coverage — registry vs guide steps             │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ drives
┌──────────────────────────────────▼──────────────────────────────────┐
│ Layer 2 — GUIDES  (changes per feature; this is the source of truth)│
│   docs/guides/*.md   — operator journeys, narrative + fenced steps  │
│   docs/guides/*.zh_cn.md  (mirror, narrative only; fences shared)   │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ replays via
┌──────────────────────────────────▼──────────────────────────────────┐
│ Layer 1 — INFRA  (rarely changes; tracks external products only)    │
│   mock_feishu.py            — Lark protocol mock (push_inbound,     │
│                               reply capture, reaction lifecycle)    │
│   mock_claude_code  (deferred until needed)                         │
│   esrd test instance        — per-replay isolated $ESRD_HOME        │
└─────────────────────────────────────────────────────────────────────┘
```

**Why three layers, not two:** the infra layer's stability is a separate
concern from the scenario layer's correctness. Conflating them (today's
`tests/e2e/scenarios/common.sh` mixes infra setup + scenario steps in
the same shell file) means an infra change rolls into every scenario;
a scenario change can accidentally edit infra. The replay engine layer
sits between, owns the replay logic, and lets guides + infra each focus
on one thing.

**What stays where:**

- `mock_feishu.py` (already exists at `py/src/feishu_adapter_runner/mock_feishu.py`):
  no behavior change. Continues to expose `push_inbound`, `reply_capture`,
  `react_capture`. Replay engine drives it.
- `tests/e2e/scenarios/common.sh`: shrinks. Boot/teardown of esrd test
  instance + mock_feishu stays. Per-scenario logic moves into guides.
- `docs/guides/*.md`: gain fenced blocks (specified in §4 below).
- `tests/e2e/scenarios/<topic>.sh`: each becomes a 5-line wrapper:

```bash
#!/usr/bin/env bash
# scenario 25 — replay docs/guides/operator-bootstrap-journey.md
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
exec mix esr.replay_guide --guide=docs/guides/operator-bootstrap-journey.md
```

---

## 4. Guide-fence protocol

The convention is markdown fenced code blocks with specific language
tags. The replay engine extracts these in document order.

### 4.1 Fence languages

| Language | Direction | Channel | Asserted? |
|---|---|---|---|
| `chat-input` | operator → bot | mock_feishu push_inbound | no (input) |
| `chat-output` | bot → operator | mock_feishu reply_capture | yes |
| `cli-input` | operator → CLI | `esr_cli admin submit` | no (input) |
| `cli-output` | CLI → operator | stdout | yes |
| `cli-stderr` | CLI → operator | stderr | yes |
| `setup-bash` | scenario fixture | shell exec | yes (exit 0) |

`setup-bash` covers things that aren't an operator action but are
needed for the scenario to run (e.g. creating a fresh `~/.esrd-test/`
state, exporting env vars). Used sparingly; most setup belongs in
`common.sh`.

### 4.2 Fence frontmatter (info string after the language)

`chat-input` requires `app_id` + `chat_id` + (optional) `user`. Example:

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/session:new name=test-cc
```
````

The replay engine maps `app_id` to a configured mock_feishu adapter
instance, `chat_id` to a synthetic test chat, `user` to a Feishu
`open_id` (resolved via the test fixture's user table). If `user` is
omitted, the engine uses the default test operator (`linyilun` per
ESR's bootstrap convention).

`chat-output` and `cli-output` accept an optional `capture=<varname>`
to bind a matched placeholder for later steps:

````markdown
```chat-output capture=session_id
ok: true
session_id: <UUID>
```

```chat-input app_id=esr_helper_dev chat_id=oc_test_chat
/session:end session={{session_id}}
```
````

### 4.3 Placeholder grammar

| Token | Matches |
|---|---|
| `<UUID>` | UUID v4 |
| `<UUIDv7>` | UUID v7 (if/when adopted) |
| `<int>` | one or more decimal digits |
| `<word>` | `[A-Za-z0-9_-]+` |
| `<string>` | one or more non-newline characters |
| `<…>` | wildcard, ignore this token (don't capture) |
| `<...>` | wildcard ditto, ASCII variant |

Placeholders are line-by-line. A line in the expected fence body
matches the actual output line if every placeholder substitutes a
valid match for its token. Non-placeholder text matches literally.

### 4.4 Multi-line + ordering semantics

By default, fence body is matched line-by-line in order against the
output. If extra lines appear in the actual output, the match fails
unless the fence ends with `<…>` indicating "additional lines OK".
Output ordering is strict: a `chat-output` fence must be the next
reply to the immediately preceding `chat-input`. To assert "no reply
within N seconds", use a `chat-silent` fence (deferred to v1.1; v1
asserts every input has a paired output).

---

## 5. Replay engine — `mix esr.replay_guide`

### 5.1 Public surface

```
mix esr.replay_guide [--guide=<path>] [--all] [--strict] [--verbose]
```

- `--guide=<path>` — replay one guide. Default if no flag.
- `--all` — replay every `docs/guides/*.md`.
- `--strict` — fail on warnings (extra lines, unrecognized fence
  language). Default: warn.
- `--verbose` — emit each step as it runs.

Exit 0 on full success; non-zero on any mismatch / setup failure.

### 5.2 Internal flow

```
1. Read docs/guides/<topic>.md
2. Markdown parser → token stream
3. Extract fenced blocks where language ∈ {chat-input, chat-output,
   cli-input, cli-output, cli-stderr, setup-bash}
4. Pair input/output blocks in document order; reject misaligned pairs
   (e.g. two outputs in a row, input with no output, etc) with a
   structural error pointing at the guide line.
5. Boot test fixture:
   - Fresh $ESRD_HOME at /tmp/esr-replay-<run-id>/
   - Start mock_feishu.py on a free port
   - Start esrd via scripts/esrd.sh start --instance=replay-<run-id>
   - Wait for ready signal
6. Walk the step list:
   - chat-input  → mock_feishu push_inbound; capture next reply (timeout 30s)
   - chat-output → assert captured reply matches fence body (line-by-line, placeholders)
   - cli-input   → spawn `esr_cli admin submit ...`; capture stdout/stderr
   - cli-output  → assert stdout matches
   - cli-stderr  → assert stderr matches
   - setup-bash  → bash -c body; assert exit 0
7. Tear down: stop esrd; stop mock_feishu; rm -rf fixture dir
8. Print summary: "<guide>: N steps replayed, <PASS|FAIL>"
```

### 5.3 Error reporting

On mismatch:

```
✗ docs/guides/operator-bootstrap-journey.md (step 8 of 14, line 142)

  chat-input  app_id=esr_helper_dev chat_id=oc_test_chat
  ┃ /session:new name=test-cc

  expected (chat-output):
  ┃ ok: true
  ┃ session_id: <UUID>

  actual:
  ┃ ok: false
  ┃ type: invalid_args
  ┃ message: "session_new agent required"

  → step failed at line 142; either the implementation drifted from
    the guide (run `git log --since='2 weeks ago' runtime/lib/esr/commands/session/new.ex`
    to see recent changes) or the guide is stale (update the fence body
    to match the new behavior).
```

The hint line is computed: when expected != actual, scan recent commits
touching the suspected source file (parsable from the input slash kind
→ command_module via the SlashRoute Registry).

---

## 6. Coverage gate — `mix esr.check_guide_coverage`

### 6.1 What it asserts

Every command kind registered in `Esr.Resource.SlashRoute.Registry`
appears in at least one fenced step across `docs/guides/*.md`.

The kind is extracted from the fence body:

- `chat-input`: parse the slash text → `/session:new ...` → resolve to
  kind `session_new` via the registry.
- `cli-input`: parse the kind name from `esr-dev exec <kind> ...` or
  `esr_cli admin submit <kind> ...`.

A guide step that doesn't unambiguously resolve to a kind (e.g.
plain text "hello, what's the cwd?" sent through chat-input as a
`/help` test) doesn't count. The replay engine logs each
kind-coverage hit; coverage gate aggregates.

### 6.2 Output

```
$ mix esr.check_guide_coverage

✓ 73 / 73 chat-callable kinds covered
✓ 12 / 12 internal kinds covered

Per-kind coverage report:
  session_new: docs/guides/operator-bootstrap-journey.md (step 7),
               docs/guides/sessiontemplate-feishu-test.md (step 3)
  workspace_new: docs/guides/operator-bootstrap-journey.md (step 5)
  ...
```

On gap:

```
✗ 71 / 73 chat-callable kinds covered (2 gaps)

Uncovered kinds:
  agent_remove
  pty_attach

Add guide coverage by including a chat-input or cli-input fence whose
slash/kind resolves to each uncovered kind. Coverage gate is enforced
in CI (.github/workflows/ci.yml).
```

### 6.3 CI wiring

`.github/workflows/ci.yml` gains two new steps after the existing
`mix esr.check_command_docs` step:

```yaml
- name: Replay guides
  run: cd runtime && mix esr.replay_guide --all --strict

- name: Check guide coverage
  run: cd runtime && mix esr.check_guide_coverage
```

Both block the merge on failure.

---

## 7. Migration plan

Five phases; ~1500 LOC + bilingual guide upgrades.

### Phase A — Foundation (replay engine + coverage gate, no migrations)

- New: `runtime/lib/mix/tasks/esr/replay_guide.ex`
- New: `runtime/lib/mix/tasks/esr/check_guide_coverage.ex`
- New: `runtime/lib/esr/guide/parser.ex` (markdown fence extractor)
- New: `runtime/lib/esr/guide/replay_runner.ex` (driver + assertion)
- New: `runtime/lib/esr/guide/kind_resolver.ex` (slash text → kind name)
- Tests: each module 70%+ unit coverage
- One small synthetic guide `docs/guides/_replay_smoke.md` exercises
  every fence kind end-to-end; CI runs it.

### Phase B — Canary (operator-bootstrap-journey)

- Upgrade `docs/guides/operator-bootstrap-journey.md` (and its `.zh_cn.md`
  mirror, fences shared) with the new fence convention.
- Replace `tests/e2e/scenarios/19_session_first_default.sh` content
  with a 5-line wrapper that calls `mix esr.replay_guide --guide=...`.
- Verify CI green.
- Acceptance: the 2026-05-10 `/session:new name=test-cc` regression is
  expressible as a single fence pair and would have caught the bug.

### Phase C — Bulk migration (remaining guides + scenarios)

For each guide currently in `docs/guides/`:
- `operator-bootstrap-journey.md` (Phase B)
- `feishu-adapter-setup.md`
- `2026-05-10-sessiontemplate-feishu-test.md`
- `operator-bootstrap-checklist.md` (this is a checklist not a journey;
  evaluate whether it should adopt fences or stay as-is)

Add fences. Map each existing scenario to a guide-replay wrapper.

Decisions per existing scenario:
- Has a corresponding guide → replace with replay wrapper.
- No guide but represents an operator journey → write a new guide first,
  then replay.
- Tests admin-CLI-only flows (e.g. scenario 04 multi-app routing,
  scenario 27 dependency-unmet structured error) → guide as
  "advanced/admin journeys" or stay as legacy bash. Clearly mark.

Each scenario migration is one commit.

### Phase D — CI gate

- Wire `mix esr.replay_guide --all` + `mix esr.check_guide_coverage`
  into `.github/workflows/ci.yml`.
- Block PRs that drop coverage (covered → uncovered transitions
  detected via comparison to `dev` HEAD).

### Phase E — Cleanup + linter

- Audit `tests/e2e/scenarios/common.sh`. Remove helpers that bypass
  SlashHandler for chat-callable commands (the lure that produced the
  Phase 5 regression).
- Add a linter rule (mix or shell): any file under `tests/e2e/scenarios/`
  invoking `esr_cli admin submit <slash-callable-kind>` is rejected
  unless explicitly allowlisted (admin-CLI-only flows).
- Update `CLAUDE.md` with a one-line link: `- [Guide-driven e2e](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md) — drift prevention via guide replay.`

---

## 8. Acceptance criteria

| # | Acceptance | Verify |
|---|---|---|
| 1 | All chat-callable kinds in `Esr.Resource.SlashRoute.Registry` covered by ≥1 guide step | `mix esr.check_guide_coverage` exit 0 |
| 2 | All admin-CLI kinds covered by ≥1 guide step | same |
| 3 | `mix esr.replay_guide --all --strict` passes | CI |
| 4 | The 2026-05-10 `/session:new name=test-cc` regression is encoded as a fence in `operator-bootstrap-journey.md`; replay against pre-fix `dev@8777357` would FAIL there; replay against post-fix `dev@<post-#334>` PASSES | bisect smoke (manual one-time) |
| 5 | Guide-replay reports drifts with file:line + diff | inspect failure output |
| 6 | `mock_feishu.py` and `common.sh` infra layer is unchanged in this PR series (no infra coupling to guide format) | review diff |
| 7 | `docs/grammar/{commands,errors}.md` continues to be generated from `Esr.Commands.Meta` (no change) | `mix esr.gen_command_docs` runs clean |

---

## 9. Open questions / future work

These are deferred — not blockers for shipping the foundation:

1. **Auto-baseline guides from `Esr.Commands.Meta`.** A future
   `mix esr.gen_baseline_guide --command=<kind>` would emit a starter
   fence sequence per command from its `command_meta()` examples. Devs
   then humanize. Tracked in `docs/futures/todo.md`.

2. **Parallelism.** Replaying 30+ guides serially could take minutes.
   Per-guide isolation via fixture dir is already the design;
   parallelizing across guides via `mix run` workers is a follow-up.

3. **Fixture freshness.** Some guides (e.g. plugin-config-hot-reload)
   need a clean fresh-install state; others build on the same state
   incrementally. The replay engine's default is fresh-per-guide; an
   explicit fixture-share annotation could let chains share state.
   Defer until a real use case appears.

4. **mock_feishu protocol versioning.** When real Feishu adds new
   event shapes, mock_feishu's contract drifts. Out of scope here;
   covered by the infra layer's own gating (pinning Lark API version
   + a contract-test against a recorded real event corpus).

5. **Browser-driven scenarios for PTY/web flows.** `/claude_code:tui`
   returns a URL the operator clicks. Today scenario 22 / phase E test
   asserts the URL shape via http GET, not a real browser session.
   A headless-browser layer (playwright?) is a strict super-set of v1
   scope; defer.

6. **Internationalized guide outputs.** mock_feishu replays operator
   text; if a command renders Chinese strings (some `/doctor` /
   `/help` outputs do), the fence body contains those Chinese strings
   verbatim. This is fine. If outputs become locale-aware (per-user
   language switch), fences need a locale annotation. Defer.

---

## 10. Approval gate

The user (linyilun) approves the spec by replying to it on Feishu. On
approval:

1. Spec committed at `docs/superpowers/specs/2026-05-10-guide-driven-e2e.md`
   (this file) + `.zh_cn.md` mirror.
2. Plan written via `superpowers:writing-plans` to
   `docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md`.
3. Implementation begins with Phase A.

---

## Appendix A — Worked example: the 2026-05-10 regression in fence form

What scenario 25 should have looked like in the new world:

````markdown
### Step 8: bare `/session:new name=` resolves to default template

After Phase 5, `feishu-cc` is the auto-elected default template (it's
the only registered template post-fresh-install). An operator typing
just `/session:new name=test-cc` should succeed without `agent=`,
`dir=`, `template=`, or `workspace=` — every other arg is auto-resolved
from chat-current state + the default template.

```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/session:new name=test-cc
```

```chat-output capture=session_id
ok: true
session_id: <UUID>
template: feishu-cc
agent: cc
```
````

Replay against `dev@8777357` (pre-#334): mismatch on actual
`{ok: false, type: invalid_args, ...}` → CI blocks Phase 5 PR.

Replay against post-#334: both lines match → CI green.

This is the **invariant gate** Phase 5 should have shipped with.
