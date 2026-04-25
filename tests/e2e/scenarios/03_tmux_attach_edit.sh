#!/usr/bin/env bash
# PR-7 scenario 03 — tmux attach + pane inspection + end.
# §9 user-steps 9-12.
#
# T12-comms-3l rewrite (2026-04-24): post-T11b architecture auto-creates
# sessions on first inbound and the pane command is claude CLI (not a
# bare shell), so the pre-T11b `/new-session tag=tmux ...` + `esr actors
# inspect ...state.session_name` flow no longer applies. Instead:
#
#   1. Auto-create a session via a Feishu inbound
#   2. Use `tmux -S $ESR_E2E_TMUX_SOCK list-sessions` to find the
#      session's `esr_cc_*` tmux name
#   3. Assert we can capture-pane on it (proves the pane is alive +
#      attachable — the core user-facing tmux integration guarantee)
#   4. End session via admin submit → tmux session should disappear
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

load_agent_yaml
seed_capabilities
seed_workspaces
seed_adapters
start_mock_feishu
start_esrd
wait_for_sidecar_ready 30

# --- user-step 10: create session via inbound -----------------------
curl -sS -X POST -H 'content-type: application/json' \
  -d '{"chat_id":"oc_mock_tmux","user":"ou_admin","text":"Please reply with exactly the three letters: ack"}' \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null

# Wait for CC's reply (confirms the pipeline — including TmuxProcess
# + claude + cc_mcp — is fully wired).
for _ in $(seq 1 600); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
       | jq -e '.[] | select(.receive_id=="oc_mock_tmux")' >/dev/null; then
    break
  fi
  sleep 0.1
done
assert_mock_feishu_sent_includes "oc_mock_tmux" "ack"

# --- user-step 11: discover tmux session + capture pane ------------
# TmuxProcess uses tmux sessions named `esr_cc_<unique_int>`. Isolation
# via ESR_E2E_TMUX_SOCK guarantees only our test's sessions are on this
# socket, so a single `list-sessions` grep is unambiguous.
TMUX_SESSION_NAME=$(tmux -S "${ESR_E2E_TMUX_SOCK}" list-sessions -F '#{session_name}' 2>/dev/null \
  | grep -E '^esr_cc_[0-9]+$' | head -n1)
[[ -n "$TMUX_SESSION_NAME" ]] \
  || _fail_with_context "user-step 11: no esr_cc_<N> tmux session on ${ESR_E2E_TMUX_SOCK}"
echo "tmux session: ${TMUX_SESSION_NAME}"

# capture-pane must succeed — proves the pane is live and attachable.
# (The pane runs claude CLI, not a bare shell; we don't shell-exec into
# it because the <channel> path is the production-correct way to
# deliver prompts. This step only asserts pane accessibility.)
PANE_OUT=$(tmux -S "${ESR_E2E_TMUX_SOCK}" capture-pane -p -t "${TMUX_SESSION_NAME}" 2>&1)
[[ -n "$PANE_OUT" ]] \
  || _fail_with_context "user-step 11: capture-pane on ${TMUX_SESSION_NAME} returned empty"
# Claude's TUI always renders at least its prompt box; fail loudly if
# we somehow landed on a dead shell that emitted nothing.

# --- user-step 12: end session --------------------------------------
LIVE_SESSION_ID=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
  | awk '/^thread:/ { sub("thread:", "", $1); print $1; exit }')
[[ -n "$LIVE_SESSION_ID" ]] \
  || _fail_with_context "user-step 12: no thread:<sid> actor to end"

ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit session_end \
  --arg "session_id=${LIVE_SESSION_ID}" \
  --wait --timeout 30

for _ in $(seq 1 50); do
  if ! uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "thread:${LIVE_SESSION_ID}"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_lacks "thread:${LIVE_SESSION_ID}" "user-step 12: tmux peer torn down"

# tmux session should also be gone (TmuxProcess.on_terminate runs
# `kill-session` on normal stop). The SIGTERM → claude cleanup chain
# can take up to ~15s because claude's MCP shutdown hooks run first;
# poll generously.
for _ in $(seq 1 150); do
  if ! tmux -S "${ESR_E2E_TMUX_SOCK}" has-session -t "${TMUX_SESSION_NAME}" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
! tmux -S "${ESR_E2E_TMUX_SOCK}" has-session -t "${TMUX_SESSION_NAME}" 2>/dev/null \
  || _fail_with_context "user-step 12: tmux session ${TMUX_SESSION_NAME} still alive after end"

export _E2E_BASELINE="$BASELINE"

echo "PASS: scenario 03"
