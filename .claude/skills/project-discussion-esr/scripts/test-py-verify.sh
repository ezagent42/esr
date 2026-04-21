#!/bin/bash
# test-runner for py-verify module
# Baseline: 32 passed in ~0.6s
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest \
  tests/test_capability.py tests/test_handlers_cross_cutting.py \
  tests/test_purity_frozen.py tests/test_purity_imports.py "$@"
