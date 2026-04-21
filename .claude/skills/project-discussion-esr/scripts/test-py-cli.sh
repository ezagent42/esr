#!/bin/bash
# test-runner for py-cli module
# Baseline: 90 passed in ~5.5s
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest tests/test_cli_*.py tests/test_runtime_bridge.py tests/test_cmd_run_output_format.py "$@"
