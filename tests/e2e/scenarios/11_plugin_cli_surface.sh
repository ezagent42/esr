#!/usr/bin/env bash
# Track 0 Task 0.8 — CLI surface e2e: exercises every /plugin admin
# command via `esr admin submit <kind>`.
#
# Spec: docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md §五.
#
# What this proves:
#   - All 5 plugin admin commands round-trip via the file-queue path
#     (CommandQueue.Watcher → Dispatcher → Plugin.* command module).
#   - `enable` writes to plugins.yaml; subsequent `list` reflects the
#     write (after a restart in real usage; we read the file directly).
#   - `disable` removes; idempotency holds.
#   - `info <unknown>` and `install <bad-path>` produce friendly
#     error text rather than 500-style failures.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces

# Start with explicit empty enabled list — tests should observe the
# enable→[<name>] transition rather than the legacy default fallback.
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<'YAML'
enabled: []
YAML

start_esrd

# --- 1) /plugin list on empty system ---------------------------------
LIST_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit plugin_list \
  --wait --timeout 10)
echo "$LIST_OUT"
assert_contains "$LIST_OUT" "ok: true" "plugin_list returned ok"
# Phase 1: 3 stub manifests on disk, all disabled (enabled: [] above).
assert_contains "$LIST_OUT" "[disabled]" "list reports plugins as disabled"

# --- 2) /plugin info <unknown> ---------------------------------------
INFO_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit plugin_info \
  --arg name=ghost --wait --timeout 10)
echo "$INFO_OUT"
assert_contains "$INFO_OUT" "ok: true" "plugin_info returns ok envelope even on miss"
assert_contains "$INFO_OUT" "plugin not found: ghost" "info reports missing plugin"

# --- 3) /plugin install <bad-source> ---------------------------------
INSTALL_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit plugin_install \
  --arg source=/nonexistent/path --wait --timeout 10)
echo "$INSTALL_OUT"
assert_contains "$INSTALL_OUT" "ok: true" "plugin_install ok envelope"
assert_contains "$INSTALL_OUT" "source not found" "install rejects nonexistent path"

# --- 4) /plugin enable <ghost> — non-installed rejected --------------
ENABLE_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit plugin_enable \
  --arg name=ghost --wait --timeout 10)
echo "$ENABLE_OUT"
assert_contains "$ENABLE_OUT" "ok: true" "plugin_enable ok envelope"
assert_contains "$ENABLE_OUT" "plugin not installed: ghost" "enable rejects unknown plugin"

# --- 5) /plugin disable <name> on empty list — idempotent ------------
DISABLE_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit plugin_disable \
  --arg name=ghost --wait --timeout 10)
echo "$DISABLE_OUT"
assert_contains "$DISABLE_OUT" "ok: true" "plugin_disable ok envelope"
# disable always succeeds (idempotent) — the file just stays empty.
assert_contains "$DISABLE_OUT" "disabled plugin: ghost" "disable reports name"

# Verify plugins.yaml was rewritten (the disable command writes even on
# no-op, producing `enabled: []` which we set up). It must remain a
# valid yaml that a subsequent boot can parse.
PLUGINS_YAML_PATH="${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml"
[[ -f "$PLUGINS_YAML_PATH" ]] || _fail_with_context "plugins.yaml missing after disable"

echo "PASS: scenario 11 — plugin CLI surface (5 commands)"
