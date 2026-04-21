#!/bin/bash
# test-runner for runtime-subsystems (AdapterHub, HandlerRouter, Topology, Persistence, Telemetry)
# Baseline: 56 passed
# NOTE: Running all subsystems in a single `mix test <dir1>/ <dir2>/ ...` hits a build-lock race on cold cache.
# Running each subgroup separately is reliable — hence the loop.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/runtime"
rc=0
for group in adapter_hub handler_router persistence telemetry topology; do
  echo "=== runtime-subsystems :: $group ==="
  mix test "test/esr/$group/" "$@" || rc=$?
done
exit "$rc"
