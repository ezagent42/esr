#!/usr/bin/env bash
# Self-test for common.sh — exits non-zero on any helper misbehaviour.
# Run in CI before the real scenarios to catch common.sh regressions.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# assert_eq positive
assert_eq "hello" "hello" "equal strings should pass"

# assert_eq negative — run in subshell, expect non-zero
( assert_eq "a" "b" "deliberate mismatch" ) && \
  { echo "FAIL: assert_eq accepted mismatch"; exit 1; } || true

# assert_contains
assert_contains "hello world" "world" "contains substring"

# barrier round-trip
barrier_signal test_barrier_self
barrier_wait test_barrier_self 5

# baseline diff idempotency
snap_a=$(e2e_tmp_baseline_snapshot)
snap_b=$(e2e_tmp_baseline_snapshot)
[[ "$snap_a" == "$snap_b" ]] || { echo "FAIL: baseline not idempotent"; exit 1; }

# PR-9 T9: wait_for_sidecar_ready must time out with a clear error when
# the mock_feishu endpoint is unreachable. We deliberately DON'T start
# mock_feishu here — the helper should bail within the timeout.
( MOCK_FEISHU_PORT=1 wait_for_sidecar_ready 1 >/dev/null 2>&1 ) && \
  { echo "FAIL: wait_for_sidecar_ready should time out without mock_feishu"; exit 1; } || true

echo "PASS: common.sh self-test"
