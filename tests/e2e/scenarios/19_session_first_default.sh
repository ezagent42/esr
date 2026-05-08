#!/usr/bin/env bash
# e2e scenario 19 — session-first default workspace resolution.
#
# Spec: docs/superpowers/specs/2026-05-08-session-first-default-resolution.md
#
# WHAT THIS TEST PROVES:
#   - /user:add auto-creates <username>-default workspace + sets as user-default
#     (M-5/D3).
#   - /user:use changes the user-default to a different workspace (M-5/§4.3).
#   - /session:new without any workspace= arg + no chat-default uses
#     user-default per Resolve chain (M-5/§4.6).
#   - The literal name "default" is no longer a fallback; sessions only
#     resolve via chat-default or user-default.
#   - /workspace:add-folder works without name= when chat-current or
#     user-default is set (M-5/D5).
#
# COMPLEMENTS scenario 14 + 18 which exercise multi-agent + multi-instance
# spawn paths after a session has been created.
#
# INVARIANT GATE (spec §11):
#   bash tests/e2e/scenarios/19_session_first_default.sh 2>&1 | tail -3
#   → "PASS: 19_session_first_default"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
# Note: NOT seeding any workspace via seed_workspaces — the whole point
# is the operator never typed a workspace name.
seed_adapters
start_esrd

# --- step 1: add a fresh user — auto-creates user-default workspace ---
USERNAME="autodef_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

ADD_OUT=$(esr_cli admin submit user_add \
  --arg name="${USERNAME}" \
  --wait --timeout 30)

echo "19 user_add output: ${ADD_OUT}"
assert_contains "$ADD_OUT" "ok: true"                    "19: user_add ok"
assert_contains "$ADD_OUT" "default_workspace"           "19: result carries default_workspace"
assert_contains "$ADD_OUT" "${USERNAME}-default"         "19: name is <username>-default"

# --- step 2: /session:new — should resolve to user-default -----------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-19"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 session_new output: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true"               "19: session_new ok"
assert_contains "$SESSION_OUT" "${USERNAME}-default"    "19: session bound to user-default ws"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "19: no session_id from session_new"
echo "19: session created: ${SID}"

# --- step 3: /workspace:add-folder (no name=) — uses user-default ----
REPO_DIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/repo-19"
mkdir -p "${REPO_DIR}/.git"

ADDFOLDER_OUT=$(esr_cli admin submit workspace_add_folder \
  --arg path="${REPO_DIR}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 workspace_add_folder (no name): ${ADDFOLDER_OUT}"
assert_contains "$ADDFOLDER_OUT" "ok: true"             "19: add-folder ok without name"
assert_contains "$ADDFOLDER_OUT" "${USERNAME}-default"  "19: add-folder routed to user-default"

# --- step 4: /user:use — switch user-default to a different ws -------
SECOND_WS="${USERNAME}-secondary"
esr_cli admin submit workspace_new \
  --arg name="${SECOND_WS}" \
  --arg owner="${USERNAME}" \
  --wait --timeout 30 > /dev/null

USE_OUT=$(esr_cli admin submit user_use \
  --arg workspace="${SECOND_WS}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 20)

echo "19 user_use: ${USE_OUT}"
assert_contains "$USE_OUT" "ok: true"                    "19: user_use ok"
assert_contains "$USE_OUT" "${SECOND_WS}"                "19: user_use returns new ws name"

# --- step 5: re-/session:new — should bind to the NEW user-default ---
SESSION2_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}-2" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 session_new#2 output: ${SESSION2_OUT}"
assert_contains "$SESSION2_OUT" "ok: true"               "19: 2nd session_new ok"
assert_contains "$SESSION2_OUT" "${SECOND_WS}"           "19: 2nd session bound to new user-default"

# --- step 6: literal "default" workspace must NOT exist post-bootstrap
DESCRIBE_OUT=$(esr_cli admin submit workspace_describe \
  --arg workspace=default \
  --wait --timeout 15 2>&1 || true)

echo "19 describe default: ${DESCRIBE_OUT}"
assert_contains "$DESCRIBE_OUT" "unknown_workspace" \
  "19: literal `default` workspace must not exist (M-5/D4)"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 20 > /dev/null || true

mkdir -p "${WORKDIR}-2"
echo "PASS: 19_session_first_default"
