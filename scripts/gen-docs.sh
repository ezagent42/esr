#!/usr/bin/env bash
# Regenerate `docs/cli-reference.md` and `docs/runtime-channel-reference.md`
# from the live click CLI tree and `runtime/lib/esr_web/cli_channel.ex`.
# PR-19 2026-04-28.
#
# Manual: run after touching `py/src/esr/cli/**` or `cli_channel.ex`'s
# dispatch clauses. Commit the regenerated files in the same PR as the
# code change so reviewers see CLI surface drift inline.
#
# CLAUDE.md adds a reminder so AI pair-programmers don't forget.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v uv >/dev/null 2>&1; then
  echo "gen-docs.sh: 'uv' not found on PATH; install via https://docs.astral.sh/uv/" >&2
  exit 1
fi

CLI_OUT="$REPO_ROOT/docs/cli-reference.md"
RUNTIME_OUT="$REPO_ROOT/docs/runtime-channel-reference.md"

echo "→ Generating $CLI_OUT"
uv run --project "$REPO_ROOT/py" python "$SCRIPT_DIR/gen_cli_reference.py" > "$CLI_OUT"

echo "→ Generating $RUNTIME_OUT"
# gen_runtime_channel_reference.py is pure stdlib (re + Path); no project
# context needed, but we still go through uv so the python version
# matches the rest of the project's tooling.
uv run --project "$REPO_ROOT/py" python "$SCRIPT_DIR/gen_runtime_channel_reference.py" > "$RUNTIME_OUT"

echo
echo "✓ Done. Review with:"
echo "    git diff $CLI_OUT $RUNTIME_OUT"
echo
echo "If the diffs reflect intentional CLI/topic changes, stage and commit"
echo "in the same PR as the source change."
