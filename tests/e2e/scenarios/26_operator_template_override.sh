#!/usr/bin/env bash
# scenario 26 — operator-shipped template override.
#
# Spec: docs/superpowers/specs/2026-05-10-session-template-and-channel.md §5.3, §10.1
# Plan: docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md Task 5.6
#
# What this proves:
#   1. An operator-dropped yaml at
#      `${ESRD_HOME}/${ESRD_INSTANCE}/session_templates/foo.yaml`
#      is registered at boot by `Esr.Bundle.Loader.load_all/0`'s
#      operator-dir walk (spec §5.3 "Operator ad-hoc templates" — single
#      yaml conflating manifest+template).
#   2. `/session:new template=foo` resolves the operator template +
#      materializes it + spawns the session. Same agent_def shape as
#      feishu-cc since the operator template targets the same channel
#      kinds (the materializer is feishu-cc-shaped in Phase 5).
#   3. Source attribution: the operator template carries
#      `source: :operator` in `Esr.SessionTemplate.Registry.list_all/0`
#      (validated indirectly via the boot log's `registered operator
#      template` line vs `registered bundle=...` for bundle-shipped).
#
# Phase 5 rough edge: there's no clean "/plugin:reload session_templates"
# slash today. `Esr.Bundle.Loader.load_all/0` runs at esrd boot and
# walks both bundle dir + operator dir. To pick up edits to the
# operator yaml without an esrd restart, an operator would invoke
# `Esr.Bundle.Loader.load_all/0` via remote_console (Phase 8 ships a
# real reload slash). For this scenario the boot-time walk is
# sufficient — we drop the operator yaml BEFORE start_esrd.
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/26_operator_template_override.sh 2>&1 | tail -3
#   → "PASS: 26_operator_template_override"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces

# Drop an operator-ad-hoc template at the canonical path BEFORE esrd
# boots — Bundle.Loader picks it up during boot's load_all walk.
# Spec §5.3 "Operator ad-hoc templates": single yaml conflates
# manifest + template; `dependencies` block + template body in the
# same file.
OPERATOR_DIR="${ESRD_HOME}/${ESRD_INSTANCE}/session_templates"
mkdir -p "${OPERATOR_DIR}"

cat > "${OPERATOR_DIR}/foo.yaml" <<'YAML'
schema_version: 1
name: foo
description: Operator-defined override (feishu-cc-shaped)
dependencies:
  plugins: [feishu, claude_code]
  bundles: []
channels:
  - alias: in
    kind: feishu.chat_proxy
    config:
      app_id: <runtime>
      chat_id: <runtime>
  - alias: cc_mcp
    kind: claude_code.mcp_stdio
    config:
      port: ephemeral
agents:
  - kind: claude_code.cc
    name: <runtime>
    consumes: [cc_mcp]
flow:
  inbound:
    - source: in.text
      pipeline:
        - Esr.Entity.Agent.MentionParser
        - "<route_to_agent>"
  outbound:
    - source: <agent>.reply
      sink: in.send
YAML

start_esrd

LOG="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
[[ -f "$LOG" ]] || _fail_with_context "expected esrd log at $LOG"

# --- step 1: operator template registered at boot --------------------
echo "STEP 1: assert operator template foo registered with source=:operator"

deadline=$(( $(date +%s) + 10 ))
op_registered=0
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -q "registered operator template=foo" "$LOG"; then
    op_registered=1
    break
  fi
  sleep 0.5
done

if [[ "$op_registered" != 1 ]]; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected boot log to register operator template foo"
fi

echo "  ok: operator template foo registered at boot"

# --- step 2: /session:new template=foo spawns session ----------------
echo "STEP 2: /session:new template=foo → session spawn"

USERNAME="ophdr_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"
esr_cli admin submit user_add --arg name="${USERNAME}" --wait --timeout 30 >/dev/null

CHAT_ID="oc_e2e26_${ESR_E2E_RUN_ID}"
APP_ID="esr_e2e26_${ESR_E2E_RUN_ID}"
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-26"
mkdir -p "${WORKDIR}"

SESS_OUT=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR}" \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg name="op-foo-#${ESR_E2E_RUN_ID}" \
  --arg template="foo" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "26 session_new (operator template): ${SESS_OUT}"
SID=$(echo "$SESS_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "26: no session_id from operator-template /session:new"

echo "  ok: session ${SID} spawned via operator template=foo"

# --- step 3: source attribution surfaces in error listings -----------
# Hitting an unknown_template prints `available: foo (operator), feishu-cc
# (bundle:feishu-cc)`. This indirectly verifies source-attribution
# round-trips through SessionTemplate.Registry.list_all/0.
echo "STEP 3: source attribution surfaces in unknown_template error"

GHOST_OUT=$(esr_cli admin submit session_new \
  --arg dir="/tmp/ignored" \
  --arg chat_id="oc_attr_${ESR_E2E_RUN_ID}" \
  --arg app_id="esr_attr_${ESR_E2E_RUN_ID}" \
  --arg name="ghost-#${ESR_E2E_RUN_ID}" \
  --arg template="ghost-${ESR_E2E_RUN_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30 2>&1 || true)

echo "26 session_new (ghost template): ${GHOST_OUT}"
assert_contains "$GHOST_OUT" "unknown_template" \
  "26: ghost template surfaces unknown_template error"
assert_contains "$GHOST_OUT" "foo (operator)" \
  "26: error lists operator template foo with attribution"
assert_contains "$GHOST_OUT" "feishu-cc (bundle:feishu-cc)" \
  "26: error lists bundle template feishu-cc with attribution"

# --- final ------------------------------------------------------------
echo "PASS: 26_operator_template_override"
