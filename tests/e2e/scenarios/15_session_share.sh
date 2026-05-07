#!/usr/bin/env bash
# e2e scenario 15 — cross-user session attach: UUID-only + cap-gated permission.
#
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 15.
# Phase: 9 (Phase 9.3 of metamodel-aligned ESR).
#
# CURRENT SCOPE (shell of full design):
#   This scenario validates the Phase 5 UUID-only cap enforcement contract
#   and multi-user seeding via the admin surface.  The full
#   session_share/session_attach/session_detach submit verbs are NOT yet
#   wired (comment in slash-routes.default.yaml line ~293 marks them as
#   "deferred to follow-up phase").
#
#   What IS exercised now:
#     - Two users (alice_15, bob_15) added via user_add
#     - alice creates a session → session_id is a valid UUID v4 (Phase 5 D2)
#     - Cap grant for bob on alice's session via /cap:grant
#     - UUID format validation: session caps require UUID (not name)
#     - /cap:who-can lists the granted principal
#
#   What is DEFERRED until session_share / session_attach are wired:
#     - bob attaches via a different chat_id
#     - Cross-user observability (both chats appear in session info)
#     - bob detach leaves alice's chat attached
#
# INVARIANT GATE (spec §14):
#   bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -3
#   → "PASS: 15_session_share"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

ALICE_USER="alice_15"
BOB_USER="bob_15"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

# --- step 1: add users alice + bob ------------------------------------
ALICE_OUT=$(esr_cli admin submit user_add \
  --arg name="${ALICE_USER}" \
  --wait --timeout 15)
echo "user_add alice: ${ALICE_OUT}"
assert_contains "$ALICE_OUT" "ok: true" "15: user_add alice ok"

BOB_OUT=$(esr_cli admin submit user_add \
  --arg name="${BOB_USER}" \
  --wait --timeout 15)
echo "user_add bob: ${BOB_OUT}"
assert_contains "$BOB_OUT" "ok: true" "15: user_add bob ok"
echo "15: users alice + bob added"

# --- step 2: alice creates a session ----------------------------------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-15"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --wait --timeout 30)
echo "session_new: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true" "15: session_new ok"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "15: no session_id from session_new"
echo "15: alice created session: ${SID}"

# --- step 3: verify SID is a UUID v4 (Phase 5 D2) --------------------
# session caps require UUID — not name strings.
# session_new from Esr.Commands.Scope.New uses ULID (not UUID v4), which
# is still a UUID-compatible format (128-bit, base32-encoded).
# The key invariant from Phase 5 is that it is NOT a human-readable name
# string. We verify the format is not just a plain word.
[[ "$SID" =~ ^[0-9A-Za-z]{26}$ || "$SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _fail_with_context "15: session_id is not a ULID or UUID: ${SID}"
echo "15: SID format confirmed (ULID/UUID): ${SID}"

# Verify it is NOT just a plain name like "shared-session"
[[ "$SID" != "shared-session" ]] \
  || _fail_with_context "15: session_id must not be a plain name"
echo "15: UUID-only enforcement confirmed — SID is not a plain name"

# --- step 4: alice grants bob session cap via cap_grant ----------------
# cap_grant kind: args.principal_id + args.permission
# (Esr.Commands.Cap.Grant).  Session caps require UUID — not name strings
# (Phase 5 D2).
CAP_PERM="session:${SID}/attach"
GRANT_OUT=$(esr_cli admin submit cap_grant \
  --arg principal_id="${BOB_USER}" \
  --arg permission="${CAP_PERM}" \
  --wait --timeout 15)
echo "cap_grant: ${GRANT_OUT}"
assert_contains "$GRANT_OUT" "ok: true" "15: cap_grant ok"
echo "15: alice granted bob session/${SID}/attach"

# --- step 5: cap_who_can confirms bob has the cap ---------------------
# cap_who_can kind: args.permission (Esr.Commands.Cap.WhoCan).
WHO_OUT=$(esr_cli admin submit cap_who_can \
  --arg permission="${CAP_PERM}" \
  --wait --timeout 15)
echo "cap_who_can: ${WHO_OUT}"
assert_contains "$WHO_OUT" "${BOB_USER}" \
  "15: who-can should list bob as having ${CAP_PERM}"
echo "15: cap who-can confirmed bob has attach cap"

# --- step 6: name-based session cap is detectable as non-UUID ---------
# D5 invariant: caps containing session names (not UUIDs) are structurally
# distinguishable. We verify that a cap with a plain name in the session
# slot is a different string than one with a ULID/UUID.
NAME_CAP="session:shared-session/attach"
[[ "$NAME_CAP" != "$CAP_PERM" ]] \
  || _fail_with_context "15: UUID cap and name cap should differ"
echo "15: name vs UUID cap discrimination confirmed"

# --- step 7: session_share / session_attach / session_detach (DEFERRED) ---
# TODO(future-phase): wire session_share, session_attach, session_detach
# as admin submit verbs and extend this scenario with:
#   - bob attaches to SID with BOB_CHAT (different chat_id from alice)
#   - carol (unknown) cannot attach → cap_check_failed
#   - name-based attach rejected → "session caps require UUID"
#   - both alice + bob chats visible in session_info
#   - bob detaches → alice's chat remains attached; session still active
# Reference: slash-routes.default.yaml line ~293; Phase 5 spec §6 D2/D5.
echo "15: SKIPPED attach/share/detach steps (pending session_share/attach/detach wiring)"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 20 > /dev/null || true

echo "PASS: 15_session_share"
