#!/usr/bin/env bash
# e2e scenario 17 — plugin config hot-reload: env propagation via mock-claude binary.
#
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md
# Phase: HR-4 (hot-reload sub-phase, 2026-05-07 user choice B).
#
# WHAT THIS TEST PROVES (operator-grade):
#   The full chain:
#     plugin_set http_proxy  →  plugin_reload claude_code
#     →  session_remove_agent / session_add_agent  (subprocess restart)
#     →  new cc subprocess inherits the new HTTP_PROXY env value
#
#   Concretely:
#     1. esrd starts with claude_code.claude_binary = mock-claude.sh
#        (so no real Anthropic API is needed)
#     2. mock-claude writes its env snapshot to a temp file on startup
#     3. First spawn: no proxy → dump file has proxy=-NONE-
#     4. plugin_set http_proxy=http://192.0.2.1:8080 + plugin_reload
#     5. session_remove_agent + session_add_agent → subprocess restart
#     6. Second spawn: new env → dump file has proxy=http://192.0.2.1:8080
#
# INVARIANT GATE (spec §14):
#   bash tests/e2e/scenarios/17_plugin_config_hot_reload.sh 2>&1 | tail -3
#   → "PASS: 17_plugin_config_hot_reload"
#
# Note: The "no proxy → 403" step from the user story is represented by
# asserting proxy=-NONE- in the first dump (not a real TCP probe; the
# mock binary makes env assertion sufficient and deterministic).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# Absolute path to the mock-claude binary.
MOCK_CLAUDE_BIN="${_E2E_REPO_ROOT}/tests/e2e/fixtures/mock-claude.sh"

# Side-channel file that mock-claude writes its env snapshot to.
# Each agent restart overwrites this file; we assert per-phase.
MOCK_DUMP_FILE="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/mock-claude-dump.txt"

# RFC 5737 test IP — never routes to a real proxy, but is a valid URL.
TEST_PROXY="http://192.0.2.1:8080"

# Temp workdir for the cc agent.
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-17"

mkdir -p "$(dirname "${MOCK_DUMP_FILE}")" "${WORKDIR}"

# --- validate prerequisite tools ----------------------------------------
for _tool in jq curl; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    _fail_with_context "17: required tool '$_tool' not on PATH"
  fi
done

[[ -x "${MOCK_CLAUDE_BIN}" ]] \
  || _fail_with_context "17: mock-claude binary not executable: ${MOCK_CLAUDE_BIN}"

# --- helpers ------------------------------------------------------------

# Wait for the mock-claude dump file to appear/update after agent restart.
# Mock-claude writes it synchronously on startup, so a 10s wait is generous.
wait_for_dump_file() {
  local label=$1 max_s=${2:-10} elapsed=0
  echo "17: [${label}] waiting for dump file..."
  while [[ ! -s "${MOCK_DUMP_FILE}" ]]; do
    sleep 0.2
    elapsed=$(awk "BEGIN {print $elapsed + 0.2}")
    if awk "BEGIN {exit !($elapsed > $max_s)}"; then
      _fail_with_context "17: [${label}] mock dump file not written after ${max_s}s"
    fi
  done
}

# Read the proxy line from the dump file.
read_dump_proxy() {
  grep '^proxy=' "${MOCK_DUMP_FILE}" | cut -d= -f2- || echo ""
}

# Remove the dump file so the next wait_for_dump_file call is clean.
reset_dump_file() {
  rm -f "${MOCK_DUMP_FILE}"
}

# =====================================================================
# STEP 0: setup
# =====================================================================

# Export ESR_MOCK_CLAUDE_DUMP_FILE so esrd (and its child mock-claude)
# inherit the path. Erlexec adds env vars on top of the inherited OS env,
# so the subprocess sees everything the parent process exported.
export ESR_MOCK_CLAUDE_DUMP_FILE="${MOCK_DUMP_FILE}"

# Seed global plugins.yaml with claude_binary pointing at mock-claude.
# No http_proxy initially (empty string = no proxy).
seed_plugin_config "$(cat <<EXTRA
  claude_code:
    claude_binary: "${MOCK_CLAUDE_BIN}"
EXTRA
)"

seed_capabilities
start_esrd

echo "17: esrd started with mock-claude binary"

# =====================================================================
# STEP 1: create session
# =====================================================================

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --wait --timeout 30)
echo "17: session_new: ${SESSION_OUT}"
assert_contains "${SESSION_OUT}" "ok: true" "17: session_new returned ok"

SID=$(echo "${SESSION_OUT}" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "${SID}" ]] || _fail_with_context "17: no session_id from session_new"
echo "17: session created: ${SID}"

# =====================================================================
# STEP 2: add agent alice (spawns mock-claude subprocess)
# =====================================================================

