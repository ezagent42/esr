# Guide-driven e2e (anti-drift)

**Status:** Draft — pending user approval
**Date:** 2026-05-10
**Author:** Claude (with linyilun)
**Companion:** [`.zh_cn.md`](2026-05-10-guide-driven-e2e.zh_cn.md)

---

## 1. Why now

Phase 5 of the SessionTemplate + Channel migration shipped a regression in
`Esr.Commands.Session.New.execute/2`: the bare `/session:new name=test-cc`
form (no `agent=`, no `dir=`, no `workspace=`) hit a stale `validate_args`
gate. **Scenario 25** (the explicit Phase 5 invariant test) ran green.
Production hit `error: invalid_args` first try.

Three causes:

1. **Path mismatch.** Every e2e scenario that exercises a **slash
   command** invokes it via `esr_cli admin submit ...`, bypassing
   `Esr.Entity.SlashHandler.merge_chat_context/3` (the chat envelope
   injector). Plain-text inbound (e.g. "hello, what's the cwd?") and
   multimedia inbound DO go through the production
   `mock_feishu push_inbound` path (verified in scenarios 01/02/04/05/20).
   The bypass is slash-specific by convention — there's nothing in
   `mock_feishu` that prevents pushing a slash text inbound; the
   harness simply never has.
2. **Argument coverage hole.** All 24 scenarios pass `--arg dir=`
   explicitly. The bare `name=`-only form an operator actually types is
   never tested.
3. **Guide drift.** `docs/guides/*.md` describe operator journeys. No
   machine readback ties guides to e2e. Implementation changes silently
   diverge from guide.

**Fix:** guides become the operator-journey source of truth; a small
script replays guide steps through the production code path.

---

## 1.5 Vocabulary

These four terms appear throughout this spec. ESR's existing vocabulary
(`docs/notes/concepts.md` rev-11) doesn't define them, so they're locked
here and mirrored in the project-level `CONTEXT.md`.

| Term | Definition |
|---|---|
| **journey** | The full operator path end-to-end (fresh install → first CC reply). One per project. Indexed by `docs/guides/full-user-journey.md`. |
| **flow** | A sub-segment of the journey (bootstrap / workspace+session / pty-attach / etc). One flow ↔ one guide ↔ one-or-more scenarios. |
| **guide** | A flow's human-readable document at `docs/guides/flow-<topic>.md`. Doubles as the fence source for replay. |
| **scenario** | A flow's machine execution shell at `tests/e2e/scenarios/<n>.sh`, linked back to its guide via the `# Replays:` header. |

Cardinality:

```
journey ──contains──▶ N flows
flow    ──documented by──▶ 1 guide
flow    ──executed by──▶ ≥1 scenarios (typically 1; advanced flows may have permutations)
```

## 2. Goals & non-goals

### Goals

- Lock guides as the operator-journey source of truth.
- A `scripts/replay-guide.sh` shell script parses `chat-input` /
  `chat-output` fences from a guide markdown and replays them via
  `mock_feishu` push_inbound + reply_capture, asserting outputs match.
- A Claude Code hook fires when `runtime/lib/esr/commands/*.ex` is
  edited, reminding the agent to run the relevant guide replay before
  committing.
- A CLAUDE.md rule documents the convention for human + agent readers.
- CI runs `replay-guide.sh` on every guide that has fences; mismatches
  block merge.

### Non-goals

- Not replacing `Esr.Commands.Meta`-driven `docs/grammar/*` generation.
  That's per-command reference (single-command dictionary), complementary.
- Not auto-generating guides. Guides are human-written; we only embed
  machine-readable fences.
- Not testing the Feishu protocol itself. mock_feishu's contract with
  real Feishu is a separate (deferred) concern.
