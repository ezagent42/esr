#!/bin/bash
# test-runner for handler-feishu-thread
# Baseline: 11 passed
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../handlers/feishu_thread/tests/ "$@"
