#!/usr/bin/env bash
# scenario 25 — template-instantiated session, end-to-end.
#
# Spec: docs/superpowers/specs/2026-05-10-session-template-and-channel.md §10.1
# Plan: docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md Task 5.5
#
# What this proves (Phase 5 cut-over):
#   1. The in-tree feishu-cc bundle (manifest + template) loads at boot
#      with both feishu + claude_code plugins enabled.
#   2. `Esr.Session.DefaultTemplate.auto_elect_if_single/0` writes
#      `default_template: feishu-cc` into
#      `${ESRD_HOME}/${ESRD_INSTANCE}/plugins/session/config.yaml` —
#      because feishu-cc is the only registered template post-boot.
#   3. `/session:new` (admin queue submit, no explicit `template=`)
#      resolves the default template, materializes an agent_def, and
#      spawns the canonical CC chain (FeishuChatProxy + CCProcess +
#      PtyProcess). Same shape as scenario 22 — driven through the
#      template loader rather than agents.yaml.
#   4. `/session:new template=feishu-cc` is accepted (explicit form).
#   5. `/session:new template=does-not-exist` returns the structured
#      `unknown_template` error listing available templates.
#
# COMPLEMENTS scenario 22 (resource-typed-grammar baseline) and
# scenario 27 (template_dependency_unmet, the negative twin).
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/25_session_template_instantiation.sh 2>&1 | tail -3
#   → "PASS: 25_session_template_instantiation"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces

start_esrd

LOG="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
[[ -f "$LOG" ]] || _fail_with_context "expected esrd log at $LOG"

# --- step 1: assert the in-tree feishu-cc bundle registered ----------
echo "STEP 1: assert feishu-cc bundle registered with template"

deadline=$(( $(date +%s) + 10 ))
registered_found=0
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -q "bundle loader: registered bundle=feishu-cc template=feishu-cc" "$LOG"; then
    registered_found=1
    break
  fi
  sleep 0.5
done

if [[ "$registered_found" != 1 ]]; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected boot log to register feishu-cc bundle + template"
fi

echo "  ok: feishu-cc bundle + template registered at boot"

# --- step 2: assert default template auto-elected --------------------
echo "STEP 2: assert default_template auto-elected to feishu-cc"

# Inspect the on-disk session plugin config (per spec §5.4: virtual
# `session` namespace at $ESRD_HOME/<inst>/plugins/session/config.yaml).
SESSION_CFG="${ESRD_HOME}/${ESRD_INSTANCE}/plugins/session/config.yaml"

deadline=$(( $(date +%s) + 10 ))
elected=0
while [[ $(date +%s) -lt $deadline ]]; do
  if [[ -f "$SESSION_CFG" ]] && grep -q "default_template:" "$SESSION_CFG"; then
    elected=1
    break
  fi
  sleep 0.5
done

if [[ "$elected" != 1 ]]; then
  echo "--- session config dir contents ---" >&2
  ls -la "${ESRD_HOME}/${ESRD_INSTANCE}/plugins/session/" 2>&1 >&2 || true
  echo "--- log tail ---" >&2
  tail -n 60 "$LOG" >&2 || true
  _fail_with_context "expected $SESSION_CFG to carry default_template"
fi

grep -q "feishu-cc" "$SESSION_CFG" \
  || _fail_with_context "session config default_template should be feishu-cc"

echo "  ok: default_template = feishu-cc on disk"

# --- step 3: /session:new (no template= arg) uses the default --------
echo "STEP 3: /session:new without template= uses operator default"

USERNAME="tmpl_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"
esr_cli admin submit user_add --arg name="${USERNAME}" --wait --timeout 30 >/dev/null

CHAT_ID="oc_e2e25_${ESR_E2E_RUN_ID}"
APP_ID="esr_e2e25_${ESR_E2E_RUN_ID}"
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-25-default"
mkdir -p "${WORKDIR}"

SESS_OUT=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR}" \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg name="default-tmpl-#${ESR_E2E_RUN_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "25 session_new (default template): ${SESS_OUT}"
SID=$(echo "$SESS_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "25: no session_id from default-template /session:new"

echo "  ok: session ${SID} spawned via auto-elected default template"

# --- step 4: /session:new template=feishu-cc explicit ----------------
echo "STEP 4: /session:new template=feishu-cc explicit form"

CHAT_ID2="oc_e2e25b_${ESR_E2E_RUN_ID}"
APP_ID2="esr_e2e25b_${ESR_E2E_RUN_ID}"
WORKDIR2="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-25-explicit"
mkdir -p "${WORKDIR2}"

SESS_OUT2=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR2}" \
  --arg chat_id="${CHAT_ID2}" \
  --arg app_id="${APP_ID2}" \
  --arg name="explicit-tmpl-#${ESR_E2E_RUN_ID}" \
  --arg template=feishu-cc \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "25 session_new (explicit template): ${SESS_OUT2}"
SID2=$(echo "$SESS_OUT2" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID2" ]] || _fail_with_context "25: no session_id from explicit-template /session:new"

echo "  ok: session ${SID2} spawned via explicit template=feishu-cc"

# --- step 5: /session:new template=ghost returns unknown_template ---
echo "STEP 5: /session:new template=ghost → unknown_template"

GHOST_OUT=$(esr_cli admin submit session_new \
  --arg dir="/tmp/ignored" \
  --arg chat_id="oc_ghost_${ESR_E2E_RUN_ID}" \
  --arg app_id="esr_ghost_${ESR_E2E_RUN_ID}" \
  --arg name="ghost-#${ESR_E2E_RUN_ID}" \
  --arg template="does-not-exist" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30 2>&1 || true)

echo "25 session_new (ghost template): ${GHOST_OUT}"
assert_contains "$GHOST_OUT" "unknown_template" \
  "25: explicit unknown template surfaces unknown_template error"
assert_contains "$GHOST_OUT" "feishu-cc" \
  "25: unknown_template error lists available feishu-cc"

# --- final ------------------------------------------------------------
echo "PASS: 25_session_template_instantiation"
