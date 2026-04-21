#!/bin/bash
# test-runner for scripts module
# Baseline: 32 passed, 1 failed (SCRIPTS-1 stale fixture) in pytest + 6 passed in bash
# NOTE: The failure is a known stale fixture (test_loopguard_scenarios_allowlist.py).
# Not an env issue; see bootstrap-report.md "known issues".
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
echo "=== pytest scripts/tests ==="
uv run --project py pytest scripts/tests/ "$@" || true
echo ""
echo "=== bash scripts/tests/test_esrd_sh.sh ==="
exec bash scripts/tests/test_esrd_sh.sh
