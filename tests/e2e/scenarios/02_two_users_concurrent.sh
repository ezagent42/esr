#!/usr/bin/env bash
# PR-7 scenario 02 — two concurrent users, session isolation.
# See spec §3.3 + §9 user-steps 7-8.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

load_agent_yaml
seed_capabilities
seed_workspaces
start_mock_feishu
start_esrd
register_feishu_adapter

run_user() {
  local tag=$1 chat_id=$2 phrase=$3
  uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run \
    "/new-session esr-dev tag=${tag} app_id=e2e-mock"
  # Wait for the peer
  for _ in $(seq 1 50); do
    if uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:${tag}"; then
      break
    fi
    sleep 0.1
  done
  barrier_signal "session_ready_${tag}"

  # Parent signals probe_gate_open when BOTH are ready — wait here.
  barrier_wait "probe_gate_open" 15

  curl -sS -X POST -H 'content-type: application/json' \
    -d "{\"chat_id\":\"${chat_id}\",\"sender_open_id\":\"ou_${tag}\",\"content_text\":\"${phrase}\"}" \
    "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null
  barrier_signal "probe_sent_${tag}"
}

# Launch both subshells in parallel.
run_user "alpha" "oc_mock_A" "probe-alpha-unique" &
PID_A=$!
run_user "beta" "oc_mock_B" "probe-beta-unique" &
PID_B=$!

# Parent waits for both to reach session_ready, then opens the probe gate.
barrier_wait "session_ready_alpha" 30
barrier_wait "session_ready_beta" 30
barrier_signal "probe_gate_open"

# Parent waits for both probes to be sent, then for replies to appear.
barrier_wait "probe_sent_alpha" 10
barrier_wait "probe_sent_beta" 10

# Let CC process inbounds.
for _ in $(seq 1 100); do
  replies_a=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_A")] | length')
  replies_b=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_B")] | length')
  [[ "$replies_a" -ge 1 && "$replies_b" -ge 1 ]] && break
  sleep 0.1
done

# --- isolation assertions --------------------------------------------
SENT=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages")
A_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_A") | .content' | tr '\n' ' ')
B_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_B") | .content' | tr '\n' ' ')
assert_not_contains "$A_BODY" "probe-beta-unique" "alpha got beta's content"
assert_not_contains "$B_BODY" "probe-alpha-unique" "beta got alpha's content"

# Join subshells.
wait "$PID_A" "$PID_B"

# --- user-step 8: end both -------------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session alpha"
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session beta"
for _ in $(seq 1 50); do
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  if ! echo "$out" | grep -q "cc:alpha" && ! echo "$out" | grep -q "cc:beta"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_lacks "cc:alpha" "user-step 8a"
assert_actors_list_lacks "cc:beta" "user-step 8b"

echo "PASS: scenario 02"
