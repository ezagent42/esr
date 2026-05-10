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

1. **Path mismatch.** Every e2e scenario invokes commands via
   `esr_cli admin submit ...`, bypassing
   `Esr.Entity.SlashHandler.merge_chat_context/3` (the chat envelope
   injector). Production goes through SlashHandler; tests don't.
2. **Argument coverage hole.** All 24 scenarios pass `--arg dir=`
   explicitly. The bare `name=`-only form an operator actually types is
   never tested.
3. **Guide drift.** `docs/guides/*.md` describe operator journeys. No
   machine readback ties guides to e2e. Implementation changes silently
   diverge from guide.

**Fix:** guides become the operator-journey source of truth; a small
script replays guide steps through the production code path.

---

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
- Not building Elixir mix tasks for replay/coverage. A 100-line bash
  script + hook + CLAUDE.md rule covers the recurring drift class
  without adding a 4-module Elixir subsystem.
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

### 3.3 Claude Code hook

`.claude/hooks/replay-guide-reminder.json`:

```json
{
  "event": "PostToolUse",
  "matcher": {
    "tool_name": ["Edit", "Write", "MultiEdit"],
    "args.file_path": "runtime/lib/esr/commands/.*\\.ex$"
  },
  "command": "echo '⚠️  You edited a command handler. Before committing, run scripts/replay-guide.sh against any guide that uses this command. Find the relevant guide via: rg \"$(basename $(echo \"<file_path>\" | sed -e \"s|.*/||\" -e \"s|\\.ex$||\" | tr A-Z a-z))\" docs/guides/'"
}
```

The exact hook DSL follows the project's existing hook conventions
(check `docs/futures/todo.md` or the `hookify:` skill for the canonical
schema). Goal: the agent / dev gets a one-line reminder when a command
file is edited.

### 3.4 CLAUDE.md addition

Three short lines, link out to this spec for detail:

```
## Guide-driven e2e (anti-drift)

- Edit a command handler? Run `scripts/replay-guide.sh` on the relevant guide before committing.
- Guide drift detected? Prompt the user — fix implementation OR update the guide. Don't silently ignore.
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md).
```

Per the user's CLAUDE.md discipline (set 2026-05-10): keep CLAUDE.md
tight, link out for detail.

### 3.5 CI workflow step

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

Three phases, ~300 LOC total.

### Phase 1: Foundation (~150 LOC, 1 PR)

- Write `scripts/replay-guide.sh` (~100 LOC bash).
- Add `.claude/hooks/replay-guide-reminder.json` (or equivalent
  per the hook DSL).
- Add CLAUDE.md section (3 lines + link).
- Add `.github/workflows/ci.yml` step.
- Smoke test: a synthetic minimal guide `docs/guides/_replay_smoke.md`
  with one input/output pair; CI runs it green.

### Phase 2: Canary (~50 LOC + guide upgrades)

- Upgrade `docs/guides/operator-bootstrap-journey.md` (and its
  `.zh_cn.md` mirror, fences shared) with fences for the 5 main
  steps (workspace, session, agent, plain text → CC reply, TUI URL).
- Replay locally → CI green.
- Verify the 2026-05-10 `/session:new name=test-cc` regression: replay
  against `dev@8777357` (pre-#334) FAILS at step 8; against post-#334
  PASSES. This is the invariant Phase 5 should have shipped.

### Phase 3: Opportunistic spread

- When a new feature ships → its guide gets fences as part of the PR.
- When an existing guide is touched → fences added if not already.
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
| 5 | `operator-bootstrap-journey.md` has fences for the 5 main steps | inspect guide |
| 6 | The 2026-05-10 regression is replayable as a fence; pre-#334 FAILs there, post-#334 PASSes | bisect smoke (manual one-time) |

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
