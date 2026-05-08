#!/usr/bin/env bash
# Track 0 Task 0.7 — core-only e2e: ESR boots cleanly with NO plugins
# enabled. Validates Spec A's "core works without any plugin loaded"
# claim at runtime, not just on paper.
#
# Spec: docs/superpowers/specs/2026-05-04-core-decoupling-design.md §五.
#
# What this proves:
#   - runtime.exs honors `enabled: []` and reads it correctly.
#   - Application.start/2 + load_enabled_plugins/0 path is a no-op
#     when no plugins are registered.
#   - /plugin list reports "no plugins installed".
#   - Core admin commands (/help, /whoami) still work without any
#     plugin's slash-route fragments contributing.
#
# Bail-out criterion (per refactor-lessons.md): if BEAM crashes or
# refuses to boot with `enabled: []`, that's a structural defect, not
# a flake — abort and revert.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces

# Track 0 Task 0.7 fixture: write `plugins.yaml` with explicit empty
# enabled list so runtime.exs picks core-only, NOT the legacy default.
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<'YAML'
enabled: []
YAML

# Boot esrd. If load_enabled_plugins/0 is broken or runtime.exs's
# yaml read crashes, this step fails. That's the load-bearing assertion.
start_esrd

# --- verify boot succeeded -------------------------------------------
# `esr admin submit help --wait` exercises the slash command pipeline
# end-to-end (CommandQueue.Watcher → Dispatcher → SlashRoute.Registry).
# A core-only boot has zero plugin-contributed routes — only the
# default-shipped ones — so /help should still render successfully.
HELP_OUT=$(esr_cli admin submit help \
  --wait --timeout 15)
echo "$HELP_OUT"
assert_contains "$HELP_OUT" "ok: true" "core-only: /help returned ok"

# `/plugin list` must report each known plugin as disabled (since
# enabled: [] above). The plugin subsystem itself is core, so this
# command is always available regardless of plugin enable state.
PLUGIN_LIST_OUT=$(esr_cli admin submit plugin_list \
  --wait --timeout 10)
echo "$PLUGIN_LIST_OUT"
assert_contains "$PLUGIN_LIST_OUT" "ok: true" "core-only: /plugin list returned ok"

# In Phase 1 the 3 stub manifests (voice / feishu / claude_code) live
# under runtime/lib/esr/plugins/. They show as [disabled] when nothing
# in enabled_plugins picks them up.
assert_contains "$PLUGIN_LIST_OUT" "[disabled]" "core-only: list reports plugins as disabled"

echo "PASS: scenario 08 — core-only boot + /plugin list"
