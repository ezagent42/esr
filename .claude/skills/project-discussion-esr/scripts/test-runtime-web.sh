#!/bin/bash
# test-runner for runtime-web (Phoenix channels)
# Baseline: 22 passed + 4 flaky (ELIXIR-1 CliChannelTest timing) in parallel mode.
# With --max-cases 1 --seed 0: reduces to 2 flakes.
# The critical integration test (channel_integration_test.exs) passes reliably.
# NOTE: `mix test test/esr_web/` (with trailing slash) discovers 0 tests.
# We enumerate the four test files explicitly to work around this quirk.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/runtime"
exec mix test \
  test/esr_web/channel_channel_test.exs \
  test/esr_web/channel_integration_test.exs \
  test/esr_web/cli_channel_test.exs \
  test/esr_web/controllers/error_json_test.exs "$@"
