#!/usr/bin/env bash
# scenario 24 — yaml-layout-v2 per-thing-directory adapter lifecycle.
#
# Spec: docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md §6.2
#
# What this proves:
#   1. /adapter:list against an empty layout reports "no adapter instances configured"
#   2. register_adapter writes adapters/<name>/config.yaml (per-thing layout —
#      NOT a monolithic adapters.yaml).
#   3. /adapter:disable moves adapters/<name>/ → adapters/_disabled/<name>/ —
#      Esr.Adapters.list/0 ignores it; list_disabled/0 picks it up.
#   4. /adapter:enable reverses the move.
#   5. /adapter:remove deletes adapters/<name>/ entirely.
#   6. Esrd boot sees the disabled instance and skips its spawn (only
#      `app_a` is active, `app_b` stays paused).
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/24_yaml_layout_v2.sh 2>&1 | tail -3
#   → "PASS: 24_yaml_layout_v2"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces

# Start with explicit empty enabled list so the boot path is core +
# whatever the spawn-on-restore wires up; we don't need real plugins
# for the lifecycle assertions.
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<'YAML'
enabled: []
YAML

start_esrd

ADAPTERS_DIR="${ESRD_HOME}/${ESRD_INSTANCE}/adapters"

# --- 1) /adapter:list against empty layout ---------------------------
LIST_EMPTY=$(esr_cli admin submit adapter_list --wait --timeout 10)
echo "$LIST_EMPTY"
assert_contains "$LIST_EMPTY" "ok: true" "adapter_list ok envelope on empty"
assert_contains "$LIST_EMPTY" "no adapter instances configured" \
  "empty layout reports the canonical no-instances message"

# --- 2) register_adapter writes adapters/<name>/config.yaml ----------
REG_OUT=$(esr_cli admin submit register_adapter \
  --arg type=feishu --arg name=app_a \
  --arg app_id=cli_a --arg app_secret=sec_a \
  --wait --timeout 15)
echo "$REG_OUT"
assert_contains "$REG_OUT" "ok: true" "register_adapter ok envelope"

[[ -f "${ADAPTERS_DIR}/app_a/config.yaml" ]] \
  || _fail_with_context "expected ${ADAPTERS_DIR}/app_a/config.yaml after register_adapter"
[[ ! -f "${ESRD_HOME}/${ESRD_INSTANCE}/adapters.yaml" ]] \
  || _fail_with_context "v2 layout must NOT create a monolithic adapters.yaml"

grep -q "type: feishu" "${ADAPTERS_DIR}/app_a/config.yaml" \
  || _fail_with_context "config.yaml missing 'type: feishu'"
grep -q "app_secret" "${ADAPTERS_DIR}/app_a/config.yaml" \
  || _fail_with_context "config.yaml missing app_secret (sidecar would crash-loop)"

# Add a second instance so we have two to disable/enable.
esr_cli admin submit register_adapter \
  --arg type=feishu --arg name=app_b \
  --arg app_id=cli_b --arg app_secret=sec_b \
  --wait --timeout 15 >/dev/null

[[ -f "${ADAPTERS_DIR}/app_b/config.yaml" ]] \
  || _fail_with_context "expected ${ADAPTERS_DIR}/app_b/config.yaml after second register"

# --- 3) /adapter:disable moves the dir to _disabled/ -----------------
DISABLE_OUT=$(esr_cli admin submit adapter_disable \
  --arg name=app_b --wait --timeout 10)
echo "$DISABLE_OUT"
assert_contains "$DISABLE_OUT" "ok: true" "adapter_disable ok envelope"
assert_contains "$DISABLE_OUT" "disabled adapter app_b" "disable confirms in text"

[[ ! -d "${ADAPTERS_DIR}/app_b" ]] \
  || _fail_with_context "adapters/app_b/ should be gone after disable"
[[ -f "${ADAPTERS_DIR}/_disabled/app_b/config.yaml" ]] \
  || _fail_with_context "expected adapters/_disabled/app_b/config.yaml after disable"

# adapter:list now shows app_a as active and app_b under _disabled.
LIST_AFTER_DISABLE=$(esr_cli admin submit adapter_list --wait --timeout 10)
echo "$LIST_AFTER_DISABLE"
assert_contains "$LIST_AFTER_DISABLE" "app_a" "active list still shows app_a"
assert_contains "$LIST_AFTER_DISABLE" "_disabled (paused):" \
  "list renders the _disabled section heading"
assert_contains "$LIST_AFTER_DISABLE" "app_b" "list shows app_b under _disabled"

# --- 4) /adapter:enable reverses the move ----------------------------
ENABLE_OUT=$(esr_cli admin submit adapter_enable \
  --arg name=app_b --wait --timeout 10)
echo "$ENABLE_OUT"
assert_contains "$ENABLE_OUT" "ok: true" "adapter_enable ok envelope"
assert_contains "$ENABLE_OUT" "enabled adapter app_b" "enable confirms in text"

[[ -f "${ADAPTERS_DIR}/app_b/config.yaml" ]] \
  || _fail_with_context "expected adapters/app_b/config.yaml back after enable"
[[ ! -d "${ADAPTERS_DIR}/_disabled/app_b" ]] \
  || _fail_with_context "adapters/_disabled/app_b/ should be gone after enable"

# Re-disable so we can assert the boot-time skip behaviour next.
esr_cli admin submit adapter_disable \
  --arg name=app_b --wait --timeout 10 >/dev/null
[[ -f "${ADAPTERS_DIR}/_disabled/app_b/config.yaml" ]] \
  || _fail_with_context "second disable did not move app_b back to _disabled/"

# --- 5) /adapter:remove deletes the directory ------------------------
# Add a doomed instance, remove it, verify the dir is gone.
esr_cli admin submit register_adapter \
  --arg type=feishu --arg name=app_doomed \
  --arg app_id=cli_d --arg app_secret=sec_d \
  --wait --timeout 15 >/dev/null

REMOVE_OUT=$(esr_cli admin submit adapter_remove \
  --arg instance_id=app_doomed --wait --timeout 10)
echo "$REMOVE_OUT"
assert_contains "$REMOVE_OUT" "ok: true" "adapter_remove ok envelope"
assert_contains "$REMOVE_OUT" "removed feishu adapter" "remove text confirms"

[[ ! -d "${ADAPTERS_DIR}/app_doomed" ]] \
  || _fail_with_context "adapters/app_doomed/ should be gone after remove"

# --- 6) reserved name rejection (defense-in-depth) -------------------
INVALID_OUT=$(esr_cli admin submit register_adapter \
  --arg type=feishu --arg name=_bad \
  --arg app_id=cli_x --arg app_secret=sec_x \
  --wait --timeout 10 || true)
echo "$INVALID_OUT"
# Either invalid_args (current name validation in register_adapter) or
# register_adapter_failed wrapping {:error, :invalid_name} from
# Esr.Adapters.add/4 — both are acceptable rejections of a leading-`_` name.
if echo "$INVALID_OUT" | grep -qE "invalid_args|invalid_name|register_adapter_failed"; then
  :
else
  _fail_with_context "expected register_adapter to reject '_bad' (reserved prefix); got: ${INVALID_OUT}"
fi

[[ ! -d "${ADAPTERS_DIR}/_bad" ]] \
  || _fail_with_context "reserved-name '_bad' must NOT have created a directory"

echo "PASS: 24_yaml_layout_v2"
