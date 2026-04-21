#!/bin/bash
# test-runner for handler-cc-session
# Baseline: 4 passed
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest ../handlers/cc_session/tests/ "$@"
