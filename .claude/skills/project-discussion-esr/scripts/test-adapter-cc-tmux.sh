#!/bin/bash
# test-runner for adapter-cc-tmux
# Baseline: 23 passed in ~0.3s
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../adapters/cc_tmux/tests/ "$@"
