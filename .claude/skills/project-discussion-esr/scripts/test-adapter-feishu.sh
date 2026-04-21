#!/bin/bash
# test-runner for adapter-feishu
# Baseline: 40 passed in ~90s (slow due to lark_oapi + ws deps)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../adapters/feishu/tests/ "$@"
