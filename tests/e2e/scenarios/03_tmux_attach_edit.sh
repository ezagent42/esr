#!/usr/bin/env bash
# PR-7 scenario 03 — tmux attach + pane edit + detach + end.
# §9 user-steps 9-12. Uses cli:actors/inspect --field (extended in H).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

load_agent_yaml
start_mock_feishu
start_esrd
register_feishu_adapter

# --- user-step 10: create session -----------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run \
  "/new-session esr-dev tag=tmux app_id=e2e-mock"
for _ in $(seq 1 50); do
  if uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
       | grep -q "cc:tmux"; then break; fi
  sleep 0.1
done
assert_actors_list_has "cc:tmux" "user-step 10: cc:tmux peer spawned"

# Find tmux_process actor id for this session.
TMUX_ACTOR=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list --json \
  | jq -r '.[] | select(.actor_type=="tmux_process" and (.actor_id | contains("tmux"))) | .actor_id' \
  | head -n1)
[[ -n "$TMUX_ACTOR" ]] || _fail_with_context "no tmux_process actor for cc:tmux"

# Ask runtime for state.session_name (introspection path — spec §3.4 option A).
TMUX_SESSION_NAME=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors inspect \
  "$TMUX_ACTOR" --field state.session_name)
[[ -n "$TMUX_SESSION_NAME" && "$TMUX_SESSION_NAME" =~ ^esr_cc_[0-9]+$ ]] || \
  _fail_with_context "unexpected tmux session name: '${TMUX_SESSION_NAME}'"

# --- user-step 11: send keys + capture pane --------------------------
tmux -S "${ESR_E2E_TMUX_SOCK}" send-keys -t "${TMUX_SESSION_NAME}" \
  "echo hello-tmux" Enter
sleep 0.5
assert_tmux_pane_contains "${TMUX_SESSION_NAME}" "hello-tmux"

# --- user-step 12: end session --------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session tmux"
for _ in $(seq 1 50); do
  if ! uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:tmux"; then break; fi
  sleep 0.1
done
assert_actors_list_lacks "cc:tmux" "user-step 12: tmux peer torn down"

echo "PASS: scenario 03"
