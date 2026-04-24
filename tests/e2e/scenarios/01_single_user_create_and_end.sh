#!/usr/bin/env bash
# PR-7 scenario 01 — single user, create → reply → react → send_file → end.
# See docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md §3.2
# and §9 coverage matrix user-steps 1-6.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces
seed_adapters   # seed adapters.yaml with base_url → boot restore spawns the sidecar
start_mock_feishu
start_esrd
# register_feishu_adapter  # replaced by seed_adapters + Application.restore_adapters_from_disk/1

# T9: wait for feishu_adapter_runner to finish its startup dance (Phoenix
# join + handler_hello + mock_feishu ws_connect) before pushing any
# inbound. Without this, step 2's push_inbound races the sidecar and
# mock_feishu emits to an empty _ws_clients list, silently losing the
# message.
wait_for_sidecar_ready 30

# --- user-step 1: create session --------------------------------------
# E2E RCA (2026-04-23): v1.0 used `esr cmd run "/new-session ..."` but that
# CLI is for .compiled/<name>.yaml artefacts, not slash commands. The
# correct admin-side path is `esr admin submit session_new --arg ...`.
SESSION_CREATE_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit session_new \
  --arg agent=cc \
  --arg dir=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/workdir-single \
  --wait --timeout 30)
echo "$SESSION_CREATE_OUT"
assert_contains "$SESSION_CREATE_OUT" "ok: true" "user-step 1: session_new returned ok"
# Capture the assigned session_id for later teardown (session_new returns
# a random ULID since chat binding is deferred to the FeishuChatProxy).
SESSION_ID=$(echo "$SESSION_CREATE_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SESSION_ID" ]] || _fail_with_context "user-step 1: no session_id in output"
echo "created session ${SESSION_ID}"

# --- user-step 2: inbound plain message → CC replies ------------------
# Post-T11b.7 the cc_adapter_runner handler no longer composes a canned
# reply — real CC now runs in tmux with the cc_mcp bridge, sees our
# inbound as a <channel> tag in its conversation context, and decides
# the response itself. We instruct CC explicitly to reply with "ack"
# so the sent_messages assertion can still pin a deterministic substring.
INBOUND_MSG_ID=$(curl -sS -X POST \
  -H 'content-type: application/json' \
  -d '{"chat_id":"oc_mock_single","user":"ou_admin","text":"Please reply with exactly the three letters: ack"}' \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" \
  | jq -r '.message_id')
[[ -n "$INBOUND_MSG_ID" ]] || _fail_with_context "push_inbound did not return message_id"

# Wait for CC's reply to land in mock's sent_messages.
# Real CC takes longer than the canned placeholder — allow up to 60s
# for the model's turn + cc_mcp reply tool dispatch.
for _ in $(seq 1 600); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
       | jq -e '.[] | select(.receive_id=="oc_mock_single")' >/dev/null; then
    break
  fi
  sleep 0.1
done
assert_mock_feishu_sent_includes "oc_mock_single" "ack"  # CC's reply per prompt

# --- user-step 3: CC reacts on inbound --------------------------------
# Depending on agent wiring, CC invokes `react` automatically. The FCP
# un-reacts on reply (production design — the reaction signals "working",
# the un-react signals "done"), so the live /reactions list may be empty
# by the time we poll. Count live + un_reactions together.
for _ in $(seq 1 100); do
  live=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/reactions" \
    | jq --arg mid "$INBOUND_MSG_ID" '[.[] | select(.message_id==$mid)] | length')
  hist=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/un_reactions" \
    | jq --arg mid "$INBOUND_MSG_ID" '[.[] | select(.message_id==$mid)] | length')
  (( live + hist >= 1 )) && break
  sleep 0.1
done
assert_mock_feishu_reactions_count "$INBOUND_MSG_ID" 1

# --- user-step 4: CC sends file ---------------------------------------
EXPECTED_SHA=$(shasum -a 256 "${_E2E_REPO_ROOT}/tests/e2e/fixtures/probe_file.txt" \
  | awk '{print $1}')
# CC invokes send_file via its tool; wait for it to show up.
for _ in $(seq 1 100); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
       | jq -e '.[] | select(.chat_id=="oc_mock_single")' >/dev/null; then
    break
  fi
  sleep 0.1
done
assert_mock_feishu_file_sha "oc_mock_single" "$EXPECTED_SHA"

# --- user-step 5: second message, same session -----------------------
curl -sS -X POST -H 'content-type: application/json' \
  -d '{"chat_id":"oc_mock_single","user":"ou_admin","text":"again"}' \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null
sleep 1
# Same peer, so cc:single still present.
assert_actors_list_has "cc:single" "user-step 5: session persisted after 2nd msg"

# --- user-step 6: end session ----------------------------------------
uv run --project "${_E2E_REPO_ROOT}/py" esr cmd run "/end-session single"
for _ in $(seq 1 50); do
  if ! uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
         | grep -q "cc:single"; then
    break
  fi
  sleep 0.1
done
assert_actors_list_lacks "cc:single" "user-step 6: peer torn down"

# --- user-step 12 (cleanup assertion — deferred until trap runs) ------
# Trap runs after this script exits; assertion on baseline happens in
# the Makefile recipe that also runs `assert_baseline_clean "$BASELINE"`.
# For solo-script runs, export BASELINE so the trap can use it:
export _E2E_BASELINE="$BASELINE"

echo "PASS: scenario 01"
