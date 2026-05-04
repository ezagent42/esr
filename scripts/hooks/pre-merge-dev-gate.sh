#!/usr/bin/env bash
# scripts/hooks/pre-merge-dev-gate.sh — Claude Code PreToolUse hook.
#
# Wired in `.claude/settings.json` as a PreToolUse hook on the Bash tool.
# Reads the tool-call JSON on stdin, and if the command is a `gh pr merge`
# targeting `dev`, runs the e2e + agent-browser gate. On failure, prints
# a structured block message and exits non-zero so Claude Code refuses
# the merge.
#
# Why a precondition gate, not just CI:
#   - dev is the deploy target for esrd-dev (running on the operator's
#     machine, exposed via Tailscale at 100.64.0.27:4001). A bad merge
#     to dev affects the running service immediately.
#   - GitHub branch protection requires admin-bypass for our parallel-
#     squash workflow, so CI doesn't block. The discipline has to live
#     locally.
#   - PR-156 (rows/cols swap) was caught only after the user opened the
#     attach page; tests at the time didn't exercise visual rendering.
#     This gate adds a screenshot-shape check so the analogous bug class
#     is caught before merge.
#
# Exit codes (per Claude Code hook protocol):
#   0  - allow the operation (default; gate not applicable OR all checks passed)
#   2  - block, with human-readable explanation on stderr
#
# This script is fast-path on irrelevant Bash commands: <50ms when the
# command isn't a `gh pr merge` to dev. It only spins up e2e + Chrome
# when it's actually gating something.

set -uo pipefail

REPO_ROOT="${ESR_REPO_DIR:-/Users/h2oslabs/Workspace/esr/.worktrees/dev}"

# --- Step 0: parse stdin JSON, fast-path irrelevant calls ----------------

INPUT="$(cat)"
TOOL_NAME=$(echo "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || true)

if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)

# Match `gh pr merge` (the only command we gate). Use a permissive grep —
# we'll do precise base-branch detection below.
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+merge\b'; then
  exit 0
fi

# --- Step 1: figure out if the merge target is `dev` ---------------------
#
# Three flavors of `gh pr merge`:
#   (a) gh pr merge --base dev          → explicit, easy
#   (b) gh pr merge 159 --admin --squash → no --base; use the PR's own base
#   (c) gh pr merge                       → current branch's PR; ditto
#
# For (b)/(c) we need to ask gh what the base is.

target_base=""
if echo "$COMMAND" | grep -qE -- '--base[[:space:]=]+dev\b'; then
  target_base="dev"
elif echo "$COMMAND" | grep -qE -- '--base[[:space:]=]+[^[:space:]]+'; then
  # Explicit non-dev base; we don't gate.
  exit 0
