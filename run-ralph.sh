#!/bin/bash
# run-ralph.sh — safe launcher for the ESR v0.1 ralph-loop.
# Guards against running in the wrong directory / wrong repo.

set -euo pipefail

EXPECTED_DIR="/Users/h2oslabs/Workspace/esr"
PROMPT_FILE="docs/superpowers/ralph-loop-prompt.md"
MAX_ITER="${MAX_ITER:-200}"
PROMISE="ESR_V0_1_COMPLETE"

# ---- Guard: correct cwd --------------------------------------------------

cd "$EXPECTED_DIR"

if [[ "$(pwd)" != "$EXPECTED_DIR" ]]; then
    echo "✗ refusing to run: wrong cwd ($(pwd))" >&2
    exit 1
fi

# ---- Guard: correct git repo ---------------------------------------------

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$repo_root" != "$EXPECTED_DIR" ]]; then
    echo "✗ refusing to run: git root is '$repo_root', expected '$EXPECTED_DIR'" >&2
    exit 1
fi

# ---- Guard: prompt file exists ------------------------------------------

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "✗ refusing to run: $PROMPT_FILE missing" >&2
    exit 1
fi

# ---- Launch -------------------------------------------------------------

echo "▶ ESR v0.1 ralph-loop"
echo "  cwd:     $(pwd)"
echo "  prompt:  $PROMPT_FILE"
echo "  promise: $PROMISE"
echo "  max:     $MAX_ITER iterations"
echo ""
echo "Paste the following into an esr-rooted Claude Code session:"
echo ""
echo "  /ralph-loop \"\$(cat $PROMPT_FILE)\" --completion-promise \"$PROMISE\" --max-iterations $MAX_ITER"
echo ""
echo "If you're seeing this script output outside Claude Code, that's expected —"
echo "/ralph-loop is a Claude Code slash command, not a shell command."
