#!/bin/bash
# test-runner for handler-tmux-proxy
# Baseline: 4 passed
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../handlers/tmux_proxy/tests/ "$@"