else
  # No --base. Ask gh for the PR's base.
  pr_num=$(echo "$COMMAND" | grep -oE 'gh\s+pr\s+merge\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [[ -n "$pr_num" ]]; then
    target_base=$(gh -R "${ESR_GH_REPO:-ezagent42/esr}" pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
  else
    # No PR number — `gh pr merge` infers from current branch. Same query.
    target_base=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
  fi
fi

if [[ "$target_base" != "dev" ]]; then
  # Merge isn't targeting dev — not our problem.
  exit 0
fi

# --- Step 2: run the gate ------------------------------------------------

cd "$REPO_ROOT" || {
  echo "pre-merge-dev-gate: cannot cd to $REPO_ROOT" >&2
  exit 2
}

GATE_LOG=$(mktemp)
trap 'rm -f "$GATE_LOG"' EXIT

fail() {
  cat >&2 <<EOF
🚫 pre-merge-dev-gate BLOCKED the merge to dev.

Reason: $1

The merge command was:
  $COMMAND

Gate output (last 30 lines):
$(tail -30 "$GATE_LOG" 2>/dev/null | sed 's/^/  /')

Fix the failure (or update the e2e/browser tests if the failure is
spurious), then retry the merge command. The gate runs:
  - tests/e2e/scenarios/06_pty_attach.sh (HTML shell smoke)
  - tests/e2e/scenarios/07_pty_bidir.sh  (Feishu→cc roundtrip)
  - agent-browser /attach render check (xterm cols/rows ≥ 100/30)
EOF
  exit 2
}

# 2a. e2e scenarios
echo "=== scenario 06 ===" > "$GATE_LOG"
if ! bash tests/e2e/scenarios/06_pty_attach.sh >>"$GATE_LOG" 2>&1; then
  fail "e2e scenario 06 (HTML shell smoke) failed"
fi

echo "=== scenario 07 ===" >> "$GATE_LOG"
if ! bash tests/e2e/scenarios/07_pty_bidir.sh >>"$GATE_LOG" 2>&1; then
  fail "e2e scenario 07 (PTY ↔ cc_mcp bidirectional) failed"
fi

# 2b. agent-browser render check
#
# Two layers, additive:
#
#   (i)  Chrome --dump-dom: xterm.js dataset attrs (cols/rows) are set
#        synchronously inside openTerminal() after fitAddon.fit(). This
#        catches viewport / layout regressions but NOT wire-protocol
#        regressions (PR-156 rows/cols swap shipped with valid
#        cols/rows in the DOM yet a broken WS frame ordering).
#
#   (ii) agent-browser content assertion (memory rule §K, todo.md item):
#        Playwright-driven load → screenshot → DOM-text grab via
#        `agent-browser get text .xterm-rows`. Confirms the page
#        rendered SOMETHING (the [session ended] overlay for an
#        unguarded sid, or PTY content if a backing PTY exists). A
#        zero-byte / empty xterm grid trips the gate.
echo "=== agent-browser render check ===" >> "$GATE_LOG"
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
if [[ ! -x "$CHROME" ]]; then
  echo "(skipping — Google Chrome not installed at $CHROME)" >> "$GATE_LOG"
else
  PROBE_SID="HOOK_GATE_$(date +%s%N)"
  PROBE_URL="http://${ESR_PUBLIC_HOST:-127.0.0.1}:${PORT:-4001}/sessions/${PROBE_SID}/attach"
  TMPDIR=$(mktemp -d)
  DUMP=$(mktemp)
  # (i) Layer 1: dump-dom for cols/rows.
  # virtual-time-budget here is OK: app.js's xterm setup is rAF-driven
  # and renderer-synchronous; no WS roundtrip is required to populate
  # the data-opened-cols/rows dataset attrs (those are set inside
  # openTerminal() right after fitAddon.fit()). The flag advances
  # virtual time so the rAFs fire before Chrome dumps. Compare this
  # with --screenshot mode where async WS data DOES matter and
  # virtual-time-budget would cut it off — which is why we use
  # --run-all-compositor-stages-before-draw there but NOT here.
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1512,982 \
    --force-device-scale-factor=2 \
    --virtual-time-budget=4000 \
    --user-data-dir="$TMPDIR" \
    --dump-dom "$PROBE_URL" > "$DUMP" 2>>"$GATE_LOG" &
  CHROME_PID=$!
  ( sleep 12; kill -9 $CHROME_PID 2>/dev/null ) &
  KILLER=$!
  wait $CHROME_PID 2>/dev/null
  kill $KILLER 2>/dev/null
  rm -rf "$TMPDIR"

  cols=$(grep -oE 'data-opened-cols="[0-9]+"' "$DUMP" | grep -oE '[0-9]+' | head -1)
  rows=$(grep -oE 'data-opened-rows="[0-9]+"' "$DUMP" | grep -oE '[0-9]+' | head -1)
  echo "cols=${cols:-MISSING} rows=${rows:-MISSING}" >> "$GATE_LOG"
  rm -f "$DUMP"

  if [[ -z "$cols" || -z "$rows" ]]; then
    fail "agent-browser: xterm.js dataset attrs missing — page didn't render correctly"
  fi
  if (( cols < 100 || cols > 300 )); then
    fail "agent-browser: cols=$cols out of expected range 100..300"
  fi
  if (( rows < 30 || rows > 100 )); then
    fail "agent-browser: rows=$rows out of expected range 30..100"
  fi

  # (ii) Layer 2: agent-browser content assertion.
  if ! command -v agent-browser >/dev/null 2>&1; then
    echo "(skipping content assertion — agent-browser not on PATH)" >> "$GATE_LOG"
  else
    echo "--- agent-browser content assertion ---" >> "$GATE_LOG"
    # Open the same probe URL via Playwright (real WS connection, not
    # one-shot Chrome dump) and read xterm.js's rendered rows.
    if ! agent-browser open "$PROBE_URL" >>"$GATE_LOG" 2>&1; then
      fail "agent-browser open failed for $PROBE_URL"
    fi
    # Wait for xterm to mount + WS to connect. The session-ended overlay
    # should appear within ~2s for an unguarded sid (no PTY backing).
    agent-browser wait 3000 >>"$GATE_LOG" 2>&1 || true

    SHOT=$(mktemp -t pre_merge_gate.XXXXXX.png)
    if ! agent-browser screenshot "$SHOT" >>"$GATE_LOG" 2>&1; then
      rm -f "$SHOT"
      fail "agent-browser screenshot failed"
    fi
    SHOT_SIZE=$(stat -f %z "$SHOT" 2>/dev/null || stat -c %s "$SHOT" 2>/dev/null || echo 0)
    rm -f "$SHOT"
    echo "screenshot bytes=$SHOT_SIZE" >> "$GATE_LOG"
    # A genuinely empty/blank PNG is < ~1 KB. Real renders are 5KB+
    # even for a single-line overlay.
    if [[ "$SHOT_SIZE" -lt 1500 ]]; then
      fail "agent-browser screenshot trivially small ($SHOT_SIZE bytes) — page may have failed to render"
    fi

    # xterm.js mounts `.xterm-screen` inside the `#term` div after
    # term.open() succeeds — that requires (a) the bundle loaded,
    # (b) container had measurable dimensions, (c) fontFamily resolved.
    # Its presence proves xterm.js initialization completed without
    # exception. Without it, scripts/hooks would have only the dataset
    # cols/rows attrs (set just before .xterm-screen mounts) — a
    # construct-then-throw bug could pass the cols/rows check yet
    # leave the screen unrendered.
    SCREEN_COUNT=$(agent-browser get count ".xterm-screen" 2>>"$GATE_LOG" || echo 0)
    echo "xterm-screen count=${SCREEN_COUNT}" >> "$GATE_LOG"
    if [[ "$SCREEN_COUNT" != "1" ]]; then
      fail "agent-browser: .xterm-screen missing — xterm.js init didn't complete"
    fi

    # The bundled JS is also expected to install a textarea for input
    # (xterm-helper-textarea). Together with .xterm-screen this is two
    # independent post-init invariants — a partial JS load that
    # rendered the screen but skipped event wiring would still fail.
    HELPER_COUNT=$(agent-browser get count ".xterm-helper-textarea" 2>>"$GATE_LOG" || echo 0)
    echo "xterm-helper-textarea count=${HELPER_COUNT}" >> "$GATE_LOG"
    if [[ "$HELPER_COUNT" != "1" ]]; then
      fail "agent-browser: .xterm-helper-textarea missing — xterm input wiring incomplete"
    fi
  fi
fi

# All clear — let the merge proceed.
exit 0
