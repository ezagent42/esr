#!/bin/bash
# test-runner for py-ipc module
# Baseline: 75 passed, 1 skipped (test_ipc_integration_live — gated on ESR_E2E_RUNTIME=1) in ~1.9s
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/py"
exec uv run pytest \
  tests/test_envelope.py tests/test_channel_client.py tests/test_channel_client_call.py \
  tests/test_channel_pusher.py tests/test_adapter_loader.py tests/test_adapter_manifest.py \
  tests/test_adapter_runner.py tests/test_adapter_runner_main.py tests/test_adapter_runner_run.py \
  tests/test_handler_worker.py tests/test_handler_worker_main.py tests/test_handler_worker_run.py \
  tests/test_ipc_integration.py tests/test_url_discovery.py "$@"
