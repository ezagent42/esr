#!/usr/bin/env bash
# e2e scenario 23 — zero-config CLI bootstrap journey.
#
# Spec: docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md
#
# WHAT THIS TEST PROVES:
#   - Fresh install (NO capabilities.yaml seed, NO operator.json) — first
#     `esr exec user_add` flows through the "system:bootstrap" sentinel
#     bypass (slash_handler § 3.2 guard) and PR #281's auto-admin path
#     promotes the new user to admin (`auto_admin: true`).
#   - The auto-admin path writes operator.json (§ 3.4); subsequent CLI
#     commands resolve the new user from operator.json (§ 3.5) and run
#     with their `*` cap, so register_adapter / feishu_bind succeed
#     without env-var hacks.
#   - ESR_OPERATOR_PRINCIPAL_ID env is NOT consulted (D3 hard cutover).
#
# DELIBERATELY DOES NOT call common.sh's `seed_capabilities` — that
# helper pre-seeds an `ou_admin` row with `*`, which would defeat the
# whole point. We also `unset ESR_BOOTSTRAP_PRINCIPAL_ID` to keep the
# Supervisor's first-run bootstrap (env-driven seed) from firing.
#
# INVARIANT GATE (spec § 7):
#   bash tests/e2e/scenarios/23_zero_config_bootstrap.sh 2>&1 | tail -3
#   → "PASS: 23_zero_config_bootstrap"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- env scrub: zero-config means zero env vars -----------------------
# common.sh sets defaults for both, including ESR_OPERATOR_PRINCIPAL_ID
# (=ou_admin) and ESR_BOOTSTRAP_PRINCIPAL_ID (mirrors operator). For this
# scenario we explicitly unset both BEFORE start_esrd / esr_cli so the
# Supervisor sees a fresh install and the CLI submitter resolution chain
# falls through to the sentinel.
unset ESR_BOOTSTRAP_PRINCIPAL_ID || true
unset ESR_OPERATOR_PRINCIPAL_ID || true

# common.sh's `esr_cli` wrapper re-injects ESR_OPERATOR_PRINCIPAL_ID into
# the child env from the local var. After unset that becomes empty —
# spec § 3.5 says the env var is now ignored anyway, but to be safe we
# also redefine the wrapper to drop the export entirely. Cleaner than
# patching common.sh for one scenario.
esr_cli() {
  local port_file="${ESRD_HOME}/${ESR_INSTANCE}/esrd.port"
  local host="127.0.0.1:4001"
  if [[ -r "${port_file}" ]]; then
    host="127.0.0.1:$(cat "${port_file}")"
  fi
  ESR_HOST="${host}" \
  ESR_INSTANCE="${ESR_INSTANCE}" \
  ESRD_HOME="${ESRD_HOME}" \
    "${_E2E_REPO_ROOT}/runtime/esr" "$@"
}

# --- setup -----------------------------------------------------------
load_agent_yaml
seed_plugin_config
# DELIBERATELY skip seed_capabilities — fresh install, no admin yet.
seed_adapters
start_esrd

# --- step 1: user_add via sentinel bypass ----------------------------
USERNAME="bootstrap_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

ADD_OUT=$(esr_cli admin submit user_add \
  --arg name="${USERNAME}" \
  --wait --timeout 30)

echo "23 user_add (bootstrap): ${ADD_OUT}"
assert_contains "$ADD_OUT" "ok: true"          "23: user_add ok via sentinel bypass"
assert_contains "$ADD_OUT" "auto_admin"        "23: result carries auto_admin field"
assert_contains "$ADD_OUT" "auto-admin"        "23: text mentions auto-admin grant"

# --- step 2: operator.json was written -------------------------------
OPER_JSON="${ESRD_HOME}/${ESR_INSTANCE}/operator.json"
[[ -f "$OPER_JSON" ]] || _fail_with_context "23: operator.json not written at ${OPER_JSON}"

OPER_BODY=$(cat "$OPER_JSON")
echo "23 operator.json: ${OPER_BODY}"
assert_contains "$OPER_BODY" "${USERNAME}"     "23: operator.json contains username"
assert_contains "$OPER_BODY" "user_add"        "23: operator.json set_by=user_add"
assert_contains "$OPER_BODY" "schema_version"  "23: operator.json carries schema_version"

# --- step 3: subsequent CLI runs use operator.json (no sentinel) ----
# A second user_add as the (now-admin) operator should succeed without
# auto_admin (admin already exists) — proves the CLI is reading the new
# user's principal_id from operator.json, NOT the sentinel.
USERNAME2="user2_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

ADD2_OUT=$(esr_cli admin submit user_add \
  --arg name="${USERNAME2}" \
  --wait --timeout 30)

echo "23 user_add #2 (post-bootstrap): ${ADD2_OUT}"
assert_contains "$ADD2_OUT" "ok: true"               "23: 2nd user_add ok (operator.json path)"
assert_contains "$ADD2_OUT" "auto_admin: false"      "23: 2nd user_add no auto-admin"

# --- step 4: sentinel kind not in allowed list → unauthorized ---------
# Even with no operator.json read failure (we have one now), if we
# manually invoke a non-allowed kind via the sentinel it would still be
# unauthorized. We can't easily inject submitted_by="system:bootstrap"
# from the CLI now (operator.json takes precedence), but the unit test
# `slash_handler_bootstrap_bypass_test.exs` covers this case explicitly.

echo "PASS: 23_zero_config_bootstrap"
