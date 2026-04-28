#!/usr/bin/env bash
# Convenience wrapper: `./esr.sh <subcmd>` instead of
# `uv run --project py esr <subcmd>`. Call from anywhere via absolute
# path or symlink — the wrapper resolves the repo root from $0 so cwd
# doesn't matter.
#
# Long-term plan is to replace this with a packaged binary
# (PyInstaller / shiv / pex) so operators don't need uv on PATH.
# Tracked at docs/futures/esr-cli-binary.md.
#
# Usage examples:
#   ./esr.sh status
#   ./esr.sh adapter feishu create-app --name "ESR 助手" --target-env prod
#   ESRD_HOME=~/.esrd-dev ./esr.sh actors list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v uv >/dev/null 2>&1; then
  echo "esr.sh: 'uv' not found on PATH; install via https://docs.astral.sh/uv/" >&2
  exit 1
fi

exec uv run --project "$SCRIPT_DIR/py" esr "$@"
