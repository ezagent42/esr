#!/usr/bin/env bash
# scenario 29 — external-path bundle install via /plugin:install.
#
# Spec: docs/superpowers/specs/2026-05-10-session-template-and-channel.md §10.1
# Plan: docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md Task 4.7
#
# What this proves:
#   1. A bundle dir copied OUTSIDE the in-tree path (`/tmp/external_bundle/`)
#      can be installed via `/plugin:install --source=...` and lands in
#      `runtime/lib/esr/bundles/<bundle_name>/` per Phase 4 install logic.
#   2. The bundle's template registers in Esr.SessionTemplate.Registry
#      under the template's own name (which can differ from the bundle dir
#      name — bundle name = dir basename of the copied target;
#      template name = whatever the template.yaml's `name:` says).
#   3. Phase 5+ extension (commented): /session:new template=<tname> works
#      after the bundle install with both feishu + claude_code enabled.
#   4. Phase 5+ extension (commented): /plugin:disable <bundle> auto-
#      deregisters the template via Bundle.Loader.unload.
#
# Phase 4 stops at the install + registration assertions.
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/29_external_bundle_install.sh 2>&1 | tail -3
#   → "PASS: 29_external_bundle_install"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces

# Both feishu + claude_code enabled — this scenario tests the happy
# install path (deps satisfied), not the missing-dep skip (covered by
# scenario 27).
mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
cat > "${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml" <<'YAML'
enabled:
  - feishu
  - claude_code
YAML

# --- step 1: prepare an external bundle dir at /tmp/<run_id>/external_bundle
EXTERNAL_BUNDLE_PARENT="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/external"
EXTERNAL_BUNDLE_DIR="${EXTERNAL_BUNDLE_PARENT}/external-bundle"
rm -rf "$EXTERNAL_BUNDLE_PARENT"
mkdir -p "$EXTERNAL_BUNDLE_DIR"

echo "STEP 1: stage external bundle dir at $EXTERNAL_BUNDLE_DIR"

# Bundle dir name `external-bundle`, template `name:` `feishu-ext-cc`
# — exercises the "bundle name ≠ template name" path from the plan.
cat > "${EXTERNAL_BUNDLE_DIR}/manifest.yaml" <<'YAML'
schema_version: 1
name: external-bundle
version: 0.1.0
description: External-path test bundle (scenario 29)
dependencies:
  plugins: [feishu, claude_code]
  bundles: []
YAML

cat > "${EXTERNAL_BUNDLE_DIR}/template.yaml" <<'YAML'
schema_version: 1
name: feishu-ext-cc
description: External bundle template (scenario 29)
channels:
  - alias: in
    kind: feishu.chat_proxy
    config:
      app_id: <runtime>
      chat_id: <runtime>
  - alias: cc_mcp
    kind: claude_code.mcp_http
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

echo "  ok: external bundle staged at $EXTERNAL_BUNDLE_DIR"

# --- step 2: start esrd ----------------------------------------------
start_esrd

LOG="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
[[ -f "$LOG" ]] || _fail_with_context "expected esrd log at $LOG"

# --- step 3: invoke /plugin:install --source=$EXTERNAL_BUNDLE_DIR ----
echo "STEP 3: /plugin:install --source=$EXTERNAL_BUNDLE_DIR"

# kind name for plugin_install per slash-routes:default.yaml.
INSTALL_OUT=$(esr_cli admin submit plugin_install \
  --arg source="$EXTERNAL_BUNDLE_DIR" --wait --timeout 30)
echo "$INSTALL_OUT"

# Bundle install path produces "installed bundle: <bundle_name>" text.
assert_contains "$INSTALL_OUT" "installed bundle: external-bundle" \
  "install reports bundle name 'external-bundle'"
assert_contains "$INSTALL_OUT" "template registered" \
  "install reports template registered (deps satisfied)"

echo "  ok: install reports bundle install + template registered"

# --- step 4: assert log shows boot-time + install-time registration ---
echo "STEP 4: log mentions registered bundle=external-bundle"

if ! grep -qE "bundle loader: registered bundle=external-bundle" "$LOG"; then
  echo "--- esrd log tail ---" >&2
  tail -n 80 "$LOG" >&2 || true
  _fail_with_context "expected log to contain 'registered bundle=external-bundle'"
fi

echo "  ok: log confirms external-bundle template registration"

# --- step 5: assert the bundle dir was copied to the in-tree path ----
# /plugin:install copies external dirs to runtime/lib/esr/bundles/<bundle_name>/
# (subject to test-time env override; in production e2e it's the real path).
# The in-tree path is the dev source layout: <repo_root>/runtime/lib/esr/bundles/
echo "STEP 5: assert the bundle dir landed at the in-tree path"

INTREE_BUNDLE_DIR="${_E2E_REPO_ROOT}/runtime/lib/esr/bundles/external-bundle"

if [[ ! -d "$INTREE_BUNDLE_DIR" ]]; then
  echo "--- expected bundle at $INTREE_BUNDLE_DIR but it's absent ---" >&2
  _fail_with_context "external bundle should have been copied to runtime/lib/esr/bundles/external-bundle"
fi

[[ -f "$INTREE_BUNDLE_DIR/manifest.yaml" ]] \
  || _fail_with_context "expected manifest.yaml at $INTREE_BUNDLE_DIR"
[[ -f "$INTREE_BUNDLE_DIR/template.yaml" ]] \
  || _fail_with_context "expected template.yaml at $INTREE_BUNDLE_DIR"

echo "  ok: bundle dir copied to in-tree path"

# --- step 6: cleanup the in-tree bundle so subsequent runs are pristine
# IMPORTANT: this scenario MUTATES the in-tree path. Without cleanup, a
# second run hits the "bundle already installed" rejection. The teardown
# below must run on PASS or FAIL — guard with a cleanup func + EXIT trap.
_cleanup_external_bundle() {
  rm -rf "$INTREE_BUNDLE_DIR" || true
  rm -rf "$EXTERNAL_BUNDLE_PARENT" || true
}
trap '_cleanup_external_bundle; _on_exit' EXIT

echo "STEP 6: cleanup hook registered"

# --- Phase 5+ extensions (commented; covered when /session:new template= lands) ---
# step 7: /session:new template=feishu-ext-cc name=foo → succeeds
# step 8: /plugin:disable external-bundle → template gone from registry
#         BUT existing session foo still works (frozen template)
#
# These rely on Phase 5's template consumer + Phase 6's /plugin:disable
# bundle-aware unload — outside Phase 4's scope.

echo "PASS: 29_external_bundle_install"
