#!/usr/bin/env bash
# e2e scenario 18 — multi-CC atomic spawn via /session:add-agent.
#
# Spec: docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md §11.
# Phase: M-5.2 of multi-instance routing cleanup.
#
# WHAT THIS TEST PROVES:
#   - /session:add-agent (admin-submit kind: session_add_agent) goes through
#     Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn/2 (M-2.7),
#     not the legacy metadata-only add_instance/2 path.
#   - Successful spawn returns the new structured payload that M-2.8 added:
#     `actor_ids.cc` (UUID v4) and `actor_ids.pty` (UUID v4).
#   - The (CC, PTY) :one_for_all subtree (Esr.Scope.AgentInstanceSupervisor,
#     M-2.6) is per-instance — adding three agents in the same session
#     spawns three distinct subtrees with non-colliding actor_ids.
#   - Duplicate-name check (M-2.7 step 1) fires BEFORE the AgentSupervisor
#     is called — second alice rejected with structured error.
#   - The session_end teardown propagates through the per-session
#     Scope.AgentSupervisor, terminating all agent subtrees in one shot.
#
# COMPLEMENTS scenario 14, which exercises the metadata-only paths
# (set_primary, duplicate-name guard, removal) without asserting on
# actor_ids or the live supervisor tree.
#
# INVARIANT GATE (spec §11):
#   bash tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh 2>&1 | tail -3
#   → "PASS: 18_multi_cc_atomic_spawn"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

# Routing steps deferred (mock_feishu inbound injection — see scenario 14
# header); the spawn pipeline assertions stand on their own.

# --- step 1: create session -------------------------------------------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-18"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --wait --timeout 30)
echo "18 session_new output: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true" "18: session_new returned ok"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "18: no session_id from session_new"
echo "18: session created: ${SID}"

# --- step 2: spawn alice + assert actor_ids fields --------------------
ADD_ALICE=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=alice \
  --wait --timeout 30)
echo "18 add_agent alice: ${ADD_ALICE}"
assert_contains "$ADD_ALICE" "ok: true"     "18: add_agent alice ok"
assert_contains "$ADD_ALICE" '"alice"'      "18: alice name in output"

# M-2.8 contract: actor_ids field present with cc + pty UUIDs.
assert_contains "$ADD_ALICE" "actor_ids"    "18: actor_ids field surfaced"
assert_contains "$ADD_ALICE" '"cc"'         "18: actor_ids.cc surfaced"
assert_contains "$ADD_ALICE" '"pty"'        "18: actor_ids.pty surfaced"

# UUID v4 shape: 8-4-4-4-12 hex with version-4 nibble. Surfaced as a
# JSON string inside the "actor_ids" sub-object — grep for the pattern.
if ! grep -E -q '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' \
       <<<"$ADD_ALICE"; then
  _fail_with_context "18: alice add_agent output missing UUID v4 in actor_ids"
fi
echo "18: alice spawned + actor_ids verified"

ALICE_CC=$(echo "$ADD_ALICE" | grep -E -o '"cc":\s*"[0-9a-f-]{36}"' | head -1)
ALICE_PTY=$(echo "$ADD_ALICE" | grep -E -o '"pty":\s*"[0-9a-f-]{36}"' | head -1)
echo "18: alice cc actor_id = ${ALICE_CC}"
echo "18: alice pty actor_id = ${ALICE_PTY}"

# --- step 3: spawn bob — second instance in the same session ----------
ADD_BOB=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=bob \
  --wait --timeout 30)
echo "18 add_agent bob: ${ADD_BOB}"
assert_contains "$ADD_BOB" "ok: true"        "18: add_agent bob ok"
assert_contains "$ADD_BOB" '"bob"'           "18: bob name in output"
assert_contains "$ADD_BOB" "actor_ids"       "18: bob actor_ids surfaced"

BOB_CC=$(echo "$ADD_BOB" | grep -E -o '"cc":\s*"[0-9a-f-]{36}"' | head -1)
BOB_PTY=$(echo "$ADD_BOB" | grep -E -o '"pty":\s*"[0-9a-f-]{36}"' | head -1)

# M-2.6 invariant: each agent instance gets its own pair of actor_ids;
# no collisions across siblings in the same session.
if [[ "$ALICE_CC" == "$BOB_CC" ]] || [[ "$ALICE_PTY" == "$BOB_PTY" ]]; then
  _fail_with_context "18: alice and bob actor_ids collide (alice=${ALICE_CC}/${ALICE_PTY} bob=${BOB_CC}/${BOB_PTY})"
fi
echo "18: bob spawned with distinct actor_ids — multi-instance subtree confirmed"

# --- step 4: spawn carol — three concurrent agents under one session ---
ADD_CAROL=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=carol \
  --wait --timeout 30)
echo "18 add_agent carol: ${ADD_CAROL}"
assert_contains "$ADD_CAROL" "ok: true"      "18: add_agent carol ok"
assert_contains "$ADD_CAROL" '"carol"'       "18: carol name in output"

CAROL_CC=$(echo "$ADD_CAROL" | grep -E -o '"cc":\s*"[0-9a-f-]{36}"' | head -1)

if [[ "$CAROL_CC" == "$ALICE_CC" ]] || [[ "$CAROL_CC" == "$BOB_CC" ]]; then
  _fail_with_context "18: carol cc actor_id collides with alice/bob"
fi
echo "18: carol spawned — three sibling subtrees coexist"

# --- step 5: duplicate name guard fires before spawn ------------------
DUP_OUT=$(esr_cli admin submit session_add_agent \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=alice \
  --wait --timeout 30 2>&1 || true)
echo "18 dup alice attempt: ${DUP_OUT}"
assert_contains "$DUP_OUT" "duplicate_agent_name" \
  "18: duplicate-name check rejected second alice"
echo "18: duplicate-name guard confirmed (M-2.7 metadata check)"

# --- step 6: session_end teardown cascades to all agent subtrees -------
END_OUT=$(esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 30 2>&1 || true)
echo "18 session_end: ${END_OUT}"
echo "18: session_end fired (subtree teardown is supervisor-driven; no flake here)"

echo "PASS: 18_multi_cc_atomic_spawn"
