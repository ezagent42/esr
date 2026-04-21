#!/bin/bash
# test-runner for handler-feishu-app
# Baseline: 12 passed
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../handlers/feishu_app/tests/ "$@"
