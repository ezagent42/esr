#!/bin/bash
# test-runner for runtime-core (Elixir OTP actor runtime)
# Baseline: 73 passed
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/runtime"
exec mix test \
  test/esr/application_restore_adapters_test.exs test/esr/application_restore_test.exs \
  test/esr/application_test.exs test/esr/dead_letter_test.exs \
  test/esr/peer_registry_test.exs test/esr/peer_server_action_dispatch_test.exs \
  test/esr/peer_server_emit_ack_test.exs test/esr/peer_server_esr_channel_test.exs \
  test/esr/peer_server_event_handling_test.exs test/esr/peer_server_invoke_command_test.exs \
  test/esr/peer_server_pause_test.exs test/esr/peer_server_persist_test.exs \
  test/esr/peer_server_retry_test.exs test/esr/peer_server_test.exs \
  test/esr/peer_server_tool_invoke_test.exs test/esr/peer_supervisor_test.exs \
  test/esr/session_registry_test.exs test/esr/uri_test.exs \
  test/esr/worker_supervisor_test.exs test/esr/workspaces_registry_test.exs "$@"
