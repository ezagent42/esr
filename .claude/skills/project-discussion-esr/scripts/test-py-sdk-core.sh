#!/bin/bash
# test-runner for py-sdk-core module
# Baseline: 149 passed (no failures, no skipped) in ~0.9s
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest \
  tests/test_actions.py tests/test_adapter.py tests/test_adapter_layout.py \
  tests/test_command.py tests/test_command_compose.py tests/test_command_yaml.py \
  tests/test_events.py tests/test_handler.py tests/test_handler_layout.py \
  tests/test_optimizer_cse.py tests/test_optimizer_dead_node.py tests/test_package.py \
  tests/test_pattern_compile_yaml.py tests/test_pattern_cycle_rejected.py \
  tests/test_pattern_feishu_app_session.py tests/test_pattern_feishu_thread_session.py \
  tests/test_pattern_param_lint.py tests/test_public_api.py tests/test_uri.py \
  tests/test_workspaces.py "$@"
