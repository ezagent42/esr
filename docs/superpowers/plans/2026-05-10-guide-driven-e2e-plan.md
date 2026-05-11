# Guide-driven e2e (anti-drift) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `docs/guides/flow-*.md` the operator-journey source of truth, machine-replayable via a bash driver that exercises esrd through the production chat path (`mock_feishu push_inbound` + reply capture).

**Architecture:** Out-of-process bash driver (`scripts/replay-guide.sh`, ~100 LOC) parses `chat-input` / `chat-output` fences in a guide markdown, boots fresh esrd + mock_feishu, replays each step via HTTP, and diffs replies line-by-line with placeholder substitution. CI runs the driver against every fenced guide on each PR; a Claude Code hook reminds developers to run the relevant guide when editing a command handler. Companion ADR-0001 records the bash-vs-mix-task decision.

**Tech Stack:** Bash (set -Eeuo pipefail conventions per `tests/e2e/scenarios/common.sh`), `jq` for JSON parsing, Python heredocs via `uv run --project py python` for markdown fence extraction, `curl` for HTTP calls, GitHub Actions for CI.

**Branch strategy:**
- Plan lands on `spec/guide-driven-e2e` (PR #335) alongside spec rev-4 → merge.
- Each phase ships from a **fresh feature branch off origin/dev**:
  - Phase 0 → `feat/guide-driven-e2e-phase-0-audit`
  - Phase 1 → `feat/guide-driven-e2e-phase-1-foundation`
  - Phase 2 → `feat/guide-driven-e2e-phase-2-canary`
  - Phase 3 → organic, per-feature (no dedicated branch)

---

## File Structure

### New files

| Path | Phase | LOC | Responsibility |
|---|---|---|---|
| `scripts/replay-guide.sh` | 1 | ~100 | Parse fences, boot fixture, replay, diff |
| `scripts/check-scenario-headers.sh` | 1 | ~30 | Lint `# Replays:` headers on scenarios |
| `scripts/hooks/replay-guide-reminder.sh` | 1 | ~20 | PostToolUse hook: nag on command-handler edits |
| `docs/guides/_replay_smoke.md` | 1 | ~15 | Synthetic guide for CI smoke; 1 input/output pair |
| `docs/guides/full-user-journey.md` | 0 | ~30 | Gold-standard journey index (sub-flow rows) |
| `docs/guides/flow-bootstrap.md` | 0 (rename) + 2 (fences) | ~60 | Renamed from `operator-bootstrap-journey.md` |
| `docs/guides/flow-bootstrap.zh_cn.md` | 0 (rename) + 2 (fences) | ~60 | zh_cn mirror |
| `docs/guides/flow-sessiontemplate-feishu-test.md` | 0 (rename) | n/a | Renamed from `2026-05-10-sessiontemplate-feishu-test.md` |
| `docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md` | 0 (rename) | n/a | zh_cn mirror |

### Modified files

| Path | Phase | Change |
|---|---|---|
| `.claude/settings.json` | 1 | Add PostToolUse hook entry (Edit\|Write\|MultiEdit matcher) |
| `CLAUDE.md` | 1 | Add 3-line anti-drift section linking to spec |
| `.github/workflows/ci.yml` | 1 | Add replay step + header-lint step |
| `tests/e2e/scenarios/19_session_first_default.sh` | 2 | Add `# Replays:` header + replay-driven body |
| `docs/guides/full-user-journey.md` | 1, 2 | Fill rows as fences land |
| `docs/guides/writing-an-agent-topology.md` | 0 | Audit; delete if references dissolved `agents.yaml` |

---

## Phase 0: Guide audit + rename (1 PR, ~50 LOC)

Pure docs cleanup. No new behavior. Must land before Phase 1 (gives Phase 1 stable filenames to glob).

### Task 0.1: Open Phase 0 branch

**Files:** none (git only)

- [ ] **Step 1: Create branch off latest dev**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-0-audit origin/dev
```

- [ ] **Step 2: Verify clean state**

Run: `git status`
Expected: `On branch feat/guide-driven-e2e-phase-0-audit ... nothing to commit, working tree clean`

### Task 0.2: Audit stale guide references

**Files:**
- Inspect: `docs/guides/*.md`

- [ ] **Step 1: Grep for known-dissolved references**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
echo "=== agents.yaml refs ===" ; rg -l "agents\.yaml" docs/guides/ || true
echo "=== /new-session legacy slash ===" ; rg -l "/new-session\b" docs/guides/ || true
echo "=== pre-rev-3 grammar markers ===" ; rg -l "Esr\.Commands\.Plugin\.Install" docs/guides/ || true
```

Expected: a short list of files that need rewriting or deletion. Capture the output for Step 2.

- [ ] **Step 2: Write the audit decision into the PR description**

In the eventual PR body, list:
- `writing-an-agent-topology.md` — references `agents.yaml`: DELETE (agents.yaml dissolved Phase 6 of SessionTemplate migration; topology is now derived from `agent_kinds:` in plugin manifests, not user-authored).
- `operator-bootstrap-checklist.md` — keep as-is (verification checklist, not a flow).
- `feishu-adapter-setup.md` — keep, will get fences in Phase 3 organic spread.

No commit yet — the deletion lands in Task 0.5.

### Task 0.3: Rename `operator-bootstrap-journey.md` → `flow-bootstrap.md`

**Files:**
- Rename: `docs/guides/operator-bootstrap-journey.md` → `docs/guides/flow-bootstrap.md`
- Rename: `docs/guides/operator-bootstrap-journey.zh_cn.md` → `docs/guides/flow-bootstrap.zh_cn.md` (if exists)

- [ ] **Step 1: Check zh_cn mirror existence**

Run: `ls docs/guides/operator-bootstrap-journey*`
Expected: one or two files. Record which.

- [ ] **Step 2: Rename via git mv**

```bash
git mv docs/guides/operator-bootstrap-journey.md docs/guides/flow-bootstrap.md
# If zh_cn mirror exists:
# git mv docs/guides/operator-bootstrap-journey.zh_cn.md docs/guides/flow-bootstrap.zh_cn.md
```

- [ ] **Step 3: Find inbound links and update them**

```bash
rg -l "operator-bootstrap-journey" --type md
```

Expected: a list of markdown files that referenced the old name. Edit each to point at `flow-bootstrap.md` (and `.zh_cn.md` where the link was zh_cn).

- [ ] **Step 4: Commit**

```bash
git commit -m "docs: rename operator-bootstrap-journey → flow-bootstrap (spec/§4 Phase 0)"
```

### Task 0.4: Rename `2026-05-10-sessiontemplate-feishu-test.md` → `flow-sessiontemplate-feishu-test.md`

**Files:**
- Rename: `docs/guides/2026-05-10-sessiontemplate-feishu-test.md` → `docs/guides/flow-sessiontemplate-feishu-test.md`
- Rename: `docs/guides/2026-05-10-sessiontemplate-feishu-test.zh_cn.md` → `docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md`

- [ ] **Step 1: git mv both files**

```bash
git mv docs/guides/2026-05-10-sessiontemplate-feishu-test.md \
       docs/guides/flow-sessiontemplate-feishu-test.md
git mv docs/guides/2026-05-10-sessiontemplate-feishu-test.zh_cn.md \
       docs/guides/flow-sessiontemplate-feishu-test.zh_cn.md
```

- [ ] **Step 2: Find inbound links and update**

```bash
rg -l "2026-05-10-sessiontemplate-feishu-test" --type md
```

Update each match to the new filename.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: rename sessiontemplate-feishu-test guide to flow- convention"
```

### Task 0.5: Delete `writing-an-agent-topology.md` (stale)

**Files:**
- Delete: `docs/guides/writing-an-agent-topology.md`
- Delete: `docs/guides/writing-an-agent-topology.zh_cn.md` (if exists)

- [ ] **Step 1: Confirm the guide is stale**

```bash
rg -n "agents\.yaml" docs/guides/writing-an-agent-topology.md | head -5
```

Expected: matches showing it documents the dissolved `agents.yaml`. If output is empty (the guide was already updated since the audit), STOP and reassess — skip this task and note in the PR body.

- [ ] **Step 2: Find inbound links**

```bash
rg -l "writing-an-agent-topology" --type md
```

Expected: zero or few matches. For each match, replace the link with a pointer to the new `agent_kinds:` documentation in the relevant plugin manifest spec, or remove the link entirely.

- [ ] **Step 3: Delete + commit**

```bash
git rm docs/guides/writing-an-agent-topology.md
# If zh_cn exists:
# git rm docs/guides/writing-an-agent-topology.zh_cn.md
git commit -m "docs: drop writing-an-agent-topology — agents.yaml dissolved PR-328"
```

### Task 0.6: Create `docs/guides/full-user-journey.md` index skeleton

**Files:**
- Create: `docs/guides/full-user-journey.md`
- Create: `docs/guides/full-user-journey.zh_cn.md`

- [ ] **Step 1: Write the English index**

Create `docs/guides/full-user-journey.md` with this content:

```markdown
# ESR full user journey

The complete operator-facing journey, broken into sub-flows. Each
sub-flow has its own fenced guide that doubles as the e2e replay
source. CI runs `scripts/replay-guide.sh` against every fenced
guide on every PR.

**Vocabulary:** see [`CONTEXT.md`](../../CONTEXT.md) for the
journey/flow/guide/scenario terms.

| Sub-flow | What it covers | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd → first user → register adapter → bind feishu → workspace + session + agent → first CC reply | [flow-bootstrap.md](flow-bootstrap.md) | [19_session_first_default.sh](../../tests/e2e/scenarios/19_session_first_default.sh) |
| SessionTemplate (Feishu test) | Operator end-to-end test of SessionTemplate + Channel migration | [flow-sessiontemplate-feishu-test.md](flow-sessiontemplate-feishu-test.md) | (none yet — Phase 3 organic) |

Rows for further sub-flows (multi-session, PTY attach, plugin lifecycle,
bundle install, ...) are added by feature PRs as they ship — see the
anti-drift rule in [spec §3.3](../superpowers/specs/2026-05-10-guide-driven-e2e.md#33-docsguidesfull-user-journeymd--the-gold-standard-index).
```

- [ ] **Step 2: Write the zh_cn mirror**

Create `docs/guides/full-user-journey.zh_cn.md` with:

```markdown
# ESR 全部用户 journey

完整的操作员可见 journey，按 sub-flow 切分。每个 sub-flow 自己的
fenced 指南同时充当 e2e 回放源。CI 在每个 PR 上对所有有 fence 的
指南跑 `scripts/replay-guide.sh`。

**术语：** 见 [`CONTEXT.md`](../../CONTEXT.md) 中的
journey/flow/guide/scenario 定义。

| Sub-flow | 覆盖什么 | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd → 第一个 user → 注册 adapter → 绑 feishu → workspace + session + agent → 第一次 CC 回复 | [flow-bootstrap.zh_cn.md](flow-bootstrap.zh_cn.md) | [19_session_first_default.sh](../../tests/e2e/scenarios/19_session_first_default.sh) |
| SessionTemplate（Feishu 测试） | 操作员端到端测 SessionTemplate + Channel migration | [flow-sessiontemplate-feishu-test.zh_cn.md](flow-sessiontemplate-feishu-test.zh_cn.md) | （暂无 —— Phase 3 organic） |

更多 sub-flow（multi-session、PTY attach、plugin lifecycle、bundle
install 等）随功能 PR 上线时补充——见 [spec §3.3](../superpowers/specs/2026-05-10-guide-driven-e2e.zh_cn.md#33-docsguidesfull-user-journeymd--金标准索引) 防腐烂规则。
```

- [ ] **Step 3: Commit**

```bash
git add docs/guides/full-user-journey.md docs/guides/full-user-journey.zh_cn.md
git commit -m "docs(guides): add full-user-journey index (spec §3.3)"
```

### Task 0.7: Open Phase 0 PR + admin-merge

**Files:** none (git/gh only)

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/guide-driven-e2e-phase-0-audit
```

- [ ] **Step 2: Open PR with audit summary in body**

```bash
gh pr create --base dev --title "docs(guides): Phase 0 audit + rename for guide-driven e2e" \
  --body "$(cat <<'EOF'
## Summary
Phase 0 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). Pure docs cleanup — no behavior change.

- Rename `operator-bootstrap-journey.md` → `flow-bootstrap.md` (+ zh_cn)
- Rename `2026-05-10-sessiontemplate-feishu-test.md` → `flow-sessiontemplate-feishu-test.md` (+ zh_cn)
- Delete `writing-an-agent-topology.md` (references dissolved `agents.yaml`, replaced by `agent_kinds:` block in plugin manifests per PR-328)
- Create `docs/guides/full-user-journey.md` (+ zh_cn) as the canonical journey index

## Test plan
- [ ] `rg "operator-bootstrap-journey" --type md` returns no matches
- [ ] `rg "2026-05-10-sessiontemplate-feishu-test" --type md` returns no matches
- [ ] `rg "writing-an-agent-topology" --type md` returns no matches
- [ ] `docs/guides/full-user-journey.md` exists and has two seed rows

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI then admin-merge**

```bash
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

Expected: PR merged into dev. Branch deleted.

---

## Phase 1: Foundation (1 PR, ~250 LOC)

Builds the replay machinery, hook, CI step, and smoke test. After this phase, CI runs replay against the synthetic smoke guide (PASS); no production guide is fenced yet.

### Task 1.1: Open Phase 1 branch

**Files:** none (git only)

- [ ] **Step 1: Create branch off latest dev (which now includes Phase 0)**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-1-foundation origin/dev
```

### Task 1.2: Create the synthetic smoke guide

**Files:**
- Create: `docs/guides/_replay_smoke.md`

- [ ] **Step 1: Write the smoke guide**

Create `docs/guides/_replay_smoke.md` with content:

````markdown
# _replay_smoke (CI synthetic)

Synthetic guide that exercises `scripts/replay-guide.sh` on every CI
run. One input/output fence pair. Not user-facing — leading underscore
keeps it out of full-user-journey.md.

### Step 1: register adapter, bot replies with the registered id

```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/adapter:register name=esr_helper_dev app_id=cli_a9563cc03d399cc9 app_secret=dummy_for_smoke
```

```chat-output
ok: true
adapter: esr_helper_dev
```
````

The leading `_` prefix is the convention for "private to the replay
harness" — `scripts/replay-guide.sh` and the CI loop both skip files
named `_*.md` unless explicitly given as an arg.

- [ ] **Step 2: Commit**

```bash
git add docs/guides/_replay_smoke.md
git commit -m "docs(guides): add _replay_smoke.md synthetic CI guide"
```

### Task 1.3: Write `scripts/replay-guide.sh` skeleton + smoke test

**Files:**
- Create: `scripts/replay-guide.sh`

- [ ] **Step 1: Write the skeleton**

Create `scripts/replay-guide.sh` with this content. ~100 LOC; uses `tests/e2e/scenarios/common.sh` helpers (`start_mock_feishu`, `start_esrd`, `seed_capabilities`, `_e2e_teardown`).

```bash
#!/usr/bin/env bash
# scripts/replay-guide.sh — replay a guide's chat-input/chat-output
# fences against a fresh esrd + mock_feishu fixture. See
# docs/superpowers/specs/2026-05-10-guide-driven-e2e.md §3.1.

set -Eeuo pipefail

GUIDE_PATH="${1:-}"
if [[ -z "${GUIDE_PATH}" || ! -f "${GUIDE_PATH}" ]]; then
  echo "usage: scripts/replay-guide.sh <guide-path>" >&2
  exit 64
fi

# --- bootstrap shared e2e helpers -----------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ESR_E2E_RUN_ID="replay-$(date +%s)-$$"

# shellcheck source=../tests/e2e/scenarios/common.sh
source "${REPO_ROOT}/tests/e2e/scenarios/common.sh"

# --- mapping table: logical user name -> synthetic open_id ----------
declare -A USER_MAP=(
  [linyilun]="ou_test_linyilun"
)

# Build a JSON map (used by the python parser via env var) so the
# parser can resolve user= without re-reading the bash table.
USER_MAP_JSON='{"linyilun":"ou_test_linyilun"}'
export USER_MAP_JSON

# --- parse fences from the guide ------------------------------------
# Emits one JSON object per fence on stdout, e.g.:
#   {"kind":"input","app_id":"...","chat_id":"...","user":"...","body":"..."}
#   {"kind":"output","capture":"session_id","body":"..."}
FENCES_JSON=$(uv run --project py python3 - "${GUIDE_PATH}" <<'PY'
import json, re, sys
guide = sys.argv[1]
text = open(guide, encoding="utf-8").read()
pat = re.compile(
    r"^```(chat-input|chat-output)([^\n]*)\n(.*?)\n```",
    re.MULTILINE | re.DOTALL,
)
out = []
for m in pat.finditer(text):
    kind = "input" if m.group(1) == "chat-input" else "output"
    attrs = {}
    for kv in m.group(2).strip().split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            attrs[k] = v
    out.append({"kind": kind, "attrs": attrs, "body": m.group(3)})
print(json.dumps(out))
PY
)

# --- pair input/output ---------------------------------------------
N_FENCES=$(jq 'length' <<<"${FENCES_JSON}")
if [[ "${N_FENCES}" -eq 0 ]]; then
  echo "replay-guide: ${GUIDE_PATH} has no chat-* fences, skipping" >&2
  exit 0
fi

# --- bootstrap fixture ----------------------------------------------
seed_capabilities
start_mock_feishu
start_esrd

declare -A CAPTURES=()
declare -A BOUND_USERS=()

PASS_COUNT=0
FAIL_AT=""

i=0
while [[ $i -lt $N_FENCES ]]; do
  IN_FENCE=$(jq -c ".[$i]" <<<"${FENCES_JSON}")
  IN_KIND=$(jq -r '.kind' <<<"${IN_FENCE}")
  if [[ "${IN_KIND}" != "input" ]]; then
    echo "replay-guide: ${GUIDE_PATH} fence #$i is ${IN_KIND}, expected input (alignment error)" >&2
    exit 65
  fi

  OUT_FENCE=$(jq -c ".[$((i+1))]" <<<"${FENCES_JSON}")
  OUT_KIND=$(jq -r '.kind' <<<"${OUT_FENCE}")
  if [[ "${OUT_KIND}" != "output" ]]; then
    echo "replay-guide: ${GUIDE_PATH} fence #$((i+1)) is ${OUT_KIND}, expected output (unpaired input)" >&2
    exit 65
  fi

  # --- resolve user= (auto-bind on first encounter) ---
  USER_NAME=$(jq -r '.attrs.user // "linyilun"' <<<"${IN_FENCE}")
  if [[ -z "${BOUND_USERS[${USER_NAME}]:-}" ]]; then
    OPEN_ID=$(jq -r --arg n "${USER_NAME}" '.[$n] // empty' <<<"${USER_MAP_JSON}")
    if [[ -z "${OPEN_ID}" ]]; then
      echo "replay-guide: unknown user=${USER_NAME} (extend USER_MAP_JSON in scripts/replay-guide.sh)" >&2
      exit 66
    fi
    # Auto-create user + feishu_bind via admin queue (one-time bootstrap).
    esr_cli admin submit user_add --arg name="${USER_NAME}" --wait --timeout 30 >/dev/null
    esr_cli admin submit feishu_bind \
      --arg username="${USER_NAME}" --arg open_id="${OPEN_ID}" \
      --wait --timeout 30 >/dev/null || true
    BOUND_USERS[${USER_NAME}]=1
  fi

  # --- send chat-input via push_inbound -------------
  APP_ID=$(jq -r '.attrs.app_id // "esr_helper_dev"' <<<"${IN_FENCE}")
  CHAT_ID=$(jq -r '.attrs.chat_id // "oc_test_chat"' <<<"${IN_FENCE}")
  OPEN_ID=$(jq -r --arg n "${USER_NAME}" '.[$n]' <<<"${USER_MAP_JSON}")
  BODY=$(jq -r '.body' <<<"${IN_FENCE}")

  # Substitute {{varname}} from prior captures
  for varname in "${!CAPTURES[@]}"; do
    BODY="${BODY//\{\{${varname}\}\}/${CAPTURES[${varname}]}}"
  done

  curl -sS -X POST "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "${BODY}" --arg c "${CHAT_ID}" \
              --arg o "${OPEN_ID}" --arg a "${APP_ID}" \
              '{text:$t, chat_id:$c, sender_open_id:$o, app_id:$a}')" \
    >/dev/null

  # --- poll reply_capture (or chat-history GET) for new bot reply ---
  EXPECTED=$(jq -r '.body' <<<"${OUT_FENCE}")
  CAPTURE_VAR=$(jq -r '.attrs.capture // empty' <<<"${OUT_FENCE}")
  DEADLINE=$(( $(date +%s) + 30 ))
  REPLY=""
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    LATEST=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/open-apis/im/v1/messages?chat_id=${CHAT_ID}" \
             | jq -r '.data.items[0].body.content // empty' 2>/dev/null || true)
    if [[ -n "${LATEST}" && "${LATEST}" != "${LAST_SEEN:-}" ]]; then
      REPLY="${LATEST}"; LAST_SEEN="${LATEST}"; break
    fi
    sleep 0.2
  done

  if [[ -z "${REPLY}" ]]; then
    FAIL_AT="step $((i/2 + 1)): no reply within 30s"
    break
  fi

  # --- diff line-by-line with placeholder substitution ---
  if ! _replay_diff "${EXPECTED}" "${REPLY}" "${CAPTURE_VAR}"; then
    FAIL_AT="step $((i/2 + 1)): output mismatch"
    break
  fi

  PASS_COUNT=$((PASS_COUNT + 1))
  i=$((i + 2))
done

if [[ -n "${FAIL_AT}" ]]; then
  echo "${GUIDE_PATH}: ${PASS_COUNT} step(s) passed, FAIL at ${FAIL_AT}"
  exit 1
fi

echo "${GUIDE_PATH}: ${PASS_COUNT} step(s) replayed, PASS"
exit 0
```

- [ ] **Step 2: Add the `_replay_diff` helper function near the top (after `source common.sh`)**

Insert these lines into `scripts/replay-guide.sh` right after the `source` line:

```bash
# Line-by-line diff with <UUID>/<int>/<...> placeholder substitution.
# $1 expected, $2 actual, $3 capture-var-name (optional).
_replay_diff() {
  local expected="$1" actual="$2" capture="${3:-}"
  local IFS=$'\n' read -r -a exp_lines <<<"${expected}"
  local IFS=$'\n' read -r -a act_lines <<<"${actual}"
  if [[ ${#exp_lines[@]} -ne ${#act_lines[@]} ]]; then
    echo "  line-count mismatch: expected ${#exp_lines[@]}, got ${#act_lines[@]}" >&2
    echo "  --- expected ---" >&2; echo "${expected}" >&2
    echo "  --- actual   ---" >&2; echo "${actual}" >&2
    return 1
  fi
  local k captured=""
  for k in "${!exp_lines[@]}"; do
    local pattern="${exp_lines[$k]//\</\\<}"
    pattern="${pattern//\>/\\>}"
    # Decode placeholders -> regex chunks
    local rx="${exp_lines[$k]}"
    rx="${rx//<UUID>/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}"
    rx="${rx//<int>/[0-9]+}"
    rx="${rx//<...>/.*}"
    if ! [[ "${act_lines[$k]}" =~ ^${rx}$ ]]; then
      echo "  line $((k+1)) mismatch:" >&2
      echo "    expected: ${exp_lines[$k]}" >&2
      echo "    actual:   ${act_lines[$k]}" >&2
      return 1
    fi
    # Capture: bind the first <UUID>/<int> match on any line.
    if [[ -n "${capture}" && -z "${captured}" ]]; then
      if [[ "${exp_lines[$k]}" =~ \<UUID\>|\<int\> ]]; then
        local re="^${rx}$"
        if [[ "${act_lines[$k]}" =~ ${re} ]]; then
          # Bash <5.0 doesn't have ${BASH_REMATCH[*]} reliably; re-extract via grep.
          local captured_val
          captured_val=$(echo "${act_lines[$k]}" | grep -oE '[0-9a-f-]{36}|[0-9]+' | head -1)
          CAPTURES[${capture}]="${captured_val}"
          captured=1
        fi
      fi
    fi
  done
  return 0
}
```

- [ ] **Step 3: Set executable + run shellcheck**

```bash
chmod +x scripts/replay-guide.sh
shellcheck scripts/replay-guide.sh || true   # warnings OK; errors fail PR
```

Expected: shellcheck reports zero errors. Style warnings (SC2034, SC2155) are OK and may be silenced inline.

- [ ] **Step 4: Smoke test**

```bash
bash scripts/replay-guide.sh docs/guides/_replay_smoke.md
echo "exit=$?"
```

Expected: `_replay_smoke.md: 1 step(s) replayed, PASS` and `exit=0`. If the adapter register step fails because the synthetic `app_id`/`app_secret` are rejected, adjust the smoke guide's fence body (e.g. use the actual seeded `app_id`).

- [ ] **Step 5: Commit**

```bash
git add scripts/replay-guide.sh
git commit -m "feat(replay): scripts/replay-guide.sh — parse fences + replay via mock_feishu (spec §3.1)"
```

### Task 1.4: Write `scripts/check-scenario-headers.sh`

**Files:**
- Create: `scripts/check-scenario-headers.sh`

- [ ] **Step 1: Write the linter**

```bash
#!/usr/bin/env bash
# scripts/check-scenario-headers.sh — assert every e2e scenario
# declares its source guide via a `# Replays: docs/guides/<file>.md`
# header in its first 20 lines. See spec §3.4.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO_DIR="${REPO_ROOT}/tests/e2e/scenarios"

# Files exempt from the header rule: shared helpers, smoke harness.
EXEMPT_REGEX='^(_common_selftest|common|_wait_url)\.'

fail=0
for f in "${SCENARIO_DIR}"/*.sh; do
  base="$(basename "${f}")"
  if [[ "${base}" =~ ${EXEMPT_REGEX} ]]; then
    continue
  fi
  header=$(head -20 "${f}")
  if ! grep -qE '^# Replays: docs/guides/[a-zA-Z0-9_-]+\.md' <<<"${header}"; then
    echo "FAIL: ${f} missing '# Replays: docs/guides/<file>.md' header (first 20 lines)" >&2
    fail=1
    continue
  fi
  guide=$(grep -oE 'docs/guides/[a-zA-Z0-9_-]+\.md' <<<"${header}" | head -1)
  if [[ ! -f "${REPO_ROOT}/${guide}" ]]; then
    echo "FAIL: ${f} references missing guide ${guide}" >&2
    fail=1
  fi
done

if [[ ${fail} -ne 0 ]]; then
  exit 1
fi
echo "check-scenario-headers: all scenarios have valid headers"
```

- [ ] **Step 2: chmod + run with current (un-migrated) scenarios — expect failures listing**

```bash
chmod +x scripts/check-scenario-headers.sh
bash scripts/check-scenario-headers.sh || true
```

Expected: prints a list of scenarios that lack the header. This is the migration backlog. Do NOT fix them all here — Phase 2 migrates scenario 19; Phase 3 spreads.

- [ ] **Step 3: Add an exempt-list mechanism for Phase 1 (so CI passes now)**

Edit `scripts/check-scenario-headers.sh` and replace the `EXEMPT_REGEX` line with:

```bash
# Exempt list: shared helpers + scenarios pending Phase 3 migration.
# Each entry should be removed as that scenario gets `# Replays:` header.
EXEMPT_REGEX='^(_common_selftest|common|_wait_url|01_|02_|04_|05_|06_|07_|08_|11_|12_|13_|14_|15_|16_|17_|18_|20_|21_|22_|23_|24_|25_|26_|27_|28_|29_|30_)\.'
```

Adjust the prefix list to match exactly the scenarios currently in `tests/e2e/scenarios/` (use `ls tests/e2e/scenarios/ | awk -F_ '{print $1"_"}' | sort -u` to enumerate). Phase 2 will remove `19_` from the exempt list.

- [ ] **Step 4: Re-run + commit**

```bash
bash scripts/check-scenario-headers.sh
git add scripts/check-scenario-headers.sh
git commit -m "feat(replay): scripts/check-scenario-headers.sh — Replays-header linter (spec §3.4)"
```

Expected: linter exits 0 (every existing scenario is in the exempt list).

### Task 1.5: Write `scripts/hooks/replay-guide-reminder.sh`

**Files:**
- Create: `scripts/hooks/replay-guide-reminder.sh`

- [ ] **Step 1: Write the hook script**

```bash
#!/usr/bin/env bash
# scripts/hooks/replay-guide-reminder.sh — PostToolUse hook fired when
# Claude Code Edits/Writes a file. If the file matches a command handler
# path, nudge the agent/dev to run scripts/replay-guide.sh on the
# relevant guide before committing. Spec §3.5.

set -Eeuo pipefail

input="$(cat)"
fp="$(printf '%s' "${input}" | jq -r '.tool_input.file_path // empty')"
if [[ -z "${fp}" ]]; then
  exit 0
fi

case "${fp}" in
  runtime/lib/esr/commands/*.ex|*/runtime/lib/esr/commands/*.ex)
    base="$(basename "${fp}" .ex | tr A-Z a-z)"
    cat >&2 <<EOF
⚠️  You edited ${fp}.
Before committing, run scripts/replay-guide.sh against any guide that
references this command. Find candidates:
    rg "${base}" docs/guides/
EOF
    ;;
esac
```

- [ ] **Step 2: chmod + smoke test**

```bash
chmod +x scripts/hooks/replay-guide-reminder.sh
# Simulate a PostToolUse payload:
echo '{"tool_input":{"file_path":"runtime/lib/esr/commands/session/new.ex"}}' \
  | bash scripts/hooks/replay-guide-reminder.sh
```

Expected: emits the warning text to stderr; exit 0.

- [ ] **Step 3: Confirm it's silent for non-command edits**

```bash
echo '{"tool_input":{"file_path":"runtime/lib/esr/foo.ex"}}' \
  | bash scripts/hooks/replay-guide-reminder.sh
echo "exit=$?"
```

Expected: zero output, `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add scripts/hooks/replay-guide-reminder.sh
git commit -m "feat(hooks): replay-guide-reminder.sh — nudge on command-handler edits (spec §3.5)"
```

### Task 1.6: Register the hook in `.claude/settings.json`

**Files:**
- Modify: `.claude/settings.json`

- [ ] **Step 1: Read current settings**

```bash
cat .claude/settings.json
```

Expected: a JSON object with `hooks.PostToolUse` already containing the `openclaw-channel-postcheck.sh` entry.

- [ ] **Step 2: Add the replay-guide-reminder entry**

Edit `.claude/settings.json` so the `hooks.PostToolUse` array gains a second entry. The final shape:

```json
{
  "enableAllProjectMcpServers": true,
  "channelsEnabled": true,
  "enabledPlugins": {
    "agent-setup@agent-setup": true,
    "dev-loop-skills@ezagent42": true,
    "claude-md-management@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "ezagent42": {
      "source": {
        "source": "github",
        "repo": "ezagent42/ezagent42"
      }
    }
  },
  "permissions": {
    "allow": [
      "Edit(/Users/h2oslabs/Workspace/esr/.claude/*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PROJECT_DIR}/scripts/hooks/pre-merge-dev-gate.sh",
            "timeout": 180
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "mcp__openclaw-channel__.*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PROJECT_DIR}/scripts/hooks/openclaw-channel-postcheck.sh",
            "timeout": 5
          }
        ]
      },
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

- [ ] **Step 3: Lint with `jq`**

```bash
jq . .claude/settings.json >/dev/null
```

Expected: zero output, exit 0 (validates JSON shape).

- [ ] **Step 4: Commit**

```bash
git add .claude/settings.json
git commit -m "chore(claude): register replay-guide-reminder PostToolUse hook (spec §3.5)"
```

### Task 1.7: Add CLAUDE.md anti-drift section

**Files:**
- Modify: `CLAUDE.md` (root)

- [ ] **Step 1: Verify CLAUDE.md exists**

```bash
ls CLAUDE.md
```

If absent, create with a top-level title; otherwise edit in place.

- [ ] **Step 2: Append the section**

Use Edit to add (preserving existing content):

```markdown
## Guide-driven e2e (anti-drift)

- Edit a command handler? Run `scripts/replay-guide.sh` on the relevant guide before committing.
- Guide drift detected? Prompt the user — fix implementation OR update the guide. Don't silently ignore.
- Spec: [docs/superpowers/specs/2026-05-10-guide-driven-e2e.md](docs/superpowers/specs/2026-05-10-guide-driven-e2e.md).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude-md): add Guide-driven e2e anti-drift section (spec §3.6)"
```

### Task 1.8: Add CI workflow step — report-based gate

> **Spec rev-5 change (2026-05-11):** Replay does NOT run on CI directly
> (ubuntu-latest cannot spawn the FAA Python sidecar, see the
> `mix test on Linux CI` TODO at the bottom of `.github/workflows/ci.yml`).
> Instead: developers run `scripts/generate-e2e-report.sh` locally and
> commit `docs/e2e-reports/<short-sha>.md`; CI verifies the report
> exists, is current, and shows all guides PASS. See spec §3.7.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `scripts/verify-e2e-report.sh`
- Create: `scripts/generate-e2e-report.sh`

- [ ] **Step 1: Read current ci.yml**

```bash
cat .github/workflows/ci.yml
```

Confirm there's a `build-and-test` job (or equivalent) to extend.

- [ ] **Step 2: Write the two scripts**

`scripts/verify-e2e-report.sh` (~50 LOC): finds the latest commit in
the PR diff that touches `runtime/lib/esr/commands/` or
`docs/guides/flow-*.md` (using `git log --reverse "${GITHUB_BASE_REF:-dev}"..HEAD -- <paths>`),
requires `docs/e2e-reports/<short-sha>.md` exists for that commit,
matches its full sha, and shows no `| FAIL ` rows.

`scripts/generate-e2e-report.sh` (~80 LOC): iterates fenced guides
(`_replay_smoke.md` + every `flow-*.md` with `^```chat-input`), runs
`replay-guide.sh` on each, accumulates PASS/FAIL + step count + wall
time, writes `docs/e2e-reports/<HEAD-short-sha>.md` per the spec §3.7
schema.

- [ ] **Step 3: Append two steps to the build-and-test job**

After the existing e2e step (or near the end of the job's `steps:`), add:

```yaml
      - name: Lint scenario headers
        run: bash scripts/check-scenario-headers.sh

      - name: Verify e2e report
        # Anti-drift gate per spec §3.7. Report-based instead of
        # CI-runs-replay because Ubuntu CI cannot spawn the FAA Python
        # sidecar; ESR's only production target is macOS. Developers
        # run scripts/generate-e2e-report.sh locally and commit
        # docs/e2e-reports/<short-sha>.md.
        run: bash scripts/verify-e2e-report.sh
```

- [ ] **Step 3: Validate workflow with `actionlint` if available**

```bash
which actionlint && actionlint .github/workflows/ci.yml || true
```

Expected: zero errors. Warnings about implicit shell are OK.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add replay-guide + scenario-header lint steps (spec §3.7)"
```

### Task 1.9: Open Phase 1 PR + admin-merge

**Files:** none (git/gh only)

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/guide-driven-e2e-phase-1-foundation
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base dev --title "feat(replay): Phase 1 — replay-guide.sh + hook + CI (guide-driven e2e)" \
  --body "$(cat <<'EOF'
## Summary
Phase 1 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). Ships the replay machinery:

- `scripts/replay-guide.sh` (~100 LOC) — fence parser + fixture boot + diff
- `scripts/check-scenario-headers.sh` (~30 LOC) — Replays-header linter (current scenarios on exempt list)
- `scripts/hooks/replay-guide-reminder.sh` (~20 LOC) — PostToolUse nudge on command-handler edits
- `.claude/settings.json` — register the hook
- `CLAUDE.md` — 3-line anti-drift section
- `.github/workflows/ci.yml` — replay + header-lint steps
- `docs/guides/_replay_smoke.md` — synthetic guide for the CI smoke

## Test plan
- [ ] `bash scripts/replay-guide.sh docs/guides/_replay_smoke.md` → exits 0 with `1 step(s) replayed, PASS`
- [ ] `bash scripts/check-scenario-headers.sh` → exits 0
- [ ] `echo '{"tool_input":{"file_path":"runtime/lib/esr/commands/session/new.ex"}}' | bash scripts/hooks/replay-guide-reminder.sh` → emits warning
- [ ] CI green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI; investigate any failure (do NOT skip the replay step)**

```bash
gh pr checks --watch
```

Expected: green. If the replay smoke fails, debug locally first — most likely cause is mock_feishu start sequencing or the user_add/feishu_bind admin-submit shape.

- [ ] **Step 4: Admin-merge**

```bash
gh pr merge --admin --squash --delete-branch
```

---

## Phase 2: Canary — flow-bootstrap + regression bisect (1 PR, ~150 LOC)

Adds the first real fence sequence and uses it to prove the 2026-05-10 `/session:new name=test-cc` regression would have been caught.

### Task 2.1: Open Phase 2 branch

- [ ] **Step 1: Branch off latest dev**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/guide-driven-e2e-phase-2-canary origin/dev
```

### Task 2.2: Add fences to `docs/guides/flow-bootstrap.md`

**Files:**
- Modify: `docs/guides/flow-bootstrap.md`

- [ ] **Step 1: Read the current guide content**

```bash
cat docs/guides/flow-bootstrap.md
```

Note the 5 main steps it documents: register adapter, bind feishu, create workspace, create session, send plain text → CC reply.

- [ ] **Step 2: Add the first fence pair (adapter register) right after the existing register-adapter prose**

Use Edit to insert this fenced block after the step-1 prose:

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/adapter:register name=esr_helper_dev app_id=cli_a9563cc03d399cc9 app_secret=changeme_secret
```

```chat-output
ok: true
adapter: esr_helper_dev
```
````

- [ ] **Step 3: Add fence pair 2 — feishu_bind**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/feishu:bind
```

```chat-output
ok: true
bound_open_id: ou_test_linyilun
```
````

- [ ] **Step 4: Add fence pair 3 — workspace create**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
/workspace:new name=demo path=/tmp/replay-demo-ws
```

```chat-output
ok: true
workspace: demo
```
````

- [ ] **Step 5: Add fence pair 4 — session create (THE REGRESSION GATE)**

This is the fence that would have caught the 2026-05-10 `/session:new name=test-cc` bug. Pre-PR-#334 hits `validate_args`. Post-PR-#334 resolves via default workspace.

````markdown
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

- [ ] **Step 6: Add fence pair 5 — plain text → CC reply**

````markdown
```chat-input app_id=esr_helper_dev chat_id=oc_test_chat user=linyilun
hello, what is the current working directory?
```

```chat-output
<...>
/tmp/replay-demo-ws
<...>
```
````

- [ ] **Step 7: Commit**

```bash
git add docs/guides/flow-bootstrap.md
git commit -m "docs(guides): add fences to flow-bootstrap (Phase 2 canary, 5 pairs)"
```

### Task 2.3: Mirror fences into `flow-bootstrap.zh_cn.md`

**Files:**
- Modify: `docs/guides/flow-bootstrap.zh_cn.md`

- [ ] **Step 1: Add identical fence blocks to the zh_cn mirror**

The fences themselves are not translated (slash commands and field names are English). Only the surrounding prose is Chinese. Insert the same 5 fence pairs at the matching positions.

- [ ] **Step 2: Commit**

```bash
git add docs/guides/flow-bootstrap.zh_cn.md
git commit -m "docs(guides): mirror flow-bootstrap fences into zh_cn"
```

### Task 2.4: Local replay → PASS

- [ ] **Step 1: Run replay**

```bash
bash scripts/replay-guide.sh docs/guides/flow-bootstrap.md
```

Expected: `flow-bootstrap.md: 5 step(s) replayed, PASS`. If any step fails, the bug is real — fix the underlying production code rather than weakening the fence.

### Task 2.5: Bisect verification — PROVES the regression would have been caught

**Files:** none (git only)

- [ ] **Step 1: Stash the new fence onto a one-off branch off pre-#334 dev**

```bash
# Save the new flow-bootstrap.md content
cp docs/guides/flow-bootstrap.md /tmp/flow-bootstrap-with-fences.md
# Detach onto pre-#334 history (commit 8777357 is the merge of PR #321 / dev right before #334)
git checkout 8777357 --detach
# Copy the fenced guide + replay script onto this old tree
cp /tmp/flow-bootstrap-with-fences.md docs/guides/flow-bootstrap.md
cp scripts/replay-guide.sh /tmp/replay-guide-from-phase-1.sh
chmod +x /tmp/replay-guide-from-phase-1.sh
```

- [ ] **Step 2: Run replay against pre-#334 dev → expect FAIL at fence pair 4**

```bash
bash /tmp/replay-guide-from-phase-1.sh docs/guides/flow-bootstrap.md
echo "exit=$?"
```

Expected: prints `... FAIL at step 4: ...` (the `/session:new name=test-cc` step hits `invalid_args`); `exit=1`.

If this step PASSes, the spec's "Phase 5 should have caught the regression" claim is wrong — STOP and re-read the regression. The whole anti-drift premise depends on this step failing.

- [ ] **Step 3: Restore Phase 2 branch state**

```bash
git checkout feat/guide-driven-e2e-phase-2-canary
rm -f /tmp/flow-bootstrap-with-fences.md /tmp/replay-guide-from-phase-1.sh
```

- [ ] **Step 4: Document the bisect in a one-line commit message (no code change)**

```bash
git commit --allow-empty -m "verify: regression bisect — pre-#334 replay FAILs at step 4, post-#334 PASSes (spec §4 Phase 2 acceptance #6)"
```

### Task 2.6: Convert `scenarios/19_session_first_default.sh` to thin-wrapper

**Files:**
- Modify: `tests/e2e/scenarios/19_session_first_default.sh`

- [ ] **Step 1: Replace the body with a thin-wrapper invocation of replay-guide.sh**

Rewrite the file:

```bash
#!/usr/bin/env bash
# scenario 19 — session-first default workspace resolution.
#
# Replays: docs/guides/flow-bootstrap.md
#
# This script is a thin wrapper around scripts/replay-guide.sh. The
# real test lives in the guide's fences. Edit the guide, not this file.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

exec bash "${SCRIPT_DIR}/../../../scripts/replay-guide.sh" \
  "${SCRIPT_DIR}/../../../docs/guides/flow-bootstrap.md"
```

- [ ] **Step 2: Remove `19_` from the EXEMPT_REGEX in check-scenario-headers.sh**

Edit `scripts/check-scenario-headers.sh` and remove `19_|` from the `EXEMPT_REGEX` value.

- [ ] **Step 3: Run header linter → expect PASS**

```bash
bash scripts/check-scenario-headers.sh
```

Expected: `check-scenario-headers: all scenarios have valid headers` and exit 0.

- [ ] **Step 4: Run the migrated scenario locally**

```bash
bash tests/e2e/scenarios/19_session_first_default.sh
```

Expected: PASS via replay (5 steps replayed).

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/scenarios/19_session_first_default.sh scripts/check-scenario-headers.sh
git commit -m "test(e2e): scenario 19 → thin-wrapper around flow-bootstrap.md replay (spec §3.4)"
```

### Task 2.7: Update `full-user-journey.md` Bootstrap row

**Files:**
- Modify: `docs/guides/full-user-journey.md`
- Modify: `docs/guides/full-user-journey.zh_cn.md`

- [ ] **Step 1: Mark the Bootstrap row's scenario field as live**

In both files, the Bootstrap row's "E2E scenario" cell already points at `19_session_first_default.sh` — confirm the link still resolves after Phase 0 + Phase 2 changes; no edit needed if the link already points at the right file.

- [ ] **Step 2: Commit (no-op-friendly)**

```bash
git diff docs/guides/full-user-journey.md docs/guides/full-user-journey.zh_cn.md
# If diff non-empty:
git commit -am "docs(guides): finalize Bootstrap row in full-user-journey index"
```

### Task 2.8: Open Phase 2 PR + admin-merge

- [ ] **Step 1: Push**

```bash
git push -u origin feat/guide-driven-e2e-phase-2-canary
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base dev --title "test(e2e): Phase 2 canary — flow-bootstrap fences + scenario 19 thin-wrapper" \
  --body "$(cat <<'EOF'
## Summary
Phase 2 of [docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md](../docs/superpowers/plans/2026-05-10-guide-driven-e2e-plan.md). First real fence sequence + regression bisect proof.

- `docs/guides/flow-bootstrap.md` gains 5 fence pairs (adapter / feishu_bind / workspace / session / chat → CC reply)
- `docs/guides/flow-bootstrap.zh_cn.md` mirrors
- `tests/e2e/scenarios/19_session_first_default.sh` becomes a thin wrapper around the guide replay
- Bisect verified: pre-#334 replay FAILs at fence pair 4 (`/session:new name=test-cc`); post-#334 PASSes — see commit `verify: regression bisect`

## Test plan
- [ ] `bash scripts/replay-guide.sh docs/guides/flow-bootstrap.md` → 5 steps PASS
- [ ] `bash tests/e2e/scenarios/19_session_first_default.sh` → PASS (via replay)
- [ ] `bash scripts/check-scenario-headers.sh` → PASS
- [ ] CI green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI + admin-merge**

```bash
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## Phase 3: Organic spread (no dedicated PR)

After Phase 2 lands, the anti-drift mechanism is live. There is no batch migration — coverage grows feature-by-feature.

### Convention (no checklist; this is repo discipline)

When a feature PR touches `runtime/lib/esr/commands/*.ex`:

1. The PostToolUse hook fires and nudges the author.
2. The author either:
   - Adds fences to an existing guide (and updates the `# Replays:` header in the relevant scenario script), OR
   - Creates `docs/guides/flow-<topic>.md` (+ zh_cn) and adds a row to `full-user-journey.md`, then writes a thin-wrapper scenario referencing it.
3. PR review rejects feature PRs that touch command handlers without one of those.

### Trigger for revisiting

If a year passes (or three drift bugs slip through against commands lacking fences), open a follow-up brainstorm to add `mix esr.check_guide_coverage` as a hard CI gate. Track in `docs/futures/todo.md`.

---

## Self-Review

### Spec coverage check

| Spec section | Plan task |
|---|---|
| §1 Why now (regression context) | Task 2.5 bisect verification |
| §1.5 Vocabulary | (CONTEXT.md landed in spec rev-4, not re-landed here) |
| §2 Goals | All phases together |
| §3.1 `scripts/replay-guide.sh` | Task 1.3 |
| §3.2 Fence protocol + `user=` auto-bind | Task 1.3 (USER_MAP_JSON + auto-bind block) |
| §3.3 `full-user-journey.md` index | Task 0.6 (create) + Task 2.7 (finalize) |
| §3.4 Scenario header annotation | Task 1.4 (linter) + Task 2.6 (migrate scenario 19) |
| §3.5 Claude Code hook | Task 1.5 (script) + Task 1.6 (settings.json) |
| §3.6 CLAUDE.md addition | Task 1.7 |
| §3.7 CI workflow step | Task 1.8 |
| §3.8 All-inline fixture state | Task 2.2 (flow-bootstrap fences start from absolute zero) |
| §4 Phase 0 audit | Tasks 0.1–0.7 |
| §4 Phase 1 foundation | Tasks 1.1–1.9 |
| §4 Phase 2 canary | Tasks 2.1–2.8 |
| §4 Phase 3 organic | Plan §"Phase 3: Organic spread" |
| §5 Acceptance criteria | All criteria covered across phases; #6 (bisect proof) is Task 2.5 |
| §7 Approval gate → writing-plans | This plan is the deliverable |

No gaps.

### Placeholder scan

Searched for TBD/TODO/FIXME/XXX/???. Clean.

### Type / name consistency

- `replay-guide.sh` argument: `<guide-path>` everywhere.
- `_replay_diff` helper signature consistent (`expected, actual, capture-var-name`).
- `USER_MAP_JSON` env var name consistent between bash and python parser.
- `CAPTURES` associative array name consistent across `_replay_diff` and the main loop.
- Fence frontmatter keys: `app_id`, `chat_id`, `user`, `capture` — same in spec §3.2 and Task 1.3.
- `# Replays:` header format same in spec §3.4 and Tasks 1.4 + 2.6.

---

## Open risks (not blockers)

- **mock_feishu reply-capture polling shape.** Task 1.3 assumes `GET /open-apis/im/v1/messages?chat_id=...` returns the latest message as `.data.items[0].body.content`. If the actual response shape differs (e.g. wraps in `data.list`), Task 1.3 Step 4 smoke will fail — fix the jq path before proceeding.
- **Bash 5 dependency for `<<<` here-strings + `[[ =~ ${rx}$ ]]`.** macOS default `/bin/bash` is 3.2. The shebang `#!/usr/bin/env bash` picks up the user's Homebrew bash if installed (which is the e2e convention). CI runs on Ubuntu — bash 5 is the default.
- **Adapter `app_secret=changeme_secret` literal.** Task 2.2 fence 1 uses a placeholder secret. mock_feishu in the smoke fixture doesn't validate the secret (it short-circuits TLS), so this is fine for replay. Real Feishu testing uses the user's actual secret, which never appears in any guide.
