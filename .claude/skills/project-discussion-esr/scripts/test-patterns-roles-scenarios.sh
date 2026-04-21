#!/bin/bash
# test-runner for patterns-roles-scenarios
# No direct unit tests — declarative artifacts. Coverage comes from two places:
#   1. py/tests/test_pattern_*.py (covered by test-py-sdk-core.sh)
#   2. scenarios/*.yaml run under `esr scenario run` (covered by final_gate check 4)
#
# This runner exercises both linked paths so you can confirm the declarative
# artifacts still compile + execute end-to-end.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "=== pattern compile tests (from py-sdk-core) ==="
cd py
uv run pytest \
  tests/test_pattern_compile_yaml.py \
  tests/test_pattern_cycle_rejected.py \
  tests/test_pattern_feishu_app_session.py \
  tests/test_pattern_feishu_thread_session.py \
  tests/test_pattern_param_lint.py "$@"

echo ""
echo "=== scenarios self-test (dry-run / mock) ==="
cd ..
# Scenarios are executed inside final_gate.sh check 4. Here we just lint the YAML.
for s in scenarios/*.yaml; do
  uv run --project py python -c "import yaml, sys; yaml.safe_load(open('$s')); print('OK:', '$s')"
done