- Not building Elixir mix tasks for replay/coverage. `scripts/replay-guide.sh`
  is an out-of-process **black-box driver** that boots esrd as a subprocess
  and HTTP-talks to it — fundamentally different from internal tools like
  `mix esr.gen_slash_routes` (which parse ESR's own AST). See
  [ADR-0001](../../adr/0001-bash-replay-script.md) for the full rationale.
- Not enforcing absolute coverage (every command kind must appear in a
  guide) in v1. v1 catches drift in commands that DO have guide steps;
  unchecked commands stay unchecked. Coverage gate is a follow-up if
  drift recurs in commands without guides.

---

## 3. Components

Four moving parts, all lightweight:

### 3.1 `scripts/replay-guide.sh`

A bash script (~100 LOC, plus Python helpers via `python3 -c` heredocs
where bash is awkward). Public surface:

```
scripts/replay-guide.sh <guide-path>
scripts/replay-guide.sh docs/guides/operator-bootstrap-journey.md
```

Exit 0 on full match; non-zero on first mismatch with a diff.

Internal flow (concrete, not aspirational):

1. Parse the guide's markdown via `awk` / `python3 -c` to extract
   fenced blocks where the language tag is `chat-input` or `chat-output`.
2. Pair them in document order — input → output → input → output.
   Misalignment (two outputs in a row, etc) → structural error pointing
   at the guide line.
3. Boot a fresh test fixture:
   - Fresh `$ESRD_HOME=/tmp/esr-replay-<run-id>/`
   - Start `mock_feishu.py` on a free port (re-using the helper from
     `tests/e2e/scenarios/common.sh`)
   - Start `esrd` via `scripts/esrd.sh start --instance=replay-<run-id>`
   - Wait for ready signal (port file appears)
4. Walk the step list:
   - **chat-input** → `curl http://127.0.0.1:$MOCK_FEISHU_PORT/push_inbound`
     with the fence body as the message text
   - **chat-output** → poll mock_feishu's reply_capture endpoint until
     a reply arrives (30s timeout) → diff against fence body
     line-by-line with placeholder substitution
5. Tear down: stop esrd, stop mock_feishu, `rm -rf` fixture dir.
6. Print summary: `<guide>: N steps replayed, <PASS|FAIL>`.

### 3.2 Fence protocol — minimal v1

Only two languages:

| Language | Direction | Channel |
|---|---|---|
| `chat-input` | operator → bot | mock_feishu push_inbound |
| `chat-output` | bot → operator | mock_feishu reply_capture |

Frontmatter on `chat-input` fence line: `app_id`, `chat_id`, optional
`user`. Defaults follow ESR bootstrap convention (`linyilun` operator,
`esr_helper_dev` adapter, synthetic test chat).

**`user=` resolution (v1 auto-bind).** `user=` takes a logical name
(`linyilun`, not an `ou_xxx` open_id) so guides stay readable. On first
encounter of a name, `replay-guide.sh` consults a built-in mapping table
(e.g. `linyilun → ou_test_linyilun`) and:

1. Creates the ESR user record if absent.
2. Creates the `feishu_bind` linking that user to the synthetic open_id.

Subsequent steps reuse the established bind. The mapping table lives in
`scripts/replay-guide.sh` and is extended when a new operator name
appears in a guide. `ou_xxx` values are never written into guide
frontmatter — operator-readable names only.

Placeholders (line-by-line substitution): `<UUID>` matches UUID v4,
`<int>` matches digits, `<...>` is a wildcard. v1 ships these three;
extensions land per real need.

`capture=<varname>` on `chat-output`: bind a matched placeholder for
later steps as `{{varname}}`.

Worked example:

````markdown
### Step 8: bare /session:new resolves via default template

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

`cli-input` / `cli-output` etc are **deferred to v1.1** (or later) when
a real admin-CLI-only flow needs them. The recurring bug class is
chat-flow drift; admin CLI tests via `esr_cli admin submit` already work.

### 3.3 `docs/guides/full-user-journey.md` — the gold-standard index

A new file at `docs/guides/full-user-journey.md` is the **canonical
index** of every operator journey ESR supports. Human-readable: an
operator who lands here sees the full journey map and clicks into any
sub-flow. Machine-readable: each row links to one per-flow guide
(which carries fences); CI's replay loop walks every linked guide.

Shape (sketch):

```markdown
# ESR full user journey

The complete operator-facing journey, broken into sub-flows. Each
sub-flow has its own fenced guide that doubles as the e2e scenario.

| Sub-flow | What it covers | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd, first user, register adapter, bind feishu | [flow-bootstrap.md](flow-bootstrap.md) | tests/e2e/scenarios/01_*.sh |
| Workspace + session | Workspace create, session/agent spawn, plain text → CC reply | [flow-workspace-session.md](flow-workspace-session.md) | tests/e2e/scenarios/19_*.sh |
| Multi-session | One CC instance, two chats via /agent:add-session | [flow-multi-session.md](flow-multi-session.md) | tests/e2e/scenarios/28_*.sh |
| PTY attach | /claude_code:tui → xterm.js | [flow-pty-attach.md](flow-pty-attach.md) | tests/e2e/scenarios/22_*.sh |
| Plugin lifecycle | install / enable / disable / hot-reload | [flow-plugin-lifecycle.md](flow-plugin-lifecycle.md) | tests/e2e/scenarios/16_*.sh |
| Bundle install | External-path bundle install + dependency check | [flow-bundle.md](flow-bundle.md) | tests/e2e/scenarios/29_*.sh |
| ... | ... | ... | ... |
```

Why a separate index file (vs putting fences directly in
`full-user-journey.md`):
- The journey is too long for one fence-replay run; we want isolated
  fixtures per sub-flow (some need fresh esrd, some build on prior
  state). Per-flow files = per-flow fixtures.
- Operators reading the index want a map first, drill-down second.
  Fences clutter the map.
- CI parallelism: `for flow in flow-*.md; do replay-guide.sh & done`.

Anti-rot rule: when a new feature ships an operator-visible flow, the
PR adds a new row to `full-user-journey.md` AND a corresponding
`flow-<name>.md`. Reviewers reject feature PRs that touch
`runtime/lib/esr/commands/` without a guide row.

### 3.4 `tests/e2e/scenarios/*.sh` header annotation

Every scenario script MUST declare its source guide in the header:

```bash
#!/usr/bin/env bash
# scenario 19 — session-first default workspace resolution.
#
# Replays: docs/guides/flow-workspace-session.md
#
# This script is a thin wrapper. Edit the guide, not this file.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
exec bash "${SCRIPT_DIR}/../../../scripts/replay-guide.sh" "${SCRIPT_DIR}/../../../docs/guides/flow-workspace-session.md"
```

A linter (`scripts/check-scenario-headers.sh`, ~30 LOC bash):
- Walks `tests/e2e/scenarios/*.sh`
- Asserts each has a `# Replays: docs/guides/<file>.md` line in the
  first 20 lines
- Asserts the referenced guide exists
- Asserts the scenario file is short (≤ 30 LOC) — long custom logic
  belongs in the guide or in a one-off `*-custom.sh` exempt-list

Run as a CI step alongside `replay-guide.sh`. Fails if a scenario
sneaks in without an annotation.

### 3.5 Claude Code hook

Claude Code hooks live in `.claude/settings.json` under the `hooks` key.
The matcher is a regex against the tool name only — there is no
`args.file_path` filter at the matcher level. File-path filtering is
done by the shell script itself, reading the `tool_input` JSON from
stdin (the convention used by `scripts/hooks/openclaw-channel-postcheck.sh`
in this repo).

**Add to `.claude/settings.json`:**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PROJECT_DIR}/scripts/hooks/replay-guide-reminder.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**New file `scripts/hooks/replay-guide-reminder.sh`** (~20 LOC bash).
Reads `tool_input` JSON from stdin, extracts the `file_path` field, and
only emits the reminder when the edited file matches
`runtime/lib/esr/commands/.*\.ex$`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
input="$(cat)"
fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
case "$fp" in
  runtime/lib/esr/commands/*.ex|*/runtime/lib/esr/commands/*.ex)
    base="$(basename "$fp" .ex | tr A-Z a-z)"
    cat >&2 <<EOF
⚠️  You edited $fp.
Before committing, run scripts/replay-guide.sh against any guide that
references this command. Find candidates: rg "$base" docs/guides/
EOF
    ;;
esac
```

Goal: the agent / dev gets a one-line reminder when a command file is
edited. The hook installs alongside the existing
`pre-merge-dev-gate.sh` and `openclaw-channel-postcheck.sh` hooks —
same convention, same `scripts/hooks/` directory.

### 3.6 CLAUDE.md addition

Three short lines, link out to this spec for detail:

```
## Guide-driven e2e (anti-drift)

- Edit a command handler? Run `scripts/replay-guide.sh` on the relevant guide before committing.
- Guide drift detected? Prompt the user — fix implementation OR update the guide. Don't silently ignore.
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md).
```

Per the user's CLAUDE.md discipline (set 2026-05-10): keep CLAUDE.md
tight, link out for detail.

### 3.7 CI workflow step

Append to `.github/workflows/ci.yml`'s `build-and-test` job:

```yaml
- name: Replay guides with fences
  run: |
    for guide in docs/guides/*.md; do
      if grep -q '^```chat-input' "$guide"; then
        bash scripts/replay-guide.sh "$guide"
      fi
    done
```

Guides without fences are skipped (no failure). When Phase 2 lands
fences in `operator-bootstrap-journey.md`, this step starts catching
drift on the next PR.

---

## 4. Migration plan

Four phases, ~400 LOC total.

### Phase 0: Audit + cleanup `docs/guides/` (~50 LOC, 1 PR)

Current `docs/guides/` contents (audited 2026-05-10):

| File | Status | Action |
|---|---|---|
| `2026-05-10-sessiontemplate-feishu-test.md` | Current (just shipped) | Rename → `flow-sessiontemplate-feishu-test.md`; add fences |
| `feishu-adapter-setup.md` | Current | Keep; add fences |
| `operator-bootstrap-journey.md` | Current | Rename → `flow-bootstrap.md` (or split into `flow-bootstrap.md` + `flow-workspace-session.md`); add fences |
| `operator-bootstrap-checklist.md` (+ `.zh_cn.md`) | Checklist not journey | Keep as-is; link from `full-user-journey.md` as "verification checklist" |
| `writing-an-agent-topology.md` | Possibly stale (agents.yaml dissolved Phase 6) | **Audit**: if it references `agents.yaml` as canonical → delete or rewrite for `agent_kinds:` block |

Actions:
1. Grep each guide for stale references: `agents.yaml`, deleted slashes,
   pre-rev-3 grammar, etc. Delete the truly stale; rewrite the partly-stale.
2. Standardize naming: every per-flow guide is `flow-<topic>.md`.
3. Create `docs/guides/full-user-journey.md` as the index (initially
   empty rows — Phase 1+ fills them as fences land).
4. Decommission the `2026-05-10-` date-prefixed name (it was a
   one-shot test guide; subsume into `flow-sessiontemplate-feishu-test.md`).

### Phase 1: Foundation (~150 LOC, 1 PR)

- Write `scripts/replay-guide.sh` (~100 LOC bash).
- Write `scripts/check-scenario-headers.sh` (~30 LOC bash) — header
  annotation linter.
- Add `.claude/hooks/replay-guide-reminder.json` (or equivalent
  per the hook DSL).
- Add CLAUDE.md section (3 lines + link).
- Add `.github/workflows/ci.yml` step (replay + header-check).
- Smoke test: a synthetic minimal guide `docs/guides/_replay_smoke.md`
  with one input/output pair; CI runs it green.

### Phase 2: Canary (~50 LOC + guide upgrades)

- Upgrade `docs/guides/flow-bootstrap.md` (renamed from
  `operator-bootstrap-journey.md`, plus its `.zh_cn.md` mirror) with
  fences for the 5 main steps (workspace, session, agent, plain text
  → CC reply, TUI URL).
- Add a `# Replays: docs/guides/flow-bootstrap.md` header to
  `tests/e2e/scenarios/19_session_first_default.sh` (or replace its
  body with the thin-wrapper form per §3.4).
- Add the bootstrap row to `docs/guides/full-user-journey.md`.
- Replay locally → CI green.
- Verify the 2026-05-10 `/session:new name=test-cc` regression: replay
  against `dev@8777357` (pre-#334) FAILS at step 8; against post-#334
  PASSES. This is the invariant Phase 5 should have shipped.

### Phase 3: Opportunistic spread

- When a new feature ships → add a row to `full-user-journey.md` + a
  per-flow guide with fences. PR review rejects feature PRs that touch
  `runtime/lib/esr/commands/` without a guide row.
- When an existing guide is touched → fences added if not already.
- Each migrated scenario gets the `# Replays: <guide>` header.
- No big-bang migration; coverage spreads with normal feature work.

If a year passes and significant drift still slips through → revisit
adding `mix esr.check_guide_coverage` for absolute coverage. Track in
`docs/futures/todo.md`.

---

## 5. Acceptance criteria

| # | Acceptance | Verify |
|---|---|---|
| 1 | `scripts/replay-guide.sh` parses + replays + asserts a fence pair | unit smoke against `_replay_smoke.md` |
| 2 | Hook fires when editing `runtime/lib/esr/commands/*.ex` | manual trigger |
| 3 | CLAUDE.md updated; spec linked | inspect file |
| 4 | CI runs replay against fenced guides | green PR |
| 5 | `docs/guides/flow-bootstrap.md` has fences for the 5 main steps | inspect guide |
| 6 | The 2026-05-10 regression is replayable as a fence; pre-#334 FAILs there, post-#334 PASSes | bisect smoke (manual one-time) |
| 7 | `docs/guides/full-user-journey.md` exists as the gold-standard index, lists every fenced sub-flow | inspect file |
| 8 | Every `tests/e2e/scenarios/*.sh` declares `# Replays: docs/guides/<file>.md` in header | `scripts/check-scenario-headers.sh` exit 0 |
| 9 | Stale guides removed / renamed (post Phase 0 audit) | `git diff` Phase 0 PR |

---

## 6. Open questions / future work

Tracked in `docs/futures/todo.md`:

1. **Coverage gate** (`mix esr.check_guide_coverage`). Defer until
   real drift recurs in commands without guide fences.
2. **CLI fence languages** (`cli-input` / `cli-output`). Defer until
   an admin-CLI-only drift bug surfaces.
3. **Auto-baseline guides from `Esr.Commands.Meta`**. Generation is
   already in place for `docs/grammar/*` (per-command); journey
   auto-derivation is heavier and not blocking.
4. **mock_feishu protocol versioning** (separate spec, infra layer).
5. **PTY/web flows** — `/claude_code:tui` returns a URL the operator
   clicks. Replay v1 asserts URL shape via http; full browser
   replay is deferred.

---

## 7. Approval gate

The user (linyilun) approves on Feishu. On approval:

1. This spec is committed (already pushed as PR #335).
2. Plan written via `superpowers:writing-plans` to
   `docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md`.
3. Implementation begins with Phase 1.