# Reset dump file before adding agent (subprocess writes it on startup).
reset_dump_file

ADD_ALICE=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=alice \
  --wait --timeout 20)
echo "17: add_agent alice: ${ADD_ALICE}"
assert_contains "${ADD_ALICE}" "ok: true" "17: add_agent alice ok"
echo "17: agent alice added (mock-claude subprocess spawning)"

# =====================================================================
# STEP 3: assert NO proxy in first spawn
# =====================================================================

wait_for_dump_file "pre-reload" 15
PROXY_BEFORE=$(read_dump_proxy)
echo "17: pre-reload env dump: proxy=${PROXY_BEFORE}"
assert_contains "${PROXY_BEFORE}" "-NONE-" \
  "17: step 3 — no http_proxy before reload; got proxy='${PROXY_BEFORE}'"
echo "17: step 3 PASS — proxy is absent before hot-reload"

# =====================================================================
# STEP 4: set http_proxy + reload plugin
# =====================================================================

SET_OUT=$(esr_cli admin submit plugin_set \
  --arg plugin=claude_code \
  --arg key=http_proxy \
  --arg value="${TEST_PROXY}" \
  --arg layer=global \
  --wait --timeout 15)
echo "17: plugin_set: ${SET_OUT}"
assert_contains "${SET_OUT}" "ok: true" "17: plugin_set http_proxy ok"

RELOAD_OUT=$(esr_cli admin submit plugin_reload \
  --arg plugin=claude_code \
  --wait --timeout 15)
echo "17: plugin_reload: ${RELOAD_OUT}"
assert_contains "${RELOAD_OUT}" "reloaded" \
  "17: plugin_reload must return reloaded in output"
assert_contains "${RELOAD_OUT}" "http_proxy" \
  "17: plugin_reload changed_keys must include http_proxy"
echo "17: step 4 PASS — plugin_reload acknowledged http_proxy change"

# =====================================================================
# STEP 5: restart the cc agent (remove + re-add)
#
# Hot-reload updates the effective config for NEW spawns.
# The running subprocess already has its env fixed at spawn time.
# Restart = remove alice (kills subprocess) + add alice again (new subprocess
#           inherits the updated config from Plugin.Config.resolve/2).
# =====================================================================

# Remove alice. Because alice was the only agent (not primary in multi-agent
# sense), we may need to handle the "cannot remove primary" guard.
# session_add_agent auto-sets the first agent as primary (scenario 14 confirms).
# For a single-agent session we must set a different primary before removal,
# OR end the session entirely and create a new one.
#
# Simplest: end the session and create a fresh one for the second spawn.
# This is the real operator workflow ("restart cc").

esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 20 >/dev/null || true
echo "17: session ended (agent alice terminated)"

# Wait briefly for the teardown to propagate.
sleep 0.5

# Create a new session for the post-reload spawn.
SESSION2_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --wait --timeout 30)
echo "17: session_new (2nd): ${SESSION2_OUT}"
assert_contains "${SESSION2_OUT}" "ok: true" "17: session_new (2nd) returned ok"

SID2=$(echo "${SESSION2_OUT}" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "${SID2}" ]] || _fail_with_context "17: no session_id from 2nd session_new"
echo "17: second session created: ${SID2}"

# =====================================================================
# STEP 6: add alice again (new subprocess with post-reload config)
# =====================================================================

# Reset dump file before second spawn.
reset_dump_file

ADD_ALICE2=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID2}" \
  --arg type=cc \
  --arg name=alice \
  --wait --timeout 20)
echo "17: add_agent alice (2nd): ${ADD_ALICE2}"
assert_contains "${ADD_ALICE2}" "ok: true" "17: add_agent alice (2nd) ok"
echo "17: agent alice added (2nd mock-claude subprocess spawning)"

# =====================================================================
# STEP 7: assert proxy NOW present in second spawn
# =====================================================================

wait_for_dump_file "post-reload" 15
PROXY_AFTER=$(read_dump_proxy)
echo "17: post-reload env dump: proxy=${PROXY_AFTER}"
assert_contains "${PROXY_AFTER}" "192.0.2.1:8080" \
  "17: step 7 — http_proxy must be present after reload+restart; got proxy='${PROXY_AFTER}'"
echo "17: step 7 PASS — new subprocess received updated HTTP_PROXY from plugin config"

# =====================================================================
# STEP 8: cleanup
# =====================================================================

esr_cli admin submit session_end \
  --arg session_id="${SID2}" \
  --wait --timeout 20 >/dev/null || true

reset_dump_file
rm -rf "${WORKDIR}" 2>/dev/null || true

echo "PASS: 17_plugin_config_hot_reload"
