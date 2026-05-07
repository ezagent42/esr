#!/usr/bin/env bash
# e2e scenario 16 — plugin config 3-layer per-key merge.
#
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 16.
# Phase: 9 (Phase 9.4 of metamodel-aligned ESR).
#
# Tests the plugin config layering model from Phase 7:
#   global < user < workspace  (workspace wins on a per-key basis)
#
# Uses _user_path_override + _workspace_path_override args to supply
# explicit yaml file paths, bypassing the user-UUID + workspace-ID lookup
# (those lookups require live entity data; testing them is a unit test
# concern — see runtime/test/esr/commands/plugin/*_test.exs).
#
# WHAT THIS TEST PROVES:
#   1. global http_proxy written and visible as effective (no user/ws override)
#   2. user-layer http_proxy overrides global for alice's path
#   3. workspace-layer http_proxy (empty string) overrides user layer
#   4. unset workspace → user layer resumes
#   5. unset user → global resumes
#   6. bob's path (no user override) sees global only
#
# INVARIANT GATE (spec §14):
#   bash tests/e2e/scenarios/16_plugin_config_layers.sh 2>&1 | tail -3
#   → "PASS: 16_plugin_config_layers"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# Ephemeral paths for the 3 layers under the test run dir.
LAYER_BASE="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/config-layers"
ALICE_PLUGINS_YAML="${LAYER_BASE}/alice/plugins.yaml"
WORKSPACE_PLUGINS_YAML="${LAYER_BASE}/workspace/.esr/plugins.yaml"
BOB_PLUGINS_YAML="${LAYER_BASE}/bob/plugins.yaml"

mkdir -p "$(dirname "${ALICE_PLUGINS_YAML}")" \
         "$(dirname "${WORKSPACE_PLUGINS_YAML}")" \
         "$(dirname "${BOB_PLUGINS_YAML}")"

# --- setup ------------------------------------------------------------
# Start with a minimal global plugins.yaml that enables claude_code.
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<YAML
enabled:
  - claude_code
config:
  claude_code:
    http_proxy: ""
YAML

seed_capabilities
start_esrd

# helper: invoke plugin_show_config with optional path overrides.
# Only pass _user_path_override / _workspace_path_override when non-empty.
# An empty string arg would be treated as a path by build_path_opts and
# File.read("") would silently fail → effectively no layer. We skip it
# entirely so the server uses its default (nil = no file consulted).
show_config_effective() {
  local user_path="${1:-}"
  local ws_path="${2:-}"
  local extra_args=()
  [[ -n "$user_path" ]]  && extra_args+=(--arg "_user_path_override=${user_path}")
  [[ -n "$ws_path" ]]    && extra_args+=(--arg "_workspace_path_override=${ws_path}")
  esr_cli admin submit plugin_show_config \
    --arg plugin=claude_code \
    --arg layer=effective \
    "${extra_args[@]}" \
    --wait --timeout 15
}

# --- step 1: set global http_proxy ------------------------------------
GLOBAL_SET=$(esr_cli admin submit plugin_set \
  --arg plugin=claude_code \
  --arg key=http_proxy \
  --arg value="http://global:8080" \
  --arg layer=global \
  --wait --timeout 15)
echo "global set: ${GLOBAL_SET}"
assert_contains "$GLOBAL_SET" "ok: true" "16: global plugin_set ok"
echo "16: global http_proxy set"

# --- step 2: effective (no user/ws overrides) shows global ------------
EFF=$(show_config_effective)
echo "effective (global only): ${EFF}"
assert_contains "$EFF" "http://global:8080" \
  "16: effective should show global http_proxy when no overrides"
echo "16: step 2 passed — global visible as effective"

# --- step 3: write alice user-layer plugins.yaml ----------------------
# Write directly to the override path; plugin_set layer=user with
# _user_path_override writes to the same path.
cat > "${ALICE_PLUGINS_YAML}" <<YAML
config:
  claude_code:
    http_proxy: "http://user:8081"
YAML
echo "16: alice user plugins.yaml seeded at ${ALICE_PLUGINS_YAML}"

# Verify alice effective shows user layer (user > global).
EFF_ALICE=$(show_config_effective "${ALICE_PLUGINS_YAML}" "")
echo "effective (alice user): ${EFF_ALICE}"
assert_contains "$EFF_ALICE" "http://user:8081" \
  "16: alice effective should show user http_proxy (user > global)"
echo "16: step 3 passed — user wins over global"

# --- step 4: write workspace-layer to override alice's user layer ----
# workspace_plugins_yaml(workspace_root) => <root>/.esr/plugins.yaml
# Empty string value explicitly unsets for this session's workspace.
cat > "${WORKSPACE_PLUGINS_YAML}" <<YAML
config:
  claude_code:
    http_proxy: ""
YAML
echo "16: workspace plugins.yaml seeded at ${WORKSPACE_PLUGINS_YAML}"

# workspace root is the parent dir of .esr/
WORKSPACE_ROOT="${LAYER_BASE}/workspace"

EFF_WS=$(show_config_effective "${ALICE_PLUGINS_YAML}" "${WORKSPACE_PLUGINS_YAML}")
echo "effective (alice user + workspace): ${EFF_WS}"
# workspace layer wins — http_proxy should be empty string.
# The render_config output shows the value; empty string appears as "" in the text.
assert_contains "$EFF_WS" 'http_proxy = ""' \
  "16: empty string from workspace must override user layer"
echo "16: step 4 passed — workspace empty string override wins"

# --- step 5: unset workspace; user layer resumes ----------------------
esr_cli admin submit plugin_unset \
  --arg plugin=claude_code \
  --arg key=http_proxy \
  --arg layer=workspace \
  --arg "_workspace_path_override=${WORKSPACE_PLUGINS_YAML}" \
  --wait --timeout 15 > /dev/null
echo "16: workspace http_proxy unset"

EFF_AFTER_WS_UNSET=$(show_config_effective "${ALICE_PLUGINS_YAML}" "${WORKSPACE_PLUGINS_YAML}")
echo "effective after workspace unset: ${EFF_AFTER_WS_UNSET}"
assert_contains "$EFF_AFTER_WS_UNSET" "http://user:8081" \
  "16: after workspace unset, user layer should resume"
echo "16: step 5 passed — user resumes after workspace unset"

# --- step 6: unset user; global resumes -------------------------------
esr_cli admin submit plugin_unset \
  --arg plugin=claude_code \
  --arg key=http_proxy \
  --arg layer=user \
  --arg "_user_path_override=${ALICE_PLUGINS_YAML}" \
  --wait --timeout 15 > /dev/null
echo "16: alice user http_proxy unset"

EFF_AFTER_USER_UNSET=$(show_config_effective "${ALICE_PLUGINS_YAML}" "")
echo "effective after user unset: ${EFF_AFTER_USER_UNSET}"
assert_contains "$EFF_AFTER_USER_UNSET" "http://global:8080" \
  "16: after user unset, global should resume"
echo "16: step 6 passed — global resumes after user unset"

# --- step 7: bob sees only global (no user override) ------------------
# Bob has no user plugins.yaml — effective falls back to global.
# Passing empty user_path ensures no user-layer file is consulted.
EFF_BOB=$(show_config_effective "" "")
echo "effective (bob / no override): ${EFF_BOB}"
assert_contains "$EFF_BOB" "http://global:8080" \
  "16: bob (no user override) should see global http_proxy"
echo "16: step 7 passed — bob sees global only"

# --- cleanup ----------------------------------------------------------
rm -rf "${LAYER_BASE}" 2>/dev/null || true

echo "PASS: 16_plugin_config_layers"
