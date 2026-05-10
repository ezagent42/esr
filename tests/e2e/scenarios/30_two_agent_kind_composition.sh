#!/usr/bin/env bash
# scenario 30 — two-agent-kind composition (abstraction-validation).
#
# Spec: docs/superpowers/specs/2026-05-10-session-template-and-channel.md §10.1
# Plan: docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md Task 8.5
#
# What this proves:
#   1. The Channel + agent_kind abstraction is NOT CC-specific.
#   2. A non-CC plugin (`stub_agent`) can declare its own Channel
#      (`stub_agent.noop`) + agent_kind (`stub_agent.stub`) via the same
#      manifest.yaml shape feishu/claude_code use.
#   3. A bundle (`stub-only`) composing only stub_agent's primitives loads
#      and registers a SessionTemplate via the same Bundle.Loader pipeline
#      as feishu-cc.
#   4. `/session:new template=stub-only name=foo` succeeds without ANY
#      changes to feishu or claude_code plugin code — the abstraction
#      generalizes.
#
# Test mode:
#   - This scenario REPLACES the default scenario boot config: instead of
#     enabling [feishu, claude_code], it enables [stub_agent] only.
#   - The stub-only bundle's deps are [stub_agent], so its template
#     registers; feishu-cc's deps are [feishu, claude_code], unmet → its
#     template is skipped.
#   - With stub-only as the only registered template, auto-election kicks
#     in and stub-only becomes the default.
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/30_two_agent_kind_composition.sh 2>&1 | tail -3
#   → "PASS: 30_two_agent_kind_composition"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces

# Boot esrd with ONLY stub_agent enabled. feishu-cc bundle's deps unmet
# → its template skipped; stub-only bundle's deps satisfied → its
# template registered. With one template registered, default-election
# fires.
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<'YAML'
enabled:
  - stub_agent
YAML

start_esrd

LOG="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
[[ -f "$LOG" ]] || _fail_with_context "expected esrd log at $LOG"

# --- step 1: assert stub_agent plugin loaded -------------------------
echo "STEP 1: assert stub_agent plugin started"

deadline=$(( $(date +%s) + 10 ))
plugin_started=0
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -qE "plugin loader: started stub_agent" "$LOG"; then
    plugin_started=1
    break
  fi
  sleep 0.5
done

if [[ "$plugin_started" != 1 ]]; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected boot log to start stub_agent plugin"
fi

echo "  ok: stub_agent plugin started"

# --- step 2: assert stub-only bundle + template registered -----------
echo "STEP 2: assert stub-only bundle + template registered"

deadline=$(( $(date +%s) + 10 ))
registered_found=0
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -q "bundle loader: registered bundle=stub-only template=stub-only" "$LOG"; then
    registered_found=1
    break
  fi
  sleep 0.5
done

if [[ "$registered_found" != 1 ]]; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected boot log to register stub-only bundle + template"
fi

echo "  ok: stub-only bundle + template registered at boot"

# --- step 3: assert feishu-cc skipped (deps unmet) -------------------
echo "STEP 3: assert feishu-cc bundle skipped (deps unmet)"

if ! grep -qE "bundle 'feishu-cc' missing plugin deps" "$LOG"; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected log to warn that feishu-cc deps unmet"
fi

# Should NOT have registered feishu-cc's template (only manifest).
if grep -qE "bundle loader: registered bundle=feishu-cc template=feishu-cc" "$LOG"; then
  _fail_with_context \
    "feishu-cc template should NOT register when feishu/claude_code disabled"
fi

echo "  ok: feishu-cc bundle skipped, only manifest registered"

# --- step 4: /session:new template=stub-only name=foo succeeds -------
echo "STEP 4: /session:new template=stub-only name=foo"

USERNAME="stub_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"
esr_cli admin submit user_add --arg name="${USERNAME}" --wait --timeout 30 >/dev/null

CHAT_ID="oc_e2e30_${ESR_E2E_RUN_ID}"
APP_ID="esr_e2e30_${ESR_E2E_RUN_ID}"
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-30-stub"
mkdir -p "${WORKDIR}"

SESS_OUT=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR}" \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg name="foo-#${ESR_E2E_RUN_ID}" \
  --arg template=stub-only \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "30 session_new (template=stub-only): ${SESS_OUT}"
SID=$(echo "$SESS_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "30: no session_id from stub-only /session:new"

echo "  ok: session ${SID} spawned via template=stub-only"

# --- step 5: assert no CC-specific code path was hit -----------------
echo "STEP 5: assert no claude_code-specific log lines for this session"

# A successful CC session would emit "CCProcess" / "cc_proxy" lines for
# the spawn. The stub agent's pipeline has no CC peers, so those names
# should not appear in the per-session log lines.
#
# Lenient check: it's a no-op stub session, and we just confirm spawn
# didn't pull in CC modules. Per-session structured logging isn't
# tightly coupled here; a simpler assertion is that no `cc_process` /
# `cc_mcp_ready` lines fire for the new session_id.
if grep -E "cc_process.*${SID}|cc_mcp_ready.*${SID}|CCProxy.*${SID}" "$LOG"; then
  _fail_with_context "30: stub-only session should NOT trigger CC-specific code paths"
fi

echo "  ok: no CC-specific peers spawned for the stub-only session"

# --- final ------------------------------------------------------------
echo "PASS: 30_two_agent_kind_composition"
